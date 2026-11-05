import Foundation
import Testing
@testable import OpenLens

extension MultiServerSuite {
    @Suite struct WorkspaceFilter {
        private typealias Fixture = MultiServerSuite.Aggregation

        private static let results = [
            ServerSessionsResult(serverID: "a", sessions: [
                Fixture.session("a-app-1", directory: "/work/app", hoursAgo: 1),
                Fixture.session("a-app-2", directory: "/work/app", hoursAgo: 2),
                Fixture.session("a-site", directory: "/work/site", hoursAgo: 3)
            ]),
            ServerSessionsResult(serverID: "b", sessions: [
                Fixture.session("b-app", directory: "/work/app", hoursAgo: 4),
                Fixture.session("b-docs", directory: "/work/docs", hoursAgo: 5)
            ])
        ]

        private static func aggregate(
            serverIDs: Set<String> = ["a", "b"],
            workspaceID: String? = nil
        ) -> SessionAggregation {
            SessionGrouping.aggregate(
                results: results.filter { serverIDs.contains($0.serverID) },
                tags: Fixture.tags,
                showsServerTags: true,
                workspaceFilterID: workspaceID,
                now: Fixture.now,
                calendar: Fixture.calendar,
                customName: { _ in nil }
            )
        }

        private static func options(serverIDs: Set<String> = ["a", "b"]) -> [SessionWorkspaceOption] {
            SessionGrouping.workspaceOptions(in: aggregate(serverIDs: serverIDs).entries)
        }

        @Test func workspaceOptionsComeOnlyFromTheServersInView() {
            #expect(Self.options(serverIDs: ["b"]).map(\.id) == ["b|directory:/work/app", "b|directory:/work/docs"])
            #expect(Self.options(serverIDs: ["a"]).map(\.label.workspace) == ["app", "site"])
        }

        @Test func theSameFolderOnTwoServersIsTwoWorkspaceOptionsWhenBothServersAreInView() {
            let options = Self.options()

            #expect(options.map(\.label.text) == ["Laptop · app", "10.0.0.2:4096 · app", "10.0.0.2:4096 · docs", "Laptop · site"])
        }

        @Test func aWorkspaceSelectionOutsideTheOptionsResetsToAll() {
            let options = Self.options(serverIDs: ["b"])

            #expect(SessionGrouping.resolvedWorkspaceFilter("a|directory:/work/site", options: options) == nil)
            #expect(SessionGrouping.resolvedWorkspaceFilter("b|directory:/work/docs", options: options) == "b|directory:/work/docs")
            #expect(SessionGrouping.resolvedWorkspaceFilter(nil, options: options) == nil)
        }

        @Test func filteringByWorkspaceKeepsTheSectionCountsOfWhatIsShown() {
            let aggregation = Self.aggregate(workspaceID: "a|directory:/work/app")

            #expect(aggregation.sections.map(\.kind) == [.today])
            #expect(aggregation.sections.map(\.entries.count) == [2])
            #expect(aggregation.entries.map(\.session.id) == ["a-app-1", "a-app-2"])
        }

        @Test func filteringByServerAndWorkspaceTogetherShowsOnlyThatServersWorkspace() {
            let both = Self.aggregate(serverIDs: ["b"], workspaceID: "b|directory:/work/app")
            let otherServersWorkspace = Self.aggregate(serverIDs: ["b"], workspaceID: "a|directory:/work/app")

            #expect(both.entries.map(\.session.id) == ["b-app"])
            #expect(otherServersWorkspace.entries.isEmpty)
        }

        @Test func noWorkspaceFilterLeavesTheListAsItWas() {
            #expect(Self.aggregate().entries.count == 5)
        }

        @Test func theCapsuleTitleComposesWhatIsActive() {
            let laptop = Fixture.tags["a"]

            #expect(sessionFilterTitle(server: nil, workspace: nil, hasSeveralServers: true) == "All servers")
            #expect(sessionFilterTitle(server: laptop, workspace: nil, hasSeveralServers: true) == "Laptop")
            #expect(sessionFilterTitle(server: nil, workspace: "app", hasSeveralServers: true) == "app")
            #expect(sessionFilterTitle(server: laptop, workspace: "app", hasSeveralServers: true) == "Laptop · app")
        }

        @Test func aSingleServerWithNothingChosenOffersWorkspacesNotServers() {
            #expect(sessionFilterTitle(server: nil, workspace: nil, hasSeveralServers: false) == "All workspaces")
            #expect(sessionFilterTitle(server: nil, workspace: "app", hasSeveralServers: false) == "app")
        }

        @Test func oneServerWithOneWorkspaceIsNotInteractiveButTwoWorkspacesAre() {
            #expect(!sessionFilterIsInteractive(serverCount: 1, workspaceCount: 1))
            #expect(!sessionFilterIsInteractive(serverCount: 0, workspaceCount: 0))
            #expect(sessionFilterIsInteractive(serverCount: 1, workspaceCount: 2))
            #expect(sessionFilterIsInteractive(serverCount: 2, workspaceCount: 1))
        }

