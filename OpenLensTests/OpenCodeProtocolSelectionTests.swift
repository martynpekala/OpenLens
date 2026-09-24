import Foundation
import Testing
@testable import OpenLens

struct OpenCodeProtocolSelectionTests {
    @Test func v2SessionStatusesUseTheActiveSnapshotWithoutV1Routes() async throws {
        let transport = OpenCodeContractTransport(routes: [
            "/api/info": .init(statusCode: 200, body: OpenCodeContractFixtures.v2InfoResponse),
            "/api/session/active": .init(statusCode: 200, body: Data(#"""
            {
              "data": {
                "ses_running": {"type": "running"}
              }
            }
            """#.utf8)),
        ])
        let client = OpenCodeClient(
            baseURL: try #require(URL(string: "http://opencode.example.com")),
            transport: transport
        )

        _ = try await client.probeCapabilities()
        let statuses = try await client.getSessionStatus()

        #expect(statuses["ses_running"]?.type == .busy)
        #expect(await transport.recordedPaths() == [
            "/api/info",
            "/api/session/active",
        ])
    }

    @Test func v2TodosReturnAnEmptySnapshotWithoutV1Routes() async throws {
        let transport = OpenCodeContractTransport(routes: [
            "/api/info": .init(statusCode: 200, body: OpenCodeContractFixtures.v2InfoResponse),
        ])
        let client = OpenCodeClient(
            baseURL: try #require(URL(string: "http://opencode.example.com")),
            transport: transport
        )

        _ = try await client.probeCapabilities()
        let todos = try await client.listTodos(sessionID: "ses_123")

        #expect(todos.todos.isEmpty)
        #expect(todos.hiddenCount == 0)
        #expect(await transport.recordedPaths() == ["/api/info"])
    }

    @Test func v2SessionSharingIsRejectedWithoutAV1Request() async throws {
        let transport = OpenCodeContractTransport(routes: [
            "/api/info": .init(statusCode: 200, body: OpenCodeContractFixtures.v2InfoResponse),
        ])
        let client = OpenCodeClient(
            baseURL: try #require(URL(string: "http://opencode.example.com")),
            transport: transport
        )

        _ = try await client.probeCapabilities()
        do {
            _ = try await client.shareSession(id: "ses_123")
            Issue.record("v2 session sharing must be unavailable rather than use the v1 endpoint.")
        } catch let error as OpenCodeError {
            guard case .invalidPayload = error else {
                Issue.record("Expected a clear unavailable-feature error, got \(error).")
                return
            }
        }

        #expect(await transport.recordedPaths() == ["/api/info"])
    }

    @Test func v2FailuresExposeTheTypedServerErrorPayload() async throws {
        let transport = OpenCodeContractTransport(routes: [
            "/api/info": .init(statusCode: 200, body: OpenCodeContractFixtures.v2InfoResponse),
            "/api/session": .init(statusCode: 401, body: Data(#"""
            {
              "_tag": "UnauthorizedError",
              "message": "Wrong password",
              "service": "opencode"
            }
            """#.utf8)),
        ])
        let client = OpenCodeClient(
            baseURL: try #require(URL(string: "http://opencode.example.com")),
            transport: transport
        )

        _ = try await client.probeCapabilities()
        do {
            _ = try await client.listSessions()
            Issue.record("Expected an authenticated v2 server error.")
        } catch let error as OpenCodeError {
            guard case let .apiError(statusCode, payload) = error else {
                Issue.record("Expected typed API error, got \(error).")
                return
            }
            #expect(statusCode == 401)
            #expect(payload.tag == "UnauthorizedError")
            #expect(payload.message == "Wrong password")
            #expect(payload.service == "opencode")
        }
    }

    @Test func v2MessageDetailUsesTheV2EnvelopeWithoutAV1Request() async throws {
        let transport = OpenCodeContractTransport(routes: [
            "/api/info": .init(statusCode: 200, body: OpenCodeContractFixtures.v2InfoResponse),
            "/api/session/ses_123/message/msg_456": .init(statusCode: 200, body: Data(#"""
            {
              "data": {
                "info": {
                  "id": "msg_456",
                  "sessionID": "ses_123",
                  "role": "assistant",
                  "time": {"created": 0}
                },
                "parts": []
              }
            }
            """#.utf8)),
        ])
        let client = OpenCodeClient(
            baseURL: try #require(URL(string: "http://opencode.example.com")),
            transport: transport
        )

        _ = try await client.probeCapabilities()
        let message = try await client.getMessage(sessionID: "ses_123", messageID: "msg_456")

        #expect(message.info.id == "msg_456")
        #expect(await transport.recordedPaths() == [
            "/api/info",
            "/api/session/ses_123/message/msg_456",
        ])
    }

    @Test func v1KeepsItsSupportedTodoAndSessionSharingRoutes() async throws {
        let transport = OpenCodeContractTransport(routes: [
            "/api/info": .init(statusCode: 404, body: Data(#"{"message":"not found"}"#.utf8)),
            "/global/health": .init(statusCode: 200, body: OpenCodeContractFixtures.v1HealthResponse),
            "/session/ses_123/todo": .init(statusCode: 200, body: Data(#"""
            [{"content":"Ship the migration","status":"in_progress","priority":"high"}]
            """#.utf8)),
            "/session/ses_123/share": .init(statusCode: 200, body: Data(#"""
            {"id":"ses_123","title":"Migration","time":{"created":0,"updated":0},"share":{"url":"https://example.com/ses_123"}}
            """#.utf8)),
        ])
        let client = OpenCodeClient(
            baseURL: try #require(URL(string: "http://opencode.example.com")),
            transport: transport
        )

        _ = try await client.probeCapabilities()
        let todos = try await client.listTodos(sessionID: "ses_123")
        let shared = try await client.shareSession(id: "ses_123")

        #expect(todos.todos.map(\.content) == ["Ship the migration"])
        #expect(shared.share?.url == "https://example.com/ses_123")
        #expect(await transport.recordedPaths() == [
            "/api/info",
            "/global/health",
            "/session/ses_123/todo",
            "/session/ses_123/share",
        ])
    }

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
            "/api/model": .init(statusCode: 200, body: Data(#"""
            {
              "location": {"directory":"/workspace/OpenLens","project":{"id":"openlens","directory":"/workspace/OpenLens"}},
              "data": [{"id":"coding-default","modelID":"gpt-5.2","providerID":"anthropic","name":"Claude Sonnet","capabilities":{"reasoning":true,"attachment":true,"toolcall":true},"variants":[]}]
            }
            """#.utf8)),
            "/api/model/default": .init(statusCode: 200, body: Data(#"""
            {"location":{"directory":"/workspace/OpenLens","project":{"id":"openlens","directory":"/workspace/OpenLens"}},"data":{"id":"coding-default","modelID":"gpt-5.2","providerID":"anthropic","name":"Claude Sonnet","variants":[]}}
            """#.utf8)),
            "/api/provider": .init(statusCode: 200, body: Data(#"""
            {"location":{"directory":"/workspace/OpenLens","project":{"id":"openlens","directory":"/workspace/OpenLens"}},"data":[{"id":"anthropic","name":"Anthropic"}]}
            """#.utf8)),
            "/api/agent": .init(statusCode: 200, body: Data(#"""
            {"location":{"directory":"/workspace/OpenLens","project":{"id":"openlens","directory":"/workspace/OpenLens"}},"data":[{"name":"build","description":"Build the app"}]}
            """#.utf8)),
            "/api/command": .init(statusCode: 200, body: Data(#"""
            {"location":{"directory":"/workspace/OpenLens","project":{"id":"openlens","directory":"/workspace/OpenLens"}},"data":[{"name":"review","description":"Review the diff"}]}
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
        let providers = try await client.listProviders()
        let agents = try await client.listAgents()
        let commands = try await client.listCommands()
        let files = try await client.listFiles()
        let vcs = try await client.getVCS()
        let status = try await client.listFileStatus()
        let diffs = try await client.getWorkingTreeDiff()
        let binary = try await client.readFileContent(path: "README.md")

        #expect(location.directory == "/workspace/OpenLens")
        #expect(location.worktree == "/workspace/OpenLens")
        #expect(currentProject.worktree == "/workspace/OpenLens")
        #expect(projects.map(\.id) == ["openlens"])
        #expect(providers.all.map(\.id) == ["anthropic"])
        #expect(providers.all.first?.name == "Anthropic")
        #expect(providers.all.first?.modelList.map(\.id) == ["coding-default"])
        #expect(providers.all.first?.modelList.first?.legacyModelID == "gpt-5.2")
        #expect(providers.default?["id"] == "anthropic")
        #expect(providers.default?["model"] == "coding-default")
        #expect(agents.map(\.id) == ["build"])
        #expect(commands.map(\.id) == ["review"])
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
            "/api/model",
            "/api/model/default",
            "/api/provider",
            "/api/agent",
            "/api/command",
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
