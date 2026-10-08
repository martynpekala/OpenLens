@testable import OpenLens

/// Tests use this instead of `LiveActivityManager`. Real Live Activities outlive the
/// test run, and when the next run reinstalls the app the system launches it to end
/// them, beating xcodebuild's test host launch ("Simulator device failed to launch").
final class TestLiveActivityProvider: LiveActivityProviding {
    var isActive: Bool { false }

    func startActivity(sessionID: String?, directory: String?) {}

    func update(pendingUserResponse: OpenLensActivityAttributes.PendingUserResponse?) {}

    func endActivity(phase: OpenLensActivityAttributes.Phase) {}

    func dismissImmediately() {}

    func previewLiveActivity() {}
}
