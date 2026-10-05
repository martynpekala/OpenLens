import ActivityKit
import Foundation

/// ActivityAttributes for the coding agent Live Activity.
/// This file must be compiled into both the main app target and the widget extension target.
nonisolated struct OpenLensActivityAttributes: ActivityAttributes {
    /// Session the turn belongs to; tapping the activity opens it.
    var sessionID: String?
    /// Project directory v1 replies are routed to.
    var directory: String?
    /// Preview activities from Settings answer prompts locally instead of calling the server.
    var isPreview = false

    enum Phase: String, Codable, Hashable {
        case working
        case finished
        case stopped
        case failed
    }

    /// A prompt answer short enough to offer as a button in the Live Activity.
    struct QuickReply: Codable, Hashable {
        enum Value: Codable, Hashable {
            /// A question option label or form option value.
            case text(String)
            /// A yes/no form answer.
            case flag(Bool)
        }

        var label: String
        var value: Value
    }

    struct PendingUserResponse: Codable, Hashable {
        enum Kind: String, Codable, Hashable {
            case permission
            case question
            case form
        }

        var kind: Kind
        /// Permission command or prompt text, already bounded for the ActivityKit payload.
        var detail: String
        var requestID: String?
        /// Session ownership required by the v2 reply endpoints.
        var sessionID: String?
        /// Form field the quick replies answer.
        var fieldKey: String?
        /// Buttons for answering a question or form without opening the app. Empty when the
        /// prompt needs the full answer sheet.
        var quickReplies: [QuickReply] = []
    }

    /// Dynamic state that updates as the agent works.
    struct ContentState: Codable, Hashable {
        var phase: Phase
        /// When the turn started -- used for the live timer.
        var startDate: Date
        /// When the turn ended.
        var endDate: Date?
        /// Pending user action that is blocking agent progress, if any.
        var pendingUserResponse: PendingUserResponse?

        var isFinished: Bool {
            phase != .working
        }
    }
}

// MARK: - Session Links

extension OpenLensActivityAttributes {
    static let sessionURLHost = "session"

    /// Link that opens the turn's session in the app.
    var sessionURL: URL? {
        guard let sessionID, !sessionID.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "openlens"
        components.host = Self.sessionURLHost
        components.queryItems = [URLQueryItem(name: "id", value: sessionID)]
        return components.url
    }

    /// The session ID from a link built by `sessionURL`, or nil for any other URL.
    static func sessionID(from url: URL) -> String? {
        guard url.scheme?.lowercased() == "openlens",
              url.host?.lowercased() == sessionURLHost,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let sessionID = components.queryItems?.first(where: { $0.name == "id" })?.value,
              !sessionID.isEmpty
        else {
            return nil
        }
        return sessionID
    }
}

// MARK: - Preview Data

extension OpenLensActivityAttributes {
    static var preview: OpenLensActivityAttributes {
        OpenLensActivityAttributes(sessionID: nil, directory: nil, isPreview: true)
    }
}

extension OpenLensActivityAttributes.ContentState {
    static var startDate: Date = .now

    static var working: OpenLensActivityAttributes.ContentState {
        OpenLensActivityAttributes.ContentState(phase: .working, startDate: startDate)
    }

    static var waitingForPermission: OpenLensActivityAttributes.ContentState {
        OpenLensActivityAttributes.ContentState(
            phase: .working,
            startDate: startDate,
            pendingUserResponse: OpenLensActivityAttributes.PendingUserResponse(
                kind: .permission,
                detail: "npm test -- auth middleware",
                requestID: "preview-permission"
            )
        )
    }

    static var waitingForAnswer: OpenLensActivityAttributes.ContentState {
        OpenLensActivityAttributes.ContentState(
            phase: .working,
            startDate: startDate,
            pendingUserResponse: OpenLensActivityAttributes.PendingUserResponse(
                kind: .question,
                detail: "Should the refresh token rotate on every request?",
                requestID: "preview-question",
                quickReplies: [
                    .init(label: "Rotate", value: .text("Rotate")),
                    .init(label: "Keep", value: .text("Keep")),
                ]
            )
        )
    }

    static var waitingForOpenAnswer: OpenLensActivityAttributes.ContentState {
        OpenLensActivityAttributes.ContentState(
            phase: .working,
            startDate: startDate,
            pendingUserResponse: OpenLensActivityAttributes.PendingUserResponse(
                kind: .question,
                detail: "Which branch should I compare against?",
                requestID: "preview-open-question"
            )
        )
    }

    static var finished: OpenLensActivityAttributes.ContentState {
        OpenLensActivityAttributes.ContentState(
            phase: .finished,
            startDate: startDate,
            endDate: startDate.addingTimeInterval(84)
        )
    }
}
