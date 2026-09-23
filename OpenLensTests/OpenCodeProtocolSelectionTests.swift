import Foundation
import Testing
@testable import OpenLens

struct OpenCodeProtocolSelectionTests {
    @Test func reachableV2ServerIsSelectedFromServerInfoEvidence() async throws {
        let transport = OpenCodeContractTransport(routes: [
            "/api/info": .init(statusCode: 200, body: OpenCodeContractFixtures.v2InfoResponse)
        ])
        let client = OpenCodeClient(
            baseURL: try #require(URL(string: "http://opencode.example.com")),
            transport: transport
        )

        let capabilities = try await client.probeCapabilities()

        #expect(capabilities.protocolVersion == .v2)
        #expect(capabilities.serverVersion == "2.0.0-contract")
        #expect(capabilities.eventStreamPath == "/api/event")
        #expect(capabilities.evidence == .v2ServerInfo)
        #expect(capabilities.serverInfo?.paths?.temporaryDirectory == "/tmp/opencode-contract")
        let paths = await transport.recordedPaths()
        #expect(paths == ["/api/info"])
    }

    @Test func v1ServerFallsBackWhenV2CapabilityEndpointIsMissing() async throws {
        let transport = OpenCodeContractTransport(routes: [
            "/api/info": .init(statusCode: 404, body: Data(#"{"message":"not found"}"#.utf8)),
            "/global/health": .init(statusCode: 200, body: OpenCodeContractFixtures.v1HealthResponse)
        ])
        let client = OpenCodeClient(
            baseURL: try #require(URL(string: "http://opencode.example.com")),
            transport: transport
        )

        let capabilities = try await client.probeCapabilities()

        #expect(capabilities.protocolVersion == .v1)
        #expect(capabilities.serverVersion == "1.5.4-contract")
        #expect(capabilities.eventStreamPath == "/event")
        #expect(capabilities.evidence == .v1Health)
        let paths = await transport.recordedPaths()
        #expect(paths == ["/api/info", "/global/health"])
    }

    @Test func incompatibleV2PayloadDoesNotSilentlyDowngradeToV1() async throws {
        let transport = OpenCodeContractTransport(routes: [
            "/api/info": .init(
                statusCode: 200,
                body: OpenCodeContractFixtures.invalidV2InfoResponse
            ),
            "/global/health": .init(statusCode: 200, body: OpenCodeContractFixtures.v1HealthResponse)
        ])
        let client = OpenCodeClient(
            baseURL: try #require(URL(string: "http://opencode.example.com")),
            transport: transport
        )

        do {
            _ = try await client.probeCapabilities()
            Issue.record("An incompatible v2 response must not be accepted or downgraded.")
        } catch let error as OpenCodeError {
            guard case .invalidPayload = error else {
                Issue.record("Expected an invalid v2 payload error, got \(error).")
                return
            }
        }

        let paths = await transport.recordedPaths()
        #expect(paths == ["/api/info"])
    }

    @MainActor
    @Test func v2SSEFixtureUsesTheV2EventEndpointAndEventName() async throws {
        let transport = OpenCodeContractTransport(
            routes: [:],
            eventStreamData: OpenCodeContractFixtures.v2EventStream
        )
        let client = SSEClient(
            baseURL: try #require(URL(string: "http://opencode.example.com")),
            protocolVersion: .v2,
            transport: transport
        )
        var receivedEvent: OCEvent?
        var receivedInboundEvent: SSEInboundEvent?
        client.onEvent = { receivedEvent = $0 }
        client.onInboundEvent = { receivedInboundEvent = $0 }
        client.connect()

        for _ in 0..<40 where receivedEvent == nil {
            try? await Task.sleep(for: .milliseconds(10))
        }

        let eventPaths = await transport.recordedEventPaths()
        #expect(eventPaths == ["/api/event"])
        #expect(receivedInboundEvent != nil)
        #expect(receivedEvent?.type == "session.updated")
        #expect(receivedEvent?.sessionID == "session-contract-1")
        client.disconnect()
    }

    @MainActor
    @Test func v1SSEFixtureKeepsTheLegacyEventEndpointAndPayload() async throws {
        let transport = OpenCodeContractTransport(
            routes: [:],
            eventStreamData: OpenCodeContractFixtures.v1EventStream
        )
        let client = SSEClient(
            baseURL: try #require(URL(string: "http://opencode.example.com")),
            protocolVersion: .v1,
            transport: transport
        )
        var receivedEvent: OCEvent?
        client.onEvent = { receivedEvent = $0 }
        client.connect()

        for _ in 0..<40 where receivedEvent == nil {
            try? await Task.sleep(for: .milliseconds(10))
        }

        let eventPaths = await transport.recordedEventPaths()
        #expect(eventPaths == ["/event"])
        #expect(receivedEvent?.type == "server.heartbeat")
        let sequence = (receivedEvent?.properties?.value as? [String: Any])?["sequence"] as? Int
        #expect(sequence == 7)
        client.disconnect()
    }
}

nonisolated private final class OpenCodeContractTransport: OpenCodeTransport, @unchecked Sendable {
    struct Fixture: Sendable {
        let statusCode: Int
        let body: Data
        let headers: [String: String]

        init(statusCode: Int, body: Data, headers: [String: String] = ["Content-Type": "application/json"]) {
            self.statusCode = statusCode
            self.body = body
            self.headers = headers
        }
    }

    private let routes: [String: Fixture]
    private let pathRecorder = OpenCodeContractPathRecorder()
    private let eventStreamData: Data?
    private let eventPathRecorder = OpenCodeContractPathRecorder()

    init(routes: [String: Fixture], eventStreamData: Data? = nil) {
        self.routes = routes
        self.eventStreamData = eventStreamData
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let path = request.url?.path ?? ""
        await pathRecorder.append(path)

        guard let fixture = routes[path] else {
            throw MissingOpenCodeContractRoute(path: path)
        }

        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "http://opencode.example.com")!,
            statusCode: fixture.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: fixture.headers
        )!
        return (fixture.body, response)
    }

