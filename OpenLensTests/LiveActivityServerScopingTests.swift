import Foundation
import Testing
@testable import OpenLens

extension MultiServerSuite {
    /// Stage 7a: Live Activities belong to a server as well as a session.
    @Suite struct LiveActivityScoping {
        private typealias Key = LiveActivityManager.ActivityKey

        // MARK: Keys

        @Test func twoServersStartingTheSameSessionIDKeepBothActivitiesLive() {
            let provider = RecordingLiveActivityProvider()
            let trackerA = LiveActivityTracker(liveActivity: provider, serverID: { "a" })
            let trackerB = LiveActivityTracker(liveActivity: provider, serverID: { "b" })

            trackerA.start(session: Self.session("X"))
            trackerB.start(session: Self.session("X"))

            #expect(provider.live == [Key(serverID: "a", sessionID: "X"), Key(serverID: "b", sessionID: "X")])
        }

        @Test func endingASessionOnOneServerLeavesTheSameSessionIDOnTheOtherServerRunning() {
            let provider = RecordingLiveActivityProvider()
            let trackerA = LiveActivityTracker(liveActivity: provider, serverID: { "a" })
            let trackerB = LiveActivityTracker(liveActivity: provider, serverID: { "b" })
            trackerA.start(session: Self.session("X"))
            trackerB.start(session: Self.session("X"))

            trackerB.end(phase: .finished)

            #expect(provider.live == [Key(serverID: "a", sessionID: "X")])
        }

        @Test func sessionLessActivitiesOnTwoServersCoexist() {
            let provider = RecordingLiveActivityProvider()
            let trackerA = LiveActivityTracker(liveActivity: provider, serverID: { "a" })
            let trackerB = LiveActivityTracker(liveActivity: provider, serverID: { "b" })

            trackerA.start(session: nil)
            trackerB.start(session: nil)

            #expect(provider.live == [Key(serverID: "a", sessionID: nil), Key(serverID: "b", sessionID: nil)])
        }

        @Test func dismissingOneServersActivitiesLeavesTheOthersRunning() {
            let provider = RecordingLiveActivityProvider()
            let trackerA = LiveActivityTracker(liveActivity: provider, serverID: { "a" })
            let trackerB = LiveActivityTracker(liveActivity: provider, serverID: { "b" })
            trackerA.start(session: Self.session("X"))
            trackerB.start(session: Self.session("X"))

            provider.dismissAll(serverID: "a")

            #expect(provider.live == [Key(serverID: "b", sessionID: "X")])
        }

        @Test func theTrackerReadsItsServerWhenTheConnectionLearnsItsID() {
            let provider = RecordingLiveActivityProvider()
            var connectionID: String?
            let tracker = LiveActivityTracker(liveActivity: provider, serverID: { connectionID })

            tracker.start(session: Self.session("X"))
            connectionID = "a"
            tracker.start(session: Self.session("Y"))

            #expect(provider.starts.map(\.serverID) == [nil, "a"])
        }

        // MARK: Stale sweep and dismissal

        @Test func aNewTurnReplacesItsOwnServersEarlierActivityButNotAnotherServers() {
            let sameServer = Self.attributes(server: "a", session: "X")
            let otherServer = Self.attributes(server: "b", session: "X")

            #expect(LiveActivityManager.isReplaced(sameServer, byTurnOn: "a", sessionID: "X"))
            #expect(!LiveActivityManager.isReplaced(otherServer, byTurnOn: "a", sessionID: "X"))
        }

        @Test func aNewTurnReplacesAnActivityStartedBeforeServersWereTracked() {
            let legacy = Self.attributes(server: nil, session: "X")
            #expect(LiveActivityManager.isReplaced(legacy, byTurnOn: "a", sessionID: "X"))
        }

        @Test func aNewTurnNeverReplacesAnotherSessionsOrThePreviewActivity() {
            #expect(!LiveActivityManager.isReplaced(Self.attributes(server: "a", session: "Y"), byTurnOn: "a", sessionID: "X"))
            #expect(!LiveActivityManager.isReplaced(.preview, byTurnOn: nil, sessionID: nil))
        }

