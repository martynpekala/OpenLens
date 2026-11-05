import Foundation

/// Abstraction over Live Activity management for testability.
/// Concrete implementation: `LiveActivityManager`.
///
/// Each session runs its own Live Activity, so turns in different sessions can be in progress
/// at the same time without ending each other's activity.
///
/// Activities are keyed by server as well as session: two servers can hand out the same session
/// id, and each must keep its own activity. `serverID` is the saved connection's id; nil is the
/// bucket for activities that predate multi-server support.
protocol LiveActivityProviding: AnyObject {
    func isActive(serverID: String?, sessionID: String?) -> Bool

    func startActivity(serverID: String?, sessionID: String?, directory: String?, title: String?)
    func update(serverID: String?, sessionID: String?, pendingUserResponse: OpenLensActivityAttributes.PendingUserResponse?)
    func endActivity(serverID: String?, sessionID: String?, phase: OpenLensActivityAttributes.Phase)
    func dismissImmediately(serverID: String?, sessionID: String?)
    /// Dismisses every activity of one server, e.g. when its connection goes away. Other
    /// servers' activities are left running.
    func dismissAll(serverID: String?)
    /// Dismisses the activities of every server. Only for the Settings debug action.
    func dismissEverything()
    func previewLiveActivity()
}
