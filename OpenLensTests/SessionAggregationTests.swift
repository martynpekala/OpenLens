import Foundation
import Testing
@testable import OpenLens

extension MultiServerSuite {
    @Suite struct Aggregation {
        static func session(
            _ id: String,
            directory: String? = nil,
            projectID: String? = nil,
            updated: Double
        ) -> OCSession {
            OCSession(
                id: id,
                projectID: projectID,
                directory: directory,
                title: id,
                version: "v1",
                time: OCSessionTime(created: 0, updated: updated)
            )
        }

        static let tags = [
            "a": ServerTag(nickname: "Laptop", serverURL: "10.0.0.1:4096"),
            "b": ServerTag(nickname: nil, serverURL: "http://10.0.0.2:4096/path")
        ]

        static func aggregate(_ results: [ServerSessionsResult], showsServerTags: Bool = true) -> SessionAggregation {
            SessionGrouping.aggregate(results: results, tags: tags, showsServerTags: showsServerTags, customName: { _ in nil })
        }

        @Test func theSameDirectoryOnTwoServersYieldsTwoGroups() {
            let aggregation = Self.aggregate([
                ServerSessionsResult(serverID: "a", sessions: [Self.session("a1", directory: "/work/app", updated: 2000)]),
                ServerSessionsResult(serverID: "b", sessions: [Self.session("b1", directory: "/work/app", updated: 1000)])
            ])

            #expect(aggregation.groups.count == 2)
            #expect(aggregation.groups.map(\.title) == ["app", "app"])
            #expect(Set(aggregation.groups.map(\.id)).count == 2)
            #expect(aggregation.groups.map(\.serverID) == ["a", "b"])
            #expect(aggregation.groups.map { $0.tag?.text } == ["Laptop", "10.0.0.2:4096"])
        }

        @Test func twoDirectorylessSessionsOnDifferentServersStayInSeparateUnknownGroups() {
            let aggregation = Self.aggregate([
                ServerSessionsResult(serverID: "a", sessions: [Self.session("a1", updated: 2000)]),
                ServerSessionsResult(serverID: "b", sessions: [Self.session("b1", updated: 1000)])
            ])

            #expect(aggregation.groups.count == 2)
            #expect(Set(aggregation.groups.map(\.id)).count == 2)
            #expect(aggregation.groups.allSatisfy { $0.id.hasSuffix("|unknown") })
            #expect(aggregation.groups.map { $0.sessions.map(\.id) } == [["a1"], ["b1"]])
        }

        @Test func groupsAreOrderedByTheirMostRecentSessionAcrossServers() {
            let aggregation = Self.aggregate([
                ServerSessionsResult(serverID: "a", sessions: [
                    Self.session("a-new", directory: "/work/older-project", updated: 5000),
                    Self.session("a-old", directory: "/work/stale", updated: 1000)
                ]),
                ServerSessionsResult(serverID: "b", sessions: [
                    Self.session("b-newest", directory: "/work/newest", updated: 9000),
                    Self.session("b-mid", directory: "/work/middle", updated: 3000)
                ])
            ])

            #expect(aggregation.groups.map(\.title) == ["newest", "older-project", "middle", "stale"])
        }

        @Test func oneServerFailingDegradesItsOwnSectionWhileTheOthersStillRender() {
            let aggregation = Self.aggregate([
                ServerSessionsResult(serverID: "a", sessions: [], failureMessage: "The network connection was lost."),
                ServerSessionsResult(serverID: "b", sessions: [Self.session("b1", directory: "/work/app", updated: 1000)])
            ])

            #expect(aggregation.groups.map(\.serverID) == ["b"])
            #expect(aggregation.failures.map(\.serverID) == ["a"])
            #expect(aggregation.failures.first?.message == "The network connection was lost.")
            #expect(aggregation.failures.first?.tag?.text == "Laptop")
        }

        @Test func aFailingServerKeepsTheSessionsItLastLoaded() {
            let aggregation = Self.aggregate([
                ServerSessionsResult(
                    serverID: "a",
                    sessions: [Self.session("a1", directory: "/work/app", updated: 1000)],
                    failureMessage: "timed out"
                )
            ])

            #expect(aggregation.groups.map(\.title) == ["app"])
            #expect(aggregation.failures.count == 1)
        }

        @Test func aNicknameBecomesTheTagAndAHostOtherwise() {
            #expect(Self.tags["a"]?.kind == .nickname)
            #expect(Self.tags["a"]?.text == "Laptop")
            #expect(Self.tags["b"]?.kind == .host)
            #expect(Self.tags["b"]?.text == "10.0.0.2:4096")
        }

        @Test func aBlankNicknameFallsBackToTheHost() {
            let tag = ServerTag(nickname: "   ", serverURL: "192.168.1.50:4096")
            #expect(tag.kind == .host)
            #expect(tag.text == "192.168.1.50:4096")
        }

        @Test func aCustomWorkspaceNameReplacesTheFolderNameInTheGroupTitle() {
            let aggregation = SessionGrouping.aggregate(
                results: [ServerSessionsResult(serverID: "a", sessions: [Self.session("a1", directory: "/work/app", updated: 1)])],
                tags: Self.tags,
                showsServerTags: true,
                customName: { $0 == "/work/app" ? "Renamed" : nil }
            )
            #expect(aggregation.groups.map(\.title) == ["Renamed"])
        }
    }
}
