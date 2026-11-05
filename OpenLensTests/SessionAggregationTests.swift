import Foundation
import Testing
@testable import OpenLens

extension MultiServerSuite {
    @Suite struct Aggregation {
        /// `updated` is in milliseconds, as the server sends it.
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

        static let calendar: Calendar = {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
            return calendar
        }()

        /// Noon UTC, so "today" and "yesterday" have room on both sides.
        static let now = Date(timeIntervalSince1970: 1_799_971_200 + 12 * 3600)

        /// A session last touched `hours` before `now`.
        static func session(_ id: String, directory: String? = nil, hoursAgo hours: Double) -> OCSession {
            session(id, directory: directory, updated: (now.timeIntervalSince1970 - hours * 3600) * 1000)
        }

        static func busy() -> OCSessionStatus {
            OCSessionStatus(type: .busy, attempt: nil, message: nil, next: nil)
        }

        static func aggregate(
            _ results: [ServerSessionsResult],
            showsServerTags: Bool = true,
            statuses: [String: [String: OCSessionStatus]] = [:]
        ) -> SessionAggregation {
            SessionGrouping.aggregate(
                results: results,
                tags: tags,
                showsServerTags: showsServerTags,
                statuses: statuses,
                now: now,
                calendar: calendar,
                customName: { _ in nil }
            )
        }

        static func ids(_ section: SessionListSection) -> [String] { section.entries.map(\.session.id) }

        @Test func runningSessionsArePinnedAboveEverythingRegardlessOfTheirTimestamps() {
            let aggregation = Self.aggregate(
                [ServerSessionsResult(serverID: "a", sessions: [
                    Self.session("fresh", hoursAgo: 0.1),
                    Self.session("ancient-but-running", hoursAgo: 24 * 40),
                    Self.session("recent", hoursAgo: 1)
                ])],
                statuses: ["a": ["ancient-but-running": Self.busy()]]
            )

            #expect(aggregation.sections.map(\.kind) == [.running, .today])
            #expect(Self.ids(aggregation.sections[0]) == ["ancient-but-running"])
            #expect(Self.ids(aggregation.sections[1]) == ["fresh", "recent"])
        }

        @Test func aRetryingSessionCountsAsRunningAndAnIdleOneDoesNot() {
            let retry = OCSessionStatus(type: .retry, attempt: 2, message: "rate limited", next: nil)
            let idle = OCSessionStatus(type: .idle, attempt: nil, message: nil, next: nil)
            let aggregation = Self.aggregate(
                [ServerSessionsResult(serverID: "a", sessions: [
                    Self.session("retrying", hoursAgo: 5),
                    Self.session("idle", hoursAgo: 1)
                ])],
                statuses: ["a": ["retrying": retry, "idle": idle]]
            )

            #expect(Self.ids(aggregation.sections[0]) == ["retrying"])
            #expect(aggregation.sections[0].kind == .running)
            #expect(Self.ids(aggregation.sections[1]) == ["idle"])
        }

        @Test func runningSessionsAreOrderedNewestFirstWithinTheRunningSection() {
            let aggregation = Self.aggregate(
                [ServerSessionsResult(serverID: "a", sessions: [
                    Self.session("older", hoursAgo: 30),
                    Self.session("newer", hoursAgo: 2)
                ])],
                statuses: ["a": ["older": Self.busy(), "newer": Self.busy()]]
            )

            #expect(aggregation.sections.map(\.kind) == [.running])
            #expect(Self.ids(aggregation.sections[0]) == ["newer", "older"])
        }

        @Test func aStatusOnOneServerDoesNotPinTheSameSessionIDOnAnotherServer() {
            let aggregation = Self.aggregate(
                [
                    ServerSessionsResult(serverID: "a", sessions: [Self.session("same", hoursAgo: 1)]),
                    ServerSessionsResult(serverID: "b", sessions: [Self.session("same", hoursAgo: 2)])
                ],
                statuses: ["a": ["same": Self.busy()]]
            )

            #expect(aggregation.sections.map(\.kind) == [.running, .today])
            #expect(aggregation.sections[0].entries.map(\.serverID) == ["a"])
            #expect(aggregation.sections[1].entries.map(\.serverID) == ["b"])
        }

