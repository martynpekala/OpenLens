import Foundation

/// Tracks the prompt the Live Activity shows for the session the chat is following. Progress is
/// shown with generic copy only, so the tracker mirrors just the pending permission, question, or
/// form. Other sessions keep their own activities: leaving a session detaches the tracker without
/// ending its activity, and `endActivity(sessionID:phase:)` finishes it once that session goes idle.
/// Pure value tracking — delegates actual ActivityKit calls to `LiveActivityManager`.
final class LiveActivityTracker {

    private static let maximumDetailCharacters = 180
    private static let maximumInspectedDetailCharacters = 512
    /// Live Activity buttons fit a few short answers; anything longer opens the app instead.
    private static let maximumQuickReplies = 4
    private static let maximumQuickReplyBytes = 64

    // MARK: - State

    private(set) var pendingUserResponse: OpenLensActivityAttributes.PendingUserResponse?
    /// Session whose activity this tracker drives, while attached.
    private(set) var sessionID: String?
    private(set) var isAttached = false
    /// Sessions left while their activity was running. Their activity ends once they go idle.
    private(set) var backgroundSessionIDs: Set<String> = []

    // MARK: - Dependency

    private let liveActivity: any LiveActivityProviding

    init(liveActivity: any LiveActivityProviding) {
        self.liveActivity = liveActivity
    }

    // MARK: - Lifecycle

    /// Start the Live Activity for a new turn. A prompt that is still pending carries over,
    /// since the chat only reports prompts when they change. A session whose turn is already
    /// shown keeps its activity.
    func start(session: OCSession?) {
        bind(sessionID: session?.id)
        liveActivity.startActivity(sessionID: session?.id, directory: session?.directory, title: session?.title)
        if pendingUserResponse != nil {
            pushCurrentState()
        }
    }

    /// Follow the activity of the session the chat opened, so its turn can end it even when the
    /// turn started while another session was open. The activity's prompt is replaced with the
    /// chat's, since a prompt may have been answered elsewhere while the session was not open.
    func attach(sessionID: String?) {
        guard !isAttached || self.sessionID != sessionID else { return }
        bind(sessionID: sessionID)
        pushCurrentState()
    }

    private func bind(sessionID: String?) {
        // A prompt reported while detached already belongs to the session being attached.
        if isAttached, self.sessionID != sessionID {
            leaveSession()
        }
        self.sessionID = sessionID
        isAttached = true
        if let sessionID {
            backgroundSessionIDs.remove(sessionID)
        }
    }

    /// Stop following the current session without ending its activity: it keeps running until
    /// that session goes idle. Prompts reported while detached are not published.
    func detach() {
        if isAttached {
            leaveSession()
        }
        isAttached = false
    }

    private func leaveSession() {
        if let sessionID, liveActivity.isActive(sessionID: sessionID) {
            backgroundSessionIDs.insert(sessionID)
        }
        sessionID = nil
        pendingUserResponse = nil
    }

    func hasActivity(sessionID: String) -> Bool {
        liveActivity.isActive(sessionID: sessionID)
    }

    func setPendingPermission(_ permission: OCPermissionRequest) {
        setPendingUserResponse(.init(
            kind: .permission,
            detail: permissionLiveActivityDetail(permission),
            requestID: permission.id,
            sessionID: permission.sessionID
        ))
    }

    func setPendingQuestion(_ question: OCQuestionRequest) {
        setPendingUserResponse(.init(
            kind: .question,
            detail: questionLiveActivityDetail(question),
            requestID: question.id,
            sessionID: question.sessionID,
            quickReplies: quickReplies(for: question)
        ))
    }

    func setPendingForm(_ form: OCFormRequest) {
        let quickAnswer = quickAnswer(for: form)
        setPendingUserResponse(.init(
            kind: .form,
            detail: formLiveActivityDetail(form),
            requestID: form.id,
            sessionID: form.sessionID,
            fieldKey: quickAnswer?.fieldKey,
            quickReplies: quickAnswer?.replies ?? []
        ))
    }

    func clearPendingUserResponse() {
        setPendingUserResponse(nil)
    }

    /// End the attached session's Live Activity, showing how the turn ended.
    func end(phase: OpenLensActivityAttributes.Phase = .finished) {
        guard isAttached else { return }
        liveActivity.endActivity(sessionID: sessionID, phase: phase)
    }

