import Foundation

/// Manages Live Activity intent-history state for a single agent turn.
/// Pure value tracking — delegates actual ActivityKit calls to `LiveActivityManager`.
final class LiveActivityTracker {

    private static let maximumDetailCharacters = 180
    private static let maximumInspectedDetailCharacters = 512

    // MARK: - State

    private(set) var stepNumber: Int = 0
    private(set) var previousIntent: String?
    private(set) var secondPreviousIntent: String?
    private(set) var currentIntent: String = "Thinking"
    private(set) var currentIntentIcon: String?
    private(set) var subject: String?
    private(set) var cost: String?
    private(set) var pendingUserResponse: OpenLensActivityAttributes.PendingUserResponse?

    // MARK: - Dependency

    private let liveActivity: any LiveActivityProviding

    init(liveActivity: any LiveActivityProviding) {
        self.liveActivity = liveActivity
    }

    // MARK: - Lifecycle

    /// Reset all state for a new agent turn.
    func reset() {
        stepNumber = 0
        previousIntent = nil
        secondPreviousIntent = nil
        currentIntent = "Thinking"
        currentIntentIcon = nil
        subject = nil
        cost = nil
        pendingUserResponse = nil
    }

    /// Start the Live Activity for a new turn.
    func start(agentName: String, userTask: String) {
        reset()
        liveActivity.startActivity(
            agentName: boundedDetail(agentName) ?? "OpenCode",
            userTask: boundedDetail(userTask) ?? "",
            subject: nil
        )
    }

    /// Push a new intent, shifting the history.
    func pushIntent(_ intent: String, icon: String? = nil) {
        secondPreviousIntent = previousIntent
        previousIntent = currentIntent
        currentIntent = intent
        currentIntentIcon = icon
        pendingUserResponse = nil
        stepNumber += 1
        pushCurrentState()
    }

    /// Update the subject (e.g. from reasoning text or session title).
    func updateSubject(_ newSubject: String) {
        guard let boundedSubject = boundedDetail(newSubject) else { return }
        if subject == nil || subject?.isEmpty == true {
            subject = boundedSubject
            pushCurrentState()
        }
    }

    /// Update the cost string (e.g. "$0.003").
    func updateCost(_ newCost: String) {
        guard newCost != cost else { return }
        cost = newCost
        pushCurrentState()
    }

    func setPendingPermission(_ permission: OCPermissionRequest) {
        pendingUserResponse = .init(
            kind: .permission,
            detail: permissionLiveActivityDetail(permission),
            requestID: permission.id
        )
        pushCurrentState()
    }

    func setPendingQuestion(_ question: OCQuestionRequest) {
        pendingUserResponse = .init(
            kind: .question,
            detail: questionLiveActivityDetail(question)
        )
        pushCurrentState()
    }

    func clearPendingUserResponse() {
        guard pendingUserResponse != nil else { return }
        pendingUserResponse = nil
        pushCurrentState()
    }

    /// Push the current state to the Live Activity without advancing the step history.
    /// Used when cost or subject changes between tool calls.
    private func pushCurrentState() {
        guard liveActivity.isActive else { return }
        liveActivity.update(
            subject: subject,
            currentIntent: currentIntent,
            currentIntentIcon: currentIntentIcon,
            previousIntent: previousIntent,
            secondPreviousIntent: secondPreviousIntent,
            stepNumber: max(stepNumber, 1),
            costTotal: cost,
            pendingUserResponse: pendingUserResponse
        )
    }

    /// End the Live Activity with a completion summary.
    func end() {
        liveActivity.endActivity(completionSummary: subject)
    }

    private func permissionLiveActivityDetail(_ permission: OCPermissionRequest) -> String {
        let title = boundedDetail(permission.title)
        let description = boundedDetail(permission.description)

        switch (title, description) {
        case let (title?, description?) where title.caseInsensitiveCompare(description) != .orderedSame:
            return "\(title): \(description)"
        case (_, let description?):
            return description
        case (let title?, _):
            return title
        default:
            return OpenLensActivityAttributes.PendingUserResponse.Kind.permission.fallbackDetail
        }
    }

    private func questionLiveActivityDetail(_ question: OCQuestionRequest) -> String {
        if let prompt = boundedDetail(question.questions.first?.question) {
            return prompt
        }

        if let header = boundedDetail(question.questions.first?.header) {
            return header
        }

        return OpenLensActivityAttributes.PendingUserResponse.Kind.question.fallbackDetail
    }

    /// Builds a short value without scanning or trimming an unbounded server
    /// string on the UI actor. This is used defensively even though streamed
    /// prompts are admitted through bounded payload preparation.
    private func boundedDetail(_ text: String?) -> String? {
        guard let text else { return nil }

        var preview = ""
        preview.reserveCapacity(Self.maximumDetailCharacters + 1)
        var inspected = 0
        var started = false
        var truncated = false

        for character in text {
            guard inspected < Self.maximumInspectedDetailCharacters else {
                truncated = true
                break
            }
            inspected += 1

            if !started {
                guard !character.isWhitespace else { continue }
                started = true
            }

            guard preview.count < Self.maximumDetailCharacters else {
                truncated = true
                break
            }
            preview.append(character)
        }

        while let last = preview.last, last.isWhitespace {
            preview.removeLast()
        }

        guard !preview.isEmpty else { return nil }
        return truncated ? preview + "…" : preview
    }
}
