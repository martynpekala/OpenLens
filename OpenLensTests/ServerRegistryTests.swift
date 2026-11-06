import Foundation
import Testing
@testable import OpenLens

extension MultiServerSuite {
    @Suite struct Registry {
        @Test func connectAllBringsTwoServersLiveInOneProcess() async throws {
            let fixture = Self.makeFixture(hosts: ["a.example", "b.example"])

            await fixture.registry.connectAll()

            try await Self.waitUntil {
                fixture.registry.contexts.allSatisfy { $0.connection.state == .connected }
            }
            #expect(fixture.registry.contexts.count == 2)
            #expect(fixture.registry.contexts.allSatisfy { $0.connection.isConnected })
        }

        @Test func eachContextRoutesOnlyToItsOwnServer() async throws {
            let fixture = Self.makeFixture(hosts: ["a.example", "b.example"])
            await fixture.registry.connectAll()
            try await Self.waitUntil {
                fixture.registry.contexts.allSatisfy { $0.connection.state == .connected }
            }
            let a = try #require(fixture.registry.context(id: "a.example"))
            let b = try #require(fixture.registry.context(id: "b.example"))
            fixture.servers["a.example"]?.reset()
            fixture.servers["b.example"]?.reset()

            _ = try? await a.messagesService.loadMessages(sessionID: "ses_only_a")
            _ = try? await b.messagesService.loadMessages(sessionID: "ses_only_b")

            let aKeys = try #require(fixture.servers["a.example"]).recordedKeys()
            let bKeys = try #require(fixture.servers["b.example"]).recordedKeys()
            #expect(aKeys.contains { $0.contains("ses_only_a") })
            #expect(bKeys.contains { $0.contains("ses_only_b") })
            #expect(!aKeys.contains { $0.contains("ses_only_b") })
            #expect(!bKeys.contains { $0.contains("ses_only_a") })
        }

        @Test func aConnectionPastTheCapIsRefusedAndItsProfileStaysSaved() async throws {
            let hosts = ["a.example", "b.example", "c.example", "d.example", "e.example"]
            let fixture = Self.makeFixture(hosts: hosts)
            await fixture.registry.connectAll()
            try await Self.waitUntil { fixture.registry.liveConnectionCount == 4 }
            // Recency decides who is connected: the least recently used profile is left idle.
            let idle = try #require(fixture.registry.context(id: "e.example"))
            #expect(idle.connection.state == .disconnected)
            let profile = try #require(fixture.store.connections.first { $0.id == "e.example" })

            await #expect(throws: ServerRegistry.ConnectionError.connectionLimitReached(
                maximum: ServerRegistry.maximumConcurrentConnections
            )) {
                try await fixture.registry.connect(profile: profile)
            }

