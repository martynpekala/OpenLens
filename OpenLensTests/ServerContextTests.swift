import Foundation
import Testing
@testable import OpenLens

extension MultiServerSuite {
    @Suite struct Context {
        @Test func everyServiceBuiltByAContextRoutesToThatContextsTransportAndNoOther() async throws {
            let a = try await Self.makeContext(id: "server-a", host: "a.example")
            let b = try await Self.makeContext(id: "server-b", host: "b.example")
            let calls: [(String, () async -> Void)] = [
                ("sessions", { _ = try? await a.context.sessionsService.listSessions() }),
                ("messages", { _ = try? await a.context.messagesService.loadMessages(sessionID: "ses_1") }),
                ("providers", { _ = try? await a.context.providersService.loadProviders() }),
                ("question", { _ = try? await a.context.questionService.recoverPendingForm(sessionID: "ses_1") }),
                ("review", { _ = try? await a.context.reviewService.loadReview(sessionID: "ses_1") }),
                ("inbox", { _ = try? await a.context.inboxService.loadInbox() }),
                ("workspace", { _ = try? await a.context.workspaceService.loadWorkspace() }),
            ]

            for (name, call) in calls {
                let before = a.transport.recordedPaths().count
                await call()
                #expect(a.transport.recordedPaths().count > before, "\(name) service did not reach its context's transport")
            }
            #expect(b.transport.recordedPaths().isEmpty)
        }

        @Test func aContextBuiltForAProfileCarriesThatProfilesIdentity() async throws {
            let (context, _) = try await Self.makeContext(id: "server-a", host: "a.example")

            #expect(context.connection.isConnected)
            // Both name the same server here because the context was built for a known profile.
            // The app's single context is built before any profile is known, so it carries a
            // placeholder id instead -- `connection.connectionID` is the authority on which
            // server is actually connected until the registry builds a context per profile.
            #expect(context.id == "server-a")
            #expect(context.connection.connectionID == "server-a")
        }

        @Test func aContextBuiltWithASuppliedChatClientUsesItInsteadOfBuildingANetworkedOne() async throws {
            let demoClient = ChatClient(demoMode: true)
            let context = ServerContext(
                id: "demo",
                connection: ConnectionManager(),
                liveActivity: TestLiveActivityProvider(),
                savedConnectionsStore: SavedConnectionsStore(initialConnections: []),
                recordedReplayStore: RecordedReplayStore(),
                chatClient: demoClient
            )

            #expect(context.chatClient === demoClient)
            #expect(context.chatClient.isDemoMode)
        }

        @Test func aContextWithoutASuppliedChatClientBuildsANetworkedOne() async throws {
            let (context, _) = try await Self.makeContext(id: "server-a", host: "a.example")

            #expect(!context.chatClient.isDemoMode)
        }

        private static func makeContext(
            id: String,
            host: String
        ) async throws -> (context: ServerContext, transport: RecordingTransport) {
            let transport = RecordingTransport()
            let client = OpenCodeClient(
                baseURL: try #require(URL(string: "https://\(host)")),
                transport: transport
            )
            let capabilities = try await client.probeCapabilities()
            transport.reset()
            let connection = ConnectionManager(testClient: client, capabilities: capabilities, connectionID: id)
            let context = ServerContext(
                id: id,
                connection: connection,
                liveActivity: TestLiveActivityProvider(),
                savedConnectionsStore: SavedConnectionsStore(initialConnections: []),
                recordedReplayStore: RecordedReplayStore()
            )
            return (context, transport)
        }
    }
}

// MARK: - Fake server

/// Serves `/api/info` so protocol selection picks v2, 404s everything else, and records every path.
nonisolated private final class RecordingTransport: OpenCodeTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []

    func recordedPaths() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return paths
    }

    func reset() {
        lock.lock()
        paths.removeAll()
        lock.unlock()
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = try #require(request.url)
        lock.lock()
        paths.append(url.path)
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
        UnusedEventStream()
    }
}

nonisolated private final class UnusedEventStream: OpenCodeEventStream, @unchecked Sendable {
    func start() {}
    func suspend() {}
    func resume() {}
    func cancel() {}
}
