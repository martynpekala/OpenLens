import Foundation
import SwiftUI
import Testing
import UIKit
@testable import OpenLens

@MainActor
struct SessionOutcomeRefreshTests {
    @Test func sidebarSelectionOnlyRefreshesPreviousAndCurrentRows() async throws {
        let server = SessionOutcomeRefreshTransport()
        let api = OpenCodeClient(baseURL: URL(string: "https://example.com")!, transport: server)
        let connection = ConnectionManager(testClient: api, capabilities: try await api.probeCapabilities())
        let selection = SessionOutcomeSelection()
        let sessions = (1...24).map { listedSession("ses_\($0)") }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: SessionOutcomeSidebarHarness(
            selection: selection, sessions: sessions
        )
            .environment(\.connection, connection)
            .environment(\.sessionsService, SessionsService(connection: connection))
            .environment(\.scenePhase, .active))
        window.rootViewController = host
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        // The initial appearance may recover the entire inactive catalog.
        try await waitForStatusReads(2, server: server)
        #expect(Set(await server.sessionReads) == Set(sessions.map(\.id)))
        await server.resetSessionReads()

        selection.id = "ses_2"
        // Wait through another poll so extra reads from a restarted task are caught.
        let nextPoll = await server.statusReads + 2
        try await waitForStatusReads(nextPoll, server: server)
        let reads = await server.sessionReads
        #expect(Set(reads) == ["ses_1", "ses_2"])
        #expect(reads.count == 2)
    }

    private func waitForStatusReads(_ count: Int, server: SessionOutcomeRefreshTransport) async throws {
        for _ in 0..<500 {
            if await server.statusReads >= count {
                // Allow the canonical reads and snapshot application to finish.
                try await Task.sleep(for: .milliseconds(100))
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Timed out waiting for session status polling")
    }

    @Test func endedSessionsReplaceThePreviousRunsResult() async throws {
        let server = SessionOutcomeRefreshTransport()
        let service = try await makeService(server)
        let snapshot = await service.refreshSessionOutcomes(
            in: [listedSession("ses_1"), listedSession("ses_2")],
            previousStatuses: ["ses_1": busy]
        )
        #expect(snapshot.sessions[0].outcome == "failed")
        #expect(snapshot.sessions[0].time.idle == 3000)
        #expect(snapshot.sessions[1].outcome == "succeeded")
        #expect(snapshot.statuses.isEmpty)
        #expect(await server.sessionReads == ["ses_1"])
    }

    @Test func failedOutcomeReadsRemoveTheOldSuccessAndKeepTheRow() async throws {
        let server = SessionOutcomeRefreshTransport()
        await server.failSessions(["ses_1"])
        let service = try await makeService(server)
        let original = listedSession("ses_1")
        let snapshot = await service.refreshSessionOutcomes(in: [original], previousStatuses: ["ses_1": busy])
        #expect(snapshot.sessions.count == 1)
        #expect(snapshot.sessions[0].id == "ses_1")
        #expect(snapshot.sessions[0].title == original.title)
        #expect(snapshot.sessions[0].directory == original.directory)
        #expect(snapshot.sessions[0].outcome == nil)
        #expect(snapshot.sessions[0].executionOutcome == .unknown)
    }

    @Test func failedStatusReadsKeepTheLastActiveSnapshot() async throws {
        let server = SessionOutcomeRefreshTransport()
        await server.failStatus()
        let service = try await makeService(server)
        let snapshot = await service.refreshSessionOutcomes(in: [listedSession("ses_1")], previousStatuses: ["ses_1": busy])
        #expect(snapshot.statuses["ses_1"]?.type == .busy)
        #expect(await server.sessionReads.isEmpty)
    }

    @Test func openedAndPreviouslySelectedSessionsRefreshEvenIfTheirRunWasMissed() async throws {
        let server = SessionOutcomeRefreshTransport()
        let service = try await makeService(server)
        let snapshot = await service.refreshSessionOutcomes(
            in: [listedSession("ses_1"), listedSession("ses_2")], previousStatuses: [:],
            openedSessionIDs: ["ses_1", "ses_2"]
        )
        #expect(snapshot.sessions.map(\.outcome) == ["failed", "failed"])
        #expect(Set(await server.sessionReads) == ["ses_1", "ses_2"])
    }

    @Test func returningToTheListRestoresInactiveOutcomesWithoutReadingActiveSessions() async throws {
        let server = SessionOutcomeRefreshTransport()
        await server.setActive(["ses_2"])
        let service = try await makeService(server)
        let snapshot = await service.refreshSessionOutcomes(
            in: [listedSession("ses_1"), listedSession("ses_2")], previousStatuses: [:], refreshInactive: true
        )
        #expect(snapshot.sessions[0].outcome == "failed")
        #expect(snapshot.statuses["ses_2"]?.type == .busy)
        #expect(await server.sessionReads == ["ses_1"])
    }

    @Test func failedOutcomeRecoveryCanRetryAfterTheActiveEntryIsGone() async throws {
        let server = SessionOutcomeRefreshTransport()
        await server.failSessions(["ses_1"])
        let service = try await makeService(server)
        let failed = await service.refreshSessionOutcomes(in: [listedSession("ses_1")], previousStatuses: ["ses_1": busy])
        #expect(failed.failedOutcomeSessionIDs == ["ses_1"])
        await server.failSessions([])
        let recovered = await service.refreshSessionOutcomes(
            in: failed.sessions, previousStatuses: failed.statuses, openedSessionIDs: failed.failedOutcomeSessionIDs
        )
        #expect(recovered.sessions[0].outcome == "failed")
        #expect(recovered.sessions[0].time.idle == 3000)
        #expect(recovered.failedOutcomeSessionIDs.isEmpty)
    }

    @Test func legacyRefreshKeepsItsSessionRowsAndUsesOnlyTheLegacyStatusRoute() async throws {
        let server = SessionOutcomeRefreshTransport()
        await server.useV1()
        let service = try await makeService(server)
        let listed = listedSession("ses_1")
        let snapshot = await service.refreshSessionOutcomes(
            in: [listed], previousStatuses: ["ses_1": busy], openedSessionIDs: ["ses_1"], refreshInactive: true
        )
        #expect(snapshot.sessions == [listed])
        #expect(await server.sessionReads.isEmpty)
    }

    @Test func cancelledOutcomeReadsCannotReplaceThePreviousSnapshot() async throws {
        let server = SessionOutcomeRefreshTransport()
        await server.holdSession()
        let service = try await makeService(server)
        let listed = listedSession("ses_1")
        let refresh = Task { await service.refreshSessionOutcomes(in: [listed], previousStatuses: ["ses_1": busy]) }
        for _ in 0..<200 {
            if await server.isWaiting { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await server.isWaiting)
        refresh.cancel()
        await server.releaseSession()
        let snapshot = await refresh.value
        #expect(snapshot.sessions == [listed])
        #expect(snapshot.statuses["ses_1"]?.type == .busy)
    }

    private var busy: OCSessionStatus { .init(type: .busy, attempt: nil, message: nil, next: nil) }

    private func listedSession(_ id: String) -> OCSession {
        OCSession(id: id, directory: "/workspace", title: "Listed \(id)",
                  time: .init(created: 1000, updated: 2000, idle: 1900), outcome: "succeeded")
    }

    private func makeService(_ server: SessionOutcomeRefreshTransport) async throws -> SessionsService {
        let api = OpenCodeClient(baseURL: URL(string: "https://example.com")!, transport: server)
        let connection = ConnectionManager(testClient: api, capabilities: try await api.probeCapabilities())
        return SessionsService(connection: connection)
    }
}

private actor SessionOutcomeRefreshTransport: OpenCodeTransport {
    var activeIDs: Set<String> = []
    var failedSessionIDs: Set<String> = []
    var failsStatus = false
    var usesV2 = true
    var holdsSession = false
    var waiter: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { waiter != nil }
    var sessionReads: [String] = []
    var statusReads = 0
    func resetSessionReads() { sessionReads = [] }
    func setActive(_ ids: Set<String>) { activeIDs = ids }
    func failSessions(_ ids: Set<String>) { failedSessionIDs = ids }
    func failStatus() { failsStatus = true }
    func holdSession() { holdsSession = true }
    func releaseSession() { waiter?.resume(); waiter = nil }
    func useV1() { usesV2 = false }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url!
        let body: String
        var status = 200
        switch url.path {
        case "/api/info":
            body = #"{"version":"2.0.23"}"#
            if !usesV2 { status = 404 }
        case "/global/health": body = #"{"healthy":true,"version":"1.2.0"}"#
        case "/api/session/active", "/session/status":
            statusReads += 1
            if failsStatus { throw URLError(.networkConnectionLost) }
            let statuses = Dictionary(uniqueKeysWithValues: activeIDs.map { ($0, ["type": "busy"]) })
            let json = try JSONSerialization.data(withJSONObject: usesV2 ? ["data": statuses] : statuses)
            body = String(decoding: json, as: UTF8.self)
        default:
            guard url.path.hasPrefix("/api/session/") else { throw URLError(.unsupportedURL) }
            let id = url.lastPathComponent
            sessionReads.append(id)
            if holdsSession { await withCheckedContinuation { waiter = $0 } }
            if failedSessionIDs.contains(id) { throw URLError(.networkConnectionLost) }
            body = #"{"data":{"id":"\#(id)","title":"Fresh \#(id)","outcome":"failed","time":{"created":1000,"updated":3100,"idle":3000}}}"#
        }
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
    nonisolated func makeEventStream(request: URLRequest, deliveryQueue: DispatchQueue, callbacks: OpenCodeEventStreamCallbacks) -> any OpenCodeEventStream {
        SessionOutcomeUnusedStream()
    }
}

@MainActor @Observable
private final class SessionOutcomeSelection {
    var id: String? = "ses_1"
}

private struct SessionOutcomeSidebarHarness: View {
    let selection: SessionOutcomeSelection
    let sessions: [OCSession]

    var body: some View {
        SessionsListView(
            initialState: .loaded(sessions), presentationStyle: .sidebar,
            selectedSessionID: selection.id, onSelect: { selection.id = $0.id }
        )
    }
}
private final class SessionOutcomeUnusedStream: OpenCodeEventStream, @unchecked Sendable {
    func start() {}; func suspend() {}; func resume() {}; func cancel() {}
}
