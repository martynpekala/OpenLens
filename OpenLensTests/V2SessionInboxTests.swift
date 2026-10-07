import Foundation
import Testing
@testable import OpenLens

/// The v2 queue is projected from the server's durable session inbox, so work
/// admitted by any client is visible and survives reopening, reconnecting, and
/// stream gaps.
@MainActor
struct V2SessionInboxTests {
    @Test func theQueueShowsEveryPendingKindInDeliveryOrder() async throws {
        let server = InboxFakeServer()
        await server.setInbox("ses_1", [
            .user("msg_u", "Run the tests", files: ["notes.txt"]),
            .synthetic("msg_s", "Check the build", description: "Reminder", delivery: "steer"),
            .compaction("msg_c"),
            .move("msg_m", directory: "/repos/other"),
        ])
        let chat = try await Self.openChat(server: server)

        // Steers are delivered at the next step boundary, ahead of queued work.
        #expect(chat.queuedPrompts.map(\.messageID) == ["msg_s", "msg_u", "msg_c", "msg_m"])
        #expect(chat.queuedPrompts.map(\.kind) == [
            .synthetic(description: "Reminder"), .user, .compaction, .move(directory: "/repos/other"),
        ])
        #expect(chat.queuedPrompts.map(\.delivery) == [.steer, .queue, .queue, .queue])
        #expect(chat.queuedPrompts.allSatisfy { $0.state == .queued })
        #expect(chat.queuedPrompts[0].text == "Check the build")
        #expect(chat.queuedPrompts[1].fileNames == ["notes.txt"])
    }

    @Test func entriesAlreadyInTheTranscriptAreNotQueuedTwice() async throws {
        let server = InboxFakeServer()
        await server.setInbox("ses_1", [.user("msg_a", "Already delivered"), .user("msg_b", "Still pending")])
        await server.setHistory("ses_1", [("msg_a", "Already delivered")])
        let chat = try await Self.openChat(server: server)

        #expect(chat.queuedPrompts.map(\.messageID) == ["msg_b"])
        #expect(chat.messages.map(\.id) == ["msg_a"])
    }

    @Test func aPendingAdmissionIsDistinguishedFromAcceptedWork() async throws {
        let server = InboxFakeServer()
        await server.setInbox("ses_1", [.user("msg_desktop", "From the desktop")])
        let chat = try await Self.openChat(server: server)
        chat.isLoading = true
        chat.responseState = .generating
        await server.holdPrompts()

        chat.inputText = "From the phone"
        chat.queuePrompt()
        try await Self.waitUntil { await server.heldPromptCount == 1 }

        #expect(chat.queuedPrompts.map(\.text) == ["From the desktop", "From the phone"])
        #expect(chat.queuedPrompts.map(\.state) == [.queued, .submitting])

        await server.releasePrompts()
        try await Self.waitUntil { chat.queuedPrompts.last?.state == .queued }
        let phoneID = try #require(await server.inboxIDs("ses_1").last)
        #expect(chat.queuedPrompts.map(\.messageID) == ["msg_desktop", phoneID])
    }

    @Test func inboxEventsReconcileTheSameQueue() async throws {
        let server = InboxFakeServer()
        let chat = try await Self.openChat(server: server)

        await server.setInbox("ses_1", [.user("msg_a", "First"), .user("msg_b", "Second")])
        chat.receiveStreamEvent(try Self.streamEvent("session.inbox.enqueued", inboxID: "msg_b"))
        try await Self.waitUntil { chat.queuedPrompts.count == 2 }

        await server.setInbox("ses_1", [.user("msg_a", "First", delivery: "steer")])
        chat.receiveStreamEvent(try Self.streamEvent("session.inbox.cancelled", inboxID: "msg_b"))
        try await Self.waitUntil { chat.queuedPrompts.count == 1 }
        #expect(chat.queuedPrompts.first?.delivery == .steer)

        await server.setInbox("ses_1", [])
        await server.setHistory("ses_1", [("msg_a", "First")])
        chat.receiveStreamEvent(try Self.streamEvent("session.inbox.delivered", inboxID: "msg_a"))
        try await Self.waitUntil { chat.queuedPrompts.isEmpty && chat.isStreamSynchronized }
        #expect(chat.messages.map(\.id) == ["msg_a"])
    }

    @Test func eventsForAnotherSessionDoNotTouchTheQueue() async throws {
        let server = InboxFakeServer()
        let chat = try await Self.openChat(server: server)
        await server.resetCounters()

        chat.receiveStreamEvent(try Self.streamEvent("session.inbox.enqueued", inboxID: "msg_x", sessionID: "ses_2"))
        try await Task.sleep(for: .milliseconds(50))

        #expect(await server.inboxReads == 0)
    }

    @Test func recoveryAfterAStreamGapRestoresWorkAdmittedElsewhere() async throws {
        let server = InboxFakeServer()
        let chat = try await Self.openChat(server: server)

        await server.setInbox("ses_1", [.user("msg_desktop", "Queued while away")])
        chat.synchronizeCurrentSessionFromServer()
        try await Self.waitUntil { chat.isStreamSynchronized && !chat.queuedPrompts.isEmpty }

        #expect(chat.queuedPrompts.map(\.messageID) == ["msg_desktop"])
    }

    @Test func aFailedInboxRecoveryIsNotReportedSynchronizedUntilARetrySucceeds() async throws {
        let server = InboxFakeServer()
        await server.setInbox("ses_1", [.user("msg_a", "Pending")])
        await server.setFailsInbox(true)
        let chat = try await Self.openChat(server: server)

        #expect(!chat.isStreamSynchronized)
        #expect(chat.errorMessage?.hasPrefix(AppText.sessionInboxLoadFailedPrefix) == true)

        await server.setFailsInbox(false)
        chat.synchronizeCurrentSessionFromServer()
        try await Self.waitUntil { chat.isStreamSynchronized }

        #expect(chat.queuedPrompts.map(\.messageID) == ["msg_a"])
        #expect(chat.errorMessage == nil)
    }

    @Test func aFailedPostAdmissionInboxRecoveryClearsSynchronizationUntilRetry() async throws {
        let server = InboxFakeServer()
        let chat = try await Self.openChat(server: server)
        #expect(chat.isStreamSynchronized)

        await server.setFailsInbox(true)
        chat.isLoading = true
        chat.responseState = .generating
        chat.inputText = "From the phone"
        chat.queuePrompt()
        try await Self.waitUntil { !chat.isQueueingPrompt }

        #expect(chat.errorMessage?.hasPrefix(AppText.sessionInboxLoadFailedPrefix) == true)
        #expect(!chat.isStreamSynchronized)
        #expect(chat.queuedPrompts.map(\.text) == ["From the phone"])

        await server.setFailsInbox(false)
        chat.synchronizeCurrentSessionFromServer()
        try await Self.waitUntil { chat.isStreamSynchronized }

        #expect(chat.queuedPrompts.map(\.text) == ["From the phone"])
        #expect(chat.errorMessage == nil)
    }

    @Test func distinctInboxIdentitiesWithMatchingCommandTextStayVisible() async throws {
        let server = InboxFakeServer()
        await server.setInbox("ses_1", [
            .user("msg_external_1", "/review same text"),
            .user("msg_external_2", "/review same text"),
        ])
        let chat = try await Self.openChat(server: server)
        chat.updateSlashCatalog(commands: ["review"], agents: [])
        chat.isLoading = true
        chat.responseState = .generating
        chat.inputText = "/review same text"
        chat.queuePrompt()
        #expect(chat.messages.contains { $0.content == "/review same text" })

        try await Self.waitUntil { await server.commandRequests == 1 }
        _ = await chat.loadMessages()

        #expect(chat.queuedPrompts.map(\.messageID) == ["msg_external_1", "msg_external_2"])
        #expect(chat.queuedPrompts.allSatisfy { $0.state == .queued })
    }

    @Test func steeredCompactionPrecedesEarlierUserAndSyntheticSteers() async throws {
        let server = InboxFakeServer()
        await server.setInbox("ses_1", [
            .user("msg_queue", "Queued first"),
            .user("msg_user", "Earlier steer", delivery: "steer"),
            .synthetic("msg_synthetic", "Another steer", description: "Reminder", delivery: "steer"),
            .compaction("msg_compact", delivery: "steer"),
            .user("msg_later", "Later steer", delivery: "steer"),
        ])
        let chat = try await Self.openChat(server: server)

        #expect(chat.queuedPrompts.map(\.messageID) == [
            "msg_compact", "msg_user", "msg_synthetic", "msg_later", "msg_queue",
        ])
        #expect(chat.queuedPrompts.first?.kind == .compaction)
        #expect(chat.queuedPrompts.first?.delivery == .steer)
    }

    @Test func steeredCompactionDoesNotCrossAMoveBoundary() async throws {
        let server = InboxFakeServer()
        await server.setInbox("ses_1", [
            .user("msg_user", "Earlier steer", delivery: "steer"),
            .move("msg_move", directory: "/repos/other", delivery: "steer"),
            .user("msg_later", "After the move", delivery: "steer"),
            .compaction("msg_compact", delivery: "steer"),
        ])
        let chat = try await Self.openChat(server: server)

        #expect(chat.queuedPrompts.map(\.messageID) == ["msg_user", "msg_move", "msg_later", "msg_compact"])
    }

    @Test func queuedCompactionKeepsItsQueuePosition() async throws {
        let server = InboxFakeServer()
        await server.setInbox("ses_1", [
            .user("msg_first", "Queued first"),
            .compaction("msg_compact"),
            .user("msg_last", "Queued last"),
            .user("msg_steer", "Steer", delivery: "steer"),
        ])
        let chat = try await Self.openChat(server: server)

        #expect(chat.queuedPrompts.map(\.messageID) == ["msg_steer", "msg_first", "msg_compact", "msg_last"])
    }

    @Test func aPromptAdmittedDuringRecoveryDoesNotHideChangesFromThatRecovery() async throws {
        let server = InboxFakeServer()
        await server.setInbox("ses_1", [.user("msg_a", "Cancelled elsewhere")])
        let chat = try await Self.openChat(server: server)
        chat.isLoading = true
        chat.responseState = .generating
        await server.holdInbox("ses_1")
        chat.synchronizeCurrentSessionFromServer()
        try await Self.waitUntil { await server.isHoldingInbox }

        // Another client cancels while this phone's prompt is admitted and its
        // own follow-up read fails.
        await server.setInbox("ses_1", [])
        await server.setFailsInbox(true)
        chat.inputText = "From the phone"
        chat.queuePrompt()
        try await Self.waitUntil { chat.errorMessage?.hasPrefix(AppText.sessionInboxLoadFailedPrefix) == true }
        #expect(chat.queuedPrompts.map(\.text) == ["Cancelled elsewhere", "From the phone"])

        await server.setFailsInbox(false)
        await server.releaseInbox()
        try await Self.waitUntil { chat.isStreamSynchronized }

        #expect(chat.queuedPrompts.map(\.text) == ["From the phone"])
    }

    @Test func aDelayedInboxResultDoesNotChangeTheNextSession() async throws {
        let server = InboxFakeServer()
        await server.setInbox("ses_1", [.user("msg_old", "Old session")])
        await server.setInbox("ses_2", [.user("msg_new", "New session")])
        let chat = try await Self.openChat(server: server)
        await server.holdInbox("ses_1")

        chat.synchronizeCurrentSessionFromServer()
        try await Self.waitUntil { await server.isHoldingInbox }
        await chat.loadSession(Self.session("ses_2"))
        await server.releaseInbox()
        try await Task.sleep(for: .milliseconds(50))

        #expect(chat.queuedPrompts.map(\.messageID) == ["msg_new"])
    }

    @Test func aDelayedInboxResultDoesNotRepopulateAnUnloadedSession() async throws {
        let server = InboxFakeServer()
        await server.setInbox("ses_1", [.user("msg_old", "Old connection")])
        let chat = try await Self.openChat(server: server)
        await server.holdInbox("ses_1")

        chat.synchronizeCurrentSessionFromServer()
        try await Self.waitUntil { await server.isHoldingInbox }
        chat.unloadSession(ifMatching: "ses_1")
        chat.currentSession = Self.session("ses_1")
        await server.releaseInbox()
        try await Task.sleep(for: .milliseconds(50))

        #expect(chat.queuedPrompts.isEmpty)
    }

    @Test func anExternalPromptSurvivesAResetWithoutDuplicationOrPromotion() async throws {
        let server = InboxFakeServer()
        await server.setInbox("ses_1", [.user("msg_a", "External first"), .user("msg_b", "External second")])
        let chat = try await Self.openChat(server: server)
        chat.isLoading = true
        chat.responseState = .generating

        // Only the server delivers inbox work; finishing a turn locally must
        // not move the next entry into the transcript.
        chat.finishLoading()
        #expect(chat.queuedPrompts.map(\.messageID) == ["msg_a", "msg_b"])
        #expect(chat.messages.isEmpty)

        await chat.loadSession(Self.session("ses_1"))

        #expect(chat.queuedPrompts.map(\.messageID) == ["msg_a", "msg_b"])
        #expect(chat.messages.isEmpty)
    }

    // MARK: - Helpers

    private static func session(_ id: String) -> OCSession {
        OCSession(id: id, title: id, time: .init(created: 0, updated: 0))
    }

    private static func openChat(server: InboxFakeServer) async throws -> ChatClient {
        let api = OpenCodeClient(baseURL: URL(string: "https://example.com")!, transport: server)
        let connection = ConnectionManager(testClient: api, capabilities: try await api.probeCapabilities())
        let chat = ChatClient(
            connection: connection, liveActivity: LiveActivityManager(),
            sessionsService: SessionsService(connection: connection), messagesService: MessagesService(connection: connection),
            providersService: ProvidersService(connection: connection), questionService: QuestionService(connection: connection),
            savedConnectionsStore: SavedConnectionsStore(initialConnections: []), recordedReplayStore: RecordedReplayStore()
        )
        await chat.loadSession(session("ses_1"))
        return chat
    }

    /// Runs a native event through the v2 adapter, as the stream does.
    private static func streamEvent(_ type: String, inboxID: String, sessionID: String = "ses_1") throws -> SSEInboundEvent {
        var adapter = V2EventAdapter()
        let envelope: [String: Any] = [
            "type": type,
            "data": ["sessionID": sessionID, "inboxID": inboxID],
            "location": ["directory": "/workspace"],
        ]
        return .raw(try #require(try adapter.event(envelope, directory: nil)))
    }

    private static func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
        for _ in 0..<300 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for condition")
    }
}

