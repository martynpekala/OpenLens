import Foundation
import Testing
@testable import OpenLens

extension MultiServerSuite {
    @Suite struct ConnectionScoping {
        private static let serverA = SavedConnection(
            id: "server-a", serverURL: "http://a.example:4096", username: "u", password: "")
        private static let serverB = SavedConnection(
            id: "server-b", serverURL: "http://b.example:4096", username: "u", password: "")

        @Test func modelAndProjectWritesLandOnTheConnectionTheManagerBelievesItIsNotTheStoresActiveOne() async throws {
            // The store's global marker points at B; the manager is connected to A.
            let store = SavedConnectionsStore(initialConnections: [Self.serverA, Self.serverB])
            store.saveConnection(serverURL: Self.serverB.serverURL, username: "u", password: "")
            #expect(store.activeConnectionID == Self.serverB.id)

            let (chat, connection) = try await Self.makeChat(store: store, connectionID: Self.serverA.id)

            chat.selectModel(Self.model(provider: "anthropic", id: "claude-sonnet"))
            await connection.setProjectContext(directory: "/work/a")

            let a = try #require(store.connections.first { $0.id == Self.serverA.id })
            let b = try #require(store.connections.first { $0.id == Self.serverB.id })
            #expect(a.selectedProviderID == "anthropic")
            #expect(a.selectedModelID == "claude-sonnet")
            #expect(a.selectedProjectDirectory == "/work/a")
            #expect(b.selectedProviderID == nil)
            #expect(b.selectedModelID == nil)
            #expect(b.selectedProjectDirectory == nil)
        }

        @Test func modelWritesAreDroppedWhenTheManagerHasNoConnectionEvenIfTheStoreHasAnActiveOne() async throws {
            let store = SavedConnectionsStore(initialConnections: [Self.serverA, Self.serverB])
            store.saveConnection(serverURL: Self.serverB.serverURL, username: "u", password: "")

            let (chat, _) = try await Self.makeChat(store: store, connectionID: nil)
            chat.selectModel(Self.model(provider: "anthropic", id: "claude-sonnet"))

            #expect(store.connections.allSatisfy { $0.selectedModelID == nil })
        }

        @Test func connectionIDIsNilBeforeConnectingAndAfterDisconnect() async throws {
            let fresh = ConnectionManager()
            #expect(fresh.connectionID == nil)

            let (_, connection) = try await Self.makeChat(
                store: SavedConnectionsStore(initialConnections: [Self.serverA]), connectionID: Self.serverA.id)
            #expect(connection.connectionID == Self.serverA.id)

            connection.disconnect()
            #expect(connection.connectionID == nil)
        }

        @Test func reconnectPrefersTheLastActiveConnectionOverTheMostRecentOne() async throws {
            let defaults = try Self.makeDefaults()
            let seed = SavedConnectionsStore(initialConnections: [], userDefaults: defaults)
            let savedA = seed.saveConnection(serverURL: Self.serverA.serverURL, username: "u", password: "")
            seed.setLastActiveConnection(id: savedA.id)

            var a = savedA
            a.lastConnectedAt = Date(timeIntervalSince1970: 1_000)
            var b = Self.serverB
            b.lastConnectedAt = Date(timeIntervalSince1970: 2_000)
            let store = SavedConnectionsStore(initialConnections: [a, b], userDefaults: defaults)
            #expect(store.mostRecent?.id == b.id)
            #expect(store.lastActiveConnectionID == a.id)

            #expect(await Self.reconnectedURL(store: store) == "http://a.example:4096")
        }

        @Test func reconnectFallsBackToTheMostRecentConnectionWhenTheLastActiveOneNoLongerResolves() async throws {
            let defaults = try Self.makeDefaults()
            let seed = SavedConnectionsStore(initialConnections: [], userDefaults: defaults)
            let savedA = seed.saveConnection(serverURL: Self.serverA.serverURL, username: "u", password: "")
            seed.setLastActiveConnection(id: savedA.id)

            // A was forgotten since: the persisted id points at nothing.
            let store = SavedConnectionsStore(initialConnections: [Self.serverB], userDefaults: defaults)
            #expect(store.lastActiveConnectionID == nil)

            #expect(await Self.reconnectedURL(store: store) == "http://b.example:4096")
        }

        // MARK: - Helpers

        private static func makeChat(
            store: SavedConnectionsStore, connectionID: String?
        ) async throws -> (ChatClient, ConnectionManager) {
            let api = OpenCodeClient(baseURL: URL(string: "https://example.com")!, transport: ScopingFakeServer())
            let connection = ConnectionManager(
                testClient: api, capabilities: try await api.probeCapabilities(), connectionID: connectionID)
            connection.savedConnectionsStore = store
            let chat = ChatClient(
                connection: connection, liveActivity: TestLiveActivityProvider(),
                sessionsService: SessionsService(connection: connection), messagesService: MessagesService(connection: connection),
                providersService: ProvidersService(connection: connection), questionService: QuestionService(connection: connection),
                savedConnectionsStore: store, recordedReplayStore: RecordedReplayStore()
            )
            return (chat, connection)
        }

        /// Which server `reconnect()` aimed at: the probe sees the URL, then refuses, so nothing touches the network.
        private static func reconnectedURL(store: SavedConnectionsStore) async -> String? {
            let probe = ScopingProbe()
            let connection = ConnectionManager(localNetworkAccessProbe: probe)
            connection.savedConnectionsStore = store
            await connection.reconnect()
            return probe.urls.first?.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }

        private static func makeDefaults() throws -> UserDefaults {
            let name = "ConnectionScopingTests-\(UUID().uuidString)"
            return try #require(UserDefaults(suiteName: name))
        }

        private static func model(provider: String, id: String) -> ChatClient.SelectableModel {
            ChatClient.SelectableModel(
                providerID: provider, providerName: provider, modelID: id, modelName: id,
                reasoning: false, attachment: false, toolCall: true, cost: nil, limit: nil, variants: []
            )
        }
    }
}

// MARK: - Fake server

/// Serves only the capability probe; every other path is a 404.
nonisolated private final class ScopingFakeServer: OpenCodeTransport, @unchecked Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = try #require(request.url)
        let found = url.path == "/api/info"
        return (
            found ? Data(OpenCodeContractFixtures.v2InfoResponse) : Data(#"{"error":"RouteNotFound"}"#.utf8),
            HTTPURLResponse(url: url, statusCode: found ? 200 : 404, httpVersion: nil, headerFields: nil)!
        )
    }

    func makeEventStream(
        request: URLRequest, deliveryQueue: DispatchQueue, callbacks: OpenCodeEventStreamCallbacks
    ) -> any OpenCodeEventStream {
        ScopingEventStream()
    }
}

nonisolated private final class ScopingEventStream: OpenCodeEventStream, @unchecked Sendable {
    func start() {}
    func suspend() {}
    func resume() {}
    func cancel() {}
}

@MainActor
private final class ScopingProbe: LocalNetworkAccessProbing {
    private(set) var urls: [URL] = []

    func probe(_ url: URL) async -> LocalNetworkAccessProbeResult {
        urls.append(url)
        return .accessRequired
    }
}
