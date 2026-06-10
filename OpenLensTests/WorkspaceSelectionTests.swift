import Testing
@testable import OpenLens

struct WorkspaceSelectionTests {

    @Test func prefersSavedWorkspaceWhenItIsAvailable() {
        let snapshot = WorkspaceSelectionSnapshot(
            currentProject: OCProject(id: "current", worktree: "/Users/me/OpenLens"),
            projects: [
                OCProject(id: "current", worktree: "/Users/me/OpenLens"),
                OCProject(id: "api", worktree: "/Users/me/API"),
            ],
            pathInfo: OCPathInfo(
                state: "ready",
                config: nil,
                worktree: "/Users/me/OpenLens",
                directory: "/Users/me/OpenLens"
            )
        )

        let result = WorkspaceSelectionBuilder.makeOptions(
            snapshot: snapshot,
            recentDirectories: ["/Users/me/API"],
            preferredDirectory: "/Users/me/API"
        )

        let selected = result.options.first { $0.id == result.defaultOptionID }
        #expect(selected?.directory == "/Users/me/API")
        #expect(selected?.availability == .available)
        #expect(selected?.isRecent == true)
        #expect(result.unavailablePreferredDirectory == nil)
    }

    @Test func fallsBackWhenPreferredWorkspaceIsUnavailable() {
        let snapshot = WorkspaceSelectionSnapshot(
            currentProject: OCProject(id: "current", worktree: "/Users/me/OpenLens"),
            projects: [
                OCProject(id: "current", worktree: "/Users/me/OpenLens"),
            ],
            pathInfo: OCPathInfo(
                state: "ready",
                config: nil,
                worktree: "/Users/me/OpenLens",
                directory: "/Users/me/OpenLens"
            )
        )

        let result = WorkspaceSelectionBuilder.makeOptions(
            snapshot: snapshot,
            recentDirectories: ["/Users/me/Missing"],
            preferredDirectory: "/Users/me/Missing"
        )

        let selected = result.options.first { $0.id == result.defaultOptionID }
        #expect(result.options.contains { $0.directory == "/Users/me/Missing" && $0.availability == .unavailable })
        #expect(selected?.directory == "/Users/me/OpenLens")
        #expect(selected?.availability == .available)
        #expect(result.unavailablePreferredDirectory == "/Users/me/Missing")
    }

    @Test func offersServerDefaultWhenNoWorkspaceIsReported() {
        let snapshot = WorkspaceSelectionSnapshot(
            currentProject: nil,
            projects: [],
            pathInfo: nil
        )

        let result = WorkspaceSelectionBuilder.makeOptions(
            snapshot: snapshot,
            recentDirectories: [],
            preferredDirectory: nil
        )

        let selected = result.options.first { $0.id == result.defaultOptionID }
        #expect(result.options.count == 1)
        #expect(selected?.availability == .serverDefault)
        #expect(selected?.directory == nil)
    }
}
