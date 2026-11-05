import Foundation
import Testing
@testable import OpenLens

extension MultiServerSuite {
    /// The regression gate for "one saved server means no visible change". Each test here would
    /// fail if a tag, a failure notice or the switcher leaked into the single-server case.
    @Suite struct SingleServerParity {
        /// The grouping the Sessions list did before aggregation existed, kept verbatim as the
        /// reference the aggregated output must equal.
        private struct LegacyGroup: Equatable {
            let id: String
            let title: String
            let subtitle: String?
            let sessionIDs: [String]
        }

        private static func legacyGroups(_ sessions: [OCSession]) -> [LegacyGroup] {
            func directory(_ session: OCSession) -> String? {
                let trimmed = session.directory?.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let trimmed, !trimmed.isEmpty else { return nil }
                return trimmed
            }
            func groupID(_ session: OCSession) -> String {
                if let directory = directory(session), !directory.isEmpty { return "directory:\(directory)" }
                if let projectID = session.projectID?.trimmingCharacters(in: .whitespacesAndNewlines), !projectID.isEmpty {
                    return "projectID:\(projectID)"
                }
                return "unknown"
            }
            func title(_ session: OCSession) -> String {
                if let directory = directory(session) {
                    let last = URL(fileURLWithPath: directory).lastPathComponent
                    if !last.isEmpty { return last }
                }
                if let projectID = session.projectID?.trimmingCharacters(in: .whitespacesAndNewlines), !projectID.isEmpty {
                    return projectID
                }
                return AppText.projectFallback
            }

            var grouped: [String: [OCSession]] = [:]
            var order: [String] = []
            var titles: [String: String] = [:]
            var subtitles: [String: String?] = [:]
            for session in sessions {
                let id = groupID(session)
                if grouped[id] == nil { order.append(id) }
                grouped[id, default: []].append(session)
                titles[id] = title(session)
                subtitles[id] = directory(session)
            }
            return order.map {
                LegacyGroup(id: $0, title: titles[$0] ?? AppText.projectFallback, subtitle: subtitles[$0] ?? nil, sessionIDs: (grouped[$0] ?? []).map(\.id))
            }
        }

        static let sessions: [OCSession] = [
            MultiServerSuite.Aggregation.session("s1", directory: "/work/app", projectID: "p1", updated: 9000),
            MultiServerSuite.Aggregation.session("s2", directory: "/work/other", updated: 8000),
            MultiServerSuite.Aggregation.session("s3", directory: "/work/app", updated: 7000),
            MultiServerSuite.Aggregation.session("s4", projectID: "only-a-project-id", updated: 6000),
            MultiServerSuite.Aggregation.session("s5", updated: 5000),
            MultiServerSuite.Aggregation.session("s6", directory: "  /work/other  ", updated: 4000)
        ]

        private static func aggregate(_ sessions: [OCSession], failure: String? = nil) -> SessionAggregation {
            SessionGrouping.aggregate(
                results: [ServerSessionsResult(serverID: "only", sessions: sessions, failureMessage: failure)],
                tags: ["only": ServerTag(nickname: "Laptop", serverURL: "10.0.0.1:4096")],
                showsServerTags: isMultiServerUIEnabled(savedServerCount: 1),
                customName: { _ in nil }
            )
        }

        @Test func oneServerGroupsExactlyAsTheListDidBeforeAggregation() {
            let aggregated = Self.aggregate(Self.sessions).groups.map {
                LegacyGroup(id: $0.id, title: $0.title, subtitle: $0.subtitle, sessionIDs: $0.sessions.map(\.id))
            }
            let legacy = Self.legacyGroups(Self.sessions)

            // Identity is scoped to the server now, so compare it with the scope removed.
            #expect(aggregated.map { $0.id.replacingOccurrences(of: "only|", with: "") } == legacy.map(\.id))
            #expect(aggregated.map(\.title) == legacy.map(\.title))
            #expect(aggregated.map(\.subtitle) == legacy.map(\.subtitle))
            #expect(aggregated.map(\.sessionIDs) == legacy.map(\.sessionIDs))
        }

        @Test func oneServerKeepsItsOwnGroupOrderEvenWhenItsSessionsAreNotSortedByRecency() {
            let unsorted = [
                MultiServerSuite.Aggregation.session("old", directory: "/work/first", updated: 1000),
                MultiServerSuite.Aggregation.session("new", directory: "/work/second", updated: 9000)
            ]
            #expect(Self.aggregate(unsorted).groups.map(\.title) == ["first", "second"])
            #expect(Self.aggregate(unsorted).groups.map(\.title) == Self.legacyGroups(unsorted).map(\.title))
        }

