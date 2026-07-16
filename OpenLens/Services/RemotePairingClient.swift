import CryptoKit
import Foundation
import UIKit

enum RemoteConnectionSecretStore {
    private static let keyPrefix = "openlens_remote_connection_v1_"

    @discardableResult
    static func save(_ credential: RemoteDeviceCredential) -> Bool {
        KeychainService.saveCodable(credential, key: keyPrefix + credential.connectionID)
    }

    static func load(connectionID: String) -> RemoteDeviceCredential? {
        KeychainService.loadCodable(
            RemoteDeviceCredential.self,
            key: keyPrefix + connectionID
        )
    }

    static func delete(connectionID: String) {
        KeychainService.delete(key: keyPrefix + connectionID)
    }
}

struct RemotePairingClient {
    private let urlSession: URLSession

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    func pair(using offer: RemotePairingOffer) async throws -> RemoteDeviceCredential {
        guard !offer.isExpired else { throw RemoteProtocolError.expiredPairingOffer }
        let gatewayPublicKey = try RemoteCrypto.publicKey(rawRepresentation: offer.gatewayPublicKey)
        let devicePrivateKey = RemoteCrypto.makeIdentity()
        let deviceName = UIDevice.current.name
        let connectionID = UUID().uuidString

        var request = URLRequest(url: try remoteWebSocketURL(for: offer.endpoint))
        request.timeoutInterval = 30
        request.setValue(RemoteProtocolVersion.webSocketSubprotocol, forHTTPHeaderField: "Sec-WebSocket-Protocol")
        request.setValue(offer.accessCredential.clientID, forHTTPHeaderField: "CF-Access-Client-Id")
        request.setValue(offer.accessCredential.clientSecret, forHTTPHeaderField: "CF-Access-Client-Secret")
        request.setValue(offer.pairingID, forHTTPHeaderField: "X-OpenLens-Handshake-ID")
        let socket = urlSession.webSocketTask(with: request)
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }

        var encryptor = try RemoteCrypto.pairingSender(
            gatewayPublicKey: gatewayPublicKey,
            pairingID: offer.pairingID
        )
        let pairingRequest = RemotePairingRequest(
            pairingSecret: offer.pairingSecret,
            devicePublicKey: devicePrivateKey.publicKey.rawRepresentation,
            deviceName: deviceName
        )
        let sealed = try encryptor.seal(try JSONEncoder().encode(pairingRequest))
        let envelope = RemoteWireEnvelope(
            kind: .pairingRequest,
            pairingID: offer.pairingID,
            encapsulatedKey: encryptor.encapsulatedKey,
            sequence: sealed.sequence,
            ciphertext: sealed.ciphertext
        )
        try await socket.send(.data(try envelope.encoded()))

        let responseWire = try await remoteReceiveWithTimeout(from: socket)
        let responseEnvelope = try RemoteWireEnvelope.decode(try remoteData(from: responseWire))
        if responseEnvelope.kind == .rejected {
            throw RemoteProtocolError.pairingRejected
        }
        guard responseEnvelope.kind == .pairingResponse,
              responseEnvelope.pairingID == offer.pairingID,
              let encapsulatedKey = responseEnvelope.encapsulatedKey,
              let sequence = responseEnvelope.sequence,
              let ciphertext = responseEnvelope.ciphertext
        else {
            throw RemoteProtocolError.authenticationFailed
        }

        var decryptor = try RemoteCrypto.pairingResponseRecipient(
            devicePrivateKey: devicePrivateKey,
            gatewayPublicKey: gatewayPublicKey,
            pairingID: offer.pairingID,
            encapsulatedKey: encapsulatedKey
        )
        let response = try JSONDecoder().decode(
            RemotePairingResponse.self,
            from: decryptor.open(sequence: sequence, ciphertext: ciphertext)
        )
        guard response.gatewayID == offer.gatewayID else {
            throw RemoteProtocolError.authenticationFailed
        }

        return RemoteDeviceCredential(
            connectionID: connectionID,
            endpoint: offer.endpoint,
            gatewayID: response.gatewayID,
            gatewayPublicKey: offer.gatewayPublicKey,
            deviceID: response.deviceID,
            deviceName: response.deviceName,
            devicePrivateKey: devicePrivateKey.rawRepresentation,
            accessCredential: offer.accessCredential
        )
    }
}

private func remoteWebSocketURL(for endpoint: URL) throws -> URL {
    guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
        throw RemoteProtocolError.invalidPairingOffer
    }
    switch components.scheme?.lowercased() {
    case "https": components.scheme = "wss"
#if DEBUG
    case "http": components.scheme = "ws"
#endif
    default: throw RemoteProtocolError.invalidPairingOffer
    }
    components.path = "/remote"
    components.query = nil
    guard let url = components.url else { throw RemoteProtocolError.invalidPairingOffer }
    return url
}

private func remoteData(from message: URLSessionWebSocketTask.Message) throws -> Data {
    switch message {
    case .data(let data): return data
    case .string(let string):
        guard let data = string.data(using: .utf8) else {
            throw RemoteProtocolError.malformedMessage
        }
        return data
    @unknown default:
        throw RemoteProtocolError.malformedMessage
    }
}

private func remoteReceiveWithTimeout(
    from socket: URLSessionWebSocketTask
) async throws -> URLSessionWebSocketTask.Message {
    try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
        group.addTask { try await socket.receive() }
        group.addTask {
            try await Task.sleep(for: .seconds(30))
            socket.cancel(with: .goingAway, reason: nil)
            throw RemoteProtocolError.timeout
        }
        guard let message = try await group.next() else {
            throw RemoteProtocolError.disconnected
        }
        group.cancelAll()
        return message
    }
}
