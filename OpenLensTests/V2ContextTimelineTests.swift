import Foundation
import Testing
@testable import OpenLens

@MainActor
struct V2ContextTimelineTests {
    @Test func missingRevertBoundaryFiltersBothChatAndContextByID() async throws {
        let transport = ContextTimelineTransport()
        await transport.setHistory(#"""
        {"data":[
          {"id":"msg_001","type":"user","text":"Before"},
          {"id":"msg_002","type":"system","text":"Before context"},
          {"id":"msg_004","type":"skill","name":"After","text":"After context"},
          {"id":"msg_005","type":"assistant","content":[{"type":"text","text":"After"}]}
        ],"cursor":{"next":null}}
        """#)
        let chat = try await makeChat(transport)
        chat.currentSession = OCSession(id: "ses_1", title: "Context", time: .init(created: 0, updated: 0),
                                        revert: .init(messageID: "msg_003"))
        #expect(await chat.loadMessages())
        #expect(chat.messages.map(\.id) == ["msg_001"])
        #expect(chat.contextEntries.map(\.id) == ["msg_002"])
        #expect(chat.transcriptEntryOrder == ["msg_001", "msg_002"])
        #expect(chat.timelineItems(showsThinking: true).map(\.id) == ["message-msg_001", "context-msg_002"])
        #expect(await chat.loadMessages())
        #expect(chat.timelineItems(showsThinking: true).map(\.id) == ["message-msg_001", "context-msg_002"])
    }

    @Test func pendingLiveTextTakesItsCanonicalContextPositionWithoutDuplicatingAfterRefresh() async throws {
        let transport = ContextTimelineTransport()
        let initial = #"""
        {"data":[
          {"id":"msg_user","type":"user","text":"Check"},
          {"id":"msg_before","type":"system","text":"Instructions"}
        ],"cursor":{"next":null}}
        """#
        await transport.setHistory(initial)
        await transport.setActive(true)
        let chat = try await makeChat(transport)
        #expect(await chat.loadMessages())
        var adapter = V2EventAdapter()
        func deliver(_ type: String, _ fields: [String: Any]) throws {
            var data = fields
            data["sessionID"] = "ses_1"
            data["assistantMessageID"] = "msg_live"
            let event = try #require(try adapter.event(["type": type, "data": data], directory: nil))
            chat.receiveStreamEvent(SSEInboundEvent.prepare(event, retainingRawEvent: false) ?? .raw(event))
        }
        try deliver("session.step.started", ["agent": "build", "model": ["id": "test", "providerID": "test"]])
        let pending = try #require(chat.pendingAssistantMessage)
        #expect(pending.isStreaming)
        // The existing thinking placeholder stays after known history until
        // REST supplies the streaming message's canonical position.
        #expect(chat.timelineItems(showsThinking: true).map(\.id) == ["message-msg_user", "context-msg_before", "message-msg_live-part-streaming-thinking-msg_live"])
        try deliver("session.text.started", ["ordinal": 0])
        try deliver("session.text.delta", ["ordinal": 0, "delta": "Live answer"])
        try await waitUntil { chat.timelineItems(showsThinking: true).contains { $0.id == "message-msg_live-part-msg_live-0" } }
        #expect(chat.timelineItems(showsThinking: true).map(\.id) == ["message-msg_user", "context-msg_before", "message-msg_live-part-msg_live-0"])

        await transport.setHistory(#"""
        {"data":[
          {"id":"msg_user","type":"user","text":"Check"},
          {"id":"msg_before","type":"system","text":"Instructions"},
          {"id":"msg_live","type":"assistant","content":[{"type":"text","text":"Live answer"}]},
          {"id":"msg_after","type":"model-switched","model":{"providerID":"test","id":"next"}}
        ],"cursor":{"next":null}}
        """#)
        let expected = ["message-msg_user", "context-msg_before", "message-msg_live-part-msg_live-0", "context-msg_after"]
        for _ in 0..<2 {
            #expect(await chat.loadMessages())
            #expect(chat.pendingAssistantMessage === pending)
            #expect(chat.displayedMessages.first { $0.id == "msg_live" } === pending)
            #expect(chat.timelineItems(showsThinking: true).map(\.id) == expected)
            #expect(pending.isStreaming)
        }
        try deliver("session.text.delta", ["ordinal": 0, "delta": " continues"])
        try await waitUntil { pending.streamingTextProjection(forPartID: "msg_live-0")?.copyText() == "Live answer continues" }
        #expect(chat.timelineItems(showsThinking: true).map(\.id) == expected)
        chat.unloadSession(ifMatching: "ses_1")
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for context timeline projection")
    }

    @Test(arguments: ["system", "skill", "shell", "compaction"])
    func largeContextDetailsHaveABoundedReadablePreview(_ kind: String) throws {
        let longText = String(repeating: "🧪 check passed\n", count: 4_000)
        let field = kind == "shell" ? "output" : kind == "compaction" ? "summary" : "text"
        let data = try JSONSerialization.data(withJSONObject: ["id": "msg_long", "type": kind, field: longText])
        let entry = try JSONDecoder().decode(SessionContextEntry.self, from: data)
        #expect(entry.details.count <= 40_000)
        #expect(entry.details.hasPrefix("🧪 check passed\n"))
        #expect(entry.details.hasSuffix("\n\nPreview shortened."))
        #expect(!entry.details.contains("�"))
    }

    @Test func shorteningAShellPreviewPreservesTheServersTruncationNotice() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "id": "msg_long", "type": "shell",
            "output": ["text": String(repeating: "Checks passed\n", count: 4_000), "truncated": true]
        ])
        let entry = try JSONDecoder().decode(SessionContextEntry.self, from: data)
        #expect(entry.details.count <= 40_000)
        #expect(entry.details.contains("Preview shortened."))
        #expect(entry.details.hasSuffix("Output truncated."))
    }

    @Test(arguments: [true, false])
    func structuredShellOutputKeepsNewlinesAndReportsTruncation(_ truncated: Bool) async throws {
        let transport = ContextTimelineTransport()
        await transport.setHistory(#"""
        {"data":[{"id":"msg_shell","type":"shell","status":"completed","exit":0,"output":{"text":"Checks passed.\n/workspace/OpenLens","truncated":\#(truncated)}}],"cursor":{"next":null}}
        """#)
        let chat = try await makeChat(transport)
        #expect(await chat.loadMessages())
        let expected = "Exit code: 0\n\nChecks passed.\n/workspace/OpenLens" + (truncated ? "\n\nOutput truncated." : "")
        #expect(chat.contextEntries.first?.details == expected)
    }

    @Test func unfamiliarShellOutputRemainsInspectable() async throws {
        let transport = ContextTimelineTransport()
        await transport.setHistory(#"{"data":[{"id":"msg_shell","type":"shell","output":{"futureResult":"Useful result"}}],"cursor":{"next":null}}"#)
        let chat = try await makeChat(transport)
        #expect(await chat.loadMessages())
        let details = try #require(chat.contextEntries.first?.details)
        let value = try JSONSerialization.jsonObject(with: Data(details.utf8)) as? [String: String]
        #expect(value == ["futureResult": "Useful result"])
    }

    @Test func stagedRevertHidesContextAfterTheSameHistoryBoundary() async throws {
        let chat = try await makeChat(ContextTimelineTransport())
        chat.currentSession = OCSession(id: "ses_1", title: "Context", time: .init(created: 0, updated: 0),
                                        revert: .init(messageID: "msg_skill"))
        #expect(await chat.loadMessages())
        #expect(chat.messages.map(\.id) == ["msg_user"])
        #expect(chat.contextEntries.map(\.id) == ["msg_model", "msg_agent", "msg_location", "msg_system"])
        #expect(chat.timelineItems(showsThinking: true).map(\.id) == ["message-msg_user", "context-msg_model", "context-msg_agent", "context-msg_location", "context-msg_system"])
    }

    @Test func failedExecutionWithQuotaErrorSurfacesUsageLimit() async throws {
        let transport = ContextTimelineTransport()
        await transport.setHistory(#"""
        {"data":[
          {"id":"msg_user","type":"user","time":{"created":1},"text":"hi"},
          {"id":"msg_fail_idle","type":"idle","time":{"created":2},"outcome":"failed","error":{"type":"provider.quota","message":"Usage limit reached for 5 hour. Your limit will reset at 2026-11-04 08:49:26","status":429}}
        ],"cursor":{"next":null}}
        """#)
        let chat = try await makeChat(transport)
        #expect(await chat.loadMessages())
        #expect(chat.contextEntries[0].summary.hasPrefix("Usage limit reached"))
        #expect(chat.usageLimitInfo?.resetAt != nil)
        #expect(chat.presentedError == .usageLimit(try #require(chat.usageLimitInfo)))
    }

    @Test func failedExecutionFallsBackToAssistantErrorWhenIdleOmitsIt() async throws {
        let transport = ContextTimelineTransport()
        await transport.setHistory(#"""
        {"data":[
          {"id":"msg_user","type":"user","time":{"created":1},"text":"hi"},
          {"id":"msg_asst","type":"assistant","time":{"created":2},"content":[],"finish":"error","error":{"type":"provider.quota","message":"Usage limit reached for 5 hour. Your limit will reset at 2026-11-04 08:49:26","status":429}},
          {"id":"msg_fail_idle","type":"idle","time":{"created":3},"outcome":"failed"}
        ],"cursor":{"next":null}}
        """#)
        let chat = try await makeChat(transport)
        #expect(await chat.loadMessages())
        #expect(chat.usageLimitInfo?.resetAt != nil)
        #expect(!chat.isLoading)
    }

    @Test(arguments: [#"{"type":"unknown","message":"Provider offline"}"#, #"{"name":"UnknownError","data":{"message":"Provider offline"}}"#])
    func resultStatesAndContextOnlyHistoryStayInspectable(_ error: String) async throws {
        let transport = ContextTimelineTransport()
        await transport.setHistory(#"""
        {"data":[
          {"id":"msg_running","type":"compaction","status":"running","reason":"auto","summary":"Partial summary","recent":"Current task"},
          {"id":"msg_failed","type":"compaction","status":"failed","reason":"manual","error":\#(error)},
          {"id":"msg_shell","type":"shell","status":"running","command":"swift test"},
          {"id":"msg_fail_idle","type":"idle","outcome":"failed"},
          {"id":"msg_interrupt","type":"idle","outcome":"interrupted"},
          {"id":"msg_unknown","type":"idle","outcome":"future-outcome"}
        ],"cursor":{"next":null}}
        """#)
        let chat = try await makeChat(transport)
        #expect(await chat.loadMessages())
        #expect(chat.messages.isEmpty)
        #expect(chat.contextEntries.map(\.title) == ["Compaction · Running", "Compaction · Failed", "Shell · Running", "Execution failed", "Execution interrupted", "Execution ended"])
        #expect(chat.contextEntries[0].details == "Partial summary\n\nRecent context:\nCurrent task")
        #expect(chat.contextEntries[1].details == "Provider offline")
        #expect(chat.timelineItems(showsThinking: false).count == 6)
    }

    @Test func anUnloadedSessionCannotInstallADelayedContextSnapshot() async throws {
        let transport = ContextTimelineTransport()
        let chat = try await makeChat(transport)
        await transport.holdHistory()
        let load = Task { await chat.loadMessages() }
        for _ in 0..<300 {
            if await transport.hasHeldHistory { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await transport.hasHeldHistory)
        chat.unloadSession(ifMatching: "ses_1")
        await transport.releaseHistory()
        #expect(await load.value == false)
        #expect(chat.contextEntries.isEmpty)
        #expect(chat.transcriptEntryOrder.isEmpty)
        #expect(chat.timelineItems(showsThinking: true).isEmpty)
    }

    @Test func legacyTranscriptKeepsChatRolesPartsAndRoutes() async throws {
        let transport = OpenCodeContractTransport(routes: [
            "/api/info": .init(statusCode: 404, body: Data()),
            "/global/health": .init(statusCode: 200, body: OpenCodeContractFixtures.v1HealthResponse),
            "/session/ses_1/message": .init(statusCode: 200, body: Data(#"[{"info":{"id":"v1_user","sessionID":"ses_1","role":"user"},"parts":[{"id":"v1_text","sessionID":"ses_1","messageID":"v1_user","type":"text","text":"Legacy prompt"}]}]"#.utf8))
        ])
        let api = OpenCodeClient(baseURL: URL(string: "https://example.com")!, transport: transport)
        let connection = ConnectionManager(testClient: api, capabilities: try await api.probeCapabilities())
        let transcript = try await MessagesService(connection: connection).loadTranscript(sessionID: "ses_1")
        #expect(transcript.messages.map(\.role) == [.user])
        #expect(transcript.messages.first?.content == "Legacy prompt")
        #expect(transcript.entryOrder == ["v1_user"])
        #expect(transcript.contextEntries.isEmpty)
        #expect(await transport.recordedPaths() == ["/api/info", "/global/health", "/session/ses_1/message"])
    }

    @Test func unknownPayloadsAndOverlappingPagesKeepAUsableOrderedTranscript() async throws {
        let transport = ContextTimelineTransport()
        await transport.setPages(
            first: #"{"data":[{"type":"future-entry","text":{},"model":true},{"id":"msg_shell","type":"shell","command":"swift test","status":"running"},{"id":"msg_user","type":"user","text":"Check"}],"cursor":{"next":"next"}}"#,
            second: #"{"data":[{"id":"msg_shell","type":"shell","command":"swift test","status":"completed","exit":0,"output":{"text":"Passed","truncated":false}},{"id":"msg_system","type":"system","text":"Keep checking"}],"cursor":{"next":null}}"#
        )
        let chat = try await makeChat(transport)
        #expect(await chat.loadMessages())
        #expect(chat.transcriptEntryOrder == ["msg_shell", "msg_user", "msg_system"])
        #expect(chat.contextEntries.count == 2)
        #expect(chat.contextEntries.first?.title == "Shell · Completed")
        #expect(chat.contextEntries.first?.details == "Exit code: 0\n\nPassed")
        #expect(chat.timelineItems(showsThinking: true).map(\.id) == ["context-msg_shell", "message-msg_user", "context-msg_system"])
    }

    @Test(arguments: ["session.model.selected", "session.agent.selected", "session.moved", "session.instructions.updated", "session.skill.activated", "session.shell.started", "session.shell.ended", "session.compaction.started", "session.compaction.ended", "session.compaction.failed", "session.idle"])
    func nativeContextEventsConvergeWithCanonicalHistory(_ type: String) async throws {
        let transport = ContextTimelineTransport()
        let chat = try await makeChat(transport)
        #expect(await chat.loadMessages())
        await transport.setHistory(ContextTimelineTransport.history.replacingOccurrences(of: "Use Swift Testing.", with: "Updated on desktop."))
        var adapter = V2EventAdapter()
        let event = try #require(try adapter.event([
            "id": "evt_context", "type": type, "location": ["directory": "/work"],
            "data": ["sessionID": "ses_1", "model": ["id": "claude", "providerID": "anthropic"], "agent": "build"]
        ], directory: "/work"))
        let inbound = SSEInboundEvent.prepare(event, retainingRawEvent: false) ?? .raw(event)
        // Repeated delivery is a refresh signal, not an invented transcript ID.
        chat.receiveStreamEvent(inbound)
        chat.receiveStreamEvent(inbound)
        #expect(!chat.isStreamSynchronized)
        for _ in 0..<300 where !chat.isStreamSynchronized { try await Task.sleep(for: .milliseconds(10)) }
        #expect(chat.isStreamSynchronized)
        #expect(chat.errorMessage == nil)
        #expect(chat.contextEntries.count == 8)
        #expect(chat.contextEntries.first { $0.id == "msg_system" }?.details == "Updated on desktop.")
        #expect(chat.timelineItems(showsThinking: true).map(\.id).filter { $0 == "context-msg_system" }.count == 1)
        let requestsBefore = await transport.requestCount()
        let unrelated = try #require(try adapter.event([
            "type": type, "location": ["directory": "/work"],
            "data": ["sessionID": "ses_other", "model": ["id": "claude", "providerID": "anthropic"], "agent": "build"]
        ], directory: "/work"))
        chat.receiveStreamEvent(SSEInboundEvent.prepare(unrelated, retainingRawEvent: false) ?? .raw(unrelated))
        #expect(chat.isStreamSynchronized)
        #expect(await transport.requestCount() == requestsBefore)
    }

    @Test func chatPresentsContextBetweenConversationAndToolRowsAndRefreshesWithoutDuplicates() async throws {
        let transport = ContextTimelineTransport()
        let chat = try await makeChat(transport)
        #expect(await chat.loadMessages())
        let expected = ["message-msg_user", "context-msg_model", "context-msg_agent", "context-msg_location", "context-msg_system", "context-msg_skill", "context-msg_shell", "context-msg_compact", "message-msg_reply-part-read_1", "message-msg_reply-part-msg_reply-1", "context-msg_idle"]
        #expect(chat.timelineItems(showsThinking: false).map(\.id) == expected)
        #expect(await chat.loadMessages())
        #expect(chat.timelineItems(showsThinking: false).map(\.id) == expected)
        #expect(chat.messages.map(\.role) == [.user, .assistant])
        chat.displayLimit = 2
        #expect(chat.hasEarlierMessages)
        #expect(chat.timelineItems(showsThinking: false).map(\.id) == Array(expected.suffix(3)))
        chat.loadEarlierMessages()
        #expect(chat.timelineItems(showsThinking: false).map(\.id) == expected)
        chat.unloadSession(ifMatching: "ses_1")
        #expect(chat.timelineItems(showsThinking: false).isEmpty)
    }

    private func makeChat(_ transport: ContextTimelineTransport) async throws -> ChatClient {
        let api = OpenCodeClient(baseURL: URL(string: "https://example.com")!, transport: transport)
        let connection = ConnectionManager(testClient: api, capabilities: try await api.probeCapabilities())
        let chat = ChatClient(
            connection: connection, liveActivity: TestLiveActivityProvider(),
            sessionsService: SessionsService(connection: connection), messagesService: MessagesService(connection: connection),
            providersService: ProvidersService(connection: connection), questionService: QuestionService(connection: connection),
            savedConnectionsStore: SavedConnectionsStore(initialConnections: []), recordedReplayStore: RecordedReplayStore()
        )
        chat.currentSession = OCSession(id: "ses_1", title: "Context", time: .init(created: 0, updated: 0))
        return chat
    }

    @Test func historyKeepsContextOrderWithoutInventingChatRoles() async throws {
        let transport = ContextTimelineTransport()
        let api = OpenCodeClient(baseURL: URL(string: "https://example.com")!, transport: transport)
        let connection = ConnectionManager(testClient: api, capabilities: try await api.probeCapabilities())
        let service = MessagesService(connection: connection)
        let transcript = try await service.loadTranscript(sessionID: "ses_1")

        #expect(transcript.messages.map(\.id) == ["msg_user", "msg_reply"])
        #expect(transcript.messages.map(\.role) == [.user, .assistant])
        #expect(transcript.contextEntries.map(\.id) == ["msg_model", "msg_agent", "msg_location", "msg_system", "msg_skill", "msg_shell", "msg_compact", "msg_idle"])
        #expect(transcript.entryOrder == ["msg_user", "msg_model", "msg_agent", "msg_location", "msg_system", "msg_skill", "msg_shell", "msg_compact", "msg_reply", "msg_idle"])
        #expect(transcript.contextEntries.map(\.title) == ["Model changed", "Agent changed", "Location changed", "System update", "Skill activated", "Shell · Completed", "Compaction · Completed", "Execution succeeded"])
        #expect(transcript.contextEntries[0].summary == "anthropic/claude · high")
        #expect(transcript.contextEntries[2].summary == "/work/feature")
        #expect(transcript.contextEntries[3].summary == "Instructions updated")
        #expect(transcript.contextEntries[3].details == "Use Swift Testing.")
        #expect(transcript.contextEntries[4].details == "Review the changes.")
        #expect(transcript.contextEntries[6].details.contains("Checks passed."))
        #expect(transcript.messages[1].persistedToolSteps.map(\.toolName) == ["read"])
        // Existing callers can continue to request chat messages alone.
        #expect(try await service.loadMessages(sessionID: "ses_1").map(\.id) == ["msg_user", "msg_reply"])
    }
}

private actor ContextTimelineTransport: OpenCodeTransport {
    private var page = history
    private var continuationPage: String?
    private var requests = 0
    private var active = false
    private var holdsHistory = false
    private var historyWaiter: CheckedContinuation<Void, Never>?
    var hasHeldHistory: Bool { historyWaiter != nil }
    func holdHistory() { holdsHistory = true }
    func releaseHistory() { holdsHistory = false; historyWaiter?.resume(); historyWaiter = nil }
    func setHistory(_ value: String) { page = value }
    func setActive(_ value: Bool) { active = value }
    func setPages(first: String, second: String) { page = first; continuationPage = second }
    func requestCount() -> Int { requests }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests += 1
        let url = request.url!
        let body: String
        switch url.path {
        case "/api/info": body = #"{"version":"2.0.23"}"#
        case "/api/session/ses_1/message":
            if holdsHistory { await withCheckedContinuation { historyWaiter = $0 } }
            let cursor = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "cursor" }?.value
            body = cursor == nil ? page : (continuationPage ?? page)
        case "/api/session/ses_1": body = #"{"data":{"id":"ses_1","title":"Context","time":{"created":0,"updated":0}}}"#
        case "/api/session/active": body = active ? #"{"data":{"ses_1":{"type":"busy"}}}"# : #"{"data":{}}"#
        case "/api/session/ses_1/inbox", "/api/session/ses_1/permission", "/api/session/ses_1/form": body = #"{"data":[]}"#
        default: throw URLError(.unsupportedURL)
        }
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    nonisolated func makeEventStream(request: URLRequest, deliveryQueue: DispatchQueue, callbacks: OpenCodeEventStreamCallbacks) -> any OpenCodeEventStream {
        ContextTimelineEventStream()
    }

    static let history = #"""
    {"data":[
      {"id":"msg_user","type":"user","time":{"created":1},"text":"Check the feature."},
      {"id":"msg_model","type":"model-switched","time":{"created":1},"model":{"providerID":"anthropic","id":"claude","variant":"high"},"previous":{"providerID":"openai","id":"gpt"}},
      {"id":"msg_agent","type":"agent-switched","time":{"created":1},"agent":"build","previous":"plan"},
      {"id":"msg_location","type":"location-switched","time":{"created":1},"location":{"directory":"/work/feature"},"previous":{"location":{"directory":"/work"}}},
      {"id":"msg_future","type":"future-context","text":{"future":true},"agent":42,"error":false},
      {"id":"msg_system","type":"system","time":{"created":1},"description":"Instructions updated","text":"Use Swift Testing."},
      {"id":"msg_skill","type":"skill","time":{"created":1},"skill":"skill_review","name":"review","text":"Review the changes."},
      {"id":"msg_shell","type":"shell","time":{"created":1,"completed":2},"shellID":"shell_1","command":"swift test","status":"completed","exit":0},
      {"id":"msg_compact","type":"compaction","time":{"created":1},"status":"completed","reason":"manual","summary":"Checks passed.","recent":"Keep the feature branch."},
      {"id":"msg_reply","type":"assistant","time":{"created":1},"content":[{"type":"tool","id":"read_1","name":"read","state":{"status":"completed","input":{"path":"App.swift"},"content":[{"type":"text","text":"File contents"}]}},{"type":"text","text":"Ready."}]},
      {"id":"msg_idle","type":"idle","time":{"created":1},"outcome":"succeeded"}
    ],"cursor":{"next":null}}
    """#
}

nonisolated private final class ContextTimelineEventStream: OpenCodeEventStream, @unchecked Sendable {
    func start() {}
    func suspend() {}
    func resume() {}
    func cancel() {}
}
