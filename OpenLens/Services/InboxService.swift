import Foundation

struct InboxSnapshot: Sendable {
    let permissions: [OCPermissionRequest]
    let questions: [OCQuestionRequest]
}

final class InboxService {

    private let connection: ConnectionManager

    init(connection: ConnectionManager) {
        self.connection = connection
    }

    func loadInbox() async throws -> InboxSnapshot {
        if ScreenshotFixtures.isEnabled {
            return ScreenshotFixtures.inboxSnapshot
        }

        guard let client = connection.client else {
            throw OpenCodeError.notConnected
        }

        async let permissionsTask = loadPermissions(using: client)
        async let questionsTask = loadQuestions(using: client)

        let permissionsResult = await permissionsTask
        let questionsResult = await questionsTask

        let permissions = permissionsResult.value ?? []
        let questions = questionsResult.value ?? []

        if let permissionsError = permissionsResult.error,
           let questionsError = questionsResult.error {
            throw OpenCodeError.invalidPayload(
                [permissionsError.localizedDescription, questionsError.localizedDescription]
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
            )
        }

        return InboxSnapshot(permissions: permissions, questions: questions)
    }

    private func loadPermissions(using client: OpenCodeClient) async -> InboxLoadResult<[OCPermissionRequest]> {
        do {
            return InboxLoadResult(value: try await client.listPermissions(), error: nil)
        } catch {
            return InboxLoadResult(value: nil, error: error)
        }
    }

    private func loadQuestions(using client: OpenCodeClient) async -> InboxLoadResult<[OCQuestionRequest]> {
        do {
            return InboxLoadResult(value: try await client.listPendingQuestions(), error: nil)
        } catch {
            return InboxLoadResult(value: nil, error: error)
        }
    }

    func respondToPermission(requestID: String, reply: OCPermissionReply) async throws {
        if ScreenshotFixtures.isEnabled {
            return
        }

        guard let client = connection.client else {
            throw OpenCodeError.notConnected
        }

        let _ = try await client.replyToPermission(requestID: requestID, reply: reply)
    }

    func respondToQuestion(requestID: String, answers: [[String]]) async throws {
        if ScreenshotFixtures.isEnabled {
            return
        }

        guard let client = connection.client else {
            throw OpenCodeError.notConnected
        }

        let _ = try await client.replyToQuestion(requestID: requestID, answers: answers)
    }

    func rejectQuestion(requestID: String) async throws {
        if ScreenshotFixtures.isEnabled {
            return
        }

        guard let client = connection.client else {
            throw OpenCodeError.notConnected
        }

        let _ = try await client.rejectQuestion(requestID: requestID)
    }
}

private struct InboxLoadResult<Value> {
    let value: Value?
    let error: Error?
}
