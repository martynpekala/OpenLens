import Foundation
import Testing
@testable import OpenLens

struct SessionsServiceTests {
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
