import Foundation
import Testing
@testable import OpenLens

struct OpenCodeV2PermissionTests {
    @Test func v2PermissionsUseTheOwningSessionForRecoveryAndReplies() async throws {
        let transport = V2PermissionTransport(responses: [
            .init(statusCode: 200, body: OpenCodeContractFixtures.v2InfoResponse),
            .init(statusCode: 200, body: permissionListEnvelope()),
            .init(statusCode: 204, body: Data()),
            .init(statusCode: 204, body: Data()),
            .init(statusCode: 204, body: Data()),
        ])
        let client = OpenCodeClient(
            baseURL: try #require(URL(string: "https://opencode.example.com")),
            contextDirectory: "/workspace/OpenLens",
            transport: transport
        )
        _ = try await client.probeCapabilities()

        let permissions = try await client.listPermissions(sessionID: "ses_1")
        _ = try await client.replyToPermission(sessionID: "ses_1", requestID: "per_1", reply: .once)
        _ = try await client.replyToPermission(sessionID: "ses_1", requestID: "per_1", reply: .always)
        _ = try await client.replyToPermission(sessionID: "ses_1", requestID: "per_1", reply: .reject)

        #expect(permissions.map(\.id) == ["per_1"])
        #expect(permissions.first?.sessionID == "ses_1")

        let requests = transport.recordedRequests()
        #expect(requests.map(\.path) == [
            "/api/info",
            "/api/session/ses_1/permission",
            "/api/session/ses_1/permission/per_1/reply",
            "/api/session/ses_1/permission/per_1/reply",
            "/api/session/ses_1/permission/per_1/reply",
        ])
        #expect(requests[1...].allSatisfy { $0.queryItems["location[directory]"] == nil })
        #expect(try bodyObject(requests[2])["decision"] as? String == "once")
        #expect(try bodyObject(requests[3])["decision"] as? String == "always")
        #expect(try bodyObject(requests[4])["decision"] as? String == "reject")
    }

    @Test func v2PermissionInboxRecoveryUsesTheLocationScopedRequestRoute() async throws {
        let transport = V2PermissionTransport(responses: [
            .init(statusCode: 200, body: OpenCodeContractFixtures.v2InfoResponse),
            .init(statusCode: 200, body: locatedPermissionListEnvelope()),
        ])
        let client = OpenCodeClient(
            baseURL: try #require(URL(string: "https://opencode.example.com")),
            contextDirectory: "/workspace/OpenLens",
            transport: transport
        )
        _ = try await client.probeCapabilities()

        let permissions = try await client.listPermissions()

        #expect(permissions.map(\.id) == ["per_inbox"])
        let request = try #require(transport.recordedRequests().last)
        #expect(request.path == "/api/permission/request")
        #expect(request.queryItems["location[directory]"] == "/workspace/OpenLens")
    }

    @Test func v2PermissionReplyRejectsRequestsWithoutSessionOwnership() async throws {
        let transport = V2PermissionTransport(responses: [
            .init(statusCode: 200, body: OpenCodeContractFixtures.v2InfoResponse),
        ])
        let client = OpenCodeClient(
            baseURL: try #require(URL(string: "https://opencode.example.com")),
            transport: transport
        )
        _ = try await client.probeCapabilities()

        await #expect(throws: OpenCodeError.self) {
            try await client.replyToPermission(sessionID: nil, requestID: "per_1", reply: .once)
        }

        #expect(transport.recordedRequests().map(\.path) == ["/api/info"])
    }

    @Test(arguments: [false, true], [false, true])
    func widgetPermissionRepliesUseTheNegotiatedContract(usesV2: Bool, approve: Bool) throws {
        let request = try SharedConnectionStore.permissionReplyRequest(
            baseURL: #require(URL(string: "https://example.com")), authHeader: "Basic test",
            usesV2: usesV2, sessionID: "ses_1", requestID: "per_1", approve: approve
        )
        #expect(request.url?.path == (usesV2 ? "/api/session/ses_1/permission/per_1/reply" : "/permission/per_1/reply"))
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic test")
        let body = try JSONDecoder().decode([String: String].self, from: #require(request.httpBody))
        #expect(body == [usesV2 ? "decision" : "reply": approve ? "once" : "reject"])
    }

    private func permissionListEnvelope() -> Data {
        Data(#"{"data":[{"id":"per_1","action":"mcp.github.list_issues","resources":["github:list_issues"]}]}"#.utf8)
    }

    private func locatedPermissionListEnvelope() -> Data {
        Data(#"{"location":{"directory":"/workspace/OpenLens"},"data":[{"id":"per_inbox","sessionID":"ses_inbox","action":"bash","resources":["npm test"]}]}"#.utf8)
    }

    private func bodyObject(_ request: V2PermissionTransport.RecordedRequest) throws -> [String: Any] {
        let data = try #require(request.body)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

nonisolated private final class V2PermissionTransport: OpenCodeTransport, @unchecked Sendable {
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
        let response = try lock.withLock { () throws -> Response in
            requests.append(.init(
                method: request.httpMethod ?? "GET",
                path: url.path,
                queryItems: queryItems,
                body: request.httpBody
            ))
            guard !responses.isEmpty else {
                throw MissingV2PermissionResponse()
            }
            return responses.removeFirst()
        }

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
        UnusedV2PermissionEventStream()
    }

    func recordedRequests() -> [RecordedRequest] {
        lock.withLock { requests }
    }
}

nonisolated private struct MissingV2PermissionResponse: Error {}

nonisolated private final class UnusedV2PermissionEventStream: OpenCodeEventStream, @unchecked Sendable {
    func start() {}
    func suspend() {}
    func resume() {}
    func cancel() {}
}
