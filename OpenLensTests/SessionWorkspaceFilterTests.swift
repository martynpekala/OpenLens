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
    }
}
