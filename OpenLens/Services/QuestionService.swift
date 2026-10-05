import Foundation

/// Pure service for question and permission interactions with the server.
/// No SwiftUI imports, no direct UI mutations.
final class QuestionService {

    private let connection: ConnectionManager

    init(connection: ConnectionManager) {
        self.connection = connection
    }

    // MARK: - Pending Questions

    /// Recover any pending (unanswered) questions for a given session.
    /// Returns the first matching question, or nil.
    func recoverPendingQuestion(sessionID: String) async throws -> OCQuestionRequest? {
        guard let client = connection.client else {
            throw OpenCodeError.notConnected
        }

        let pending = try await client.listPendingQuestions()
        return pending.first(where: { $0.sessionID == sessionID })
    }

    /// Recovers a pending v2 form after a stream gap or foreground return.
    func recoverPendingForm(sessionID: String) async throws -> OCFormRequest? {
        guard let client = connection.client else {
            throw OpenCodeError.notConnected
        }

        let pending = try await client.listPendingForms(sessionID: sessionID)
        return pending.first(where: { $0.sessionID == sessionID })
    }

    /// Recover any pending permission request for a given session.
    /// Returns the first matching permission, or nil.
    func recoverPendingPermission(sessionID: String? = nil) async throws -> OCPermissionRequest? {
        guard let client = connection.client else {
            throw OpenCodeError.notConnected
        }

        let pending = try await client.listPermissions(sessionID: sessionID)
        guard let sessionID else { return pending.first }
        return pending.first(where: { $0.sessionID == sessionID })
    }

    // MARK: - Reply to Question

    /// Send selected answers for a question.
    func respondToQuestion(requestID: String, answers: [[String]]) async throws {
        guard let client = connection.client else {
            throw OpenCodeError.notConnected
        }

        let _ = try await client.replyToQuestion(requestID: requestID, answers: answers)
    }

    // MARK: - Reject Question

    /// Dismiss/reject a question without answering.
    func rejectQuestion(requestID: String) async throws {
        guard let client = connection.client else {
            throw OpenCodeError.notConnected
        }

        let _ = try await client.rejectQuestion(requestID: requestID)
    }

    // MARK: - Form Response

    func respondToForm(_ form: OCFormRequest, answer: [String: OCFormValue]) async throws {
        guard InteractiveFormSafety.accepts(answer: answer, for: form) else {
            throw OpenCodeError.invalidPayload("The form reply does not satisfy the server-provided field constraints.")
        }
        guard let client = connection.client else {
            throw OpenCodeError.notConnected
        }

        try await client.replyToForm(
            sessionID: form.sessionID,
            formID: form.id,
            answer: answer
        )
    }

    func cancelForm(_ form: OCFormRequest) async throws {
        guard let client = connection.client else {
            throw OpenCodeError.notConnected
        }

        try await client.cancelForm(sessionID: form.sessionID, formID: form.id)
    }

    // MARK: - Permission Response

    /// Reply to a permission request using its server-owned session identity.
    func respondToPermission(_ permission: OCPermissionRequest, reply: OCPermissionReply) async throws {
        guard let client = connection.client else {
            throw OpenCodeError.notConnected
        }

        let _ = try await client.replyToPermission(
            sessionID: permission.sessionID,
            requestID: permission.id,
            reply: reply
        )
    }
}
