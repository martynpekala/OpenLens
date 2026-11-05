import Foundation
import Testing
@testable import OpenLens

extension MultiServerSuite {
    /// Stage 6b: the pure pieces behind the New Session target, the workspace capsule, the
    /// Review picker and the Inbox. One saved server must come out exactly as it was.
    @Suite struct CrossServerSurfaces {
        private static let tags = MultiServerSuite.Aggregation.tags
        private static func session(_ id: String, updated: Double = 1) -> OCSession {
            MultiServerSuite.Aggregation.session(id, directory: "/work/\(id)", updated: updated)
        }

        // MARK: New Session target

        @Test func newSessionTargetsTheServerTheUserWasLookingAtNotTheActiveOne() {
            let target = resolveNewSessionTarget(preferredServerID: "b", activeServerID: "a", savedServerIDs: ["a", "b"])
            #expect(target == "b")
        }

        @Test func newSessionDefaultsToTheActiveServerWhenNoServerIsPreferred() {
            let target = resolveNewSessionTarget(preferredServerID: nil, activeServerID: "b", savedServerIDs: ["a", "b"])
            #expect(target == "b")
        }

        @Test func newSessionNeverTargetsAServerThatIsNoLongerSaved() {
            let target = resolveNewSessionTarget(preferredServerID: "gone", activeServerID: "a", savedServerIDs: ["a", "b"])
            #expect(target == "a")
        }

        @Test func newSessionFallsBackToTheFirstSavedServerWhenTheActiveOneIsNotSaved() {
            let target = resolveNewSessionTarget(preferredServerID: nil, activeServerID: "draft", savedServerIDs: ["a", "b"])
            #expect(target == "a")
        }

        @Test func newSessionUsesTheActiveServerWhenNothingIsSaved() {
            let target = resolveNewSessionTarget(preferredServerID: "x", activeServerID: "draft", savedServerIDs: [])
            #expect(target == "draft")
        }

        // MARK: Capsule

        @Test func twoSavedServersPutTheServerInFrontOfTheWorkspace() {
            let title = ServerQualifiedTitle(workspace: "OpenLens", server: Self.tags["a"], savedServerCount: 2)
            #expect(title.server?.text == "Laptop")
            #expect(title.workspace == "OpenLens")
            #expect(title.spokenText == "Laptop · OpenLens")
        }

        @Test func oneSavedServerLeavesTheCapsuleAsTheWorkspaceAlone() {
            let title = ServerQualifiedTitle(workspace: "OpenLens", server: Self.tags["a"], savedServerCount: 1)
            #expect(title.server == nil)
            #expect(title.spokenText == "OpenLens")
        }

        @Test func aHostOnlyServerShowsItsShortHostInTheCapsule() {
            let title = ServerQualifiedTitle(workspace: "OpenLens", server: Self.tags["b"], savedServerCount: 2)
            #expect(title.server?.kind == .host)
            #expect(title.server?.text == "10.0.0.2:4096")
        }

        // MARK: Review picker

        @Test func reviewPickerListsTheActiveServerFirstThenEveryOtherConnectedServer() {
            let options = reviewPickerOptions(
                activeServerID: "a",
                activeSessions: [Self.session("a1"), Self.session("a2")],
                otherServers: [ServerSessionsResult(serverID: "b", sessions: [Self.session("b1")])],
                tags: Self.tags,
                showsServerTags: true
            )
            #expect(options.map(\.session.id) == ["a1", "a2", "b1"])
            #expect(options.map(\.serverID) == ["a", "a", "b"])
            #expect(options.allSatisfy { $0.tag != nil })
        }

        @Test func reviewPickerKeepsTheSameSessionIDOnTwoServersApart() {
            let options = reviewPickerOptions(
                activeServerID: "a",
                activeSessions: [Self.session("same")],
                otherServers: [ServerSessionsResult(serverID: "b", sessions: [Self.session("same")])],
                tags: Self.tags,
                showsServerTags: true
            )
            #expect(Set(options.map(\.id)).count == 2)
        }

        @Test func reviewPickerWithOneSavedServerCarriesNoServerMarks() {
            let options = reviewPickerOptions(
                activeServerID: "a",
                activeSessions: [Self.session("a1")],
                otherServers: [],
                tags: Self.tags,
                showsServerTags: isMultiServerUIEnabled(savedServerCount: 1)
            )
            #expect(options.map(\.session.id) == ["a1"])
            #expect(options.allSatisfy { $0.tag == nil })
        }

        // MARK: Inbox

        private static func inbox(_ permissionIDs: [String], warning: String? = nil) -> InboxSnapshot {
            InboxSnapshot(
                permissions: permissionIDs.map { OCPermissionRequest(id: $0, sessionID: "s") },
                questions: [],
                forms: [],
                warning: warning
            )
        }

        @Test func inboxMergesEveryServersPermissionsEachCarryingItsServer() {
            let merged = InboxAggregation.merge(
                results: [
                    ServerInboxResult(serverID: "a", snapshot: Self.inbox(["p1"]), failureMessage: nil),
                    ServerInboxResult(serverID: "b", snapshot: Self.inbox(["p1", "p2"]), failureMessage: nil)
                ],
                tags: Self.tags,
                showsServerTags: true
            )
            #expect(merged.pendingRequestCount == 3)
            #expect(merged.permissions.map(\.serverID) == ["a", "b", "b"])
            #expect(merged.permissions.allSatisfy { $0.tag != nil })
            // The same request id on two servers must stay two rows.
            #expect(Set(merged.permissions.map(\.id)).count == 3)
        }

        @Test func inboxWithOneServerCarriesNoTagAndKeepsTheServersOwnWarning() {
            let merged = InboxAggregation.merge(
                results: [ServerInboxResult(serverID: "a", snapshot: Self.inbox(["p1"], warning: "forms failed"), failureMessage: nil)],
                tags: Self.tags,
                showsServerTags: isMultiServerUIEnabled(savedServerCount: 1)
            )
            #expect(merged.permissions.allSatisfy { $0.tag == nil })
            #expect(merged.warning == "forms failed")
        }

        @Test func inboxNamesTheServerThatFailedWithoutHidingTheOthersItems() {
            let merged = InboxAggregation.merge(
                results: [
                    ServerInboxResult(serverID: "a", snapshot: Self.inbox(["p1"]), failureMessage: nil),
                    ServerInboxResult(serverID: "b", snapshot: nil, failureMessage: "timed out")
                ],
                tags: Self.tags,
                showsServerTags: true
            )
            #expect(merged.permissions.count == 1)
            #expect(merged.warning == "10.0.0.2:4096: timed out")
        }
    }
}