    /// Incomplete execution evidence must not publish a successful completion.
    func dismiss() {
        guard isAttached else { return }
        liveActivity.dismissImmediately(sessionID: sessionID)
    }

    /// End the activity of a session the chat is no longer following once its turn is over.
    /// A nil phase means the outcome is unknown, so the activity is dismissed instead.
    func endActivity(sessionID: String, phase: OpenLensActivityAttributes.Phase?) {
        guard !isAttached || self.sessionID != sessionID else { return }
        backgroundSessionIDs.remove(sessionID)
        if let phase {
            liveActivity.endActivity(sessionID: sessionID, phase: phase)
        } else {
            liveActivity.dismissImmediately(sessionID: sessionID)
        }
    }

    private func setPendingUserResponse(_ response: OpenLensActivityAttributes.PendingUserResponse?) {
        guard response != pendingUserResponse else { return }
        pendingUserResponse = response
        pushCurrentState()
    }

    private func pushCurrentState() {
        guard isAttached, liveActivity.isActive(sessionID: sessionID) else { return }
        liveActivity.update(sessionID: sessionID, pendingUserResponse: pendingUserResponse)
    }

    // MARK: - Prompt Details

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
            return "Allow or deny the request so the agent can continue."
        }
    }

    private func questionLiveActivityDetail(_ question: OCQuestionRequest) -> String {
        if let prompt = boundedDetail(question.questions.first?.question) {
            return prompt
        }

        if let header = boundedDetail(question.questions.first?.header) {
            return header
        }

        return "The agent needs an answer to continue."
    }

    private func formLiveActivityDetail(_ form: OCFormRequest) -> String {
        let field = form.fields.first { !$0.hidden }
        return boundedDetail(field?.title)
            ?? boundedDetail(field?.description)
            ?? boundedDetail(form.title)
            ?? "The agent needs an answer to continue."
    }

    // MARK: - Quick Replies

    /// Buttons for a single single-choice question. The v1 reply carries option labels, so a
    /// label that doesn't fit a button can't be offered at all.
    private func quickReplies(for question: OCQuestionRequest) -> [OpenLensActivityAttributes.QuickReply] {
        guard question.questions.count == 1,
              let info = question.questions.first,
              !info.multiple,
              (1...Self.maximumQuickReplies).contains(info.options.count)
        else { return [] }

        let labels = info.options.map(\.label)
        guard labels.allSatisfy(fitsQuickReply), Set(labels).count == labels.count else { return [] }
        return labels.map { .init(label: $0, value: .text($0)) }
    }

    /// Buttons for a form with one visible choice or yes/no field, kept only when every button
    /// is an answer the form accepts.
    private func quickAnswer(
        for form: OCFormRequest
    ) -> (fieldKey: String, replies: [OpenLensActivityAttributes.QuickReply])? {
        let visibleFields = form.fields.filter { !$0.hidden }
        guard visibleFields.count == 1, let field = visibleFields.first else { return nil }

        let candidates: [(reply: OpenLensActivityAttributes.QuickReply, value: OCFormValue)]
        switch field.kind {
        case .string:
            guard (1...Self.maximumQuickReplies).contains(field.options.count),
                  field.options.allSatisfy({ fitsQuickReply($0.value) })
            else { return nil }
            candidates = field.options.map { option in
                let label = option.label.trimmingCharacters(in: .whitespacesAndNewlines)
                return (.init(label: label.isEmpty ? option.value : label, value: .text(option.value)), .string(option.value))
            }
        case .boolean:
            candidates = [
                (.init(label: "No", value: .flag(false)), .boolean(false)),
                (.init(label: "Yes", value: .flag(true)), .boolean(true)),
            ]
        default:
            return nil
        }

        let labels = candidates.map(\.reply.label)
        guard Set(labels).count == labels.count,
              candidates.allSatisfy({ candidate in
                  fitsQuickReply(candidate.reply.label)
                      && InteractiveFormSafety.accepts(answer: [field.key: candidate.value], for: form)
              })
        else { return nil }

        return (field.key, candidates.map(\.reply))
    }

    private func fitsQuickReply(_ text: String) -> Bool {
        text.utf8.count <= Self.maximumQuickReplyBytes
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