        @Test func sessionsFallIntoTodayYesterdayAndEarlierNewestFirst() {
            let aggregation = Self.aggregate([
                ServerSessionsResult(serverID: "a", sessions: [
                    Self.session("last-month", hoursAgo: 24 * 30),
                    Self.session("this-morning", hoursAgo: 2),
                    Self.session("yesterday-late", hoursAgo: 13),
                    Self.session("yesterday-early", hoursAgo: 30),
                    Self.session("last-week", hoursAgo: 24 * 7),
                    Self.session("just-now", hoursAgo: 0.01)
                ])
            ])

            #expect(aggregation.sections.map(\.kind) == [.today, .yesterday, .earlier])
            #expect(Self.ids(aggregation.sections[0]) == ["just-now", "this-morning"])
            #expect(Self.ids(aggregation.sections[1]) == ["yesterday-late", "yesterday-early"])
            #expect(Self.ids(aggregation.sections[2]) == ["last-week", "last-month"])
        }

        @Test func emptySectionsAreOmitted() {
            let aggregation = Self.aggregate([
                ServerSessionsResult(serverID: "a", sessions: [Self.session("old", hoursAgo: 24 * 9)])
            ])
            #expect(aggregation.sections.map(\.kind) == [.earlier])
        }

        @Test func sessionsFromSeveralServersInterleaveByTimeRatherThanClusteringByServer() {
            let aggregation = Self.aggregate([
                ServerSessionsResult(serverID: "a", sessions: [
                    Self.session("a-newest", hoursAgo: 0.5),
                    Self.session("a-oldest", hoursAgo: 4)
                ]),
                ServerSessionsResult(serverID: "b", sessions: [
                    Self.session("b-middle", hoursAgo: 2),
                    Self.session("b-second", hoursAgo: 3)
                ])
            ])

            #expect(aggregation.sections.map(\.kind) == [.today])
            #expect(Self.ids(aggregation.sections[0]) == ["a-newest", "b-middle", "b-second", "a-oldest"])
            #expect(aggregation.sections[0].entries.map(\.serverID) == ["a", "b", "b", "a"])
        }

        @Test func noSectionCapsTheListSoARecentSessionInABusyProjectIsStillShown() {
            let busyProject = (0..<12).map { Self.session("busy-\($0)", directory: "/work/busy", hoursAgo: Double($0) + 1) }
            let quiet = Self.session("quiet", directory: "/work/quiet", hoursAgo: 10)
            let aggregation = Self.aggregate([ServerSessionsResult(serverID: "a", sessions: [quiet] + busyProject)])

            #expect(aggregation.sections.map(\.kind) == [.today])
            #expect(aggregation.entries.count == 13)
            #expect(Self.ids(aggregation.sections[0]).prefix(9).contains("busy-8"))
            #expect(Self.ids(aggregation.sections[0]).contains("busy-11"))
        }

        @Test func equalTimestampsKeepTheirInputOrder() {
            let aggregation = Self.aggregate([
                ServerSessionsResult(serverID: "a", sessions: [Self.session("first", hoursAgo: 1), Self.session("second", hoursAgo: 1)]),
                ServerSessionsResult(serverID: "b", sessions: [Self.session("third", hoursAgo: 1)])
            ])
            #expect(Self.ids(aggregation.sections[0]) == ["first", "second", "third"])
        }

        // MARK: Workspace tag

        @Test func theWorkspaceTagIsHiddenWhenEveryRowInViewSharesOneWorkspace() {
            let aggregation = Self.aggregate([
                ServerSessionsResult(serverID: "a", sessions: [
                    Self.session("one", directory: "/work/app", hoursAgo: 1),
                    Self.session("two", directory: "  /work/app  ", hoursAgo: 30)
                ])
            ], showsServerTags: false)

            #expect(!aggregation.showsWorkspaceTags)
        }

