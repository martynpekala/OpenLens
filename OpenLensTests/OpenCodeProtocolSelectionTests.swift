import Foundation
import Testing
@testable import OpenLens

struct OpenCodeProtocolSelectionTests {
    @Test func v2WorkspaceReadsUseCanonicalLocationAndMapBinaryFilesSafely() async throws {
        let transport = OpenCodeContractTransport(routes: [
            "/api/info": .init(statusCode: 200, body: OpenCodeContractFixtures.v2InfoResponse),
            "/api/location": .init(statusCode: 200, body: Data(#"""
            {
              "directory": "/workspace/OpenLens",
              "project": {"id": "openlens", "directory": "/workspace/OpenLens"}
            }
            """#.utf8)),
            "/api/project": .init(statusCode: 200, body: Data(#"""
            [{"id":"openlens","worktree":"/workspace/OpenLens","time":{"created":0}}]
            """#.utf8)),
            "/api/project/current": .init(statusCode: 200, body: Data(#"""
            {"id":"openlens","directory":"/workspace/OpenLens","time":{"created":0}}
            """#.utf8)),
            "/api/fs/list": .init(statusCode: 200, body: Data(#"""
            {
              "location": {"directory":"/workspace/OpenLens","project":{"id":"openlens","directory":"/workspace/OpenLens"}},
              "data": [
                {"path":"Sources","type":"directory"},
                {"path":"README.md","type":"file"}
              ]
            }
            """#.utf8)),
            "/api/fs/read/README.md": .init(
                statusCode: 200,
                body: Data([0x89, 0x50, 0x4E, 0x47]),
                headers: ["Content-Type": "image/png"]
            ),
            "/api/vcs": .init(statusCode: 200, body: Data(#"""
            {"location":{"directory":"/workspace/OpenLens","project":{"id":"openlens","directory":"/workspace/OpenLens"}},"data":{"branch":"main"}}
            """#.utf8)),
            "/api/vcs/status": .init(statusCode: 200, body: Data(#"""
            {"location":{"directory":"/workspace/OpenLens","project":{"id":"openlens","directory":"/workspace/OpenLens"}},"data":[{"file":"README.md","additions":2,"deletions":1,"status":"modified"}]}
            """#.utf8)),
            "/api/vcs/diff": .init(statusCode: 200, body: Data(#"""
            {"location":{"directory":"/workspace/OpenLens","project":{"id":"openlens","directory":"/workspace/OpenLens"}},"data":[{"file":"README.md","patch":"@@ -1,1 +1,1 @@\n-old\n+new\n","additions":1,"deletions":1,"status":"modified"}]}
            """#.utf8))
        ])
        let client = OpenCodeClient(
            baseURL: try #require(URL(string: "http://opencode.example.com")),
            contextDirectory: "/workspace/OpenLens-alias",
            transport: transport
        )

        _ = try await client.probeCapabilities()
        let location = try await client.getPath()
        let currentProject = try await client.getCurrentProject()
        let projects = try await client.listProjects()
        let files = try await client.listFiles()
        let vcs = try await client.getVCS()
        let status = try await client.listFileStatus()
        let diffs = try await client.getWorkingTreeDiff()
        let binary = try await client.readFileContent(path: "README.md")

        #expect(location.directory == "/workspace/OpenLens")
        #expect(location.worktree == "/workspace/OpenLens")
        #expect(currentProject.worktree == "/workspace/OpenLens")
        #expect(projects.map(\.id) == ["openlens"])
        #expect(files.map(\.path) == ["Sources", "README.md"])
        #expect(files.map(\.name) == ["Sources", "README.md"])
        #expect(vcs.branch == "main")
        #expect(status == [OCWorkspaceFileStatus(path: "README.md", added: 2, removed: 1, status: "modified")])
        #expect(ReviewFileChange(diff: try #require(diffs.first)).hasReadableDiff)
        #expect(binary.type == "binary")
        #expect(binary.resolvedTextContent == nil)

        let requests = await transport.recordedRequests()
        #expect(requests.allSatisfy { $0.headers["x-opencode-directory"] == nil })
        #expect(requests.map(\.path) == [
            "/api/info",
            "/api/location",
            "/api/project/current",
            "/api/project",
            "/api/fs/list",
            "/api/vcs",
            "/api/vcs/status",
            "/api/vcs/diff",
            "/api/fs/read/README.md"
        ])
        #expect(requests[1].queryItems["location[directory]"] == "/workspace/OpenLens-alias")
        #expect(requests.dropFirst(2).allSatisfy { $0.queryItems["location[directory]"] == "/workspace/OpenLens" })
    }

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
    struct RecordedRequest: Sendable {
        let path: String
        let queryItems: [String: String]
        let headers: [String: String]
    }

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
    private let requestRecorder = OpenCodeContractRequestRecorder()
    private let eventStreamData: Data?
    private let eventPathRecorder = OpenCodeContractPathRecorder()

    init(routes: [String: Fixture], eventStreamData: Data? = nil) {
        self.routes = routes
        self.eventStreamData = eventStreamData
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let path = request.url?.path ?? ""
        await pathRecorder.append(path)
        await requestRecorder.append(request)

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

    func recordedRequests() async -> [RecordedRequest] {
        await requestRecorder.values()
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

private actor OpenCodeContractRequestRecorder {
    private var requests: [OpenCodeContractTransport.RecordedRequest] = []

    func append(_ request: URLRequest) {
        let queryItems = URLComponents(url: request.url ?? URL(string: "http://opencode.example.com")!, resolvingAgainstBaseURL: false)?
            .queryItems?
            .reduce(into: [String: String]()) { items, item in
                items[item.name] = item.value
            } ?? [:]
        requests.append(
            .init(
                path: request.url?.path ?? "",
                queryItems: queryItems,
                headers: request.allHTTPHeaderFields ?? [:]
            )
        )
    }

    func values() -> [OpenCodeContractTransport.RecordedRequest] {
        requests
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
