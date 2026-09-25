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
        #expect(errorMessage.errorCode == "invalid_request")
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

    @Test func remoteRouteTableIncludesV2ProbeActiveSnapshotAndEventWithoutChangingV1() {
        #expect(OpenCodeForwarder.isAllowed(method: "GET", path: "/api/info"))
        #expect(OpenCodeForwarder.isAllowed(method: "GET", path: "/api/event"))
        #expect(OpenCodeForwarder.isAllowed(method: "GET", path: "/api/session/active"))
        #expect(OpenCodeForwarder.isAllowed(method: "GET", path: "/api/location"))
        #expect(OpenCodeForwarder.isAllowed(method: "GET", path: "/api/project/current"))
        #expect(OpenCodeForwarder.isAllowed(method: "GET", path: "/api/fs/list"))
        #expect(OpenCodeForwarder.isAllowed(method: "GET", path: "/api/fs/read/Sources/App.swift"))
        #expect(OpenCodeForwarder.isAllowed(method: "GET", path: "/api/vcs/diff"))
        #expect(OpenCodeForwarder.isAllowed(method: "GET", path: "/api/vcs/status"))
        #expect(OpenCodeForwarder.isAllowed(method: "GET", path: "/api/form"))
        #expect(OpenCodeForwarder.isAllowed(method: "GET", path: "/event"))
        #expect(!OpenCodeForwarder.isAllowed(method: "POST", path: "/api/info"))
        #expect(!OpenCodeForwarder.isAllowed(method: "POST", path: "/api/session/active"))
        #expect(!OpenCodeForwarder.isAllowed(method: "GET", path: "/api/%65vent"))
        #expect(!OpenCodeForwarder.isAllowed(method: "GET", path: "/api/info/../event"))
        #expect(!OpenCodeForwarder.isAllowed(method: "GET", path: "/api/fs/read/../.env"))
    }

    @Test func remoteRouteTableAllowsV2SessionCommandAdmissionOnly() {
        #expect(OpenCodeForwarder.isAllowed(method: "POST", path: "/api/session/ses_123/command"))
        #expect(!OpenCodeForwarder.isAllowed(method: "GET", path: "/api/session/ses_123/command"))
        #expect(!OpenCodeForwarder.isAllowed(method: "POST", path: "/api/session/ses_123/shell"))
        #expect(!OpenCodeForwarder.isAllowed(method: "POST", path: "/api/session/../command"))
    }

    @Test func remoteRouteTableCoversTheV2ClientSessionSurface() {
        #expect(OpenCodeForwarder.isAllowed(method: "GET", path: "/api/model"))
        #expect(OpenCodeForwarder.isAllowed(method: "GET", path: "/api/model/default"))
        #expect(OpenCodeForwarder.isAllowed(method: "GET", path: "/api/provider"))
        #expect(OpenCodeForwarder.isAllowed(method: "GET", path: "/api/agent"))
        #expect(OpenCodeForwarder.isAllowed(method: "GET", path: "/api/command"))
        #expect(OpenCodeForwarder.isAllowed(method: "GET", path: "/api/permission/request"))
        #expect(OpenCodeForwarder.isAllowed(method: "GET", path: "/api/session"))
        #expect(OpenCodeForwarder.isAllowed(method: "POST", path: "/api/session"))
        #expect(OpenCodeForwarder.isAllowed(method: "GET", path: "/api/session/ses_123"))
        #expect(OpenCodeForwarder.isAllowed(method: "PATCH", path: "/api/session/ses_123"))
        #expect(OpenCodeForwarder.isAllowed(method: "DELETE", path: "/api/session/ses_123"))
        #expect(OpenCodeForwarder.isAllowed(method: "POST", path: "/api/session/ses_123/interrupt"))
        #expect(OpenCodeForwarder.isAllowed(method: "GET", path: "/api/session/ses_123/message"))
        #expect(OpenCodeForwarder.isAllowed(method: "GET", path: "/api/session/ses_123/message/msg_456"))
        #expect(OpenCodeForwarder.isAllowed(method: "POST", path: "/api/session/ses_123/prompt"))
        #expect(OpenCodeForwarder.isAllowed(method: "POST", path: "/api/session/ses_123/model"))
        #expect(OpenCodeForwarder.isAllowed(method: "POST", path: "/api/session/ses_123/agent"))
        #expect(OpenCodeForwarder.isAllowed(method: "GET", path: "/api/session/ses_123/diff"))
        #expect(OpenCodeForwarder.isAllowed(method: "GET", path: "/api/session/ses_123/permission"))
        #expect(OpenCodeForwarder.isAllowed(method: "POST", path: "/api/session/ses_123/permission/per_456/reply"))
        #expect(OpenCodeForwarder.isAllowed(method: "DELETE", path: "/api/session/ses_123/revert"))
        #expect(!OpenCodeForwarder.isAllowed(method: "POST", path: "/api/session/ses_123/revert/clear"))
        #expect(OpenCodeForwarder.isAllowed(method: "POST", path: "/api/session/ses_123/revert/stage"))
        #expect(OpenCodeForwarder.isAllowed(method: "POST", path: "/api/session/ses_123/revert/commit"))
        #expect(!OpenCodeForwarder.isAllowed(method: "GET", path: "/api/session/ses_123/revert/clear"))
        #expect(!OpenCodeForwarder.isAllowed(method: "POST", path: "/api/session/../prompt"))
    }

    @Test func remoteV2ForwardingPreservesAuthenticationErrorsAndCanonicalWorkspace() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let registry = WorkspaceRegistry(storageURL: root.appendingPathComponent("allowlist.json"))
        _ = try registry.add(url: root)

        ForwarderURLProtocol.setResponse(
            statusCode: 401,
            body: Data(#"{"_tag":"UnauthorizedError","message":"Wrong password"}"#.utf8)
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ForwarderURLProtocol.self]
        let forwarder = OpenCodeForwarder(
            workspaceRegistry: registry,
            password: "test-password",
            session: URLSession(configuration: configuration)
        )

        let response = try await forwarder.perform(
            RemoteHTTPRequest(
                method: "GET",
                pathAndQuery: "/api/session/active",
                headers: ["x-opencode-directory": root.path]
            )
        )
        let forwarded = try #require(ForwarderURLProtocol.recordedRequest())
        let queryItems = URLComponents(url: try #require(forwarded.url), resolvingAgainstBaseURL: false)?
            .queryItems?
            .reduce(into: [String: String]()) { items, item in
                items[item.name] = item.value
            }

        #expect(response.statusCode == 401)
        #expect(response.body == Data(#"{"_tag":"UnauthorizedError","message":"Wrong password"}"#.utf8))
        #expect(forwarded.url?.path == "/api/session/active")
        #expect(forwarded.value(forHTTPHeaderField: "Authorization") == "Basic b3BlbmNvZGU6dGVzdC1wYXNzd29yZA==")
        #expect(queryItems == nil)
    }

    @Test func v2SessionOperationsRejectForeignOwnershipBeforeForwarding() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = WorkspaceRegistry(storageURL: root.appendingPathComponent("allowlist.json"))
        _ = try registry.add(url: root)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ForwarderURLProtocol.self]
        let forwarder = OpenCodeForwarder(workspaceRegistry: registry, password: "test", session: URLSession(configuration: configuration))
        ForwarderURLProtocol.setResponse(statusCode: 200, body: Data(#"{"data":{"id":"ses_foreign","location":{"directory":"/unregistered"}}}"#.utf8))
        for method in ["GET", "PATCH", "DELETE"] {
            await #expect(throws: RemoteProtocolError.invalidRequest) {
                _ = try await forwarder.perform(RemoteHTTPRequest(method: method, pathAndQuery: "/api/session/ses_foreign"))
            }
        }
        #expect(ForwarderURLProtocol.recordedRequest()?.httpMethod == "GET")
    }

    @Test func v2ActiveSnapshotFiltersForeignSessionsAndRechecksRegistry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = WorkspaceRegistry(storageURL: root.appendingPathComponent("allowlist.json"))
        let workspace = try registry.add(url: root)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ForwarderURLProtocol.self]
        let forwarder = OpenCodeForwarder(workspaceRegistry: registry, password: "test", session: URLSession(configuration: configuration))
        let allowed = try JSONSerialization.data(withJSONObject: ["data":["id":"ses_allowed", "location":["directory":root.path]]])
        ForwarderURLProtocol.setRoutes([
            "/api/session/active": Data(#"{"data":{"ses_allowed":{"type":"running"},"ses_foreign":{"type":"running"}}}"#.utf8),
            "/api/session/ses_allowed": allowed,
            "/api/session/ses_foreign": Data(#"{"data":{"id":"ses_foreign","location":{"directory":"/unregistered"}}}"#.utf8)
        ])
        let response = try await forwarder.perform(RemoteHTTPRequest(method: "GET", pathAndQuery: "/api/session/active"))
        let envelope = try #require(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        let active = try #require(envelope["data"] as? [String: Any])
        #expect(Set(active.keys) == ["ses_allowed"])
        _ = try await forwarder.perform(RemoteHTTPRequest(method: "DELETE", pathAndQuery: "/api/session/ses_allowed"))
        #expect(ForwarderURLProtocol.recordedRequests().suffix(2).map(\.httpMethod) == ["GET", "DELETE"])
        ForwarderURLProtocol.setRoutes([
            "/api/session/ses_allowed": Data(#"{"data":{"id":"ses_allowed","location":{"directory":"/unregistered"}}}"#.utf8)
        ])
        await #expect(throws: RemoteProtocolError.invalidRequest) {
            _ = try await forwarder.perform(RemoteHTTPRequest(method: "POST", pathAndQuery: "/api/session/ses_allowed/prompt"))
        }
        #expect(ForwarderURLProtocol.recordedRequests().map(\.httpMethod) == ["GET"])
        registry.remove(id: workspace.id)
        await #expect(throws: RemoteProtocolError.invalidRequest) {
            _ = try await forwarder.perform(RemoteHTTPRequest(method: "DELETE", pathAndQuery: "/api/session/ses_allowed"))
        }
    }

    @Test func v2StreamFiltersBeforeForwardingAndBoundsIncompleteRecords() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = WorkspaceRegistry(storageURL: root.appendingPathComponent("allowlist.json"))
        let workspace = try registry.add(url: root)
        let filter = GatewayV2EventFilter(registry: registry)
        func frame(_ directory: String, _ text: String) throws -> Data {
            let json = try JSONSerialization.data(withJSONObject: ["type":"session.text.delta", "location":["directory":directory], "data":["sessionID":"ses_1", "delta":text]])
            return Data("event: message\r\ndata: ".utf8) + json + Data("\r\n\r\n".utf8)
        }
        let allowed = try frame(root.path, "Visible")
        let hidden = try frame("/unregistered", "SECRET")
        let input = allowed + hidden
        var output = Data()
        for byte in input { for frame in try filter.append(Data([byte])) { output.append(frame) } }
        #expect(String(decoding: output, as: UTF8.self).contains("Visible"))
        #expect(!String(decoding: output, as: UTF8.self).contains("SECRET"))
        registry.remove(id: workspace.id)
        #expect(try filter.append(allowed).isEmpty)
        #expect(throws: RemoteProtocolError.messageTooLarge) {
            _ = try filter.append(Data(repeating: 65, count: RemoteProtocolVersion.maximumWireMessageBytes + 1))
        }
    }

    @Test func v2SessionCreationPinsAndValidatesBodyLocation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let second = root.appendingPathComponent("Second")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = WorkspaceRegistry(storageURL: root.appendingPathComponent("allowlist.json"))
        _ = try registry.add(url: root)
        _ = try registry.add(url: second)
        ForwarderURLProtocol.setResponse(statusCode: 200, body: Data(#"{"data":{"id":"ses_1"}}"#.utf8))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ForwarderURLProtocol.self]
        let forwarder = OpenCodeForwarder(workspaceRegistry: registry, password: "test", session: URLSession(configuration: configuration))

        for directory in [nil, second.path] as [String?] {
            var body: [String: Any] = ["title": "Created remotely"]
            if let directory { body["location"] = ["directory": directory] }
            _ = try await forwarder.perform(RemoteHTTPRequest(
                method: "POST", pathAndQuery: "/api/session",
                body: try JSONSerialization.data(withJSONObject: body)
            ))
            let request = try #require(ForwarderURLProtocol.recordedRequest())
            let payload = try #require(request.httpBody)
            let forwarded = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
            #expect(forwarded["location"] as? [String: String] == ["directory": directory ?? root.path])
            #expect(request.url?.query == nil)
        }

        for location in [
            ["directory": root.appendingPathComponent("Unregistered").path],
            ["directory": root.path, "workspace": "escape"],
            ["directory": root.path.replacingOccurrences(of: "/", with: "%2F")]
        ] {
            await #expect(throws: RemoteProtocolError.invalidRequest) {
                _ = try await forwarder.perform(RemoteHTTPRequest(
                    method: "POST", pathAndQuery: "/api/session",
                    body: try JSONSerialization.data(withJSONObject: ["location": location])
                ))
            }
        }
        await #expect(throws: RemoteProtocolError.invalidRequest) {
            _ = try await forwarder.perform(RemoteHTTPRequest(
                method: "POST", pathAndQuery: "/api/session",
                headers: ["x-opencode-directory": root.path],
                body: try JSONSerialization.data(withJSONObject: ["location": ["directory": second.path]])
            ))
        }
    }

    @Test func remoteRouteTableAllowsOnlyDocumentedV2FormOperations() {
        #expect(OpenCodeForwarder.isAllowed(method: "GET", path: "/api/session/ses_123/form"))
        #expect(OpenCodeForwarder.isAllowed(method: "POST", path: "/api/session/ses_123/form/frm_456/reply"))
        #expect(OpenCodeForwarder.isAllowed(method: "DELETE", path: "/api/session/ses_123/form/frm_456"))
        #expect(!OpenCodeForwarder.isAllowed(method: "POST", path: "/api/session/ses_123/form"))
        #expect(!OpenCodeForwarder.isAllowed(method: "GET", path: "/api/session/ses_123/form/frm_456"))
        #expect(!OpenCodeForwarder.isAllowed(method: "PATCH", path: "/api/session/ses_123/form/frm_456"))
        #expect(!OpenCodeForwarder.isAllowed(method: "POST", path: "/api/session/ses_123/form/frm_456/cancel"))
        #expect(!OpenCodeForwarder.isAllowed(method: "POST", path: "/api/session/../form/frm_456/reply"))
    }

    @Test func remoteRelayRejectsAmbiguousOrUnregisteredV2WorkspaceLocations() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let registry = WorkspaceRegistry(
            storageURL: root.appendingPathComponent("allowlist.json")
        )
        _ = try registry.add(url: root)
        let forwarder = OpenCodeForwarder(workspaceRegistry: registry, password: "test-password")
        let deliveryQueue = DispatchQueue(label: "remote-workspace-test")

        let acceptedStream = try forwarder.makeEventStream(
            request: RemoteHTTPRequest(
                method: "GET",
                pathAndQuery: "/api/event",
                headers: ["x-opencode-directory": root.path]
            ),
            deliveryQueue: deliveryQueue,
            onOpened: { _, _ in },
            onData: { _ in },
            onComplete: { _ in }
        )
        acceptedStream.cancel()

        let requests = [
            RemoteHTTPRequest(
                method: "GET",
                pathAndQuery: "/api/event",
                headers: [
                    "x-opencode-directory": root.path,
                    "X-OpenCode-Directory": root.path,
                ]
            ),
            RemoteHTTPRequest(
                method: "GET",
                pathAndQuery: "/api/event?directory=\(root.path)",
                headers: ["x-opencode-directory": root.path]
            ),
            RemoteHTTPRequest(
                method: "GET",
                pathAndQuery: "/api/event?directory=\(root.path)/unregistered"
            ),
            RemoteHTTPRequest(
                method: "GET",
                pathAndQuery: "/api/event?directory=\(root.path.replacingOccurrences(of: "/", with: "%2F"))"
            ),
            RemoteHTTPRequest(
                method: "GET",
                pathAndQuery: "/api/event?directory=\(root.path)&location[directory]=\(root.path)"
            ),
            RemoteHTTPRequest(
                method: "GET",
                pathAndQuery: "/api/event",
                headers: ["x-opencode-directory": root.path.replacingOccurrences(of: "/", with: "%2F")]
            ),
        ]

        for request in requests {
            #expect(throws: RemoteProtocolError.invalidRequest) {
                _ = try forwarder.makeEventStream(
                    request: request,
                    deliveryQueue: deliveryQueue,
                    onOpened: { _, _ in },
                    onData: { _ in },
                    onComplete: { _ in }
                )
            }
        }
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

