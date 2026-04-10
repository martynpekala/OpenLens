import Foundation

/// Abstraction over Live Activity management for testability.
/// Concrete implementation: `LiveActivityManager`.
protocol LiveActivityProviding: AnyObject {
    var isActive: Bool { get }

    func startActivity(agentName: String, userTask: String, subject: String?)
    func update(
        subject: String?,
        currentIntent: String,
        currentIntentIcon: String?,
        previousIntent: String?,
        secondPreviousIntent: String?,
        stepNumber: Int,
        costTotal: String?,
        pendingUserResponse: OpenLensActivityAttributes.PendingUserResponse?
    )
    func endActivity(completionSummary: String?)
    func previewLiveActivity()
}
