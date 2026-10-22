@testable import OpenLens

/// Tests use this instead of `LiveActivityManager`. Real Live Activities outlive the
/// test run, and when the next run reinstalls the app the system launches it to end
/// them, beating xcodebuild's test host launch ("Simulator device failed to launch").
final class TestLiveActivityProvider: LiveActivityProviding {
    func isActive(sessionID: String?) -> Bool { false }

    func startActivity(sessionID: String?, directory: String?, title: String?) {}

    func update(sessionID: String?, pendingUserResponse: OpenLensActivityAttributes.PendingUserResponse?) {}

    func endActivity(sessionID: String?, phase: OpenLensActivityAttributes.Phase) {}

    func dismissImmediately(sessionID: String?) {}

    func dismissAll() {}

    func previewLiveActivity() {}
}
