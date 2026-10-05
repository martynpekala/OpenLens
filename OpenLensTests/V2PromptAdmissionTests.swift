import Foundation
import Testing
@testable import OpenLens

/// Prompt admission against the released v2 contract: `POST .../prompt`
/// returns the durable `Session.Inbox.User`, the first admission for a caller
/// ID wins, and a lost response is reconciled from the inbox and history.
@MainActor
struct V2PromptAdmissionTests {

    // MARK: - Transport

    @Test func admissionsReturnTheDurableInboxIdentity() async throws {
        let server = AdmissionFakeServer()
        let api = try await Self.makeClient(server: server)

        let steer = try await api.sendPromptAsync(sessionID: "ses_1", text: "Now", messageID: "msg_steer")
        let queued = try await api.queuePrompt(sessionID: "ses_1", text: "Later", messageID: "msg_queue")

        #expect(steer == OCV2PromptAdmission(id: "msg_steer", sessionID: "ses_1", delivery: .steer))
        #expect(queued == OCV2PromptAdmission(id: "msg_queue", sessionID: "ses_1", delivery: .queue))
        let bodies = await server.promptRequests.map(\.json)
        #expect(bodies.map { $0["id"] as? String } == ["msg_steer", "msg_queue"])
        #expect(bodies.map { $0["delivery"] as? String } == ["steer", "queue"])
    }

