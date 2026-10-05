import Foundation

/// Abstraction over Live Activity management for testability.
/// Concrete implementation: `LiveActivityManager`.
protocol LiveActivityProviding: AnyObject {
    var isActive: Bool { get }

    func startActivity(sessionID: String?, directory: String?)
    func update(pendingUserResponse: OpenLensActivityAttributes.PendingUserResponse?)
    func endActivity(phase: OpenLensActivityAttributes.Phase)
    func dismissImmediately()
    func previewLiveActivity()
}
