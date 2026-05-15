import Foundation

struct ChatStreamRecorder {
    enum Completion {
        case saved(RecordedChatReplay)
        case discardedEmpty
    }

    private let sessionID: String
    private let sessionTitle: String?
    private let projectName: String?
    private let branch: String?
    private let startedAt: Date

    private var hasObservedBusyStatus = false
    private var events: [RecordedChatReplay.EventEnvelope] = []

    init(
        sessionID: String,
        sessionTitle: String?,
        projectName: String?,
        branch: String?,
        startedAt: Date = .now
    ) {
        self.sessionID = sessionID
        self.sessionTitle = sessionTitle?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        self.projectName = projectName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        self.branch = branch?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        self.startedAt = startedAt
    }

    mutating func record(_ event: OCEvent, now: Date = .now) -> Completion? {
        guard event.isReplayRecordable, event.sessionID == sessionID else { return nil }

        if event.sessionStatusType == .busy {
            hasObservedBusyStatus = true
        }

        let offset = max(now.timeIntervalSince(startedAt), 0)
        events.append(
            RecordedChatReplay.EventEnvelope(
                id: events.count,
                offset: offset,
                event: event
            )
        )

        guard hasObservedBusyStatus, event.sessionStatusType == .idle else {
            return nil
        }

        return completion()
    }

    func stop() -> Completion {
        completion()
    }

    private func completion() -> Completion {
        guard hasObservedBusyStatus, !events.isEmpty else {
            return .discardedEmpty
        }

        return .saved(
            RecordedChatReplay(
                sessionID: sessionID,
                sessionTitle: sessionTitle,
                projectName: projectName,
                branch: branch,
                createdAt: startedAt,
                events: events
            )
        )
    }
}