    func makeEventStream(
        request: URLRequest,
        deliveryQueue _: DispatchQueue,
        callbacks: OpenCodeEventStreamCallbacks
    ) -> any OpenCodeEventStream {
        Task {
            await eventPathRecorder.append(request.url?.path ?? "")
        }
        if let eventStreamData {
            return OpenCodeContractEventStream(
                request: request,
                callbacks: callbacks,
                data: eventStreamData
            )
        }
        return UnusedOpenCodeContractEventStream()
    }

    func recordedPaths() async -> [String] {
        await pathRecorder.values()
    }

    func recordedEventPaths() async -> [String] {
        await eventPathRecorder.values()
    }
}

private actor OpenCodeContractPathRecorder {
    private var paths: [String] = []

    func append(_ path: String) {
        paths.append(path)
    }

    func values() -> [String] {
        paths
    }
}

private struct MissingOpenCodeContractRoute: Error {
    let path: String
}

nonisolated private final class OpenCodeContractEventStream: OpenCodeEventStream, @unchecked Sendable {
    private let request: URLRequest
    private let callbacks: OpenCodeEventStreamCallbacks
    private let data: Data

    init(
        request: URLRequest,
        callbacks: OpenCodeEventStreamCallbacks,
        data: Data
    ) {
        self.request = request
        self.callbacks = callbacks
        self.data = data
    }

    func start() {
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "http://opencode.example.com")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        guard callbacks.onResponse(response) else { return }
        callbacks.onData(data)
    }

    func suspend() {}
    func resume() {}
    func cancel() {}
}

nonisolated private final class UnusedOpenCodeContractEventStream: OpenCodeEventStream, @unchecked Sendable {
    func start() {}
    func suspend() {}
    func resume() {}
    func cancel() {}
}