private final class ForwarderURLProtocol: URLProtocol, @unchecked Sendable {
    private struct Response {
        let statusCode: Int
        let body: Data
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var response = Response(statusCode: 200, body: Data())
    nonisolated(unsafe) private static var request: URLRequest?
    nonisolated(unsafe) private static var routes: [String: Data] = [:]
    nonisolated(unsafe) private static var history: [URLRequest] = []

    static func setRoutes(_ values: [String: Data]) {
        lock.lock()
        routes = values
        history = []
        request = nil
        response = Response(statusCode: 200, body: Data())
        lock.unlock()
    }

    static func recordedRequests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return history
    }

    static func setResponse(statusCode: Int, body: Data) {
        lock.lock()
        response = Response(statusCode: statusCode, body: body)
        request = nil
        routes = [:]
        history = []
        lock.unlock()
    }

    static func recordedRequest() -> URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return request
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        var captured = request
        if captured.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(contentsOf: buffer.prefix(count))
            }
            captured.httpBody = body
        }
        Self.lock.lock()
        Self.request = captured
        Self.history.append(captured)
        let response = Self.routes[request.url?.path ?? ""].map { Response(statusCode: 200, body: $0) } ?? Self.response
        Self.lock.unlock()

        let url = request.url ?? URL(string: "http://127.0.0.1")!
        let http = HTTPURLResponse(
            url: url,
            statusCode: response.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
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