            #expect(idle.connection.state == .disconnected)
            #expect(fixture.store.connections.count == 5)
            #expect(fixture.registry.liveConnectionCount == 4)
        }

        @Test func activatingAServerLeavesTheOthersConnected() async throws {
            let fixture = Self.makeFixture(hosts: ["a.example", "b.example", "c.example"])
            await fixture.registry.connectAll()
            try await Self.waitUntil { fixture.registry.liveConnectionCount == 3 }
            let before = fixture.registry.activeServerID

            let activated = fixture.registry.activate(id: "c.example")

            #expect(activated)
            #expect(fixture.registry.activeServerID == "c.example")
            #expect(fixture.registry.activeContext.id == "c.example")
            #expect(before != "c.example")
            #expect(fixture.registry.contexts.allSatisfy { $0.connection.state == .connected })
        }

        @Test func activatingAServerRecordsItAsTheLastActiveConnection() throws {
            let fixture = Self.makeFixture(hosts: ["a.example", "b.example"])
            #expect(fixture.store.lastActiveConnectionID == "a.example")

            fixture.registry.activate(id: "b.example")

            #expect(fixture.store.lastActiveConnectionID == "b.example")
        }

        @Test func connectingAnotherServerInTheBackgroundDoesNotChangeTheLastActiveConnection() async throws {
            let fixture = Self.makeFixture(hosts: ["a.example", "b.example"])
            fixture.registry.activate(id: "a.example")

            await fixture.registry.connectAll()
            try await Self.waitUntil { fixture.registry.liveConnectionCount == 2 }

            #expect(fixture.store.lastActiveConnectionID == "a.example")
        }

        @Test func removingAServerDisconnectsItAndLeavesTheOtherUntouched() async throws {
            let fixture = Self.makeFixture(hosts: ["a.example", "b.example"])
            await fixture.registry.connectAll()
            try await Self.waitUntil { fixture.registry.liveConnectionCount == 2 }
            let removed = try #require(fixture.registry.context(id: "a.example"))
            let kept = try #require(fixture.registry.context(id: "b.example"))

            fixture.registry.remove(id: "a.example")

            #expect(removed.connection.state == .disconnected)
            #expect(fixture.registry.contexts.map(\.id) == ["b.example"])
            #expect(fixture.store.connections.map(\.id) == ["b.example"])
            #expect(kept.connection.state == .connected)
            #expect(fixture.registry.activeContext.id == "b.example")
        }

        @Test func removingAServerTellsTheObserverWhichOneWentAway() {
            let fixture = Self.makeFixture(hosts: ["a.example", "b.example"])
            var removedIDs: [String] = []
            fixture.registry.onServerRemoved = { removedIDs.append($0) }

            fixture.registry.remove(id: "a.example")

            #expect(removedIDs == ["a.example"])
        }

        @Test func connectAllWithOneSavedProfileConnectsExactlyThatProfile() async throws {
            let fixture = Self.makeFixture(hosts: ["only.example"])

            await fixture.registry.connectAll()

            try await Self.waitUntil { fixture.registry.liveConnectionCount == 1 }
            #expect(fixture.registry.contexts.count == 1)
            #expect(fixture.registry.activeContext.id == "only.example")
            #expect(fixture.registry.activeContext.connection.state == .connected)
            #expect(fixture.servers["only.example"]?.recordedKeys().contains("/api/info") == true)
        }

        // MARK: - Helpers

        private struct Fixture {
            let registry: ServerRegistry
            let store: SavedConnectionsStore
            let servers: [String: RegistryFakeServer]
        }

        /// One saved profile per host, most recent first in `hosts` order, each with its own fake server.
        /// The profile id is the host so tests can name a context directly.
        private static func makeFixture(hosts: [String]) -> Fixture {
            let servers = Dictionary(uniqueKeysWithValues: hosts.map { ($0, RegistryFakeServer()) })
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
                makeTransport: { url in servers[url.host() ?? ""] ?? RegistryFakeServer() },
                localNetworkAccessProbe: RegistryProbe()
            )
            return Fixture(registry: registry, store: store, servers: servers)
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

@MainActor
private final class RegistryProbe: LocalNetworkAccessProbing {
    func probe(_ url: URL) async -> LocalNetworkAccessProbeResult { .continueConnection }
}

/// A whole OpenCode server: v2 `/api/info`, an SSE stream that opens at once, and a record of
/// every request path it was asked for. Anything else is a 404.
nonisolated private final class RegistryFakeServer: OpenCodeTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String] = []

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = try #require(request.url)
        lock.lock()
        keys.append(url.path)
        lock.unlock()

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
        RegistryFakeEventStream(request: request, deliveryQueue: deliveryQueue, callbacks: callbacks)
    }

    func recordedKeys() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return keys
    }

    func reset() {
        lock.lock()
        keys.removeAll()
        lock.unlock()
    }
}

/// Answers `200` and then stays open, which is all the SSE client needs to report connected.
nonisolated private final class RegistryFakeEventStream: OpenCodeEventStream, @unchecked Sendable {
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
