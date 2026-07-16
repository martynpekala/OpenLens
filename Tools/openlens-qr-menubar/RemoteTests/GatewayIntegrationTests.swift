import AppKit
import CryptoKit
import CoreImage
import Foundation
import Security
import Testing
@testable import OpenLensRemote

@Suite(.serialized)
struct GatewayIntegrationTests {
    @Test func updateTagsMatchBundleVersionsWithOrWithoutVPrefix() throws {
        let release = try JSONDecoder().decode(
            RemoteAgentRelease.self,
            from: Data(#"{"tag_name":"v1.0","html_url":"https://example.com/release"}"#.utf8)
        )

        #expect(release.matches(version: "1.0"))
        #expect(release.matches(version: "V1.0"))
        #expect(!release.matches(version: "1.1"))
    }

    @Test func pairingAndAuthenticatedSessionRejectAnUnapprovedPath() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let workspaceRegistry = WorkspaceRegistry(
            storageURL: temporaryDirectory.appendingPathComponent("workspaces.json")
        )
        _ = try workspaceRegistry.add(url: temporaryDirectory)
        let deviceRegistry = DeviceRegistry(
            storageURL: temporaryDirectory.appendingPathComponent("devices.json")
        )
        let identity = AgentIdentity(privateKey: RemoteCrypto.makeIdentity())
        let gateway = Gateway(
            identity: identity,
            deviceRegistry: deviceRegistry,
            forwarder: OpenCodeForwarder(workspaceRegistry: workspaceRegistry, password: "test-password"),
            accessValidator: TestAccessValidator()
        )
        try gateway.start()
        defer { gateway.stop() }
        try await Task.sleep(for: .milliseconds(150))

        let offer = try gateway.makePairingOffer(
            endpoint: #require(URL(string: "https://remote.example.com")),
            accessCredential: testAccessCredential
        )
        let devicePrivateKey = RemoteCrypto.makeIdentity()
        let socket = try await connectedSocket(handshakeID: offer.pairingID)
        defer { socket.cancel(with: .normalClosure, reason: nil) }

        var pairingEncryptor = try RemoteCrypto.pairingSender(
            gatewayPublicKey: identity.privateKey.publicKey,
            pairingID: offer.pairingID
        )
        let request = RemotePairingRequest(
            pairingSecret: offer.pairingSecret,
            devicePublicKey: devicePrivateKey.publicKey.rawRepresentation,
            deviceName: "Integration iPhone"
        )
        let pairingSealed = try pairingEncryptor.seal(try JSONEncoder().encode(request))
        let pairingRequestEnvelope = RemoteWireEnvelope(
            kind: .pairingRequest,
            pairingID: offer.pairingID,
            encapsulatedKey: pairingEncryptor.encapsulatedKey,
            sequence: pairingSealed.sequence,
            ciphertext: pairingSealed.ciphertext
        )
        try await socket.send(.data(try pairingRequestEnvelope.encoded()))

        let pairingEnvelope = try RemoteWireEnvelope.decode(try data(from: try await socket.receive()))
        var pairingDecryptor = try RemoteCrypto.pairingResponseRecipient(
            devicePrivateKey: devicePrivateKey,
            gatewayPublicKey: identity.privateKey.publicKey,
            pairingID: offer.pairingID,
            encapsulatedKey: try #require(pairingEnvelope.encapsulatedKey)
        )
        let pairingResponse = try JSONDecoder().decode(
            RemotePairingResponse.self,
            from: pairingDecryptor.open(
                sequence: try #require(pairingEnvelope.sequence),
                ciphertext: try #require(pairingEnvelope.ciphertext)
            )
        )
        #expect(pairingResponse.gatewayID == identity.gatewayID)
        #expect(deviceRegistry.all().count == 1)

        let reusedPairingSocket = try await connectedSocket(handshakeID: offer.pairingID)
        defer { reusedPairingSocket.cancel(with: .normalClosure, reason: nil) }
        try await reusedPairingSocket.send(.data(try pairingRequestEnvelope.encoded()))
        let reusedPairingResponse = try RemoteWireEnvelope.decode(
            try data(from: try await reusedPairingSocket.receive())
        )
        #expect(reusedPairingResponse.kind == .rejected)

        let sessionID = UUID().uuidString
        let sessionSocket = try await connectedSocket(handshakeID: sessionID)
        defer { sessionSocket.cancel(with: .normalClosure, reason: nil) }
        var deviceEncryptor = try RemoteCrypto.deviceSessionSender(
            devicePrivateKey: devicePrivateKey,
            gatewayPublicKey: identity.privateKey.publicKey,
            sessionID: sessionID
        )
        let hello = RemoteSessionHello(
            deviceName: "Integration iPhone",
            protocolVersion: RemoteProtocolVersion.current
        )
        let helloSealed = try deviceEncryptor.seal(try JSONEncoder().encode(hello))
        try await sessionSocket.send(.data(try RemoteWireEnvelope(
            kind: .sessionHello,
            deviceID: pairingResponse.deviceID,
            sessionID: sessionID,
            encapsulatedKey: deviceEncryptor.encapsulatedKey,
            sequence: helloSealed.sequence,
            ciphertext: helloSealed.ciphertext
        ).encoded()))

        let welcomeEnvelope = try RemoteWireEnvelope.decode(try data(from: try await sessionSocket.receive()))
        var deviceDecryptor = try RemoteCrypto.deviceSessionRecipient(
            devicePrivateKey: devicePrivateKey,
            gatewayPublicKey: identity.privateKey.publicKey,
            sessionID: sessionID,
            encapsulatedKey: try #require(welcomeEnvelope.encapsulatedKey)
        )
        let welcome = try JSONDecoder().decode(
            RemoteSessionWelcome.self,
            from: deviceDecryptor.open(
                sequence: try #require(welcomeEnvelope.sequence),
                ciphertext: try #require(welcomeEnvelope.ciphertext)
            )
        )
        #expect(welcome.gatewayID == identity.gatewayID)

        let invalidRequest = RemoteMessage(
            kind: .request,
            request: RemoteHTTPRequest(method: "GET", pathAndQuery: "/not-allowed")
        )
        let requestSealed = try deviceEncryptor.seal(try invalidRequest.encoded())
        let requestEnvelope = RemoteWireEnvelope(
            kind: .encrypted,
            deviceID: pairingResponse.deviceID,
            sessionID: sessionID,
            sequence: requestSealed.sequence,
            ciphertext: requestSealed.ciphertext
        )
        try await sessionSocket.send(.data(try requestEnvelope.encoded()))

        let errorEnvelope = try RemoteWireEnvelope.decode(try data(from: try await sessionSocket.receive()))
        let errorMessage = try RemoteMessage.decode(
            try deviceDecryptor.open(
                sequence: try #require(errorEnvelope.sequence),
                ciphertext: try #require(errorEnvelope.ciphertext)
            )
        )
        #expect(errorMessage.kind == .error)
        #expect(errorMessage.id == invalidRequest.id)

        try await sessionSocket.send(.data(try requestEnvelope.encoded()))
        let replayResponse = try RemoteWireEnvelope.decode(
            try data(from: try await sessionSocket.receive())
        )
        #expect(replayResponse.kind == .rejected)

        deviceRegistry.remove(id: pairingResponse.deviceID)
        gateway.disconnectDevice(id: pairingResponse.deviceID)
        let revokedSessionID = UUID().uuidString
        let revokedSocket = try await connectedSocket(handshakeID: revokedSessionID)
        defer { revokedSocket.cancel(with: .normalClosure, reason: nil) }
        var revokedEncryptor = try RemoteCrypto.deviceSessionSender(
            devicePrivateKey: devicePrivateKey,
            gatewayPublicKey: identity.privateKey.publicKey,
            sessionID: revokedSessionID
        )
        let revokedHello = try revokedEncryptor.seal(try JSONEncoder().encode(hello))
        try await revokedSocket.send(.data(try RemoteWireEnvelope(
            kind: .sessionHello,
            deviceID: pairingResponse.deviceID,
            sessionID: revokedSessionID,
            encapsulatedKey: revokedEncryptor.encapsulatedKey,
            sequence: revokedHello.sequence,
            ciphertext: revokedHello.ciphertext
        ).encoded()))
        let revokedResponse = try RemoteWireEnvelope.decode(
            try data(from: try await revokedSocket.receive())
        )
        #expect(revokedResponse.kind == .rejected)
        gateway.stop()
        try await Task.sleep(for: .milliseconds(150))
    }

