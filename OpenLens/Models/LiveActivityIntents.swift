import ActivityKit
import AppIntents
import Foundation

// Live Activity intents run in the app's process, even when the button is tapped in the widget
// extension, so the activity can drop the prompt as soon as the server accepts the reply.
// This file must be compiled into both the main app target and the widget extension target.

struct ApprovePermissionIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Allow Permission"

    @Parameter(title: "Request ID")
    var requestID: String

    init() {}

    init(requestID: String) {
        self.requestID = requestID
    }

    func perform() async throws -> some IntentResult {
        try await LiveActivityReplySender.send(.allow, toRequest: requestID)
        return .result()
    }
}

struct DenyPermissionIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Deny Permission"

    @Parameter(title: "Request ID")
    var requestID: String

    init() {}

    init(requestID: String) {
        self.requestID = requestID
    }

    func perform() async throws -> some IntentResult {
        try await LiveActivityReplySender.send(.deny, toRequest: requestID)
        return .result()
    }
}

struct AnswerPromptIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Answer Question"

    @Parameter(title: "Request ID")
    var requestID: String

    @Parameter(title: "Answer")
    var replyIndex: Int

    init() {}

    init(requestID: String, replyIndex: Int) {
        self.requestID = requestID
        self.replyIndex = replyIndex
    }

    func perform() async throws -> some IntentResult {
        try await LiveActivityReplySender.send(.quickReply(replyIndex), toRequest: requestID)
        return .result()
    }
}

private enum LiveActivityReplySender {
    /// Replies to the prompt only while an activity still shows it, so a stale button can't
    /// answer a prompt that was already handled elsewhere.
    static func send(_ reply: LiveActivityReply, toRequest requestID: String) async throws {
        guard !requestID.isEmpty,
              let activity = Activity<OpenLensActivityAttributes>.activities.first(where: {
                  $0.content.state.pendingUserResponse?.requestID == requestID
              }),
              let prompt = activity.content.state.pendingUserResponse
        else { return }

        if !activity.attributes.isPreview {
            guard let baseURLString = SharedConnectionStore.baseURL,
                  let baseURL = URL(string: baseURLString)
            else { throw URLError(.userAuthenticationRequired) }

            let request = try SharedConnectionStore.replyRequest(
                to: prompt,
                with: reply,
                directory: activity.attributes.directory,
                baseURL: baseURL,
                authHeader: SharedConnectionStore.authHeader,
                usesV2: SharedConnectionStore.usesV2
            )
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
        }

        var state = activity.content.state
        state.pendingUserResponse = nil
        await activity.update(ActivityContent(state: state, staleDate: nil))
    }
}
