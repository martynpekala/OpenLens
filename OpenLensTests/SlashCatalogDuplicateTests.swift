import Foundation
import Testing
@testable import OpenLens

@MainActor
struct SlashCatalogDuplicateTests {
    @Test func duplicateTokensKeepFirstPerKind() {
        let items = [
            item(.command, "undo", title: "Built-in undo"),
            item(.command, "Undo", title: "Server undo"),
            item(.command, "review"),
            item(.command, "review"),
            item(.agent, "review"),
            item(.agent, "Plan"),
            item(.agent, "plan"),
        ]

        let unique = items.removingDuplicateTokens()

        #expect(unique.map(\.id) == ["command:undo", "command:review", "agent:review", "agent:Plan"])
        #expect(unique.first?.title == "Built-in undo")
    }

    /// Crash reports from 2.1 trapped in `Dictionary(uniqueKeysWithValues:)`
    /// when a server listed a repeated or case-variant command name.
    @Test func catalogAcceptsDuplicateNames() async throws {
        let transport = OpenCodeContractTransport(routes: [
            "/api/info": .init(statusCode: 404, body: Data(#"{"message":"not found"}"#.utf8)),
            "/global/health": .init(statusCode: 200, body: OpenCodeContractFixtures.v1HealthResponse),
        ])
        let api = OpenCodeClient(baseURL: URL(string: "http://example.com")!, transport: transport)
        let connection = ConnectionManager(testClient: api, capabilities: try await api.probeCapabilities())
        let chat = ChatClient(
            connection: connection, liveActivity: TestLiveActivityProvider(),
            sessionsService: SessionsService(connection: connection), messagesService: MessagesService(connection: connection),
            providersService: ProvidersService(connection: connection), questionService: QuestionService(connection: connection),
            savedConnectionsStore: SavedConnectionsStore(initialConnections: []), recordedReplayStore: RecordedReplayStore()
        )

        chat.updateSlashCatalog(commands: ["undo", "undo", "Review", "review"], agents: ["plan", "Plan"])
    }

    private func item(_ kind: WorkspaceSlashActionItem.Kind, _ token: String, title: String = "") -> WorkspaceSlashActionItem {
        WorkspaceSlashActionItem(kind: kind, token: token, title: title, description: "", prompt: "/\(token)")
    }
}
