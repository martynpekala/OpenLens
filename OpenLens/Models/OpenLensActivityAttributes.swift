import ActivityKit
import Foundation

/// ActivityAttributes for the coding agent Live Activity.
/// This file must be compiled into both the main app target and the widget extension target.
struct OpenLensActivityAttributes: ActivityAttributes {
    /// Static context set when the activity starts (does not change).
    var agentName: String
    var userTask: String

    struct PendingUserResponse: Codable, Hashable {
        enum Kind: String, Codable, Hashable {
            case permission
            case question

            var statusText: String {
                switch self {
                case .permission:
                    "Waiting for permission"
                case .question:
                    "Waiting for answer"
                }
            }

            var compactText: String {
                switch self {
                case .permission:
                    "Approve"
                case .question:
                    "Answer"
                }
            }

            var cardTitle: String {
                switch self {
                case .permission:
                    "Permission required"
                case .question:
                    "Answer required"
                }
            }

            var iconName: String {
                switch self {
                case .permission:
                    "hand.raised.fill"
                case .question:
                    "questionmark.bubble.fill"
                }
            }

            var fallbackDetail: String {
                switch self {
                case .permission:
                    "Approve or deny the request so the agent can continue."
                case .question:
                    "Open the question sheet and send an answer so the agent can continue."
                }
            }
        }

        var kind: Kind
        var detail: String
        var requestID: String?
    }

    /// Dynamic state that updates as the agent works.
    struct ContentState: Codable, Hashable {
        /// Short subject line summarizing the task.
        var subject: String?
        /// The latest intent -- shown in the footer.
        var currentIntent: String
        /// SF Symbol name for the current intent's tool category.
        var currentIntentIcon: String?
        /// The previous intent -- shown as the top card.
        var previousIntent: String?
        /// The 2nd most previous intent -- shown as the card behind.
        var secondPreviousIntent: String?
        /// When the current intent started -- used for the live timer.
        var intentStartDate: Date
        /// When the current intent ended.
        var intentEndDate: Date?
        /// Total step number (completed + current).
        var stepNumber: Int
        /// Formatted cost string (e.g. "$0.049"), nil until first usage event.
        var costTotal: String?
        /// Pending user action that is blocking agent progress, if any.
        var pendingUserResponse: PendingUserResponse?
        /// Whether the agent has finished and the activity should dismiss.
        var isFinished: Bool {
            intentEndDate != nil
        }
    }
}

// MARK: - Preview Data

extension OpenLensActivityAttributes {
    static var preview: OpenLensActivityAttributes {
        OpenLensActivityAttributes(
            agentName: "OpenCode",
            userTask: "Fix the authentication middleware to handle expired tokens"
        )
    }
}

extension OpenLensActivityAttributes.ContentState {
    static var startDate: Date = .now

    static var step1: OpenLensActivityAttributes.ContentState {
        OpenLensActivityAttributes.ContentState(
            subject: "Fix auth middleware",
            currentIntent: "Reading auth middleware...",
            currentIntentIcon: "doc.text",
            previousIntent: nil,
            secondPreviousIntent: nil,
            intentStartDate: startDate,
            stepNumber: 1,
            costTotal: nil
        )
    }

    static var step2: OpenLensActivityAttributes.ContentState {
        OpenLensActivityAttributes.ContentState(
            subject: "Fix auth middleware",
            currentIntent: "Searching for token validation...",
            currentIntentIcon: "magnifyingglass",
            previousIntent: "Read src/middleware/auth.ts",
            secondPreviousIntent: nil,
            intentStartDate: startDate,
            stepNumber: 2,
            costTotal: "$0.003"
        )
    }

    static var step3: OpenLensActivityAttributes.ContentState {
        OpenLensActivityAttributes.ContentState(
            subject: "Fix auth middleware",
            currentIntent: "Reading token utils...",
            currentIntentIcon: "doc.text",
            previousIntent: "Found 3 references to token expiry",
            secondPreviousIntent: "Read src/middleware/auth.ts",
            intentStartDate: startDate,
            stepNumber: 3,
            costTotal: "$0.005"
        )
    }

    static var step4: OpenLensActivityAttributes.ContentState {
        OpenLensActivityAttributes.ContentState(
            subject: "Fix auth middleware",
            currentIntent: "Editing auth.ts...",
            currentIntentIcon: "pencil.line",
            previousIntent: "Read src/utils/token.ts",
            secondPreviousIntent: "Found 3 references to token expiry",
            intentStartDate: startDate,
            stepNumber: 4,
            costTotal: "$0.008"
        )
    }

    static var step5: OpenLensActivityAttributes.ContentState {
        OpenLensActivityAttributes.ContentState(
            subject: "Fix auth middleware",
            currentIntent: "Running tests...",
            currentIntentIcon: "terminal",
            previousIntent: "Added token refresh logic to auth.ts",
            secondPreviousIntent: "Read src/utils/token.ts",
            intentStartDate: startDate,
            stepNumber: 5,
            costTotal: "$0.012"
        )
    }

    static var waitingForPermission: OpenLensActivityAttributes.ContentState {
        OpenLensActivityAttributes.ContentState(
            subject: "Fix auth middleware",
            currentIntent: "Running tests...",
            currentIntentIcon: "terminal",
            previousIntent: "Added token refresh logic to auth.ts",
            secondPreviousIntent: "Read src/utils/token.ts",
            intentStartDate: startDate,
            stepNumber: 5,
            costTotal: "$0.012",
            pendingUserResponse: OpenLensActivityAttributes.PendingUserResponse(
                kind: .permission,
                detail: "bash: npm test -- auth middleware",
                requestID: "preview-permission-id"
            )
        )
    }

    static var waitingForAnswer: OpenLensActivityAttributes.ContentState {
        OpenLensActivityAttributes.ContentState(
            subject: "Fix auth middleware",
            currentIntent: "Running tests...",
            currentIntentIcon: "terminal",
            previousIntent: "Added token refresh logic to auth.ts",
            secondPreviousIntent: "Read src/utils/token.ts",
            intentStartDate: startDate,
            stepNumber: 5,
            costTotal: "$0.012",
            pendingUserResponse: OpenLensActivityAttributes.PendingUserResponse(
                kind: .question,
                detail: "Should the refresh token be rotated on every successful request?"
            )
        )
    }

    static var finished: OpenLensActivityAttributes.ContentState {
        OpenLensActivityAttributes.ContentState(
            subject: "Auth middleware fixed",
            currentIntent: "Complete",
            previousIntent: nil,
            secondPreviousIntent: nil,
            intentStartDate: startDate,
            intentEndDate: startDate.addingTimeInterval(24),
            stepNumber: 5,
            costTotal: "$0.014"
        )
    }
}
