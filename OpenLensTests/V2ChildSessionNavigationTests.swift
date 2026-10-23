import Foundation
import Testing
@testable import OpenLens

/// Delegated-work cards open the child conversation only after the server
/// confirms it belongs to the open parent, and moving between the two keeps
/// each session's unsent draft with that session.
@MainActor
struct V2ChildSessionNavigationTests {
    @Test func aCardNamesItsChildAndOpensTheCanonicalDelegatedSession() async throws {
        let transport = ChildSessionTransport()
        let chat = try await makeChat(transport)
        #expect(await chat.loadMessages())

        let step = try subagentStep(chat.messages[0])
        #expect(step.childSessionID == "ses_child")
        #expect(chat.contextEntries.first?.subagentResult?.childID == "ses_child")

        let child = await chat.resolveChildSession(id: "ses_child")

        #expect(child?.id == "ses_child")
        #expect(child?.title == "Review changes (child)")
        #expect(child?.parentID == "ses_parent")
        #expect(chat.errorMessage == nil)
        #expect(chat.currentSession?.id == "ses_parent")
    }

    @Test func aMissingChildExplainsItselfInsteadOfOpeningAnEmptyConversation() async throws {
        let chat = try await makeChat(ChildSessionTransport())

        let child = await chat.resolveChildSession(id: "ses_missing")

        #expect(child == nil)
        #expect(chat.errorMessage == AppText.childSessionMissing)
    }

    @Test func aTransportFailureIsDistinctFromAMissingChild() async throws {
        let chat = try await makeChat(ChildSessionTransport())

        let child = await chat.resolveChildSession(id: "ses_broken")

        #expect(child == nil)
        let error = try #require(chat.errorMessage)
        #expect(error.hasPrefix(AppText.childSessionFailedPrefix))
        #expect(error != AppText.childSessionMissing)
    }

    @Test func aSessionThatIsNotThisParentsChildIsRefused() async throws {
        let transport = ChildSessionTransport()
        let chat = try await makeChat(transport)

        #expect(await chat.resolveChildSession(id: "ses_unrelated") == nil)
        #expect(chat.errorMessage == AppText.childSessionNotDelegated)

        chat.errorMessage = nil
        #expect(await chat.resolveChildSession(id: "../escape") == nil)
        #expect(await chat.resolveChildSession(id: "ses_parent") == nil)
        #expect(chat.errorMessage == AppText.childSessionInvalid)
        #expect(await transport.requestedPaths().allSatisfy { !$0.contains("escape") })
    }

    @Test func aLateChildResponseDoesNotNavigateFromASessionTheUserLeft() async throws {
        let transport = ChildSessionTransport()
        let chat = try await makeChat(transport)

        let pending = Task { await chat.resolveChildSession(id: "ses_slow_child") }
        try await Task.sleep(for: .milliseconds(30))
        chat.currentSession = OCSession(id: "ses_other", title: "Elsewhere", time: .init(created: 0, updated: 0))

        #expect(await pending.value == nil)
        #expect(chat.errorMessage == nil)
    }

    @Test func returningFromTheChildRestoresTheParentDraftAndKeepsEachDraftApart() async throws {
        let transport = ChildSessionTransport()
        let chat = try await makeChat(transport)
        let parent = try #require(chat.currentSession)
        chat.inputText = "Ask the reviewer about tests"

        let child = try #require(await chat.resolveChildSession(id: "ses_child"))
        await chat.loadSession(child)
        #expect(chat.currentSession?.id == "ses_child")
        #expect(chat.inputText.isEmpty)
        chat.inputText = "Child-only note"

        await chat.loadSession(parent)
        #expect(chat.currentSession?.id == "ses_parent")
        #expect(chat.inputText == "Ask the reviewer about tests")

        await chat.loadSession(child)
        #expect(chat.inputText == "Child-only note")
    }

    private func subagentStep(_ message: ChatMessage) throws -> ChatMessage.PersistedSubagentStep {
        guard case .subagent(let step) = message.assistantSegments.first?.kind else {
            throw OpenCodeError.invalidPayload("Expected delegated work card")
        }
        return step
    }

    private func makeChat(_ transport: ChildSessionTransport) async throws -> ChatClient {
        let api = OpenCodeClient(baseURL: URL(string: "https://example.com")!, transport: transport)
        let connection = ConnectionManager(testClient: api, capabilities: try await api.probeCapabilities())
        let chat = ChatClient(
            connection: connection, liveActivity: TestLiveActivityProvider(),
            sessionsService: SessionsService(connection: connection), messagesService: MessagesService(connection: connection),
            providersService: ProvidersService(connection: connection), questionService: QuestionService(connection: connection),
            savedConnectionsStore: SavedConnectionsStore(initialConnections: []), recordedReplayStore: RecordedReplayStore()
        )
        chat.currentSession = OCSession(id: "ses_parent", title: "Delegated work", time: .init(created: 0, updated: 0))
        return chat
    }
}

private actor ChildSessionTransport: OpenCodeTransport {
    private var paths: [String] = []
    func requestedPaths() -> [String] { paths }

    static let parentHistory = #"""
    {"data":[{"id":"msg_launch","type":"assistant","time":{"created":1},"content":[{"id":"call_child","type":"tool","name":"subagent","state":{"status":"completed","input":{"agent":"review","description":"Review changes"},"content":[{"type":"text","text":"Background job started"}],"metadata":{"sessionID":"ses_child","status":"running"}}}]},{"id":"msg_result","type":"synthetic","time":{"created":2},"description":"Review changes","text":"<subagent sessionID=\"ses_child\" state=\"completed\" description=\"Review changes\">\nDone.\n</subagent>","metadata":{"source":"subagent","childID":"ses_child","agent":"review","state":"completed"}}],"cursor":{"next":null}}
    """#

    private static func session(_ id: String, title: String, parentID: String?) -> String {
        let parent = parentID.map { #","parentID":"\#($0)""# } ?? ""
        return #"{"data":{"id":"\#(id)","title":"\#(title)","time":{"created":0,"updated":0}\#(parent)}}"#
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url!
        paths.append(url.path)
        var status = 200
        let body: String
        switch url.path {
        case "/api/info": body = #"{"version":"2.0.23"}"#
        case "/api/session/ses_parent": body = Self.session("ses_parent", title: "Delegated work", parentID: nil)
        case "/api/session/ses_child": body = Self.session("ses_child", title: "Review changes (child)", parentID: "ses_parent")
        case "/api/session/ses_slow_child":
            try await Task.sleep(for: .milliseconds(150))
            body = Self.session("ses_slow_child", title: "Slow", parentID: "ses_parent")
        case "/api/session/ses_unrelated": body = Self.session("ses_unrelated", title: "Unrelated", parentID: "ses_someone_else")
        case "/api/session/ses_missing":
            status = 404
            body = #"{"message":"Session not found"}"#
        case "/api/session/ses_broken":
            status = 503
            body = #"{"message":"unavailable"}"#
        case "/api/session/ses_parent/message": body = Self.parentHistory
        case "/api/session/ses_child/message": body = #"{"data":[],"cursor":{"next":null}}"#
        case "/api/session/active": body = #"{"data":{}}"#
        default: body = #"{"data":[]}"#
        }
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    nonisolated func makeEventStream(request: URLRequest, deliveryQueue: DispatchQueue, callbacks: OpenCodeEventStreamCallbacks) -> any OpenCodeEventStream {
        ChildSessionEventStream()
    }
}

nonisolated private final class ChildSessionEventStream: OpenCodeEventStream, @unchecked Sendable {
    func start() {}
    func suspend() {}
    func resume() {}
    func cancel() {}
}
