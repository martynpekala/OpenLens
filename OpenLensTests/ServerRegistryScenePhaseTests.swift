import Foundation
import Testing
@testable import OpenLens

extension MultiServerSuite {
    @Suite struct ScenePhase {
        @Test func aServerThatIsNeverOnScreenStillBindsItsEventStreamWhenItConnects() async throws {
            let fixture = Self.makeFixture(hosts: ["a.example", "b.example"])

            await fixture.registry.connectAll()
            try await Self.waitUntil { fixture.registry.liveConnectionCount == 2 }

            let background = try #require(fixture.registry.context(id: "b.example"))
            #expect(fixture.registry.activeContext.id == "a.example")
            #expect(background.connection.sseClient?.onInboundEvent != nil)
        }

        @Test func suspendingEveryServerKeepsThemConnectedAndKeepsTheSharedCredentials() async throws {
            let fixture = Self.makeFixture(hosts: ["a.example", "b.example"])
            await fixture.registry.connectAll()
            try await Self.waitUntil { fixture.registry.liveConnectionCount == 2 }
            let activeBefore = fixture.store.activeConnectionID

            fixture.registry.suspendAll()

            #expect(fixture.registry.contexts.allSatisfy { $0.connection.state == .connected })
            #expect(fixture.store.activeConnectionID == activeBefore)
            #expect(activeBefore != nil)
            #expect(SharedConnectionStore.credentials(for: "a.example") != nil)
            #expect(SharedConnectionStore.credentials(for: "b.example") != nil)
        }

        @Test func resumingVisitsTheActiveServerFirstThenTheRestInDisplayOrder() async throws {
            let recorder = ResumeRecorder()
            let fixture = Self.makeFixture(hosts: ["a.example", "b.example", "c.example"], recorder: recorder)
            await fixture.registry.connectAll()
            try await Self.waitUntil { fixture.registry.liveConnectionCount == 3 }
            fixture.registry.activate(id: "b.example")
            recorder.observe = {
                Set(fixture.registry.contexts.filter { $0.connection.sseClient?.onInboundEvent != nil }.map(\.id))
            }
            // A resume re-binds the stream, so clearing the binding shows who has been resumed.
            for context in fixture.registry.contexts { context.connection.sseClient?.onInboundEvent = nil }

            await fixture.registry.resumeAll()

            #expect(recorder.resumedBeforeEachPause == [["b.example"], ["b.example", "a.example"]])
            #expect(fixture.registry.contexts.allSatisfy { $0.connection.sseClient?.onInboundEvent != nil })
        }

        @Test func resumingPausesOneStaggerBetweenServersAndNeverBeforeTheFirst() async throws {
            let recorder = ResumeRecorder()
            let fixture = Self.makeFixture(hosts: ["a.example", "b.example", "c.example"], recorder: recorder)
            await fixture.registry.connectAll()
            try await Self.waitUntil { fixture.registry.liveConnectionCount == 3 }

            await fixture.registry.resumeAll()

            #expect(recorder.pauses == [.milliseconds(250), .milliseconds(250)])
        }

        @Test func resumingASecondTimeWhileRecoveryIsRunningDoesNotStartAnotherRecovery() async throws {
            let fixture = Self.makeFixture(hosts: ["a.example"])
            await fixture.registry.connectAll()
            try await Self.waitUntil { fixture.registry.liveConnectionCount == 1 }
            let context = fixture.registry.activeContext
            context.chatClient.currentSession = OCSession(
                id: "ses_resume", title: "Resume", time: OCSessionTime(created: 0, updated: 0)
            )

            context.resume()
            context.resume()

            #expect(context.isRecovering)
            try await Self.waitUntil { !context.isRecovering }
            #expect(context.connection.state == .connected)
            #expect(context.connection.sseClient?.onInboundEvent != nil)
        }

        @Test func resumingAServerWithNoOpenSessionOnlyRebindsItsStream() async throws {
            let fixture = Self.makeFixture(hosts: ["a.example"])
            await fixture.registry.connectAll()
            try await Self.waitUntil { fixture.registry.liveConnectionCount == 1 }
            let context = fixture.registry.activeContext
            context.connection.sseClient?.onInboundEvent = nil

            context.resume()

            #expect(!context.isRecovering)
            #expect(context.connection.sseClient?.onInboundEvent != nil)
        }

        @Test func withOneServerTheResumeOrderIsJustThatServerAndNothingPauses() async throws {
            let recorder = ResumeRecorder()
            let fixture = Self.makeFixture(hosts: ["only.example"], recorder: recorder)
            await fixture.registry.connectAll()
            try await Self.waitUntil { fixture.registry.liveConnectionCount == 1 }

            let order = resumeOrder(contexts: fixture.registry.contexts, activeID: fixture.registry.activeServerID)
            await fixture.registry.resumeAll()

            #expect(order.map(\.id) == ["only.example"])
            #expect(recorder.pauses.isEmpty)
        }

        @Test func resumeOrderFallsBackToDisplayOrderWhenNoServerIsActive() async throws {
            let fixture = Self.makeFixture(hosts: ["a.example", "b.example"])

            let order = resumeOrder(contexts: fixture.registry.contexts, activeID: nil)

            #expect(order.map(\.id) == ["a.example", "b.example"])
        }

