import Foundation
import Testing
@testable import OpenLens

struct OpenCodeV2SessionMutationTests {
    @Test func v2SessionMutationsUseV2RoutesAndHandleNoContentResponses() async throws {
        let transport = V2SessionMutationTransport(responses: [
            .init(statusCode: 200, body: OpenCodeContractFixtures.v2InfoResponse),
            .init(statusCode: 200, body: sessionEnvelope(id: "ses_new", title: "New session")),
            .init(statusCode: 204, body: Data()),
            .init(statusCode: 200, body: sessionEnvelope(id: "ses_new", title: "Renamed session")),
            .init(statusCode: 204, body: Data()),
        ])
        let client = OpenCodeClient(
            baseURL: try #require(URL(string: "https://opencode.example.com")),
            contextDirectory: "/workspace/OpenLens",
            transport: transport
        )
        _ = try await client.probeCapabilities()

        let created = try await client.createSession(title: "New session")
        let renamed = try await client.updateSession(id: created.id, title: "Renamed session")
        let deleted = try await client.deleteSession(id: created.id)

        #expect(created.title == "New session")
        #expect(renamed.title == "Renamed session")
        #expect(deleted)

        let requests = transport.recordedRequests()
        #expect(requests.map(\.method) == ["GET", "POST", "PATCH", "GET", "DELETE"])
        #expect(requests.map(\.path) == [
            "/api/info",
            "/api/session",
            "/api/session/ses_new",
            "/api/session/ses_new",
            "/api/session/ses_new",
        ])
        #expect(requests[1].queryItems["location[directory]"] == "/workspace/OpenLens")
        #expect(requests[2...].allSatisfy { $0.queryItems["location[directory]"] == nil })
        #expect(try bodyObject(requests[1])["title"] as? String == "New session")
        #expect(try bodyObject(requests[2])["title"] as? String == "Renamed session")
        #expect(requests[4].body == nil)
    }

    @Test func v2SessionCreationRefreshesTheCallerIdentifiedSessionAfterNoContent() async throws {
        let transport = V2SessionMutationTransport(responses: [
            .init(statusCode: 200, body: OpenCodeContractFixtures.v2InfoResponse),
            .init(statusCode: 204, body: Data()),
            .init(statusCode: 200, body: sessionEnvelope(id: "ses_created", title: "No-content session")),
        ])
        let client = OpenCodeClient(
            baseURL: try #require(URL(string: "https://opencode.example.com")),
            transport: transport
        )
        _ = try await client.probeCapabilities()

        let created = try await client.createSession(title: "No-content session")

        #expect(created.id == "ses_created")
        let requests = transport.recordedRequests()
        #expect(requests[0].path == "/api/info")
        #expect(requests[1].path == "/api/session")
        let createBody = try bodyObject(requests[1])
        let callerID = try #require(createBody["id"] as? String)
        #expect(callerID.hasPrefix("ses_"))
        #expect(requests[2].path == "/api/session/\(callerID)")
    }

    @Test func v2PromptAppliesModelAndAgentBeforeAdmittingTheCallerIdentifiedTurn() async throws {
        let transport = V2SessionMutationTransport(responses: [
            .init(statusCode: 200, body: OpenCodeContractFixtures.v2InfoResponse),
            .init(statusCode: 204, body: Data()),
            .init(statusCode: 204, body: Data()),
            .init(statusCode: 200, body: Data(#"{"data":{"id":"msg_local","sessionID":"ses_1","time":{"created":0},"type":"user","payload":{"text":"Explain the migration"},"delivery":"steer"}}"#.utf8)),
        ])
        let client = OpenCodeClient(
            baseURL: try #require(URL(string: "https://opencode.example.com")),
            transport: transport
        )
        _ = try await client.probeCapabilities()

        try await client.sendPromptAsync(
            sessionID: "ses_1",
            text: "Explain the migration",
            model: .init(providerID: "anthropic", modelID: "claude-sonnet"),
            agent: "build",
            variant: "high",
            messageID: "msg_local"
        )

        let requests = transport.recordedRequests()
        #expect(requests.map(\.path) == [
            "/api/info",
            "/api/session/ses_1/model",
            "/api/session/ses_1/agent",
            "/api/session/ses_1/prompt",
        ])

        let modelPayload = try bodyObject(requests[1])
        let model = try #require(modelPayload["model"] as? [String: Any])
        #expect(model["id"] as? String == "claude-sonnet")
        #expect(model["providerID"] as? String == "anthropic")
        #expect(model["variant"] as? String == "high")
        #expect(try bodyObject(requests[2])["agent"] as? String == "build")

        let prompt = try bodyObject(requests[3])
        #expect(prompt["id"] as? String == "msg_local")
        #expect(prompt["text"] as? String == "Explain the migration")
        #expect(prompt["delivery"] as? String == "steer")
        #expect(requests[1...].allSatisfy { $0.queryItems["location[directory]"] == nil })
    }

    @Test func v2CommandUsesTheCommandAdmissionRouteAndRequestedDelivery() async throws {
        let transport = V2SessionMutationTransport(responses: [
            .init(statusCode: 200, body: OpenCodeContractFixtures.v2InfoResponse),
            .init(statusCode: 204, body: Data()),
            .init(statusCode: 204, body: Data()),
            .init(statusCode: 204, body: Data()),
        ])
        let client = OpenCodeClient(
            baseURL: try #require(URL(string: "https://opencode.example.com")),
            transport: transport
        )
        _ = try await client.probeCapabilities()

        try await client.sendCommand(
            sessionID: "ses_1",
            command: "review",
            arguments: "--staged",
            model: .init(providerID: "anthropic", modelID: "claude-sonnet"),
            agent: "build",
            variant: "high",
            files: ["README.md"],
            agents: ["reviewer"],
            skills: ["swift"],
            delivery: .queue
        )

        let requests = transport.recordedRequests()
        #expect(requests.map(\.path) == [
            "/api/info",
            "/api/session/ses_1/model",
            "/api/session/ses_1/agent",
            "/api/session/ses_1/command",
        ])
        #expect(requests[1...].allSatisfy { $0.method == "POST" })
        #expect(requests[1...].allSatisfy { $0.queryItems["location[directory]"] == nil })

        let modelPayload = try bodyObject(requests[1])
        let model = try #require(modelPayload["model"] as? [String: Any])
        #expect(model["id"] as? String == "claude-sonnet")
        #expect(model["providerID"] as? String == "anthropic")
        #expect(model["variant"] as? String == "high")
        #expect(try bodyObject(requests[2])["agent"] as? String == "build")

        let command = try bodyObject(requests[3])
        #expect(command["name"] as? String == "review")
        #expect(command["text"] as? String == "--staged")
        #expect(command["files"] as? [String] == ["README.md"])
        #expect(command["agents"] as? [String] == ["reviewer"])
        #expect(command["skills"] as? [String] == ["swift"])
        #expect(command["delivery"] as? String == "queue")
        #expect(command["command"] == nil)
        #expect(command["arguments"] == nil)
    }

    @Test func v2InterruptUsesTheInterruptRouteAndReturnsTheServerResult() async throws {
        let transport = V2SessionMutationTransport(responses: [
            .init(statusCode: 200, body: OpenCodeContractFixtures.v2InfoResponse),
            .init(statusCode: 200, body: Data(#"{"interrupted":false}"#.utf8)),
            .init(statusCode: 200, body: Data(#"{"interrupted":true}"#.utf8)),
        ])
        let client = OpenCodeClient(
            baseURL: try #require(URL(string: "https://opencode.example.com")),
            transport: transport
        )
        _ = try await client.probeCapabilities()

        #expect(try await client.abortSession(id: "ses_idle") == false)
        #expect(try await client.abortSession(id: "ses_busy") == true)

        let requests = transport.recordedRequests()
        #expect(requests.map(\.path) == [
            "/api/info",
            "/api/session/ses_idle/interrupt",
            "/api/session/ses_busy/interrupt",
        ])
        #expect(requests[1...].allSatisfy { $0.method == "POST" })
        #expect(requests[1...].allSatisfy { $0.body == nil })
        #expect(requests[1...].allSatisfy { $0.queryItems["location[directory]"] == nil })
    }

    private func sessionEnvelope(id: String, title: String) -> Data {
        Data(#"{"data":{"id":"\#(id)","title":"\#(title)","time":{"created":0,"updated":0}}}"#.utf8)
    }

    private func bodyObject(_ request: V2SessionMutationTransport.RecordedRequest) throws -> [String: Any] {
        let data = try #require(request.body)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

nonisolated private final class V2SessionMutationTransport: OpenCodeTransport, @unchecked Sendable {
    struct Response: Sendable {
        let statusCode: Int
        let body: Data
    }

    struct RecordedRequest: Sendable {
        let method: String
        let path: String
        let queryItems: [String: String]
        let body: Data?
    }

    private let lock = NSLock()
    private var responses: [Response]
    private var requests: [RecordedRequest] = []

    init(responses: [Response]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = try #require(request.url)
        let queryItems = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .reduce(into: [String: String]()) { result, item in
                if let value = item.value {
                    result[item.name] = value
                }
            }
        let response: Response
        lock.lock()
        requests.append(
            .init(
                method: request.httpMethod ?? "GET",
                path: url.path,
                queryItems: queryItems,
                body: request.httpBody
            )
        )
        guard !responses.isEmpty else {
            lock.unlock()
            throw MissingV2SessionMutationResponse()
        }
        response = responses.removeFirst()
        lock.unlock()

        return (
            response.body,
            HTTPURLResponse(url: url, statusCode: response.statusCode, httpVersion: nil, headerFields: nil)!
        )
    }

    func makeEventStream(
        request: URLRequest,
        deliveryQueue: DispatchQueue,
        callbacks: OpenCodeEventStreamCallbacks
    ) -> any OpenCodeEventStream {
        UnusedV2SessionMutationEventStream()
    }

    func recordedRequests() -> [RecordedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
}

nonisolated private struct MissingV2SessionMutationResponse: Error {}

nonisolated private final class UnusedV2SessionMutationEventStream: OpenCodeEventStream, @unchecked Sendable {
    func start() {}
    func suspend() {}
    func resume() {}
    func cancel() {}
}