    @Test func gatewayCanRestartImmediatelyAfterAStopRequest() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let workspaceRegistry = WorkspaceRegistry(
            storageURL: temporaryDirectory.appendingPathComponent("workspaces.json")
        )
        _ = try workspaceRegistry.add(url: temporaryDirectory)
        let identity = AgentIdentity(privateKey: RemoteCrypto.makeIdentity())
        let gateway = Gateway(
            identity: identity,
            deviceRegistry: DeviceRegistry(
                storageURL: temporaryDirectory.appendingPathComponent("devices.json")
            ),
            forwarder: OpenCodeForwarder(workspaceRegistry: workspaceRegistry, password: "test-password"),
            accessValidator: TestAccessValidator()
        )

        try gateway.start()
        gateway.stop()
        try gateway.start()
        let endpoint = try #require(URL(string: "https://remote.example.com"))
        var offer: RemotePairingOffer?
        for _ in 0..<120 where offer == nil {
            offer = try? gateway.makePairingOffer(
                endpoint: endpoint,
                accessCredential: testAccessCredential
            )
            if offer == nil { try await Task.sleep(for: .milliseconds(25)) }
        }
        #expect(offer != nil)
        gateway.stop()
        try await Task.sleep(for: .milliseconds(150))
    }

    @Test func workspaceAllowlistRequiresAnExactCanonicalPath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let child = root.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let registry = WorkspaceRegistry(storageURL: root.appendingPathComponent("allowlist.json"))
        _ = try registry.add(url: root)
        #expect(registry.isAllowed(root.path))
        #expect(!registry.isAllowed(child.path))
    }

    @Test func forwardingUsesAnExactMethodAndRouteTable() {
        #expect(OpenCodeForwarder.isAllowed(method: "GET", path: "/session/ses_123/message/msg_456"))
        #expect(OpenCodeForwarder.isAllowed(method: "POST", path: "/permission/per_123/reply"))
        #expect(OpenCodeForwarder.isAllowed(method: "GET", path: "/file/content"))
        #expect(!OpenCodeForwarder.isAllowed(method: "GET", path: "/session/ses_123/shell"))
        #expect(!OpenCodeForwarder.isAllowed(method: "POST", path: "/global/health"))
        #expect(!OpenCodeForwarder.isAllowed(method: "GET", path: "/session/../config"))
    }

    @Test func accessJWTRequiresSignatureIssuerAudienceExpiryAndServiceTokenIdentity() throws {
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits: 2_048,
        ]
        var error: Unmanaged<CFError>?
        let privateKey = try #require(SecKeyCreateRandomKey(attributes as CFDictionary, &error))
        let publicKey = try #require(SecKeyCopyPublicKey(privateKey))
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let configuration = CloudflareAccessConfiguration(
            teamDomain: "team.cloudflareaccess.com",
            audience: "application-audience",
            clientID: "service-token.access"
        )

        let valid = try signedJWT(
            privateKey: privateKey,
            claims: [
                "iss": configuration.issuer,
                "type": "app",
                "aud": configuration.audience,
                "common_name": configuration.clientID,
                "exp": now.timeIntervalSince1970 + 600,
            ]
        )
        #expect(CloudflareAccessVerifier.validate(
            assertion: valid,
            configuration: configuration,
            key: publicKey,
            now: now
        ))

        let wrongAudience = try signedJWT(
            privateKey: privateKey,
            claims: [
                "iss": configuration.issuer,
                "type": "app",
                "aud": "another-application",
                "common_name": configuration.clientID,
                "exp": now.timeIntervalSince1970 + 600,
            ]
        )
        #expect(!CloudflareAccessVerifier.validate(
            assertion: wrongAudience,
            configuration: configuration,
            key: publicKey,
            now: now
        ))

        let expired = try signedJWT(
            privateKey: privateKey,
            claims: [
                "iss": configuration.issuer,
                "type": "app",
                "aud": configuration.audience,
                "common_name": configuration.clientID,
                "exp": now.timeIntervalSince1970 - 60,
            ]
        )
        #expect(!CloudflareAccessVerifier.validate(
            assertion: expired,
            configuration: configuration,
            key: publicKey,
            now: now
        ))
    }

    @Test func accessVerifierLoadsAndUsesAPersistedCloudflareJWK() async throws {
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits: 2_048,
        ]
        var error: Unmanaged<CFError>?
        let privateKey = try #require(SecKeyCreateRandomKey(attributes as CFDictionary, &error))
        let publicKey = try #require(SecKeyCopyPublicKey(privateKey))
        let representation = try #require(
            SecKeyCopyExternalRepresentation(publicKey, &error) as Data?
        )
        let components = try rsaComponents(from: representation)
        let configuration = CloudflareAccessConfiguration(
            teamDomain: "team.cloudflareaccess.com",
            audience: "application-audience",
            clientID: "service-token.access"
        )
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openlens-jwks-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        let cache = TestJWKCache(
            issuer: configuration.issuer,
            fetchedAt: Date(),
            keys: [TestJWK(
                alg: "RS256",
                e: components.exponent.base64URLEncodedString(),
                kid: "test-key",
                kty: "RSA",
                n: components.modulus.base64URLEncodedString(),
                use: "sig"
            )]
        )
        try JSONEncoder().encode(cache).write(to: cacheURL)

        let verifier = CloudflareAccessVerifier(cacheURL: cacheURL)
        try await verifier.prepare(configuration: configuration, requiresNetworkRefresh: false)
        let now = Date()
        let assertion = try signedJWT(
            privateKey: privateKey,
            claims: [
                "iss": configuration.issuer,
                "type": "app",
                "aud": [configuration.audience],
                "common_name": configuration.clientID,
                "iat": now.timeIntervalSince1970,
                "exp": now.timeIntervalSince1970 + 600,
            ]
        )
        #expect(verifier.validate(assertion: assertion, now: now))
    }

    @Test @MainActor func pairingViewRendersForVisualVerification() throws {
        let filter = try #require(CIFilter(name: "CIQRCodeGenerator"))
        filter.setValue(Data("openlens-remote-visual-verification".utf8), forKey: "inputMessage")
        let output = try #require(filter.outputImage)
            .transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let cgImage = try #require(CIContext().createCGImage(output, from: output.extent))
        let image = NSImage(cgImage: cgImage, size: NSSize(width: 320, height: 320))
        let view = RemotePairingViewFactory.make(
            image: image,
            gatewayFingerprint: "4b6b2cf87c852dcc7f9a2d84",
            expiresAt: Date(timeIntervalSince1970: 1_787_600_000)
        )
        view.layoutSubtreeIfNeeded()
        let representation = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: representation)
        let png = try #require(representation.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/private/tmp/openlens-remote-pairing.png"), options: .atomic)
        #expect(png.count > 10_000)
    }

    @Test @MainActor func cloudflareConfigurationFormRendersForVisualVerification() throws {
        let view = CloudflareConfigurationForm(
            hostname: "remote.example.com",
            teamDomain: "example.cloudflareaccess.com",
            audience: "0123456789abcdef0123456789abcdef",
            hasTunnelConfiguration: true,
            hasClientID: true,
            requiresAccessRotation: false
        )
        view.layoutSubtreeIfNeeded()
        let representation = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: representation)
        let png = try #require(representation.representation(using: .png, properties: [:]))
        try png.write(
            to: URL(fileURLWithPath: "/private/tmp/openlens-cloudflare-access-config.png"),
            options: .atomic
        )
        #expect(png.count > 10_000)
    }

    private func connectedSocket(handshakeID: String) async throws -> URLSessionWebSocketTask {
        var request = URLRequest(url: URL(string: "ws://127.0.0.1:49634/remote")!)
        request.setValue(RemoteProtocolVersion.webSocketSubprotocol, forHTTPHeaderField: "Sec-WebSocket-Protocol")
        request.setValue("valid-test-assertion", forHTTPHeaderField: "Cf-Access-Jwt-Assertion")
        request.setValue(handshakeID, forHTTPHeaderField: "X-OpenLens-Handshake-ID")
        request.setValue("203.0.113.10", forHTTPHeaderField: "CF-Connecting-IP")
        let socket = URLSession.shared.webSocketTask(with: request)
        socket.resume()
        return socket
    }

    private func data(
        from message: URLSessionWebSocketTask.Message
    ) throws -> Data {
        switch message {
        case .data(let data): return data
        case .string(let value): return Data(value.utf8)
        @unknown default: throw RemoteProtocolError.malformedMessage
        }
    }

    private func signedJWT(
        privateKey: SecKey,
        claims: [String: Any]
    ) throws -> String {
        let header = try JSONSerialization.data(withJSONObject: ["alg": "RS256", "kid": "test-key"])
        let payload = try JSONSerialization.data(withJSONObject: claims)
        let signingInput = "\(header.base64URLEncodedString()).\(payload.base64URLEncodedString())"
        var error: Unmanaged<CFError>?
        let signature = try #require(SecKeyCreateSignature(
            privateKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            Data(signingInput.utf8) as CFData,
            &error
        ) as Data?)
        return "\(signingInput).\(signature.base64URLEncodedString())"
    }

    private func rsaComponents(from representation: Data) throws -> (modulus: Data, exponent: Data) {
        var index = 0
        guard readByte(from: representation, index: &index) == 0x30 else {
            throw RemoteProtocolError.malformedMessage
        }
        _ = try readDERLength(from: representation, index: &index)
        let modulus = try readDERInteger(from: representation, index: &index)
        let exponent = try readDERInteger(from: representation, index: &index)
        return (Data(modulus.drop(while: { $0 == 0 })), Data(exponent.drop(while: { $0 == 0 })))
    }

    private func readDERInteger(from data: Data, index: inout Int) throws -> Data {
        guard readByte(from: data, index: &index) == 0x02 else {
            throw RemoteProtocolError.malformedMessage
        }
        let length = try readDERLength(from: data, index: &index)
        guard length >= 1, index + length <= data.count else {
            throw RemoteProtocolError.malformedMessage
        }
        defer { index += length }
        return data.subdata(in: index..<(index + length))
    }

    private func readDERLength(from data: Data, index: inout Int) throws -> Int {
        guard let first = readByte(from: data, index: &index) else {
            throw RemoteProtocolError.malformedMessage
        }
        if first & 0x80 == 0 { return Int(first) }
        let byteCount = Int(first & 0x7f)
        guard (1...4).contains(byteCount), index + byteCount <= data.count else {
            throw RemoteProtocolError.malformedMessage
        }
        var length = 0
        for _ in 0..<byteCount {
            length = (length << 8) | Int(try #require(readByte(from: data, index: &index)))
        }
        return length
    }

    private func readByte(from data: Data, index: inout Int) -> UInt8? {
        guard index < data.count else { return nil }
        defer { index += 1 }
        return data[index]
    }

    private var testAccessCredential: CloudflareAccessCredential {
        CloudflareAccessCredential(
            clientID: "integration-test.access",
            clientSecret: "integration-test-client-secret"
        )
    }
}

private struct TestJWKCache: Codable {
    let issuer: String
    let fetchedAt: Date
    let keys: [TestJWK]
}

private struct TestJWK: Codable {
    let alg: String?
    let e: String
    let kid: String
    let kty: String
    let n: String
    let use: String?
}

private final class TestAccessValidator: CloudflareAccessValidating, @unchecked Sendable {
    func validate(assertion: String, now: Date) -> Bool {
        assertion == "valid-test-assertion"
    }
}