        @Test func resumingSkipsServersThatAreNotConnected() async throws {
            let recorder = ResumeRecorder()
            let fixture = Self.makeFixture(hosts: ["a.example", "b.example"], recorder: recorder)
            // Nothing connected: no context is live, so there is nothing to resume or pause for.

            await fixture.registry.resumeAll()

            #expect(recorder.pauses.isEmpty)
        }

        @Test func aServerThatIsNotActiveIgnoresAPermissionPromptWhenItHasNoSessionOpen() async throws {
            let fixture = Self.makeFixture(hosts: ["a.example", "b.example"])
            await fixture.registry.connectAll()
            try await Self.waitUntil { fixture.registry.liveConnectionCount == 2 }
            let active = fixture.registry.activeContext
            let background = try #require(fixture.registry.context(id: "b.example"))
            let prompt = try #require(SSEInboundEvent.prepare(OCEvent(
                type: "permission.v2.asked",
                properties: AnyCodable([
                    "id": "per_other",
                    "sessionID": "session-elsewhere",
                    "action": "mcp.github.list_issues",
                    "resources": ["github:list_issues"]
                ])
            )))
            guard case .cold(.permissionAsked, _) = prompt else {
                Issue.record("The fixture must prepare to a cold permission event")
                return
            }

            background.chatClient.receiveStreamEvent(prompt)
            active.chatClient.receiveStreamEvent(prompt)

            #expect(background.chatClient.pendingPermission == nil)
            #expect(!background.chatClient.showPermissionAlert)
            // The active server keeps raising a prompt that arrives before its session has loaded.
            #expect(active.chatClient.pendingPermission?.id == "per_other")
        }

        // MARK: - Helpers

        private struct Fixture {
            let registry: ServerRegistry
            let store: SavedConnectionsStore
        }

        @MainActor
        private static func makeFixture(hosts: [String], recorder suppliedRecorder: ResumeRecorder? = nil) -> Fixture {
            let recorder = suppliedRecorder ?? ResumeRecorder()
            let servers = Dictionary(uniqueKeysWithValues: hosts.map { ($0, SceneFakeServer()) })
            let profiles = hosts.enumerated().map { index, host in
                SavedConnection(
                    id: host,
                    serverURL: "http://\(host)",
                    username: "opencode",
                    password: "pw",
                    lastConnectedAt: Date(timeIntervalSince1970: 1_000_000 - Double(index) * 100)
                )
            }
            let store = SavedConnectionsStore(initialConnections: profiles)
            let registry = ServerRegistry(
                savedConnectionsStore: store,
                liveActivity: TestLiveActivityProvider(),
                recordedReplayStore: RecordedReplayStore(),
                makeTransport: { url in servers[url.host() ?? ""] ?? SceneFakeServer() },
                localNetworkAccessProbe: SceneProbe(),
                sleep: { duration in await recorder.pause(duration) }
            )
            return Fixture(registry: registry, store: store)
        }

        private static func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
            for _ in 0..<300 {
                if await condition() { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            Issue.record("Timed out waiting for condition")
        }
    }
}

// MARK: - Fake server

/// Stands in for the registry's sleep: records each pause, and what had been resumed when it
/// began, without ever waiting.
@MainActor
private final class ResumeRecorder: @unchecked Sendable {
    var observe: () -> Set<String> = { [] }
    private(set) var pauses: [Duration] = []
    private(set) var resumedBeforeEachPause: [Set<String>] = []

    nonisolated func pause(_ duration: Duration) async {
        await record(duration)
    }

    private func record(_ duration: Duration) {
        pauses.append(duration)
        resumedBeforeEachPause.append(observe())
    }
}

@MainActor
private final class SceneProbe: LocalNetworkAccessProbing {
    func probe(_ url: URL) async -> LocalNetworkAccessProbeResult { .continueConnection }
}

nonisolated private final class SceneFakeServer: OpenCodeTransport, @unchecked Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = try #require(request.url)
        let isInfo = url.path == "/api/info"
        let body = isInfo ? OpenCodeContractFixtures.v2InfoResponse : Data(#"{"error":"RouteNotFound"}"#.utf8)
        return (
            body,
            HTTPURLResponse(url: url, statusCode: isInfo ? 200 : 404, httpVersion: nil, headerFields: nil)!
        )
    }

    func makeEventStream(
        request: URLRequest,
        deliveryQueue: DispatchQueue,
        callbacks: OpenCodeEventStreamCallbacks
    ) -> any OpenCodeEventStream {
        SceneFakeEventStream(request: request, deliveryQueue: deliveryQueue, callbacks: callbacks)
    }
}

nonisolated private final class SceneFakeEventStream: OpenCodeEventStream, @unchecked Sendable {
    private let request: URLRequest
    private let deliveryQueue: DispatchQueue
    private let callbacks: OpenCodeEventStreamCallbacks

    init(request: URLRequest, deliveryQueue: DispatchQueue, callbacks: OpenCodeEventStreamCallbacks) {
        self.request = request
        self.deliveryQueue = deliveryQueue
        self.callbacks = callbacks
    }

    func start() {
        deliveryQueue.async { [request, callbacks] in
            let url = request.url ?? URL(string: "http://localhost")!
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            _ = callbacks.onResponse(response)
        }
    }

    func suspend() {}
    func resume() {}
    func cancel() {}
}
