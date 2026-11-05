@testable import OpenLens

/// Tests use this instead of `LiveActivityManager`. Real Live Activities outlive the
/// test run, and when the next run reinstalls the app the system launches it to end
/// them, beating xcodebuild's test host launch ("Simulator device failed to launch").
final class TestLiveActivityProvider: LiveActivityProviding {
    func isActive(serverID: String?, sessionID: String?) -> Bool { false }

    func startActivity(serverID: String?, sessionID: String?, directory: String?, title: String?) {}

    func update(serverID: String?, sessionID: String?, pendingUserResponse: OpenLensActivityAttributes.PendingUserResponse?) {}

    func endActivity(serverID: String?, sessionID: String?, phase: OpenLensActivityAttributes.Phase) {}

    func dismissImmediately(serverID: String?, sessionID: String?) {}

    func dismissAll(serverID: String?) {}
    func dismissEverything() {}

    func previewLiveActivity() {}
}
