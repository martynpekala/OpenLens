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
            ),
            inaccessibleDirectories: ["/Users/me/Missing"]
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

    @Test func keepsRememberedFolderOutsideTheProjectListSelectable() {
        // Picked earlier in the folder browser. It is not a git root, so the
        // server never lists it as a project, yet it can still be opened.
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
            recentDirectories: ["/Users/me/Scratch"],
            preferredDirectory: "/Users/me/Scratch"
        )

        let selected = result.options.first { $0.id == result.defaultOptionID }
        #expect(selected?.directory == "/Users/me/Scratch")
        #expect(selected?.availability == .available)
        #expect(selected?.canCreateSession == true)
        #expect(selected?.isRecent == true)
        #expect(result.unavailablePreferredDirectory == nil)
    }

    @Test func flagsOnlyTheFoldersTheServerRefused() {
        let snapshot = WorkspaceSelectionSnapshot(
            currentProject: OCProject(id: "current", worktree: "/Users/me/OpenLens"),
            projects: [
                OCProject(id: "current", worktree: "/Users/me/OpenLens"),
            ],
            pathInfo: nil,
            inaccessibleDirectories: ["/Users/me/Gone/"]
        )

        let result = WorkspaceSelectionBuilder.makeOptions(
            snapshot: snapshot,
            recentDirectories: ["/Users/me/Scratch", "/Users/me/Gone"],
            preferredDirectory: "/Users/me/Scratch"
        )

        let scratch = result.options.first { $0.directory == "/Users/me/Scratch" }
        let gone = result.options.first { $0.directory == "/Users/me/Gone" }
        #expect(scratch?.canCreateSession == true)
        #expect(gone?.availability == .unavailable)
        #expect(gone?.canCreateSession == false)
        #expect(result.defaultOptionID == scratch?.id)
        #expect(result.unavailablePreferredDirectory == nil)
    }

    @Test func asksTheServerOnlyAboutRememberedFoldersItDidNotReport() {
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
                directory: "/Users/me/OpenLens/Sources"
            )
        )

        let unverified = WorkspaceSelectionBuilder.directoriesNeedingVerification(
            ["/Users/me/API", "/Users/me/OpenLens/Sources", "/Users/me/Scratch/", "/Users/me/Scratch", "  "],
            in: snapshot
        )

        #expect(unverified == ["/Users/me/Scratch"])
    }

    @Test func omitsTheServerRootPlaceholderButKeepsTheRealFolder() {
        // Outside a git repository the server reports its `global` project,
        // rooted at `/`, while the active folder is the one the user opened.
        let snapshot = WorkspaceSelectionSnapshot(
            currentProject: OCProject(id: "global", worktree: "/"),
            projects: [
                OCProject(id: "global", worktree: "/"),
                OCProject(id: "api", worktree: "/Users/me/API"),
            ],
            pathInfo: OCPathInfo(
                state: "ready",
                config: nil,
                worktree: "/",
                directory: "/Users/me/Scratch"
            )
        )

        let result = WorkspaceSelectionBuilder.makeOptions(
            snapshot: snapshot,
            recentDirectories: [],
            preferredDirectory: nil
        )

        #expect(result.options.compactMap(\.directory) == ["/Users/me/Scratch", "/Users/me/API"])
        #expect(result.options.first?.isCurrent == true)
        #expect(result.options.first?.title == "Scratch")
    }

    @Test func keepsThePreviousWorkspaceListedAfterSwitchingAway() {
        // Scratch was active, then the user switched to OpenLens. The server no
        // longer reports Scratch, but it was remembered and must stay selectable.
        let snapshot = WorkspaceSelectionSnapshot(
            currentProject: OCProject(id: "openlens", worktree: "/Users/me/OpenLens"),
            projects: [
                OCProject(id: "global", worktree: "/"),
                OCProject(id: "openlens", worktree: "/Users/me/OpenLens"),
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
            recentDirectories: ["/Users/me/OpenLens", "/Users/me/Scratch"],
            preferredDirectory: nil
        )

        #expect(result.options.compactMap(\.directory) == ["/Users/me/OpenLens", "/Users/me/Scratch"])
        #expect(result.options.map(\.isCurrent) == [true, false])
        #expect(result.options.allSatisfy { $0.canCreateSession })
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
