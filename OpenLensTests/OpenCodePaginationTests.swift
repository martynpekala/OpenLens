import Foundation
import Testing
@testable import OpenLens

struct OpenCodePaginationTests {
    @Test func v2SessionAndMessageListsCollectEveryPage() async throws {
        let transport = V2PaginationTransport(pages: [
            .init(path: "/api/session", cursor: nil, body: sessionPage(ids: (0..<100).map { "session-\($0)" }, next: "sessions-page-2")),
            .init(path: "/api/session", cursor: "sessions-page-2", body: sessionPage(ids: ["session-0"], next: nil)),
            .init(path: "/api/session/session-1/message", cursor: nil, body: messagePage(ids: ["message-1", "message-2"], next: "messages-page-2")),
            .init(path: "/api/session/session-1/message", cursor: "messages-page-2", body: messagePage(ids: ["message-3"], next: nil)),
        ])
        let client = try await v2Client(transport: transport, contextDirectory: "/workspace/OpenLens")

        let sessions = try await client.listSessions()
        let messages = try await client.listMessages(sessionID: "session-1", limit: 2)

        #expect(sessions.map(\.id) == (0..<100).map { "session-\($0)" } + ["session-0"])
        #expect(messages.map(\.id) == ["message-1", "message-2", "message-3"])
        let requests = Array(transport.recordedRequests().dropFirst())
        #expect(requests.map(\.cursor) == [nil, "sessions-page-2", nil, "messages-page-2"])
        #expect(requests[0].queryItems["order"] == "desc")
        #expect(requests[2].queryItems["order"] == "asc")
        #expect(requests[1].queryItems["order"] == nil)
        #expect(requests[3].queryItems["order"] == nil)
        #expect(requests[0].queryItems["location[directory]"] == "/workspace/OpenLens")
        #expect(requests[1].queryItems["location[directory]"] == "/workspace/OpenLens")
        #expect(requests[2].queryItems["location[directory]"] == nil)
        #expect(requests[3].queryItems["location[directory]"] == nil)
    }

    @Test func v2PaginationRejectsARepeatedCursorWithoutReturningPartialResults() async throws {
        let transport = V2PaginationTransport(pages: [
            .init(path: "/api/session", cursor: nil, body: sessionPage(ids: ["session-2"], next: "repeat")),
            .init(path: "/api/session", cursor: "repeat", body: sessionPage(ids: ["session-1"], next: "repeat")),
        ])
        let client = try await v2Client(transport: transport)

        await #expect(throws: OpenCodeError.self) {
            _ = try await client.listSessions()
        }
        #expect(transport.recordedRequests().count == 3)
    }

    @Test func v2PaginationRejectsAnEmptyPage() async throws {
        let transport = V2PaginationTransport(pages: [
            .init(path: "/api/session/session-1/message", cursor: nil, body: messagePage(ids: [], next: nil)),
        ])
        let client = try await v2Client(transport: transport)

        await #expect(throws: OpenCodeError.self) {
            _ = try await client.listMessages(sessionID: "session-1")
        }
        #expect(transport.recordedRequests().count == 2)
    }

    @Test func v2PaginationRejectsABlankContinuationCursor() async throws {
        let transport = V2PaginationTransport(pages: [
            .init(path: "/api/session/session-1/message", cursor: nil, body: messagePage(ids: ["message-1"], next: "   ")),
        ])
        let client = try await v2Client(transport: transport)

        await #expect(throws: OpenCodeError.self) {
            _ = try await client.listMessages(sessionID: "session-1", limit: 1)
        }
        #expect(transport.recordedRequests().count == 2)
    }

    @Test func v2PaginationRejectsAMissingCursor() async throws {
        let transport = V2PaginationTransport(pages: [
            .init(
                path: "/api/session/session-1/message",
                cursor: nil,
                body: Data(#"{"data":[{"info":{"id":"message-1","sessionID":"session-1","role":"user","time":{"created":0}},"parts":[]}]}"#.utf8)
            ),
        ])
        let client = try await v2Client(transport: transport)

        await #expect(throws: OpenCodeError.self) {
            _ = try await client.listMessages(sessionID: "session-1")
        }
        #expect(transport.recordedRequests().count == 2)
    }

    private func v2Client(
        transport: V2PaginationTransport,
        contextDirectory: String? = nil
    ) async throws -> OpenCodeClient {
        let client = OpenCodeClient(
            baseURL: try #require(URL(string: "https://opencode.example.com")),
            contextDirectory: contextDirectory,
            transport: transport
        )
        _ = try await client.probeCapabilities()
        return client
    }

    private func sessionPage(ids: [String], next: String?) -> Data {
        let data = ids.enumerated().map { index, id in
            #"{"id":"\#(id)","title":"\#(id)","time":{"created":\#(index),"updated":\#(index)}}"#
        }.joined(separator: ",")
        let nextJSON = next.map { "\"\($0)\"" } ?? "null"
        return Data("{\"data\":[\(data)],\"cursor\":{\"next\":\(nextJSON)}}".utf8)
    }

    private func messagePage(ids: [String], next: String?) -> Data {
        let data = ids.enumerated().map { index, id in
            #"{"info":{"id":"\#(id)","sessionID":"session-1","role":"user","time":{"created":\#(index)}},"parts":[]}"#
        }.joined(separator: ",")
        let nextJSON = next.map { "\"\($0)\"" } ?? "null"
        return Data("{\"data\":[\(data)],\"cursor\":{\"next\":\(nextJSON)}}".utf8)
    }
}

nonisolated private final class V2PaginationTransport: OpenCodeTransport, @unchecked Sendable {
    struct Page: Sendable {
        let path: String
        let cursor: String?
        let body: Data
    }

    struct RecordedRequest: Sendable {
        let cursor: String?
        let queryItems: [String: String]
    }

    private let lock = NSLock()
    private let pages: [Page]
    private var requests: [RecordedRequest] = []

    init(pages: [Page]) {
        self.pages = pages
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url ?? URL(string: "https://opencode.example.com")!
        let queryItems = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .reduce(into: [String: String]()) { result, item in
                if let value = item.value {
                    result[item.name] = value
                }
            }
        let cursor = queryItems["cursor"]
        lock.lock()
        requests.append(.init(cursor: cursor, queryItems: queryItems))
        lock.unlock()

        let body: Data
        if url.path == "/api/info" {
            body = OpenCodeContractFixtures.v2InfoResponse
        } else if let page = pages.first(where: { $0.path == url.path && $0.cursor == cursor }) {
            body = page.body
        } else {
            throw MissingV2PaginationPage(path: url.path, cursor: cursor)
        }
        return (body, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
    }

    func makeEventStream(
        request: URLRequest,
        deliveryQueue: DispatchQueue,
        callbacks: OpenCodeEventStreamCallbacks
    ) -> any OpenCodeEventStream {
        UnusedV2PaginationEventStream()
    }

    func recordedRequests() -> [RecordedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
}

private struct MissingV2PaginationPage: Error {
    let path: String
    let cursor: String?
}

nonisolated private final class UnusedV2PaginationEventStream: OpenCodeEventStream, @unchecked Sendable {
    func start() {}
    func suspend() {}
    func resume() {}
    func cancel() {}
}
