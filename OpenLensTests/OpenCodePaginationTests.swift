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

    @Test func v2PaginationAcceptsAnEmptyTerminalContinuationPage() async throws {
        let transport = V2PaginationTransport(pages: [
            .init(path: "/api/session/session-1/message", cursor: nil, body: messagePage(ids: ["message-1"], next: "page-2")),
            .init(path: "/api/session/session-1/message", cursor: "page-2", body: messagePage(ids: [], next: nil)),
        ])
        let client = try await v2Client(transport: transport)

        let messages = try await client.listMessages(sessionID: "session-1")

        #expect(messages.map(\.id) == ["message-1"])
        #expect(transport.recordedRequests().count == 3)
    }

    @Test func v2MessageListMapsTaggedTimelineEntriesAndSkipsIdleEntries() async throws {
        let transport = V2PaginationTransport(pages: [
            .init(
                path: "/api/session/session-1/message",
                cursor: nil,
                body: Data(#"""
                {
                  "data": [
                    {
                      "id": "message-user",
                      "type": "user",
                      "time": {"created": 1},
                      "text": "Hello"
                    },
                    {
                      "id": "message-assistant",
                      "type": "assistant",
                      "time": {"created": 2},
                      "agent": "build",
                      "model": {"id": "luna", "providerID": "github-copilot"},
                      "content": [
                        {"type": "reasoning", "text": "Thinking"},
                        {"type": "text", "text": "Hi"}
                      ]
                    },
                    {
                      "id": "message-idle",
                      "type": "idle",
                      "time": {"created": 3}
                    }
                  ],
                  "cursor": {"next": null}
                }
                """#.utf8)
            ),
        ])
        let client = try await v2Client(transport: transport)

        let messages = try await client.listMessages(sessionID: "session-1")

        #expect(messages.map(\.id) == ["message-user", "message-assistant"])
        #expect(messages[0].parts.first?.text == "Hello")
        #expect(messages[1].info.modelDisplayName == "github-copilot/luna")
        #expect(messages[1].parts.map(\.type) == [.reasoning, .text])
    }

    @MainActor
    @Test func v2TranscriptRestoresNamedToolStepsThroughChatPresentation() async throws {
        let transport = V2PaginationTransport(pages: [
            .init(
                path: "/api/session/session-1/message",
                cursor: nil,
                body: Data(#"""
                {
                  "data": [
                    {
                      "id": "message-assistant",
                      "type": "assistant",
                      "time": {"created": 2},
                      "content": [
                        {"id": "text-before", "type": "text", "text": "I will inspect the project."},
                        {
                          "id": "read-tool",
                          "type": "tool",
                          "name": "read",
                          "state": {
                            "status": "running",
                            "input": {"path": "OpenLens/App.swift"},
                            "structured": {},
                            "content": []
                          }
                        },
                        {
                          "id": "bash-tool",
                          "type": "tool",
                          "name": "bash",
                          "state": {
                            "status": "completed",
                            "input": {"command": "swift test"},
                            "structured": {},
                            "content": [{"type": "text", "text": "All tests passed."}]
                          }
                        },
                        {
                          "id": "grep-tool",
                          "type": "tool",
                          "name": "grep",
                          "state": {
                            "status": "error",
                            "input": {"pattern": "TODO", "path": "OpenLens"},
                            "structured": {},
                            "content": [{"type": "text", "text": "No output."}],
                            "error": {"type": "unknown", "message": "Permission denied"}
                          }
                        },
                        {
                          "id": "not-a-tool",
                          "type": "reasoning",
                          "name": "bash",
                          "state": {"status": "running"},
                          "text": "Checking transcript order."
                        },
                        {"id": "text-after", "type": "text", "text": "Finished."}
                      ]
                    }
                  ],
                  "cursor": {"next": null}
                }
                """#.utf8)
            ),
        ])
        let client = try await v2Client(transport: transport)

        let decodedMessage = try #require(
            try await client.listMessages(sessionID: "session-1").first
        )
        let transcript = ChatMessage(
            id: decodedMessage.info.id,
            role: decodedMessage.info.role,
            content: decodedMessage.parts.compactMap(\.renderableText).joined(),
            parts: decodedMessage.parts
        )
        let toolSteps = transcript.persistedToolSteps
        let timeline = ChatTimeline.items(from: [transcript], showsThinking: true)

        #expect(toolSteps.map(\.toolName) == ["read", "bash", "grep"])
        #expect(toolSteps.map(\.label) == [
            "Read OpenLens/App.swift",
            "Bash swift test",
            "Grep \"TODO\" in OpenLens",
        ])
        #expect(toolSteps.map(\.outputPreview) == [
            "OpenLens/App.swift",
            "All tests passed.",
            "Permission denied",
        ])
        #expect(toolSteps.map(\.isError) == [false, false, true])
        #expect(timeline.map(\.id) == [
            "message-message-assistant-part-text-before",
            "message-message-assistant-part-read-tool",
            "message-message-assistant-part-bash-tool",
            "message-message-assistant-part-grep-tool",
            "message-message-assistant-part-not-a-tool",
            "message-message-assistant-part-text-after",
        ])

        let v1Transcript = ChatMessage(
            id: "v1-assistant",
            role: .assistant,
            content: "",
            parts: [
                OCPart(
                    id: "v1-bash-tool",
                    sessionID: "session-1",
                    messageID: "v1-assistant",
                    type: .tool,
                    tool: "bash",
                    state: OCToolState(
                        status: .completed,
                        input: AnyCodable(["command": "swift test"]),
                        output: "All tests passed."
                    )
                ),
            ]
        )
        #expect(v1Transcript.persistedToolSteps.map(\.toolName) == ["bash"])
    }

    @Test func v2SessionListAcceptsAnInitiallyEmptyTerminalPage() async throws {
        let transport = V2PaginationTransport(pages: [
            .init(path: "/api/session", cursor: nil, body: sessionPage(ids: [], next: nil)),
        ])
        let client = try await v2Client(transport: transport)

        let sessions = try await client.listSessions()

        #expect(sessions.isEmpty)
        #expect(transport.recordedRequests().count == 2)
    }

    @Test func v2PaginationRejectsAnEmptyPageWithAnotherCursor() async throws {
        let transport = V2PaginationTransport(pages: [
            .init(path: "/api/session", cursor: nil, body: sessionPage(ids: [], next: "page-2")),
        ])
        let client = try await v2Client(transport: transport)

        await #expect(throws: OpenCodeError.self) {
            _ = try await client.listSessions()
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

    @Test func v2SessionLocationsSurviveListAndDetailDecodingAcrossProjects() async throws {
        let transport = V2PaginationTransport(pages: [
            .init(path: "/api/session", cursor: nil, body: Data(#"{"data":[{"id":"ses_alpha","title":"Alpha","location":{"directory":"/workspace/Alpha","project":{"id":"alpha","directory":"/workspace/Alpha"}},"time":{"created":0,"updated":2}},{"id":"ses_beta","title":"Beta","location":{"directory":"/workspace/Beta","project":{"id":"beta","directory":"/workspace/Beta"}},"time":{"created":0,"updated":1}}],"cursor":{"next":null}}"#.utf8)),
            .init(path: "/api/session/ses_alpha", cursor: nil, body: Data(#"{"data":{"id":"ses_alpha","title":"Alpha","location":{"directory":"/workspace/Alpha","project":{"id":"alpha","directory":"/workspace/Alpha"}},"time":{"created":0,"updated":2}}}"#.utf8)),
        ])
        let client = try await v2Client(transport: transport, contextDirectory: "/workspace/Beta")

        let sessions = try await client.listSessions()
        #expect(sessions.map(\.directory) == ["/workspace/Alpha", "/workspace/Beta"])
        #expect(sessions.map(\.projectID) == ["alpha", "beta"])
        #expect(try await client.getSession(id: "ses_alpha").directory == "/workspace/Alpha")
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
            #"{"id":"\#(id)","type":"user","time":{"created":\#(index)},"text":"\#(id)"}"#
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
