import Foundation
import Testing
@testable import OpenLens

struct OpenCodeV2RevertTests {
    @Test func v2RevertClearsStaleStateStagesTheSelectedMessageCommitsAndRefreshesSession() async throws {
        let transport = V2RevertTransport(responses: [
            .init(statusCode: 200, body: OpenCodeContractFixtures.v2InfoResponse),
            .init(statusCode: 204, body: Data()),
            .init(statusCode: 200, body: Data(#"{"data":{"messageID":"msg_2"}}"#.utf8)),
            .init(statusCode: 204, body: Data()),
            .init(statusCode: 200, body: sessionEnvelope(id: "ses_1", title: "Reverted")),
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
        #expect(requests.map(\.method) == ["GET", "POST", "POST", "POST", "GET"])
        #expect(requests.map(\.path) == [
            "/api/info",
            "/api/session/ses_1/revert/clear",
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

    @Test func v2SessionDiffUsesTheV2RouteAndMessageBoundary() async throws {
        let transport = V2RevertTransport(responses: [
            .init(statusCode: 200, body: OpenCodeContractFixtures.v2InfoResponse),
            .init(statusCode: 200, body: Data(#"{"location":{"directory":"/workspace/OpenLens"},"data":[]}"#.utf8)),
        ])
        let client = OpenCodeClient(
            baseURL: try #require(URL(string: "https://opencode.example.com")),
            transport: transport
        )
        _ = try await client.probeCapabilities()

        #expect(try await client.getSessionDiff(sessionID: "ses_1", messageID: "msg_2").isEmpty)

        let request = try #require(transport.recordedRequests().last)
        #expect(request.path == "/api/session/ses_1/diff")
        #expect(request.queryItems["messageID"] == "msg_2")
    }

    @Test func v2IncompleteRevertRefreshesTheCanonicalSessionBeforeSurfacingTheConflict() async throws {
        let transport = V2RevertTransport(responses: [
            .init(statusCode: 200, body: OpenCodeContractFixtures.v2InfoResponse),
            .init(statusCode: 204, body: Data()),
            .init(statusCode: 200, body: Data(#"{"data":{"messageID":"msg_2"}}"#.utf8)),
            .init(statusCode: 409, body: Data(#"{"error":"SessionBusy"}"#.utf8)),
            .init(statusCode: 200, body: sessionEnvelope(id: "ses_1", title: "Still busy")),
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
            "/api/session/ses_1/revert/clear",
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
            throw MissingV2RevertResponse()
        }
        let response = responses.removeFirst()
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