// MARK: - Fake server

private actor InboxFakeServer: OpenCodeTransport {
    struct Entry: Sendable {
        let json: String
        let id: String

        static func user(_ id: String, _ text: String, files: [String] = [], delivery: String = "queue") -> Entry {
            let fileJSON = files.map { #"{"data":"","mime":"text/plain","source":{"type":"file"},"name":"\#($0)"}"# }
            return Entry(
                json: #"{"id":"\#(id)","sessionID":"SES","time":{"created":1},"type":"user","payload":{"text":"\#(text)","files":[\#(fileJSON.joined(separator: ","))]},"delivery":"\#(delivery)"}"#,
                id: id
            )
        }

        static func synthetic(_ id: String, _ text: String, description: String, delivery: String) -> Entry {
            Entry(
                json: #"{"id":"\#(id)","sessionID":"SES","time":{"created":1},"type":"synthetic","payload":{"text":"\#(text)","description":"\#(description)"},"delivery":"\#(delivery)"}"#,
                id: id
            )
        }

        static func compaction(_ id: String, delivery: String = "queue") -> Entry {
            Entry(json: #"{"id":"\#(id)","sessionID":"SES","time":{"created":1},"type":"compaction","payload":{},"delivery":"\#(delivery)"}"#, id: id)
        }

        static func move(_ id: String, directory: String, delivery: String = "queue") -> Entry {
            Entry(
                json: #"{"id":"\#(id)","sessionID":"SES","time":{"created":1},"type":"move","payload":{"projectID":"p","location":{"directory":"\#(directory)"}},"delivery":"\#(delivery)"}"#,
                id: id
            )
        }
    }

    private var inboxes: [String: [Entry]] = [:]
    private var histories: [String: [(String, String)]] = [:]
    private var failsInbox = false
    private var heldInboxSession: String?
    private var inboxWaiter: CheckedContinuation<Void, Never>?
    private var holdsPrompts = false
    private var promptWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var inboxReads = 0
    private(set) var commandRequests = 0

    var isHoldingInbox: Bool { inboxWaiter != nil }
    var heldPromptCount: Int { promptWaiters.count }
    func inboxIDs(_ sessionID: String) -> [String] { inboxes[sessionID, default: []].map(\.id) }

    func setInbox(_ sessionID: String, _ entries: [Entry]) { inboxes[sessionID] = entries }
    func setHistory(_ sessionID: String, _ messages: [(String, String)]) { histories[sessionID] = messages }
    func setFailsInbox(_ fails: Bool) { failsInbox = fails }
    func holdInbox(_ sessionID: String) { heldInboxSession = sessionID }
    func releaseInbox() {
        heldInboxSession = nil
        inboxWaiter?.resume()
        inboxWaiter = nil
    }
    func holdPrompts() { holdsPrompts = true }
    func releasePrompts() {
        holdsPrompts = false
        promptWaiters.forEach { $0.resume() }
        promptWaiters = []
    }
    func resetCounters() { inboxReads = 0 }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url!
        let path = url.path
        let parts = path.split(separator: "/").map(String.init)

        func respond(_ status: Int, _ json: String) -> (Data, URLResponse) {
            (Data(json.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }

        if path == "/api/info" { return respond(200, #"{"version":"2.0.23"}"#) }
        if path == "/api/session/active" { return respond(200, #"{"data":{}}"#) }
        guard parts.count >= 3, parts[1] == "session" else { return respond(404, "{}") }
        let sessionID = parts[2]

        switch parts.count == 3 ? "" : parts[3] {
        case "":
            return respond(200, #"{"data":{"id":"\#(sessionID)","title":"\#(sessionID)","time":{"created":0,"updated":0}}}"#)
        case "inbox":
            inboxReads += 1
            if heldInboxSession == sessionID {
                heldInboxSession = nil
                await withCheckedContinuation { inboxWaiter = $0 }
            }
            if failsInbox { throw URLError(.networkConnectionLost) }
            let entries = inboxes[sessionID, default: []]
                .map { $0.json.replacingOccurrences(of: "SES", with: sessionID) }
            return respond(200, #"{"data":[\#(entries.joined(separator: ","))]}"#)
        case "message":
            let messages = histories[sessionID, default: []].map { id, text in
                #"{"id":"\#(id)","type":"user","time":{"created":1},"text":"\#(text)"}"#
            }
            return respond(200, #"{"data":[\#(messages.joined(separator: ","))],"cursor":{"next":null}}"#)
        case "permission", "form":
            return respond(200, #"{"data":[]}"#)
        case "command":
            commandRequests += 1
            return respond(204, "")
        case "prompt":
            if holdsPrompts {
                await withCheckedContinuation { promptWaiters.append($0) }
            }
            let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
            let id = body["id"] as? String ?? "msg_server"
            let entry = Entry.user(id, body["text"] as? String ?? "", delivery: body["delivery"] as? String ?? "steer")
            inboxes[sessionID, default: []].append(entry)
            return respond(200, #"{"data":\#(entry.json.replacingOccurrences(of: "SES", with: sessionID))}"#)
        default:
            return respond(404, "{}")
        }
    }

    nonisolated func makeEventStream(
        request: URLRequest,
        deliveryQueue: DispatchQueue,
        callbacks: OpenCodeEventStreamCallbacks
    ) -> any OpenCodeEventStream {
        InboxUnusedStream()
    }
}

private final class InboxUnusedStream: OpenCodeEventStream, @unchecked Sendable {
    func start() {}
    func suspend() {}
    func resume() {}
    func cancel() {}
}