        @Test func theWorkspaceTagIsShownWhenSeveralWorkspacesAreInView() {
            let aggregation = Self.aggregate([
                ServerSessionsResult(serverID: "a", sessions: [
                    Self.session("one", directory: "/work/app", hoursAgo: 1),
                    Self.session("two", directory: "/work/site", hoursAgo: 30)
                ])
            ], showsServerTags: false)

            #expect(aggregation.showsWorkspaceTags)
            #expect(aggregation.entries.map(\.label.workspace) == ["app", "site"])
        }

        @Test func theSameFolderOnTwoServersCountsAsTwoWorkspacesSoTheServerStaysVisible() {
            let aggregation = Self.aggregate([
                ServerSessionsResult(serverID: "a", sessions: [Self.session("a1", directory: "/work/app", hoursAgo: 1)]),
                ServerSessionsResult(serverID: "b", sessions: [Self.session("b1", directory: "/work/app", hoursAgo: 2)])
            ])

            #expect(aggregation.showsWorkspaceTags)
            #expect(aggregation.entries.map { $0.label.spokenText } == ["Laptop · app", "10.0.0.2:4096 · app"])
        }

        @Test func theServerAppearsInTheTagOnlyWhenMoreThanOneServerIsSaved() {
            let sessions = [
                Self.session("one", directory: "/work/app", hoursAgo: 1),
                Self.session("two", directory: "/work/site", hoursAgo: 2)
            ]
            let single = Self.aggregate([ServerSessionsResult(serverID: "a", sessions: sessions)], showsServerTags: false)
            let several = Self.aggregate([ServerSessionsResult(serverID: "a", sessions: sessions)], showsServerTags: true)

            #expect(single.entries.allSatisfy { $0.label.server == nil })
            #expect(single.entries.map { $0.label.spokenText } == ["app", "site"])
            #expect(several.entries.allSatisfy { $0.label.server?.text == "Laptop" })
            #expect(several.entries.map { $0.label.spokenText } == ["Laptop · app", "Laptop · site"])
        }

        @Test func aDirectorylessSessionIsNamedByItsProjectIDOrTheFallback() {
            let aggregation = Self.aggregate([
                ServerSessionsResult(serverID: "a", sessions: [
                    Self.session("p", projectID: "only-a-project-id", updated: Self.now.timeIntervalSince1970 * 1000),
                    Self.session("none", updated: Self.now.timeIntervalSince1970 * 1000 - 1000)
                ])
            ], showsServerTags: false)

            #expect(aggregation.entries.map(\.label.workspace) == ["only-a-project-id", AppText.projectFallback])
            #expect(aggregation.showsWorkspaceTags)
        }

        @Test func aCustomWorkspaceNameReplacesTheFolderNameInTheTag() {
            let aggregation = SessionGrouping.aggregate(
                results: [ServerSessionsResult(serverID: "a", sessions: [Self.session("a1", directory: "/work/app", hoursAgo: 1)])],
                tags: Self.tags,
                showsServerTags: false,
                now: Self.now,
                calendar: Self.calendar,
                customName: { $0 == "/work/app" ? "Renamed" : nil }
            )
            #expect(aggregation.entries.map(\.label.workspace) == ["Renamed"])
        }

        // MARK: Failures

        @Test func oneServerFailingDegradesItsOwnSectionWhileTheOthersStillRender() {
            let aggregation = Self.aggregate([
                ServerSessionsResult(serverID: "a", sessions: [], failureMessage: "The network connection was lost."),
                ServerSessionsResult(serverID: "b", sessions: [Self.session("b1", directory: "/work/app", hoursAgo: 1)])
            ])

            #expect(aggregation.entries.map(\.serverID) == ["b"])
            #expect(aggregation.failures.map(\.serverID) == ["a"])
            #expect(aggregation.failures.first?.message == "The network connection was lost.")
            #expect(aggregation.failures.first?.tag?.text == "Laptop")
        }

        @Test func aFailingServerKeepsTheSessionsItLastLoaded() {
            let aggregation = Self.aggregate([
                ServerSessionsResult(
                    serverID: "a",
                    sessions: [Self.session("a1", directory: "/work/app", hoursAgo: 1)],
                    failureMessage: "timed out"
                )
            ])

            #expect(aggregation.entries.map(\.session.id) == ["a1"])
            #expect(aggregation.failures.count == 1)
        }

        // MARK: Server identity

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
    }
}
