import Foundation
import Testing
@testable import OpenLens

@MainActor
struct V2ReconciliationTests {
    @Test(arguments: ["/api/session/active", "/api/session/ses_1/permission", "/api/session/ses_1/form"])
    func recoveryFailureRemainsUnsynchronizedUntilSuccessfulRetry(failingPath: String) async throws {
        let transport = ReconciliationTransport(failingPath: failingPath)
        let api = OpenCodeClient(baseURL: URL(string: "https://example.com")!, transport: transport)
        let capabilities = try await api.probeCapabilities()
        let connection = ConnectionManager(testClient: api, capabilities: capabilities)
        let chat = ChatClient(
            connection: connection, liveActivity: LiveActivityManager(),
            sessionsService: SessionsService(connection: connection), messagesService: MessagesService(connection: connection),
            providersService: ProvidersService(connection: connection), questionService: QuestionService(connection: connection),
            savedConnectionsStore: SavedConnectionsStore(initialConnections: []), recordedReplayStore: RecordedReplayStore()
        )
        chat.currentSession = OCSession(id: "ses_1", title: "Recover", time: .init(created: 0, updated: 0))
        chat.synchronizeCurrentSessionFromServer()
        try await Task.sleep(for: .milliseconds(150))
        #expect(!chat.isStreamSynchronized)
        await transport.allowRecovery()
        chat.synchronizeCurrentSessionFromServer()
        for _ in 0..<50 where !chat.isStreamSynchronized { try await Task.sleep(for: .milliseconds(10)) }
        #expect(chat.isStreamSynchronized)
        #expect(chat.errorMessage == nil)
    }
    @Test func switchingSessionsRejectsAnInFlightPermissionRecovery() async throws {
        let transport = ReconciliationTransport(failingPath: "")
        await transport.holdPermission()
        let api = OpenCodeClient(baseURL: URL(string: "https://example.com")!, transport: transport)
        let connection = ConnectionManager(testClient: api, capabilities: try await api.probeCapabilities())
        let chat = ChatClient(
            connection: connection, liveActivity: LiveActivityManager(),
            sessionsService: SessionsService(connection: connection), messagesService: MessagesService(connection: connection),
            providersService: ProvidersService(connection: connection), questionService: QuestionService(connection: connection),
            savedConnectionsStore: SavedConnectionsStore(initialConnections: []), recordedReplayStore: RecordedReplayStore()
        )
        chat.currentSession = OCSession(id: "ses_1", title: "Old", time: .init(created: 0, updated: 0))
        let recovery = Task { await chat.recoverPendingPermission() }
        for _ in 0..<50 {
            if await transport.isWaiting { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await transport.isWaiting)
        chat.currentSession = OCSession(id: "ses_2", title: "New", time: .init(created: 0, updated: 0))
        await transport.releasePermission()
        #expect(await recovery.value == false)
        #expect(chat.pendingPermission == nil)
        #expect(!chat.showPermissionAlert)
    }

}

private actor ReconciliationTransport: OpenCodeTransport {
    var failingPath: String?
    var delaysPermission = false
    var waiter: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { waiter != nil }
    func holdPermission() { delaysPermission = true }
    func releasePermission() { waiter?.resume(); waiter = nil }

    init(failingPath: String) { self.failingPath = failingPath }
    func allowRecovery() { failingPath = nil }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url!
        let path = url.path
        if path == failingPath { throw URLError(.networkConnectionLost) }
        if path.hasSuffix("/permission"), delaysPermission {
            await withCheckedContinuation { waiter = $0 }
            let body = Data(#"{"data":[{"id":"per_1","sessionID":"ses_1","action":"shell","resources":["pwd"]}]}"#.utf8)
            return (body, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let body: String
        switch path {
        case "/api/info": body = #"{"version":"2.0.16"}"#
        case "/api/session/ses_1": body = #"{"data":{"id":"ses_1","title":"Recover","location":{"directory":"/workspace"},"time":{"created":0,"updated":0}}}"#
        case "/api/session/ses_1/message": body = #"{"data":[],"cursor":{"next":null}}"#
        case "/api/session/active": body = #"{"data":{}}"#
        case "/api/session/ses_1/permission", "/api/session/ses_1/form": body = #"{"data":[]}"#
        default: throw URLError(.unsupportedURL)
        }
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    nonisolated func makeEventStream(request: URLRequest, deliveryQueue: DispatchQueue, callbacks: OpenCodeEventStreamCallbacks) -> any OpenCodeEventStream {
        ReconciliationUnusedStream()
    }
}
private final class ReconciliationUnusedStream: OpenCodeEventStream, @unchecked Sendable {
    func start() {} ; func suspend() {} ; func resume() {} ; func cancel() {}
}