        @Test func dismissingAServerTakesDownItsOwnAndLegacyActivitiesOnly() {
            #expect(LiveActivityManager.isDismissed(Self.attributes(server: "a", session: "X"), withServer: "a"))
            #expect(LiveActivityManager.isDismissed(Self.attributes(server: nil, session: "X"), withServer: "a"))
            #expect(!LiveActivityManager.isDismissed(Self.attributes(server: "b", session: "X"), withServer: "a"))
        }

        // MARK: Links

        @Test func theActivityLinkNamesTheServerItBelongsTo() throws {
            let url = try #require(Self.attributes(server: "b", session: "X").sessionURL)
            let link = try #require(OpenLensActivityAttributes.sessionLink(from: url))
            #expect(link == .init(sessionID: "X", serverID: "b"))
            #expect(url.absoluteString.contains("server=b"))
        }

        @Test func aLegacyLinkWithNoServerStillParsesToJustTheSession() throws {
            let url = try #require(URL(string: "openlens://session?id=X"))
            let link = try #require(OpenLensActivityAttributes.sessionLink(from: url))
            #expect(link == .init(sessionID: "X", serverID: nil))
            #expect(OpenLensActivityAttributes.sessionID(from: url) == "X")
        }

        @Test func anActivityWithNoServerBuildsTheLegacyLinkShape() throws {
            let url = try #require(Self.attributes(server: nil, session: "X").sessionURL)
            #expect(url.absoluteString == "openlens://session?id=X")
        }

        @Test func aLinkNamingAConnectedServerResolvesToThatServerEvenWhenAnotherIsActive() {
            let ids = activityLinkCandidateServerIDs(linkedServerID: "b", activeServerID: "a", connectedServerIDs: ["a", "b"])
            #expect(ids == ["b"])
        }

        @Test func aLinkNamingAServerThatIsNotConnectedResolvesToNothing() {
            let ids = activityLinkCandidateServerIDs(linkedServerID: "gone", activeServerID: "a", connectedServerIDs: ["a", "b"])
            #expect(ids.isEmpty)
        }

        @Test func aLegacyLinkSearchesEveryConnectedServerWithTheActiveOneFirst() {
            let ids = activityLinkCandidateServerIDs(linkedServerID: nil, activeServerID: "b", connectedServerIDs: ["a", "b", "c"])
            #expect(ids == ["b", "a", "c"])
        }

        @Test func oneServerStillResolvesALegacyLinkToItself() {
            let ids = activityLinkCandidateServerIDs(linkedServerID: nil, activeServerID: "a", connectedServerIDs: ["a"])
            #expect(ids == ["a"])
        }

        // MARK: Helpers

        private static func session(_ id: String) -> OCSession {
            MultiServerSuite.Aggregation.session(id, directory: "/work/\(id)", updated: 1)
        }

        private static func attributes(server: String?, session: String?) -> OpenLensActivityAttributes {
            OpenLensActivityAttributes(sessionID: session, directory: nil, sessionTitle: nil, serverID: server)
        }
    }
}

// MARK: - Fake server

/// Records which activities are live by `(server, session)`, like `LiveActivityManager` keys
/// them. A sibling of `TestLiveActivityProvider`, which stays a deliberate no-op.
private final class RecordingLiveActivityProvider: LiveActivityProviding {
    typealias Key = LiveActivityManager.ActivityKey
    private(set) var live: Set<Key> = []
    private(set) var starts: [Key] = []

    func isActive(serverID: String?, sessionID: String?) -> Bool {
        live.contains(Key(serverID: serverID, sessionID: sessionID))
    }

    func startActivity(serverID: String?, sessionID: String?, directory: String?, title: String?) {
        let key = Key(serverID: serverID, sessionID: sessionID)
        starts.append(key)
        live.insert(key)
    }

    func update(serverID: String?, sessionID: String?, pendingUserResponse: OpenLensActivityAttributes.PendingUserResponse?) {}

    func endActivity(serverID: String?, sessionID: String?, phase: OpenLensActivityAttributes.Phase) {
        live.remove(Key(serverID: serverID, sessionID: sessionID))
    }

    func dismissImmediately(serverID: String?, sessionID: String?) {
        live.remove(Key(serverID: serverID, sessionID: sessionID))
    }

    func dismissAll(serverID: String?) {
        live = live.filter { $0.serverID != serverID }
    }

    func dismissEverything() { live.removeAll() }

    func previewLiveActivity() {}
}
