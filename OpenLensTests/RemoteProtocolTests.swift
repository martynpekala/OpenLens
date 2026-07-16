import CryptoKit
import Foundation
import Testing
@testable import OpenLens

struct RemoteProtocolTests {
    @Test func pairingOfferRoundTripsThroughDeepLink() throws {
        let offer = RemotePairingOffer(
            endpoint: try #require(URL(string: "https://remote.example.com")),
            gatewayID: "gateway-1",
            gatewayPublicKey: Data((0..<32).map(UInt8.init)),
            pairingID: "pairing-1",
            pairingSecret: Data((32..<64).map(UInt8.init)),
            accessCredential: CloudflareAccessCredential(
                clientID: "client-id.access",
                clientSecret: "client-secret"
            ),
            expiresAt: Date(timeIntervalSince1970: 2_000_000_000)
        )

        let url = try #require(offer.deepLinkURL)
        let decoded = try #require(RemotePairingOffer(url: url))

        #expect(decoded == offer)
        #expect(url.absoluteString.contains("accessClientID="))
        #expect(url.absoluteString.contains("accessClientSecret="))
    }

    @Test func unsupportedRemoteProtocolVersionIsRejected() {
        let unsupportedEnvelope = Data(#"{"version":2,"kind":"rejected"}"#.utf8)
        #expect(throws: RemoteProtocolError.unsupportedVersion) {
            _ = try RemoteWireEnvelope.decode(unsupportedEnvelope)
        }
    }

    @Test func pairingLinkRequiresCloudflareAccessCredential() throws {
        let linkWithoutAccessCredential = try #require(URL(string:
            "openlens://remote?endpoint=https%3A%2F%2Fremote.example.com&gatewayID=gateway-1&gatewayKey=AA&pairingID=pair-1&secret=AA&expires=2000000000"
        ))
        #expect(RemotePairingOffer(url: linkWithoutAccessCredential) == nil)
    }

    @Test func authenticatedSessionEncryptsBothDirectionsAndRejectsReplay() throws {
        let gatewayPrivateKey = RemoteCrypto.makeIdentity()
        let devicePrivateKey = RemoteCrypto.makeIdentity()
        let sessionID = "session-1"

        var deviceSender = try RemoteCrypto.deviceSessionSender(
            devicePrivateKey: devicePrivateKey,
            gatewayPublicKey: gatewayPrivateKey.publicKey,
            sessionID: sessionID
        )
        var gatewayRecipient = try RemoteCrypto.gatewaySessionRecipient(
            gatewayPrivateKey: gatewayPrivateKey,
            devicePublicKey: devicePrivateKey.publicKey,
            sessionID: sessionID,
            encapsulatedKey: deviceSender.encapsulatedKey
        )

        let sealedRequest = try deviceSender.seal(Data("request".utf8))
        let openedRequest = try gatewayRecipient.open(
            sequence: sealedRequest.sequence,
            ciphertext: sealedRequest.ciphertext
        )
        #expect(openedRequest == Data("request".utf8))

        #expect(throws: RemoteProtocolError.replayDetected) {
            _ = try gatewayRecipient.open(
                sequence: sealedRequest.sequence,
                ciphertext: sealedRequest.ciphertext
            )
        }

        var gatewaySender = try RemoteCrypto.gatewaySessionSender(
            gatewayPrivateKey: gatewayPrivateKey,
            devicePublicKey: devicePrivateKey.publicKey,
            sessionID: sessionID
        )
        var deviceRecipient = try RemoteCrypto.deviceSessionRecipient(
            devicePrivateKey: devicePrivateKey,
            gatewayPublicKey: gatewayPrivateKey.publicKey,
            sessionID: sessionID,
            encapsulatedKey: gatewaySender.encapsulatedKey
        )

        let sealedResponse = try gatewaySender.seal(Data("response".utf8))
        let openedResponse = try deviceRecipient.open(
            sequence: sealedResponse.sequence,
            ciphertext: sealedResponse.ciphertext
        )
        #expect(openedResponse == Data("response".utf8))
    }

    @Test func pairingResponseAuthenticatesTheGateway() throws {
        let gatewayPrivateKey = RemoteCrypto.makeIdentity()
        let devicePrivateKey = RemoteCrypto.makeIdentity()

        var sender = try RemoteCrypto.pairingResponseSender(
            devicePublicKey: devicePrivateKey.publicKey,
            gatewayPrivateKey: gatewayPrivateKey,
            pairingID: "pair-1"
        )
        var recipient = try RemoteCrypto.pairingResponseRecipient(
            devicePrivateKey: devicePrivateKey,
            gatewayPublicKey: gatewayPrivateKey.publicKey,
            pairingID: "pair-1",
            encapsulatedKey: sender.encapsulatedKey
        )

        let sealed = try sender.seal(Data("paired".utf8))
        #expect(try recipient.open(sequence: sealed.sequence, ciphertext: sealed.ciphertext) == Data("paired".utf8))
    }

    @Test func remoteHTTPRequestForwardsOnlyAllowedHeaders() throws {
        var request = URLRequest(url: try #require(URL(string: "https://remote.example.com/session?id=1")))
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("/workspace", forHTTPHeaderField: "x-opencode-directory")
        request.setValue("secret", forHTTPHeaderField: "Authorization")

        let remote = try RemoteHTTPRequest(request: request)

        #expect(remote.pathAndQuery == "/session?id=1")
        #expect(remote.headers.keys.contains(where: { $0.lowercased() == "content-type" }))
        #expect(remote.headers.keys.contains(where: { $0.lowercased() == "x-opencode-directory" }))
        #expect(!remote.headers.keys.contains(where: { $0.lowercased() == "authorization" }))
    }
}
