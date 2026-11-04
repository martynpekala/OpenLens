import Foundation
import Testing
@testable import OpenLens

/// Sending new work in an archived conversation restores it first, so the
/// turn is not filed away with it. The restore is confirmed against the
/// canonical session before the prompt leaves the device.
@MainActor
struct ArchivedSessionSendTests {

    // MARK: - Restoring on send

    @Test func sendingInAnArchivedConversationRestoresItBeforeThePrompt() async throws {
        let server = ArchivedSendFakeServer()
        let chat = try await Self.openArchivedChat(server: server)
        await server.resetCounters()

        chat.inputText = "Hello"
        chat.send()
        try await Self.waitUntil { chat.promptSubmissions.first?.state.isAccepted == true }

        let requests = await server.requests
        let restoreIndex = try #require(requests.firstIndex {
            $0.method == "PATCH" && $0.path == "/api/session/ses_1"
        })
        let promptIndex = try #require(requests.firstIndex {
            $0.method == "POST" && $0.path == "/api/session/ses_1/prompt"
        })
        #expect(restoreIndex < promptIndex)
        let restoreBody = try #require(requests[restoreIndex].json["archived"] as? Bool)
        #expect(restoreBody == false)
        // Exactly one restore serves the send; the canonical snapshot it
        // returned keeps the next send from repeating the mutation.
        #expect(requests.filter { $0.method == "PATCH" && $0.path == "/api/session/ses_1" }.count == 1)
        #expect(chat.currentSession?.isArchived == false)
        #expect(chat.errorMessage == nil)
    }

    @Test func theRestoreNotifiesTheSessionCatalog() async throws {
        let server = ArchivedSendFakeServer()
        let (chat, sessionsService) = try await Self.openArchivedChatWithService(server: server)
        await server.resetCounters()

        chat.inputText = "Hello"
        chat.send()
        try await Self.waitUntil { chat.promptSubmissions.first?.state.isAccepted == true }

        // The archived list and active catalog observe this counter to reload.
        #expect(sessionsService.archiveMutationCount == 1)
    }

    @Test func anUnconfirmedRestoreStopsThePromptWithoutSendingIt() async throws {
        let server = ArchivedSendFakeServer()
        let chat = try await Self.openArchivedChat(server: server)
        await server.setSilentlyIgnoresUnarchive(true)
        await server.resetCounters()

        chat.inputText = "Hello"
        chat.send()
        try await Self.waitUntil { chat.promptSubmissions.first?.state == .failed }

        #expect(await server.promptRequests.isEmpty)
        #expect(chat.inputText == "Hello")
        #expect(chat.errorMessage?.hasPrefix("Failed to send") == true)
        #expect(chat.currentSession?.isArchived == true)
    }

    @Test func activeConversationsSendWithoutTouchingTheArchive() async throws {
        let server = ArchivedSendFakeServer()
        await server.setArchived(nil)
        let chat = try await Self.openArchivedChat(server: server)
        await server.resetCounters()

        chat.inputText = "Hello"
        chat.send()
        try await Self.waitUntil { chat.promptSubmissions.first?.state.isAccepted == true }

        let requests = await server.requests
        #expect(!requests.contains { $0.method == "PATCH" && $0.path == "/api/session/ses_1" })
    }

    @Test func queuedFollowUpsInAnArchivedConversationRestoreItFirst() async throws {
        let server = ArchivedSendFakeServer()
        let chat = try await Self.openArchivedChat(server: server)
        chat.isLoading = true
        chat.responseState = .generating
        await server.resetCounters()

        chat.inputText = "Later"
        chat.queuePrompt()
        try await Self.waitUntil { chat.promptSubmissions.first?.state.isAccepted == true }

        let requests = await server.requests
        let restoreIndex = try #require(requests.firstIndex {
            $0.method == "PATCH" && $0.path == "/api/session/ses_1"
        })
        let queueIndex = try #require(requests.firstIndex {
            $0.method == "POST" && $0.path == "/api/session/ses_1/prompt"
        })
        #expect(restoreIndex < queueIndex)
        #expect(chat.currentSession?.isArchived == false)
    }

    // MARK: - Helpers

    private static func openArchivedChat(server: ArchivedSendFakeServer) async throws -> ChatClient {
        try await openArchivedChatWithService(server: server).chat
    }

    private static func openArchivedChatWithService(
        server: ArchivedSendFakeServer
    ) async throws -> (chat: ChatClient, sessionsService: SessionsService) {
        let api = OpenCodeClient(baseURL: URL(string: "https://example.com")!, transport: server)
        let connection = ConnectionManager(testClient: api, capabilities: try await api.probeCapabilities())
        let sessionsService = SessionsService(connection: connection)
        let chat = ChatClient(
            connection: connection, liveActivity: TestLiveActivityProvider(),
            sessionsService: sessionsService, messagesService: MessagesService(connection: connection),
            providersService: ProvidersService(connection: connection), questionService: QuestionService(connection: connection),
            savedConnectionsStore: SavedConnectionsStore(initialConnections: []), recordedReplayStore: RecordedReplayStore()
        )
        await chat.loadSession(
            OCSession(id: "ses_1", title: "Session", time: .init(created: 0, updated: 0, archived: 4500))
        )
        await server.resetCounters()
        return (chat, sessionsService)
    }

    private static func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
        for _ in 0..<300 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for condition")
    }
}