    @Test func theInboxListsPendingWorkOfEveryKind() async throws {
        let server = AdmissionFakeServer()
        await server.setRawInbox(#"""
        [
          {"id":"msg_u","sessionID":"ses_1","time":{"created":1},"type":"user","payload":{"text":"Queued"},"delivery":"queue"},
          {"id":"msg_s","sessionID":"ses_1","time":{"created":2},"type":"synthetic","payload":{"text":"Note"},"delivery":"steer"},
          {"id":"msg_c","sessionID":"ses_1","time":{"created":3},"type":"compaction","payload":{},"delivery":"queue"}
        ]
        """#)
        let api = try await Self.makeClient(server: server)

        let inbox = try await api.listSessionInbox(sessionID: "ses_1")

        #expect(inbox.map(\.id) == ["msg_u", "msg_s", "msg_c"])
        #expect(inbox.map(\.type) == ["user", "synthetic", "compaction"])
        #expect(inbox.map(\.delivery) == [.queue, .steer, .queue])
        #expect(inbox.map(\.text) == ["Queued", "Note", nil])
    }

    @Test func admissionLookupChecksTheInboxThenTheHistory() async throws {
        let server = AdmissionFakeServer()
        let api = try await Self.makeClient(server: server)
        _ = try await api.queuePrompt(sessionID: "ses_1", text: "Pending", messageID: "msg_pending")
        await server.setPromotesAdmissions(true)
        _ = try await api.sendPromptAsync(sessionID: "ses_1", text: "Delivered", messageID: "msg_done")

        let pending = try await api.findPromptAdmission(sessionID: "ses_1", messageID: "msg_pending")
        let delivered = try await api.findPromptAdmission(sessionID: "ses_1", messageID: "msg_done")
        let missing = try await api.findPromptAdmission(sessionID: "ses_1", messageID: "msg_missing")

        #expect(pending == OCV2PromptAdmission(id: "msg_pending", sessionID: "ses_1", delivery: .queue))
        #expect(delivered?.id == "msg_done")
        #expect(missing == nil)
    }

    @Test func onlyFailuresAfterTheRequestMayHaveLeftAreAmbiguous() {
        let ambiguous: [Error] = [
            URLError(.timedOut),
            URLError(.networkConnectionLost),
            OpenCodeError.httpError(statusCode: 502),
            RemoteProtocolError.timeout,
            RemoteProtocolError.disconnected,
            // The gateway reports an upstream failure after forwarding.
            RemoteProtocolError.remoteError("request_failed"),
        ]
        let definitive: [Error] = [
            URLError(.notConnectedToInternet),
            URLError(.cannotConnectToHost),
            OpenCodeError.httpError(statusCode: 400),
            OpenCodeError.notConnected,
            RemoteProtocolError.invalidRequest,
            // The gateway refuses before forwarding when it is saturated.
            RemoteProtocolError.remoteError("too_many_requests"),
        ]

        #expect(ambiguous.allSatisfy(OpenCodeClient.requestMayHaveReachedServer))
        #expect(!definitive.contains(where: OpenCodeClient.requestMayHaveReachedServer))
    }

    // MARK: - Chat admission states

    @Test func anAdmittedPromptRetainsItsAdmissionIdentity() async throws {
        let server = AdmissionFakeServer()
        let chat = try await Self.openChat(server: server)

        chat.inputText = "Hello"
        chat.send()
        try await Self.waitUntil { chat.promptSubmissions.first?.state.isAccepted == true }

        let submission = try #require(chat.promptSubmissions.first)
        #expect(submission.state == .accepted(admissionID: submission.id))
        #expect(await server.admittedIDs == [submission.id])
        #expect(chat.messages.map(\.id) == [submission.id])
        #expect(chat.errorMessage == nil)
    }

    @Test func aLostResponseIsConfirmedFromTheInboxWithoutResending() async throws {
        let server = AdmissionFakeServer()
        let chat = try await Self.openChat(server: server)
        await server.loseNextResponses(1)

        chat.inputText = "Hello"
        chat.send()
        try await Self.waitUntil { chat.promptSubmissions.first?.state.isAccepted == true }

        #expect(await server.promptRequests.count == 1)
        #expect(chat.errorMessage == nil)
        #expect(chat.inputText.isEmpty)
        #expect(chat.isLoading)
    }

    @Test func aRetryAfterALostResponseCreatesNoSecondTaskOrVisiblePrompt() async throws {
        let server = AdmissionFakeServer()
        await server.setPromotesAdmissions(true)
        let chat = try await Self.openChat(server: server)
        await server.loseNextResponses(1)
        await server.setFailsReads(true)

        chat.inputText = "Hello"
        chat.send()
        try await Self.waitUntil { chat.promptSubmissions.first?.state == .uncertain }

        #expect(chat.errorMessage == AppText.promptAdmissionUncertain)
        #expect(chat.inputText == "Hello")
        #expect(!chat.isLoading)

        await server.setFailsReads(false)
        chat.send()
        try await Self.waitUntil { chat.promptSubmissions.first?.state.isAccepted == true }
        try await Self.waitUntil { await server.messageListReads > 0 }

        let ids = await server.promptRequests.map { $0.json["id"] as? String }
        let texts = await server.promptRequests.map { $0.json["text"] as? String }
        #expect(ids.count == 2 && Set(ids).count == 1)
        #expect(texts == ["Hello", "Hello"])
        #expect(await server.admittedIDs.count == 1)
        #expect(chat.promptSubmissions.count == 1)
        #expect(chat.messages.filter { $0.role == .user }.map(\.content) == ["Hello"])
    }

    @Test func aTranscriptThatConfirmsAnUncertainPromptWithdrawsTheRetry() async throws {
        let server = AdmissionFakeServer()
        await server.setPromotesAdmissions(true)
        let chat = try await Self.openChat(server: server)
        await server.loseNextResponses(1)
        await server.setFailsReads(true)

        chat.inputText = "Hello"
        chat.send()
        try await Self.waitUntil { chat.promptSubmissions.first?.state == .uncertain }

        await server.setFailsReads(false)
        _ = await chat.loadMessages()

        #expect(chat.promptSubmissions.first?.state.isAccepted == true)
        #expect(chat.inputText.isEmpty)
        #expect(chat.errorMessage == nil)
        #expect(chat.messages.filter { $0.role == .user }.map(\.content) == ["Hello"])
    }

    @Test func aPromptMissingFromTheServerStaysUncertainAndIsRetriedOnce() async throws {
        let server = AdmissionFakeServer()
        let chat = try await Self.openChat(server: server)
        await server.dropNextRequests(1)

        chat.inputText = "Hello"
        chat.send()
        try await Self.waitUntil { chat.promptSubmissions.first?.state == .uncertain }
        #expect(await server.inboxReads == 1)
        #expect(chat.errorMessage?.hasPrefix("Failed") == false)

        chat.send()
        try await Self.waitUntil { chat.promptSubmissions.first?.state.isAccepted == true }

        let ids = await server.promptRequests.compactMap { $0.json["id"] as? String }
        #expect(ids.count == 2 && Set(ids).count == 1)
        #expect(await server.admittedIDs == [ids[0]])
    }

    @Test func changingAnUncertainPromptCreatesANewAdmission() async throws {
        let server = AdmissionFakeServer()
        let chat = try await Self.openChat(server: server)
        await server.dropNextRequests(1)

        chat.inputText = "Hello"
        chat.send()
        try await Self.waitUntil { chat.promptSubmissions.first?.state == .uncertain }

        chat.inputText = "Hello, with more detail"
        chat.send()
        try await Self.waitUntil { chat.promptSubmissions.last?.state.isAccepted == true }

        let requests = await server.promptRequests.map(\.json)
        let ids = requests.compactMap { $0["id"] as? String }
        #expect(ids.count == 2 && ids[0] != ids[1])
        #expect(requests.last?["text"] as? String == "Hello, with more detail")
        #expect(chat.promptSubmissions.map(\.state) == [.uncertain, .accepted(admissionID: ids[1])])
    }

    @Test func aChangedPromptFirstConfirmsTheEarlierUncertainOne() async throws {
        let server = AdmissionFakeServer()
        let chat = try await Self.openChat(server: server)
        await server.loseNextResponses(1)
        await server.setFailsReads(true)

        chat.inputText = "Hello"
        chat.send()
        try await Self.waitUntil { chat.promptSubmissions.first?.state == .uncertain }
        await server.setFailsReads(false)
        await server.resetCounters()

        chat.inputText = "Something else"
        chat.send()
        try await Self.waitUntil { chat.promptSubmissions.last?.state.isAccepted == true }

        let paths = await server.requests.map(\.path)
        let firstInboxRead = try #require(paths.firstIndex(of: "/api/session/ses_1/inbox"))
        let newPrompt = try #require(paths.firstIndex(of: "/api/session/ses_1/prompt"))
        #expect(firstInboxRead < newPrompt)
        #expect(chat.promptSubmissions.allSatisfy { $0.state.isAccepted })
        #expect(await server.admittedIDs.count == 2)
    }

    @Test func eachUserRowReportsItsAdmissionState() async throws {
        let server = AdmissionFakeServer()
        let chat = try await Self.openChat(server: server)
        await server.rejectNextRequests(1)

        chat.inputText = "Hello"
        chat.send()
        let rowID = try #require(chat.messages.last?.id)
        #expect(chat.promptSubmissionState(forMessageID: rowID) == .sending)
        try await Self.waitUntil { chat.promptSubmissionState(forMessageID: rowID) == .failed }

        chat.send()
        try await Self.waitUntil { chat.promptSubmissions.last?.state.isAccepted == true }
        // The rejected row is replaced by the resent prompt, not duplicated.
        #expect(chat.messages.filter { $0.role == .user }.map(\.content) == ["Hello"])
        #expect(chat.promptSubmissionState(forMessageID: rowID) == nil)
    }

    @Test func aServerRejectionFailsWithoutReconcilingAndKeepsTheComposerText() async throws {
        let server = AdmissionFakeServer()
        let chat = try await Self.openChat(server: server)
        await server.rejectNextRequests(1)

        chat.inputText = "Hello"
        chat.send()
        try await Self.waitUntil { chat.promptSubmissions.first?.state == .failed }

        #expect(chat.errorMessage?.hasPrefix("Failed to send") == true)
        #expect(chat.inputText == "Hello")
        #expect(await server.inboxReads == 0)

        chat.send()
        try await Self.waitUntil { chat.promptSubmissions.last?.state.isAccepted == true }
        let ids = await server.promptRequests.compactMap { $0.json["id"] as? String }
        #expect(ids.count == 2 && ids[0] != ids[1])
    }

    @Test func aQueuedRetryAfterALostResponseKeepsOneQueuedEntry() async throws {
        let server = AdmissionFakeServer()
        let chat = try await Self.openChat(server: server)
        chat.isLoading = true
        chat.responseState = .generating
        await server.loseNextResponses(1)
        await server.setFailsReads(true)

        chat.inputText = "Later"
        chat.queuePrompt()
        try await Self.waitUntil { chat.promptSubmissions.first?.state == .uncertain }

        #expect(chat.queuedPrompts.isEmpty)
        #expect(chat.inputText == "Later")
        #expect(chat.errorMessage == AppText.promptAdmissionUncertain)

        await server.setFailsReads(false)
        chat.queuePrompt()
        try await Self.waitUntil { chat.promptSubmissions.first?.state.isAccepted == true }

        let ids = await server.promptRequests.compactMap { $0.json["id"] as? String }
        #expect(ids.count == 2 && Set(ids).count == 1)
        #expect(await server.inboxIDs == [ids[0]])
        // The fake reports an idle session on reload, so the entry may already
        // be promoted from the queue into the transcript; either way only once.
        let visibleIDs = chat.queuedPrompts.map(\.messageID)
            + chat.messages.filter { $0.role == .user }.map(\.id)
        #expect(visibleIDs == [ids[0]])
        #expect(chat.queuedPrompts.allSatisfy { $0.state == .queued })
    }

    // MARK: - Helpers

    private static func makeClient(server: AdmissionFakeServer) async throws -> OpenCodeClient {
        let api = OpenCodeClient(baseURL: URL(string: "https://example.com")!, transport: server)
        _ = try await api.probeCapabilities()
        return api
    }

    private static func openChat(server: AdmissionFakeServer) async throws -> ChatClient {
        let api = OpenCodeClient(baseURL: URL(string: "https://example.com")!, transport: server)
        let connection = ConnectionManager(testClient: api, capabilities: try await api.probeCapabilities())
        let chat = ChatClient(
            connection: connection, liveActivity: LiveActivityManager(),
            sessionsService: SessionsService(connection: connection), messagesService: MessagesService(connection: connection),
            providersService: ProvidersService(connection: connection), questionService: QuestionService(connection: connection),
            savedConnectionsStore: SavedConnectionsStore(initialConnections: []), recordedReplayStore: RecordedReplayStore()
        )
        await chat.loadSession(OCSession(id: "ses_1", title: "Session", time: .init(created: 0, updated: 0)))
        await server.resetCounters()
        return chat
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

/// Mirrors v2.0.23 inbox admission: the first admission of a caller ID wins,
/// and a retry returns the existing entry from the inbox or history.
private actor AdmissionFakeServer: OpenCodeTransport {
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
        let delivery: String
    }

    private var inbox: [Entry] = []
    private var history: [Entry] = []
    private var rawInbox: String?
    private var promotesAdmissions = false
    private var lostResponses = 0
    private var droppedRequests = 0
    private var rejectedRequests = 0
    private var failsReads = false
    private(set) var requests: [Request] = []
    private(set) var admittedIDs: [String] = []
    private(set) var inboxReads = 0
    private(set) var messageListReads = 0

    var promptRequests: [Request] { requests.filter { $0.path.hasSuffix("/prompt") } }
    var inboxIDs: [String] { inbox.map(\.id) }

    func setRawInbox(_ json: String) { rawInbox = json }
    func setPromotesAdmissions(_ promotes: Bool) { promotesAdmissions = promotes }
    func loseNextResponses(_ count: Int) { lostResponses = count }
    func dropNextRequests(_ count: Int) { droppedRequests = count }
    func rejectNextRequests(_ count: Int) { rejectedRequests = count }
    func setFailsReads(_ fails: Bool) { failsReads = fails }
    func resetCounters() {
        requests = []
        inboxReads = 0
        messageListReads = 0
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url!
        let method = request.httpMethod ?? "GET"
        let path = url.path
        let recorded = Request(method: method, path: path, body: request.httpBody ?? Data())
        requests.append(recorded)
        let components = path.split(separator: "/").map(String.init)

        func respond(_ status: Int, _ json: String = "") -> (Data, URLResponse) {
            (Data(json.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }

        if method == "POST", path == "/api/session/ses_1/prompt" {
            return try admit(recorded.json, respond: respond)
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
            return respond(200, #"{"data":{"id":"ses_1","title":"Session","time":{"created":0,"updated":0}}}"#)
        case "/api/session/ses_1/inbox":
            inboxReads += 1
            if failsReads { throw URLError(.networkConnectionLost) }
            return respond(200, #"{"data":\#(rawInbox ?? "[\(inbox.map(Self.inboxJSON).joined(separator: ","))]")}"#)
        case "/api/session/ses_1/message":
            messageListReads += 1
            if failsReads { throw URLError(.networkConnectionLost) }
            let messages = history.map(Self.messageJSON).joined(separator: ",")
            return respond(200, #"{"data":[\#(messages)],"cursor":{"next":null}}"#)
        case "/api/session/ses_1/permission", "/api/session/ses_1/form":
            return respond(200, #"{"data":[]}"#)
        default:
            break
        }

        if components.count == 5, components[3] == "message" {
            if failsReads { throw URLError(.networkConnectionLost) }
            guard let entry = history.first(where: { $0.id == components[4] }) else {
                return respond(404, #"{"_tag":"MessageNotFoundError","message":"Message not found"}"#)
            }
            return respond(200, #"{"data":\#(Self.messageJSON(entry))}"#)
        }
        return respond(404)
    }

    private func admit(
        _ body: [String: Any],
        respond: (Int, String) -> (Data, URLResponse)
    ) throws -> (Data, URLResponse) {
        if droppedRequests > 0 {
            droppedRequests -= 1
            throw URLError(.timedOut)
        }
        if rejectedRequests > 0 {
            rejectedRequests -= 1
            return respond(400, #"{"_tag":"InvalidRequestError","message":"Rejected"}"#)
        }

        let id = body["id"] as? String ?? "msg_server"
        let entry: Entry
        if let existing = (inbox + history).first(where: { $0.id == id }) {
            entry = existing
        } else {
            entry = Entry(id: id, text: body["text"] as? String ?? "", delivery: body["delivery"] as? String ?? "steer")
            admittedIDs.append(id)
            if promotesAdmissions {
                history.append(entry)
            } else {
                inbox.append(entry)
            }
        }

        if lostResponses > 0 {
            lostResponses -= 1
            throw URLError(.timedOut)
        }
        return respond(200, #"{"data":\#(Self.inboxJSON(entry))}"#)
    }

    private static func inboxJSON(_ entry: Entry) -> String {
        #"{"id":"\#(entry.id)","sessionID":"ses_1","time":{"created":1},"type":"user","payload":{"text":"\#(entry.text)"},"delivery":"\#(entry.delivery)"}"#
    }

    private static func messageJSON(_ entry: Entry) -> String {
        #"{"id":"\#(entry.id)","type":"user","time":{"created":1},"text":"\#(entry.text)"}"#
    }

    nonisolated func makeEventStream(
        request: URLRequest,
        deliveryQueue: DispatchQueue,
        callbacks: OpenCodeEventStreamCallbacks
    ) -> any OpenCodeEventStream {
        AdmissionUnusedStream()
    }
}

private final class AdmissionUnusedStream: OpenCodeEventStream, @unchecked Sendable {
    func start() {}
    func suspend() {}
    func resume() {}
    func cancel() {}
}
