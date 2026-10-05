import Foundation
import Testing
@testable import OpenLens

struct SessionsServiceTests {
    @Test func v1SessionStillDecodesItsTopLevelDirectory() throws {
        let session = try JSONDecoder().decode(
            OCSession.self,
            from: Data(#"{"id":"ses_legacy","projectID":"legacy","directory":"/workspace/Legacy","title":"Legacy","time":{"created":0,"updated":1}}"#.utf8)
        )

        #expect(session.directory == "/workspace/Legacy")
        #expect(session.projectID == "legacy")
    }

    @MainActor
    @Test func openingLocatedSessionsSwitchesContextInBothDirections() async throws {
        let sessions = try JSONDecoder().decode([OCSession].self, from: Data(#"[{"id":"ses_alpha","title":"Alpha","location":{"directory":"/workspace/Alpha"}},{"id":"ses_beta","title":"Beta","location":{"directory":"/workspace/Beta"}}]"#.utf8))
        let connection = ConnectionManager()
        let store = SavedConnectionsStore(initialConnections: [])
        let chat = ChatClient(
            connection: connection,
            liveActivity: LiveActivityManager(),
            sessionsService: SessionsService(connection: connection),
            messagesService: MessagesService(connection: connection),
            providersService: ProvidersService(connection: connection),
            questionService: QuestionService(connection: connection),
            savedConnectionsStore: store,
            recordedReplayStore: RecordedReplayStore()
        )

        for session in [sessions[0], sessions[1], sessions[0]] {
            await chat.loadSession(session)
            #expect(connection.selectedProjectDirectory == session.directory)
            #expect(chat.currentSession?.id == session.id)
        }

        await connection.setProjectContext(directory: "/workspace/Beta")
        await chat.restoreProjectContext(for: sessions[0])
        #expect(connection.selectedProjectDirectory == "/workspace/Alpha")
        #expect(chat.currentSession?.id == "ses_alpha")
    }

    @Test func sessionsResolveTheirProjectDirectoryWhenV2ProvidesOnlyProjectID() {
        let sessions = [
            OCSession(
                id: "ses_123",
                projectID: "proj_openlens",
                title: "",
                time: OCSessionTime(created: 0, updated: 0)
            )
        ]
        let projects = [
            OCProject(id: "proj_openlens", worktree: "/workspace/OpenLens")
        ]

        let resolved = SessionsService.applyingProjectDirectories(sessions, projects: projects)

        #expect(resolved[0].directory == "/workspace/OpenLens")
        #expect(resolved[0].workspaceDisplayName == "OpenLens")
    }

    @Test func sessionsKeepTheirOwnDirectoryWhenItIsAlreadyProvided() {
        let sessions = [
            OCSession(
                id: "ses_123",
                projectID: "proj_openlens",
                directory: "/workspace/FeatureBranch",
                title: "",
                time: OCSessionTime(created: 0, updated: 0)
            )
        ]
        let projects = [
            OCProject(id: "proj_openlens", worktree: "/workspace/OpenLens")
        ]

        let resolved = SessionsService.applyingProjectDirectories(sessions, projects: projects)

        #expect(resolved[0].directory == "/workspace/FeatureBranch")
        #expect(resolved[0].workspaceDisplayName == "FeatureBranch")
    }
}