private extension PromptSubmission.State {
    var isAccepted: Bool {
        if case .accepted = self { return true }
        return false
    }
}

// MARK: - Fake server

/// A v2 fake whose session starts archived. A `PATCH /api/session/:id` with
/// `archived: false` restores it and the canonical read confirms the new
/// state, unless the older-server behavior of silently ignoring the field is
/// enabled.
private actor ArchivedSendFakeServer: OpenCodeTransport {
    struct Request: Sendable {
        let method: String
        let path: String
        let body: Data

        var json: [String: Any] {
            (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        }
    }

    private struct Entry: Sendable {
        let id: String
        let text: String
    }

    private var inbox: [Entry] = []
    private var history: [Entry] = []
    private var archived: Double? = 4500
    private var silentlyIgnoresUnarchive = false
    private(set) var requests: [Request] = []

    var promptRequests: [Request] { requests.filter { $0.path.hasSuffix("/prompt") } }

    func setArchived(_ timestamp: Double?) { archived = timestamp }
    func setSilentlyIgnoresUnarchive(_ ignores: Bool) { silentlyIgnoresUnarchive = ignores }
    func resetCounters() { requests = [] }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url!
        let method = request.httpMethod ?? "GET"
        let path = url.path
        let recorded = Request(method: method, path: path, body: request.httpBody ?? Data())
        requests.append(recorded)

        func respond(_ status: Int, _ json: String = "") -> (Data, URLResponse) {
            (Data(json.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }

        if method == "POST", path == "/api/session/ses_1/prompt" {
            return admit(recorded.json, respond: respond)
        }

        let location = #""location":{"directory":"/workspace","project":{"id":"p","directory":"/workspace"}}"#
        switch path {
        case "/api/info":
            return respond(200, #"{"version":"2.0.23"}"#)
        case "/api/model":
            return respond(200, #"{\#(location),"data":[{"id":"claude-a","providerID":"anthropic","name":"Claude A"}]}"#)
        case "/api/model/default":
            return respond(200, #"{\#(location),"data":{"id":"claude-a","providerID":"anthropic","name":"Claude A"}}"#)
        case "/api/provider":
            return respond(200, #"{\#(location),"data":[{"id":"anthropic","name":"Anthropic"}]}"#)
        case "/api/session/active":
            return respond(200, #"{"data":{}}"#)
        case "/api/session/ses_1":
            if method == "PATCH" {
                if !silentlyIgnoresUnarchive {
                    archived = nil
                }
                return respond(204)
            }
            let archivedJSON = archived.map { ",\"archived\":\($0)" } ?? ""
            return respond(200, #"{"data":{"id":"ses_1","title":"Session","time":{"created":0,"updated":0\#(archivedJSON)}}}"#)
        case "/api/session/ses_1/inbox":
            return respond(200, #"{"data":[\#(inbox.map(Self.inboxJSON).joined(separator: ","))]}"#)
        case "/api/session/ses_1/message":
            let messages = history.map(Self.messageJSON).joined(separator: ",")
            return respond(200, #"{"data":[\#(messages)],"cursor":{"next":null}}"#)
        case "/api/session/ses_1/permission", "/api/session/ses_1/form":
            return respond(200, #"{"data":[]}"#)
        default:
            break
        }
        return respond(404)
    }

    private func admit(
        _ body: [String: Any],
        respond: (Int, String) -> (Data, URLResponse)
    ) -> (Data, URLResponse) {
        let id = body["id"] as? String ?? "msg_server"
        let entry: Entry
        if let existing = (inbox + history).first(where: { $0.id == id }) {
            entry = existing
        } else {
            entry = Entry(id: id, text: body["text"] as? String ?? "")
            inbox.append(entry)
        }
        return respond(200, #"{"data":\#(Self.inboxJSON(entry))}"#)
    }

    private static func inboxJSON(_ entry: Entry) -> String {
        #"{"id":"\#(entry.id)","sessionID":"ses_1","time":{"created":1},"type":"user","payload":{"text":"\#(entry.text)"},"delivery":"steer"}"#
    }

    private static func messageJSON(_ entry: Entry) -> String {
        #"{"id":"\#(entry.id)","type":"user","time":{"created":1},"text":"\#(entry.text)"}"#
    }

    nonisolated func makeEventStream(
        request: URLRequest,
        deliveryQueue: DispatchQueue,
        callbacks: OpenCodeEventStreamCallbacks
    ) -> any OpenCodeEventStream {
        ArchivedSendUnusedStream()
    }
}

private final class ArchivedSendUnusedStream: OpenCodeEventStream, @unchecked Sendable {
    func start() {}
    func suspend() {}
    func resume() {}
    func cancel() {}
}
