import Foundation
import Testing
@testable import OpenLens

/// Catch-up summaries come from `session.generate`: they never become part of
/// the conversation, run only when asked, and stay with the session that
/// requested them.
@MainActor
struct V2SessionSummaryTests {
    @Test func generatingASummaryLeavesTheConversationUnchanged() async throws {
        let transport = SummaryTransport()
        let chat = try await makeChat(transport)
        #expect(await chat.loadMessages())
        let messageIDs = chat.messages.map(\.id)
        #expect(chat.supportsSessionSummary)

        await chat.generateSessionSummary(.summary)

        let entry = chat.sessionSummaryEntry(for: .summary)
        #expect(entry.summary?.text == "- Goal: ship search\n- Next: run tests")
        #expect(entry.summary?.kind == .summary)
        #expect(entry.error == nil)
        #expect(!entry.isGenerating)
        #expect(chat.messages.map(\.id) == messageIDs)
        #expect(chat.sessionSummaryEntry(for: .nextStep).summary == nil)

        let generate = try #require(await transport.requests().last)
        #expect(generate.path == "/api/session/ses_parent/generate")
        #expect(generate.method == "POST")
        #expect(generate.body?["prompt"] as? String == SessionSummaryKind.summary.prompt)
        #expect(await transport.requests().allSatisfy { !$0.path.hasSuffix("/prompt") && !$0.path.hasSuffix("/compact") })
    }

    @Test func readingTheCachedResultNeverCallsTheModelAgain() async throws {
        let transport = SummaryTransport()
        let chat = try await makeChat(transport)
        await chat.generateSessionSummary(.nextStep)
        let calls = await transport.generateCount()

        for _ in 0..<3 { _ = chat.sessionSummaryEntry(for: .nextStep) }

        #expect(await transport.generateCount() == calls)
        #expect(calls == 1)
    }

    @Test func aFailedRegenerationKeepsThePreviousResultAndTheTranscript() async throws {
        let transport = SummaryTransport()
        let chat = try await makeChat(transport)
        #expect(await chat.loadMessages())
        await chat.generateSessionSummary(.summary)
        let previous = try #require(chat.sessionSummaryEntry(for: .summary).summary)
        await transport.setFailsGeneration(true)

        await chat.generateSessionSummary(.summary)

        let entry = chat.sessionSummaryEntry(for: .summary)
        #expect(entry.summary == previous)
        #expect(entry.error?.hasPrefix(AppText.sessionSummaryFailedPrefix) == true)
        #expect(!entry.isGenerating)
        #expect(chat.messages.map(\.id) == ["msg_user", "msg_reply"])
    }

    @Test func aNewerTranscriptMarksTheSummaryStaleUntilRegenerated() async throws {
        let transport = SummaryTransport()
        let chat = try await makeChat(transport)
        #expect(await chat.loadMessages())
        await chat.generateSessionSummary(.summary)
        let summary = try #require(chat.sessionSummaryEntry(for: .summary).summary)
        #expect(!chat.isSessionSummaryStale(summary))

        await transport.setIncludesFollowUp(true)
        #expect(await chat.loadMessages())

        #expect(chat.isSessionSummaryStale(summary))
        await chat.generateSessionSummary(.summary)
        let regenerated = try #require(chat.sessionSummaryEntry(for: .summary).summary)
        #expect(!chat.isSessionSummaryStale(regenerated))
    }

    @Test func aLateResultStaysWithTheSessionThatAskedForIt() async throws {
        let transport = SummaryTransport()
        await transport.setDelaysGeneration(true)
        let chat = try await makeChat(transport)
        let parent = try #require(chat.currentSession)

        let pending = Task { await chat.generateSessionSummary(.summary) }
        try await Task.sleep(for: .milliseconds(30))
        chat.currentSession = OCSession(id: "ses_other", title: "Elsewhere", time: .init(created: 0, updated: 0))
        await pending.value

        #expect(chat.sessionSummaryEntry(for: .summary).summary == nil)
        chat.currentSession = parent
        #expect(chat.sessionSummaryEntry(for: .summary).summary?.text.isEmpty == false)
    }

