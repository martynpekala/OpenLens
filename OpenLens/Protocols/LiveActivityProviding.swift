import Foundation

/// Abstraction over Live Activity management for testability.
/// Concrete implementation: `LiveActivityManager`.
///
/// Each session runs its own Live Activity, so turns in different sessions can be in progress
/// at the same time without ending each other's activity.
protocol LiveActivityProviding: AnyObject {
    func isActive(sessionID: String?) -> Bool

    func startActivity(sessionID: String?, directory: String?, title: String?)
    func update(sessionID: String?, pendingUserResponse: OpenLensActivityAttributes.PendingUserResponse?)
    func endActivity(sessionID: String?, phase: OpenLensActivityAttributes.Phase)
    func dismissImmediately(sessionID: String?)
    /// Dismisses every activity, e.g. when the server connection they belong to goes away.
    func dismissAll()
    func previewLiveActivity()
}