        @Test func oneServerProducesNoServerTagOnAnyGroup() {
            let aggregation = Self.aggregate(Self.sessions)

            #expect(!aggregation.groups.isEmpty)
            #expect(aggregation.groups.allSatisfy { $0.tag == nil })
        }

        @Test func oneServersLoadFailureProducesNoSectionNoticeAndKeepsItsSessions() {
            // A single server's failure is the list's own error handling, not a per-section notice.
            let aggregation = Self.aggregate(Self.sessions, failure: "timed out")

            #expect(aggregation.failures.allSatisfy { $0.tag == nil })
            #expect(aggregation.groups.count == Self.legacyGroups(Self.sessions).count)
        }

        @Test func twoSavedServersTagEveryGroupSoTheGateDetectsALeak() {
            let aggregation = SessionGrouping.aggregate(
                results: [
                    ServerSessionsResult(serverID: "a", sessions: [MultiServerSuite.Aggregation.session("a1", directory: "/x", updated: 1)]),
                    ServerSessionsResult(serverID: "b", sessions: [MultiServerSuite.Aggregation.session("b1", directory: "/x", updated: 2)])
                ],
                tags: MultiServerSuite.Aggregation.tags,
                showsServerTags: isMultiServerUIEnabled(savedServerCount: 2),
                customName: { _ in nil }
            )

            #expect(aggregation.groups.allSatisfy { $0.tag != nil })
        }

        @Test func oneSavedServerOffersNoSwitcherAndTheCapsuleStaysNonInteractive() {
            let tag = ServerTag(nickname: nil, serverURL: "10.0.0.1:4096")

            let single = serverSwitchTargets([(id: "only", tag: tag)])
            #expect(!single.isInteractive)
            #expect(single.targets.isEmpty)
            #expect(!serverSwitchTargets([]).isInteractive)
        }

        @Test func twoSavedServersTurnTheCapsuleIntoASwitcherListingBoth() {
            let tag = ServerTag(nickname: nil, serverURL: "10.0.0.1:4096")

            let several = serverSwitchTargets([(id: "a", tag: tag), (id: "b", tag: tag)])
            #expect(several.isInteractive)
            #expect(several.targets.map(\.id) == ["a", "b"])
        }

        @Test func oneSavedServerLeavesTheNewSessionTargetOnTheActiveServerWithNoPicker() {
            let target = resolveNewSessionTarget(preferredServerID: nil, activeServerID: "only", savedServerIDs: ["only"])
            #expect(target == "only")
            // The sheet offers a server picker only when the switcher has targets to choose between.
            #expect(serverSwitchTargets([(id: "only", tag: ServerTag(nickname: nil, serverURL: "10.0.0.1:4096"))]).targets.count <= 1)
        }

        @Test func oneSavedServerLeavesTheWorkspaceCapsuleAsTheWorkspaceAlone() {
            let tag = ServerTag(nickname: "Laptop", serverURL: "10.0.0.1:4096")
            let title = ServerQualifiedTitle(workspace: "OpenLens", server: tag, savedServerCount: 1)
            #expect(title.server == nil)
            #expect(title.workspace == "OpenLens")
        }

        @Test func oneSavedServerLeavesTheReviewPickerAsTheActiveServersSessionsOnly() {
            let options = reviewPickerOptions(
                activeServerID: "only",
                activeSessions: MultiServerSuite.SingleServerParity.sessions,
                otherServers: [],
                tags: ["only": ServerTag(nickname: "Laptop", serverURL: "10.0.0.1:4096")],
                showsServerTags: isMultiServerUIEnabled(savedServerCount: 1)
            )
            #expect(options.map(\.session.id) == MultiServerSuite.SingleServerParity.sessions.map(\.id))
            #expect(options.allSatisfy { $0.tag == nil })
        }

        @Test func oneSavedServerLeavesTheInboxUntaggedWithItsOwnWarning() {
            let snapshot = InboxSnapshot(
                permissions: [OCPermissionRequest(id: "p1", sessionID: "s")],
                questions: [],
                forms: [],
                warning: "forms failed"
            )
            let merged = InboxAggregation.merge(
                results: [ServerInboxResult(serverID: "only", snapshot: snapshot, failureMessage: nil)],
                tags: ["only": ServerTag(nickname: "Laptop", serverURL: "10.0.0.1:4096")],
                showsServerTags: isMultiServerUIEnabled(savedServerCount: 1)
            )
            #expect(merged.permissions.map(\.item.id) == ["p1"])
            #expect(merged.permissions.allSatisfy { $0.tag == nil })
            #expect(merged.warning == "forms failed")
        }
    }
}