    @Test func v1ServersDoNotOfferOrCallGeneration() async throws {
        let transport = OpenCodeContractTransport(routes: [
            "/api/info": .init(statusCode: 404, body: Data(#"{"message":"not found"}"#.utf8)),
            "/global/health": .init(statusCode: 200, body: OpenCodeContractFixtures.v1HealthResponse),
        ])
        let api = OpenCodeClient(baseURL: URL(string: "http://example.com")!, transport: transport)
        let connection = ConnectionManager(testClient: api, capabilities: try await api.probeCapabilities())
        let chat = ChatClient(
            connection: connection, liveActivity: TestLiveActivityProvider(),
            sessionsService: SessionsService(connection: connection), messagesService: MessagesService(connection: connection),
            providersService: ProvidersService(connection: connection), questionService: QuestionService(connection: connection),
            savedConnectionsStore: SavedConnectionsStore(initialConnections: []), recordedReplayStore: RecordedReplayStore()
        )
        chat.currentSession = OCSession(id: "ses_parent", title: "Legacy", time: .init(created: 0, updated: 0))

        #expect(!chat.supportsSessionSummary)
        await chat.generateSessionSummary(.summary)

        #expect(chat.sessionSummaryEntry(for: .summary).error == AppText.sessionSummaryUnavailable)
        #expect(await transport.recordedPaths() == ["/api/info", "/global/health"])
    }

    private func makeChat(_ transport: SummaryTransport) async throws -> ChatClient {
        let api = OpenCodeClient(baseURL: URL(string: "https://example.com")!, transport: transport)
        let connection = ConnectionManager(testClient: api, capabilities: try await api.probeCapabilities())
        let chat = ChatClient(
            connection: connection, liveActivity: TestLiveActivityProvider(),
            sessionsService: SessionsService(connection: connection), messagesService: MessagesService(connection: connection),
            providersService: ProvidersService(connection: connection), questionService: QuestionService(connection: connection),
            savedConnectionsStore: SavedConnectionsStore(initialConnections: []), recordedReplayStore: RecordedReplayStore()
        )
        chat.currentSession = OCSession(id: "ses_parent", title: "Search work", time: .init(created: 0, updated: 0))
        return chat
    }
}

private actor SummaryTransport: OpenCodeTransport {
    struct Request: @unchecked Sendable {
        let method: String
        let path: String
        let body: [String: Any]?
    }

    private var recorded: [Request] = []
    private var failsGeneration = false
    private var delaysGeneration = false
    private var includesFollowUp = false
    private var generations = 0

    func requests() -> [Request] { recorded }
    func generateCount() -> Int { generations }
    func setFailsGeneration(_ value: Bool) { failsGeneration = value }
    func setDelaysGeneration(_ value: Bool) { delaysGeneration = value }
    func setIncludesFollowUp(_ value: Bool) { includesFollowUp = value }

    private var history: String {
        let followUp = includesFollowUp
            ? #",{"id":"msg_more","type":"user","time":{"created":3},"text":"Also add tests"}"#
            : ""
        return #"{"data":[{"id":"msg_user","type":"user","time":{"created":1},"text":"Add file search"},{"id":"msg_reply","type":"assistant","time":{"created":2},"content":[{"id":"prt_1","type":"text","text":"Search is done."}]}\#(followUp)],"cursor":{"next":null}}"#
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url!
        let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        recorded.append(Request(method: request.httpMethod ?? "GET", path: url.path, body: body))
        var status = 200
        let response: String
        switch url.path {
        case "/api/info": response = #"{"version":"2.0.23"}"#
        case "/api/session/ses_parent/message": response = history
        case "/api/session/ses_parent/generate":
            generations += 1
            if delaysGeneration { try await Task.sleep(for: .milliseconds(150)) }
            if failsGeneration {
                status = 503
                response = #"{"message":"model unavailable"}"#
            } else {
                response = #"{"data":{"text":"  - Goal: ship search\n- Next: run tests \n"}}"#
            }
        case "/api/session/active": response = #"{"data":{}}"#
        default: response = #"{"data":[]}"#
        }
        return (Data(response.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    nonisolated func makeEventStream(request: URLRequest, deliveryQueue: DispatchQueue, callbacks: OpenCodeEventStreamCallbacks) -> any OpenCodeEventStream {
        SummaryEventStream()
    }
}

nonisolated private final class SummaryEventStream: OpenCodeEventStream, @unchecked Sendable {
    func start() {}
    func suspend() {}
    func resume() {}
    func cancel() {}
}