        // MARK: - Filter popover counts

        private static func counts(
            unavailable: Set<String> = [],
            serverID: String? = nil,
            workspaceID: String? = nil
        ) -> SessionFilterCounts {
            SessionGrouping.filterCounts(
                entries: aggregate().entries,
                serverIDs: ["a", "b", "c", "d"],
                unavailableServerIDs: unavailable,
                serverFilterID: serverID,
                workspaceFilterID: workspaceID
            )
        }

        @Test func eachServerCountsItsOwnSessionsAndAllServersCountsEverything() {
            let counts = Self.counts()

            #expect(counts.count(forServer: "a") == 3)
            #expect(counts.count(forServer: "b") == 2)
            #expect(counts.allServers == 5)
        }

        @Test func eachWorkspaceCountsItsSessionsAndTheSameFolderOnTwoServersCountsSeparately() {
            let counts = Self.counts()

            #expect(counts.count(forWorkspace: "a|directory:/work/app") == 2)
            #expect(counts.count(forWorkspace: "b|directory:/work/app") == 1)
            #expect(counts.count(forWorkspace: "a|directory:/work/site") == 1)
            #expect(counts.count(forWorkspace: "b|directory:/work/docs") == 1)
            #expect(counts.allWorkspaces == 5)
        }

        @Test func workspaceCountsRespectTheServerFilterAndAllWorkspacesTotalsOnlyThatServer() {
            let counts = Self.counts(serverID: "b")

            #expect(counts.count(forWorkspace: "b|directory:/work/app") == 1)
            #expect(counts.count(forWorkspace: "a|directory:/work/app") == nil)
            #expect(counts.allWorkspaces == 2)
        }

        @Test func serverCountsRespectTheWorkspaceFilterAndAllServersTotalsOnlyThatWorkspace() {
            let counts = Self.counts(workspaceID: "a|directory:/work/app")

            #expect(counts.count(forServer: "a") == 2)
            #expect(counts.count(forServer: "b") == 0)
            #expect(counts.allServers == 2)
        }

        @Test func aDroppedServerIsCountedByWhatItStillShowsNotByItsHealth() {
            let counts = Self.counts(unavailable: ["b"])

            // b has dropped, but its last-loaded sessions are still on screen. Showing "--"
            // beside them while b's own workspace row showed a count contradicted itself, and
            // the status dot already says b is unhealthy.
            #expect(counts.count(forServer: "b") == 2)
            #expect(counts.count(forServer: "a") == 3)
            #expect(counts.count(forWorkspace: "b|directory:/work/docs") == 1)
            #expect(counts.allServers == 5)
            #expect(counts.allWorkspaces == 5)
        }

        @Test func aServerWithNothingOnScreenHasNoCountOnlyWhileItCannotAnswer() {
            // Neither c nor d holds any session here. c cannot answer, so it has no count to
            // give; d can answer and genuinely has nothing, which is a different fact and
            // reads as zero rather than a dash.
            let counts = Self.counts(unavailable: ["c"])

            #expect(counts.count(forServer: "c") == nil)
            #expect(counts.count(forServer: "d") == 0)
        }

        @Test func anAvailableServerWithNoSessionsCountsZeroNotAnEmDash() {
            let counts = SessionGrouping.filterCounts(
                entries: Self.aggregate(serverIDs: ["a"]).entries,
                serverIDs: ["a", "b", "c", "d"],
                unavailableServerIDs: [],
                serverFilterID: nil,
                workspaceFilterID: nil
            )

            #expect(counts.count(forServer: "a") == 3)
            #expect(counts.count(forServer: "b") == 0)
        }

        @Test func theServersSectionIsLeftOutWhileOnlyOneServerIsSaved() {
            #expect(!sessionFilterShowsServersSection(serverCount: 0))
            #expect(!sessionFilterShowsServersSection(serverCount: 1))
            #expect(sessionFilterShowsServersSection(serverCount: 2))
        }

        @Test func clearingTheFilterResetsBothTheServerAndTheWorkspace() {
            let selection = SessionFilterSelection(serverID: "a", workspaceID: "a|directory:/work/app")
            let cleared = selection.cleared()

            #expect(selection.isActive)
            #expect(cleared == SessionFilterSelection(serverID: nil, workspaceID: nil))
            #expect(!cleared.isActive)
        }

        @Test func aWorkspaceAloneOrAServerAloneCountsAsAnActiveFilter() {
            #expect(SessionFilterSelection(serverID: "a", workspaceID: nil).isActive)
            #expect(SessionFilterSelection(serverID: nil, workspaceID: "a|directory:/work/app").isActive)
        }
    }
}
