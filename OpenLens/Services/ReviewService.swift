import Foundation

final class ReviewService {

    private let connection: ConnectionManager

    init(connection: ConnectionManager) {
        self.connection = connection
    }

    func loadReview(sessionID: String) async throws -> SessionReviewSnapshot {
        if ScreenshotFixtures.isEnabled {
            return ScreenshotFixtures.reviewSnapshot(sessionID: sessionID)
        }

        guard let client = connection.client else {
            throw OpenCodeError.notConnected
        }

        async let messagesTask = client.listMessages(sessionID: sessionID)
        async let diffsTask = client.getSessionDiff(sessionID: sessionID)

        let (messages, diffs) = try await (messagesTask, diffsTask)

        let changeSets = try await loadChangeSets(sessionID: sessionID, messages: messages)

        return SessionReviewSnapshot(
            sessionID: sessionID,
            changeSets: changeSets,
            workingTree: diffs.map(ReviewFileChange.init(diff:))
        )
    }

    func revertChangeSet(sessionID: String, messageID: String) async throws {
        if ScreenshotFixtures.isEnabled {
            return
        }

        guard let client = connection.client else {
            throw OpenCodeError.notConnected
        }

        let _ = try await client.revertMessage(sessionID: sessionID, messageID: messageID)
    }

    private func loadChangeSets(sessionID: String, messages: [OCMessageWithParts]) async throws -> [ReviewChangeSet] {
        guard let client = connection.client else {
            throw OpenCodeError.notConnected
        }

        let candidateMessages = messages
            .filter { $0.info.role == .user }
            .sorted { lhs, rhs in
                (lhs.info.createdTimestamp ?? 0) > (rhs.info.createdTimestamp ?? 0)
            }

        var seenFingerprints = Set<String>()
        var changeSets: [ReviewChangeSet] = []

        for message in candidateMessages.prefix(20) {
            let diffs = try await client.getSessionDiff(sessionID: sessionID, messageID: message.id)
            let files = diffs.map(ReviewFileChange.init(diff:))

            guard !files.isEmpty else { continue }

            let fingerprint = makeFingerprint(files)
            guard seenFingerprints.insert(fingerprint).inserted else { continue }

            changeSets.append(
                ReviewChangeSet(
                    id: message.id,
                    title: changeSetTitle(for: message),
                    createdAt: message.info.createdTimestamp.map { Date(timeIntervalSince1970: $0) },
                    messagePreview: messagePreview(for: message),
                    files: files
                )
            )
        }

        return changeSets.sorted { lhs, rhs in
            switch (lhs.createdAt, rhs.createdAt) {
            case let (left?, right?): left > right
            case (.some, .none): true
            case (.none, .some): false
            case (.none, .none): lhs.title < rhs.title
            }
        }
    }

    private func changeSetTitle(for message: OCMessageWithParts) -> String {
        if let summaryTitle = message.info.summary?.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank {
            return summaryTitle
        }

        if let firstText = message.parts
            .compactMap(\ .text)
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty }) {
            return firstText
        }

        return "Change set"
    }

    private func messagePreview(for message: OCMessageWithParts) -> String? {
        message.parts
            .compactMap(\ .text)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }

    private func makeFingerprint(_ files: [ReviewFileChange]) -> String {
        files
            .sorted { $0.path < $1.path }
            .map { "\($0.path)|\($0.status)|\($0.additions)|\($0.deletions)" }
            .joined(separator: "#")
    }
}
