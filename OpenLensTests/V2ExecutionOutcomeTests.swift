import Foundation
import Testing
@testable import OpenLens

@MainActor
struct V2ExecutionOutcomeTests {
    @Test(arguments: ["succeeded", "failed", "interrupted", "future-outcome"])
    func canonicalOutcomeAndIdleSurviveSessionRoundTrip(outcome: String) throws {
        let data = Data(#"{"id":"ses_1","outcome":"\#(outcome)","time":{"created":1000,"updated":2000,"idle":1900}}"#.utf8)
        let session = try JSONDecoder().decode(OCSession.self, from: data)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as! [String: Any]
        #expect(encoded["outcome"] as? String == outcome)
        #expect((encoded["time"] as? [String: Any])?["idle"] as? Double == 1900)
    }

    @Test(arguments: ["succeeded", "failed", "interrupted"])
    func foregroundRefreshRestoresTheCanonicalResult(outcome: String) async throws {
        let server = OutcomeTransport(outcome: outcome)
        let activity = OutcomeActivityProvider()
        let chat = try await makeChat(server, activity: activity)
        chat.beginExternalResponse()
        #expect(await chat.refreshCurrentSessionFromServer())
        #expect(chat.currentSession?.outcome == outcome)
        #expect(chat.currentSession?.time.idle == 1900)
        #expect(chat.executionState.rawValue == outcome)
        #expect(!chat.isLoading)
        let expectedPhase: OpenLensActivityAttributes.Phase = outcome == "succeeded" ? .finished : outcome == "failed" ? .failed : .stopped
        #expect(activity.phases == [expectedPhase])
    }

    @Test(arguments: ["missing-outcome", "missing-idle", "future-outcome"])
    func incompleteEvidenceNeverShowsSuccess(evidence: String) async throws {
        let server = OutcomeTransport(outcome: evidence == "missing-outcome" ? nil : evidence == "missing-idle" ? "succeeded" : evidence,
                                      idle: evidence == "missing-idle" ? nil : 1900)
        let chat = try await makeChat(server)
        #expect(await chat.refreshCurrentSessionFromServer())
        #expect(chat.executionState == .unknown)
    }

    @Test func activeExecutionAndCompletedStepsTakePrecedenceOverThePreviousResult() async throws {
        let server = OutcomeTransport(outcome: "succeeded", active: true)
        let chat = try await makeChat(server)
        #expect(await chat.refreshCurrentSessionFromServer())
        #expect(chat.executionState == .working)
        chat.pendingAssistantMessage = ChatMessage(id: "msg_1", role: .assistant, content: "First step", isStreaming: true)
        var adapter = V2EventAdapter()
        let event = try #require(try adapter.event(["type": "session.step.ended", "data": ["sessionID": "ses_1", "assistantMessageID": "msg_1", "finish": "stop"]], directory: nil))
        chat.receiveStreamEvent(try #require(SSEInboundEvent.prepare(event)))
        try await waitUntil { chat.messages.contains { $0.id == "msg_1" && !$0.isStreaming } }
        #expect(chat.isLoading)
        #expect(chat.executionState == .working)
        #expect(chat.currentSession?.outcome == "succeeded")
    }

    @Test(arguments: [OCExecutionState.waitingPermission, .waitingForm])
    func pendingInteractionsAreRecoveredIndependentlyOfThePreviousResult(state: OCExecutionState) async throws {
        let server = OutcomeTransport(outcome: "failed", active: true)
        let chat = try await makeChat(server)
        #expect(await chat.refreshCurrentSessionFromServer())
        await server.setPendingInteraction(state)
        chat.synchronizeCurrentSessionFromServer()
        try await waitUntil { chat.isStreamSynchronized }
        #expect(chat.executionState == state)
        #expect(chat.currentSession?.outcome == "failed")
        await server.setPendingInteraction(nil)
        chat.synchronizeCurrentSessionFromServer()
        try await waitUntil { chat.isStreamSynchronized }
        #expect(chat.executionState == .working)
    }

    @Test(arguments: ["succeeded", "failed", "interrupted"], [false, true])
    func streamEventsAndGapRecoveryRestoreTheResult(outcome: String, usesEvent: Bool) async throws {
        let server = OutcomeTransport(outcome: "succeeded", active: true)
        let chat = try await makeChat(server)
        #expect(await chat.refreshCurrentSessionFromServer())
        await server.complete(outcome: outcome, idle: 3000)
        if usesEvent {
            var adapter = V2EventAdapter()
            let event = try #require(try adapter.event(["type": "session.execution.\(outcome)", "data": ["sessionID": "ses_1"]], directory: nil))
            chat.receiveStreamEvent(.raw(event))
        } else {
            chat.synchronizeCurrentSessionFromServer()
        }
        try await waitUntil { chat.isStreamSynchronized }
        #expect(chat.executionState.rawValue == outcome)
        #expect(chat.currentSession?.time.idle == 3000)
        #expect(!chat.isLoading)
    }

    @Test func delayedRefreshCannotApplyThePreviousSessionsResult() async throws {
        let server = OutcomeTransport(outcome: "failed")
        let chat = try await makeChat(server)
        await server.holdSession()
        let refresh = Task { await chat.refreshCurrentSessionFromServer() }
        try await waitUntil { await server.isWaiting }
        chat.unloadSession(ifMatching: "ses_1")
        chat.currentSession = OCSession(id: "ses_2", title: "Other", time: .init(created: 0, updated: 0))
        await server.releaseSession()
        #expect(await refresh.value == false)
        #expect(chat.currentSession?.id == "ses_2")
        #expect(chat.currentSession?.outcome == nil)
        #expect(chat.executionState == .unknown)
    }

    @Test func aMissingActiveEntryFetchesTheOutcomeBeforeFinishing() async throws {
        let server = OutcomeTransport(outcome: "succeeded", active: true)
        let chat = try await makeChat(server)
        #expect(await chat.refreshCurrentSessionFromServer())
        await server.complete(outcome: "failed", idle: 3000)
        #expect(await chat.refreshCurrentSessionStatus())
        #expect(chat.executionState == .failed)
        #expect(chat.currentSession?.time.idle == 3000)
        #expect(!chat.isLoading)
    }

    @Test func aMissingActiveEntryWithTheOldIdleMarkerDoesNotReuseSuccess() async throws {
        let server = OutcomeTransport(outcome: "succeeded", active: true)
        let activity = OutcomeActivityProvider()
        let chat = try await makeChat(server, activity: activity)
        #expect(await chat.refreshCurrentSessionFromServer())
        await server.complete(outcome: "succeeded", idle: 1900)
        try await Task.sleep(for: .seconds(2))
        #expect(await chat.refreshCurrentSessionStatus())
        #expect(chat.executionState == .unknown)
        #expect(!chat.isLoading)
        #expect(!activity.phases.contains(.finished))
        #expect(activity.dismissCount == 1)
    }

    @Test func streamedSessionUpdatesPreserveOutcomesThroughLaterPartialUpdates() async throws {
        let server = OutcomeTransport(outcome: "succeeded")
        let chat = try await makeChat(server)
        #expect(await chat.refreshCurrentSessionFromServer())
        let canonical = OCEvent(type: "session.updated", properties: AnyCodable([
            "info": ["id": "ses_1", "outcome": "interrupted", "time": ["created": 1000, "updated": 3000, "idle": 2900]]
        ]))
        chat.receiveStreamEvent(try #require(SSEInboundEvent.prepare(canonical)))
        #expect(chat.executionState == .interrupted)
        var adapter = V2EventAdapter()
        let rename = try #require(try adapter.event(["type": "session.renamed", "data": ["sessionID": "ses_1", "title": "Renamed"]], directory: nil))
        chat.receiveStreamEvent(try #require(SSEInboundEvent.prepare(rename)))
        let model = try #require(try adapter.event(["type": "session.model.selected", "data": ["sessionID": "ses_1", "model": ["id": "new-model", "providerID": "provider"]]], directory: nil))
        chat.receiveStreamEvent(try #require(SSEInboundEvent.prepare(model)))
        #expect(chat.currentSession?.title == "Renamed")
        #expect(chat.currentSession?.model?.id == "new-model")
        #expect(chat.currentSession?.outcome == "interrupted")
        #expect(chat.currentSession?.time.idle == 2900)
    }

    @Test func aDelayedActiveSnapshotCannotStopTheNewSession() async throws {
        let server = OutcomeTransport(outcome: "failed")
        let chat = try await makeChat(server)
        await server.holdActive()
        let refresh = Task { await chat.refreshCurrentSessionStatus() }
        try await waitUntil { await server.isWaiting }
        chat.unloadSession(ifMatching: "ses_1")
        chat.currentSession = OCSession(id: "ses_2", title: "Other", time: .init(created: 0, updated: 0))
        chat.beginExternalResponse()
        await server.releaseActive()
        #expect(await refresh.value == false)
        #expect(chat.currentSession?.id == "ses_2")
        #expect(chat.currentSession?.outcome == nil)
        #expect(chat.isLoading)
        #expect(chat.executionState == .working)
    }

    @Test(arguments: [OCExecutionState.waitingPermission, .waitingForm], [false, true])
    func aServerAnsweredInteractionCannotKeepTheFailedRunsActivityAlive(state: OCExecutionState, usesPolling: Bool) async throws {
        let server = OutcomeTransport(outcome: "succeeded", active: true)
        let activity = OutcomeActivityProvider()
        let chat = try await makeChat(server, activity: activity)
        await server.setPendingInteraction(state)
        chat.synchronizeCurrentSessionFromServer()
        try await waitUntil { chat.isStreamSynchronized }
        #expect(chat.executionState == state)
        await server.setPendingInteraction(nil)
        await server.complete(outcome: "failed", idle: 3000)
        if usesPolling {
            #expect(await chat.refreshCurrentSessionStatus())
            #expect(activity.phases.last == .failed)
            #expect(await chat.recoverPendingPermission())
            #expect(await chat.recoverPendingForms())
        } else {
            chat.synchronizeCurrentSessionFromServer()
            try await waitUntil { chat.isStreamSynchronized }
        }
        #expect(chat.pendingPermission == nil)
        #expect(chat.pendingForm == nil)
        #expect(!chat.isLoading)
        #expect(chat.executionState == .failed)
        #expect(activity.phases == [.failed])
    }

    @Test(arguments: [#"{"outcome":17,"time":{"created":1000,"updated":2000,"idle":1900}}"#,
                      #"{"outcome":"succeeded","time":{"created":1000,"updated":2000,"idle":"invalid"}}"#,
                      #"{"outcome":{},"time":{"created":1000,"updated":2000,"idle":[]}}"#])
    func malformedAdvisoryOutcomeValuesDoNotHideSessions(fields: String) throws {
        let payload = #"[{"id":"ses_1","title":"Visible",\#(fields.dropFirst().dropLast())}]"#
        let sessions = try JSONDecoder().decode([OCSession].self, from: Data(payload.utf8))
        #expect(sessions.count == 1)
        #expect(sessions.first?.id == "ses_1")
        #expect(sessions.first?.executionOutcome == .unknown)
        #expect(sessions.first?.time.created == 1000)
        #expect(sessions.first?.time.updated == 2000)
    }

    private func makeChat(_ server: OutcomeTransport, activity: any LiveActivityProviding = TestLiveActivityProvider()) async throws -> ChatClient {
        let api = OpenCodeClient(baseURL: URL(string: "https://example.com")!, transport: server)
        let connection = ConnectionManager(testClient: api, capabilities: try await api.probeCapabilities())
        let chat = ChatClient(
            connection: connection, liveActivity: activity,
            sessionsService: SessionsService(connection: connection), messagesService: MessagesService(connection: connection),
            providersService: ProvidersService(connection: connection), questionService: QuestionService(connection: connection),
            savedConnectionsStore: SavedConnectionsStore(initialConnections: []), recordedReplayStore: RecordedReplayStore()
        )
        chat.currentSession = OCSession(id: "ses_1", title: "Outcome", time: .init(created: 0, updated: 0))
        return chat
    }

    private func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for recovery")
    }
}

private actor OutcomeTransport: OpenCodeTransport {
    var outcome: String?
    var idle: Double?
    var active: Bool
    var holdsSession = false
    var holdsActive = false
    var pendingInteraction: OCExecutionState?
    var waiter: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { waiter != nil }

    init(outcome: String?, idle: Double? = 1900, active: Bool = false) {
        self.outcome = outcome
        self.idle = idle
        self.active = active
    }
    func complete(outcome: String, idle: Double) { self.outcome = outcome; self.idle = idle; active = false }
    func setPendingInteraction(_ state: OCExecutionState?) { pendingInteraction = state }
    func holdActive() { holdsActive = true }
    func releaseActive() { holdsActive = false; waiter?.resume(); waiter = nil }
    func holdSession() { holdsSession = true }
    func releaseSession() { waiter?.resume(); waiter = nil }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url!
        let body: String
        switch url.path {
        case "/api/info": body = #"{"version":"2.0.23"}"#
        case "/api/session/ses_1":
            if holdsSession { await withCheckedContinuation { waiter = $0 } }
            var time: [String: Any] = ["created": 1000, "updated": 2000]
            time["idle"] = idle
            var session: [String: Any] = ["id": "ses_1", "title": "Outcome", "time": time]
            session["outcome"] = outcome
            body = String(decoding: try JSONSerialization.data(withJSONObject: ["data": session]), as: UTF8.self)
        case "/api/session/ses_1/message": body = #"{"data":[],"cursor":{"next":null}}"#
        case "/api/session/active":
            if holdsActive { await withCheckedContinuation { waiter = $0 } }
            body = active ? #"{"data":{"ses_1":{"type":"busy"}}}"# : #"{"data":{}}"#
        case "/api/session/ses_1/permission":
            body = pendingInteraction == .waitingPermission ? #"{"data":[{"id":"per_1","sessionID":"ses_1","action":"shell","resources":["pwd"]}]}"# : #"{"data":[]}"#
        case "/api/session/ses_1/form":
            body = pendingInteraction == .waitingForm ? #"{"data":[{"id":"form_1","sessionID":"ses_1","title":"Choose","fields":[{"key":"approved","type":"boolean","title":"Proceed?"}]}]}"# : #"{"data":[]}"#
        case "/api/session/ses_1/inbox": body = #"{"data":[]}"#
        default: throw URLError(.unsupportedURL)
        }
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    nonisolated func makeEventStream(request: URLRequest, deliveryQueue: DispatchQueue, callbacks: OpenCodeEventStreamCallbacks) -> any OpenCodeEventStream {
        OutcomeUnusedStream()
    }
}
private final class OutcomeUnusedStream: OpenCodeEventStream, @unchecked Sendable {
    func start() {}; func suspend() {}; func resume() {}; func cancel() {}
}

@MainActor
private final class OutcomeActivityProvider: LiveActivityProviding {
    var isActive: Bool { true }
    var phases: [OpenLensActivityAttributes.Phase] = []
    var dismissCount = 0
    func startActivity(sessionID: String?, directory: String?) {}
    func update(pendingUserResponse: OpenLensActivityAttributes.PendingUserResponse?) {}
    func endActivity(phase: OpenLensActivityAttributes.Phase) { phases.append(phase) }
    func dismissImmediately() { dismissCount += 1 }
    func previewLiveActivity() {}
}
