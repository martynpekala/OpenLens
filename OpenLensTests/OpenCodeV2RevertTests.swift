import Foundation
import Testing
@testable import OpenLens

struct OpenCodeV2RevertTests {
    @Test func v2RevertClearsStaleStateStagesTheSelectedMessageCommitsAndRefreshesSession() async throws {
        let transport = V2RevertTransport(contract: [
            .init(method: "GET", path: "/api/info", statusCode: 200, body: OpenCodeContractFixtures.v2InfoResponse),
            .init(method: "DELETE", path: "/api/session/ses_1/revert", statusCode: 204, body: Data()),
            .init(
                method: "POST",
                path: "/api/session/ses_1/revert/stage",
                statusCode: 200,
                body: Data(#"{"data":{"messageID":"msg_2"}}"#.utf8)
            ),
            .init(method: "POST", path: "/api/session/ses_1/revert/commit", statusCode: 204, body: Data()),
            .init(
                method: "GET",
                path: "/api/session/ses_1",
                statusCode: 200,
                body: sessionEnvelope(id: "ses_1", title: "Reverted")
            ),
        ])
        let client = OpenCodeClient(
            baseURL: try #require(URL(string: "https://opencode.example.com")),
            transport: transport
        )
        _ = try await client.probeCapabilities()

        let session = try #require(
            try await client.revertMessage(sessionID: "ses_1", messageID: "msg_2")
        )

        #expect(session.id == "ses_1")
        #expect(session.title == "Reverted")

        let requests = transport.recordedRequests()
        #expect(requests.map(\.method) == ["GET", "DELETE", "POST", "POST", "GET"])
        #expect(requests.map(\.path) == [
            "/api/info",
            "/api/session/ses_1/revert",
            "/api/session/ses_1/revert/stage",
            "/api/session/ses_1/revert/commit",
            "/api/session/ses_1",
        ])
        #expect(requests[1...].allSatisfy { $0.queryItems["location[directory]"] == nil })
        #expect(requests[1].body == nil)
        #expect(requests[3].body == nil)

        let stagePayload = try #require(requests[2].body)
        let stage = try #require(JSONSerialization.jsonObject(with: stagePayload) as? [String: Any])
        #expect(stage["messageID"] as? String == "msg_2")
        #expect(stage["files"] as? Bool == true)
    }

    @Test func v2SessionDiffUsesTheV2RouteAndSelectedTurnBoundary() async throws {
        let transport = V2RevertTransport(contract: [
            .init(method: "GET", path: "/api/info", statusCode: 200, body: OpenCodeContractFixtures.v2InfoResponse),
            .init(
                method: "GET",
                path: "/api/session/ses_1/diff",
                statusCode: 200,
                body: Data(#"{"data":[{"file":"Earlier.swift","patch":"-let version = 1\n+let version = 2"}]}"#.utf8),
                queryItems: ["from": "msg_earlier"]
            ),
            .init(
                method: "GET",
                path: "/api/session/ses_1/diff",
                statusCode: 200,
                body: Data(#"{"data":[{"file":"Later.swift","patch":"-let version = 2\n+let version = 3"}]}"#.utf8),
                queryItems: ["from": "msg_later"]
            ),
            .init(
                method: "GET",
                path: "/api/session/ses_1/diff",
                statusCode: 200,
                body: Data(#"{"data":[{"file":"Current.swift","patch":"-let version = 3\n+let version = 4"}]}"#.utf8)
            ),
        ])
        let client = OpenCodeClient(
            baseURL: try #require(URL(string: "https://opencode.example.com")),
            contextDirectory: "/workspace/Other",
            transport: transport
        )
        _ = try await client.probeCapabilities()

        let earlierDiff = try await client.getSessionDiff(sessionID: "ses_1", messageID: "msg_earlier")
        let laterDiff = try await client.getSessionDiff(sessionID: "ses_1", messageID: "msg_later")
        let defaultDiff = try await client.getSessionDiff(sessionID: "ses_1")

        #expect(earlierDiff.first?.file == "Earlier.swift")
        #expect(laterDiff.first?.file == "Later.swift")
        #expect(defaultDiff.first?.file == "Current.swift")

        let requests = transport.recordedRequests()
        #expect(requests[1...].map(\.path) == Array(repeating: "/api/session/ses_1/diff", count: 3))
        #expect(requests[1].queryItems == ["from": "msg_earlier"])
        #expect(requests[2].queryItems == ["from": "msg_later"])
        #expect(requests[3].queryItems.isEmpty)
    }

    @Test func v1SessionDiffKeepsTheLegacyMessageIDBoundary() async throws {
        let transport = V2RevertTransport(contract: [
            .init(
                method: "GET",
                path: "/session/ses_1/diff",
                statusCode: 200,
                body: Data(#"[]"#.utf8),
                queryItems: ["messageID": "msg_legacy"]
            ),
        ])
        let client = OpenCodeClient(
            baseURL: try #require(URL(string: "https://opencode.example.com")),
            transport: transport
        )

        #expect(try await client.getSessionDiff(sessionID: "ses_1", messageID: "msg_legacy").isEmpty)
    }

    @Test func v2IncompleteRevertRefreshesTheCanonicalSessionBeforeSurfacingTheConflict() async throws {
        let transport = V2RevertTransport(contract: [
            .init(method: "GET", path: "/api/info", statusCode: 200, body: OpenCodeContractFixtures.v2InfoResponse),
            .init(method: "DELETE", path: "/api/session/ses_1/revert", statusCode: 204, body: Data()),
            .init(
                method: "POST",
                path: "/api/session/ses_1/revert/stage",
                statusCode: 200,
                body: Data(#"{"data":{"messageID":"msg_2"}}"#.utf8)
            ),
            .init(
                method: "POST",
                path: "/api/session/ses_1/revert/commit",
                statusCode: 409,
                body: Data(#"{"error":"SessionBusy"}"#.utf8)
            ),
            .init(
                method: "GET",
                path: "/api/session/ses_1",
                statusCode: 200,
                body: sessionEnvelope(id: "ses_1", title: "Still busy")
            ),
        ])
        let client = OpenCodeClient(
            baseURL: try #require(URL(string: "https://opencode.example.com")),
            transport: transport
        )
        _ = try await client.probeCapabilities()

        do {
            _ = try await client.revertMessage(sessionID: "ses_1", messageID: "msg_2")
            Issue.record("Expected the busy-session conflict to fail the revert.")
        } catch let error as OpenCodeError {
            guard case .incompleteRevert(let session, let reason) = error else {
                Issue.record("Expected an incomplete revert error, got \(error.localizedDescription)")
                return
            }
            #expect(session.id == "ses_1")
            #expect(session.title == "Still busy")
            #expect(reason.contains("409"))
        } catch {
            Issue.record("Expected an OpenCodeError, got \(error.localizedDescription)")
        }

        #expect(transport.recordedRequests().map(\.path) == [
            "/api/info",
            "/api/session/ses_1/revert",
            "/api/session/ses_1/revert/stage",
            "/api/session/ses_1/revert/commit",
            "/api/session/ses_1",
        ])
    }

    private func sessionEnvelope(id: String, title: String) -> Data {
        Data(#"{"data":{"id":"\#(id)","title":"\#(title)","time":{"created":0,"updated":0}}}"#.utf8)
    }
}

nonisolated private final class V2RevertTransport: OpenCodeTransport, @unchecked Sendable {
    struct ContractOperation: Sendable {
        let method: String
        let path: String
        let statusCode: Int
        let body: Data
        let queryItems: [String: String]

        init(
            method: String,
            path: String,
            statusCode: Int,
            body: Data,
            queryItems: [String: String] = [:]
        ) {
            self.method = method
            self.path = path
            self.statusCode = statusCode
            self.body = body
            self.queryItems = queryItems
        }
    }

    struct RecordedRequest: Sendable {
        let method: String
        let path: String
        let queryItems: [String: String]
        let body: Data?
    }

    private let lock = NSLock()
    private var contract: [ContractOperation]
    private var requests: [RecordedRequest] = []

    init(contract: [ContractOperation]) {
        self.contract = contract
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = try #require(request.url)
        let queryItems = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .reduce(into: [String: String]()) { result, item in
                if let value = item.value {
                    result[item.name] = value
                }
            }

        lock.lock()
        requests.append(
            .init(
                method: request.httpMethod ?? "GET",
                path: url.path,
                queryItems: queryItems,
                body: request.httpBody
            )
        )
        guard !contract.isEmpty else {
            lock.unlock()
            throw MissingV2RevertResponse()
        }
        let operation = contract.removeFirst()
        lock.unlock()

        let statusCode: Int
        let body: Data
        if operation.method == request.httpMethod,
           operation.path == url.path,
           operation.queryItems == queryItems {
            statusCode = operation.statusCode
            body = operation.body
        } else {
            statusCode = operation.path == url.path ? 405 : 404
            body = Data(#"{"error":"RouteNotFound"}"#.utf8)
        }

        return (
            body,
            HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
        )
    }

    func makeEventStream(
        request: URLRequest,
        deliveryQueue: DispatchQueue,
        callbacks: OpenCodeEventStreamCallbacks
    ) -> any OpenCodeEventStream {
        UnusedV2RevertEventStream()
    }

    func recordedRequests() -> [RecordedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
}

nonisolated private struct MissingV2RevertResponse: Error {}

nonisolated private final class UnusedV2RevertEventStream: OpenCodeEventStream, @unchecked Sendable {
    func start() {}
    func suspend() {}
    func resume() {}
    func cancel() {}
}
