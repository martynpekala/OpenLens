import Foundation

struct InboxSnapshot: Sendable {
    let permissions: [OCPermissionRequest]
    let questions: [OCQuestionRequest]
    let forms: [OCFormRequest]
    /// A partial-load warning. Successful inbox sections remain actionable
    /// instead of being replaced with an all-or-nothing error state.
    let warning: String?

    init(
        permissions: [OCPermissionRequest],
        questions: [OCQuestionRequest],
        forms: [OCFormRequest],
        warning: String? = nil
    ) {
        self.permissions = permissions
        self.questions = questions
        self.forms = forms
        self.warning = warning
    }
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
        async let formsTask = loadForms(using: client)

        let permissionsResult = await permissionsTask
        let questionsResult = await questionsTask
        let formsResult = await formsTask

        let permissions = permissionsResult.value ?? []
        let questions = questionsResult.value ?? []
        let forms = formsResult.value ?? []
        let errors = [permissionsResult.error, questionsResult.error, formsResult.error]
            .compactMap { $0?.localizedDescription.nilIfBlank }

        if permissionsResult.error != nil,
           questionsResult.error != nil,
           formsResult.error != nil {
            throw OpenCodeError.invalidPayload(
                errors.joined(separator: "\n")
            )
        }

        return InboxSnapshot(
            permissions: permissions,
            questions: questions,
            forms: forms,
            warning: errors.isEmpty ? nil : errors.joined(separator: "\n")
        )
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

    private func loadForms(using client: OpenCodeClient) async -> InboxLoadResult<[OCFormRequest]> {
        do {
            return InboxLoadResult(value: try await client.listPendingForms(), error: nil)
        } catch {
            return InboxLoadResult(value: nil, error: error)
        }
    }

    func respondToPermission(_ permission: OCPermissionRequest, reply: OCPermissionReply) async throws {
        if ScreenshotFixtures.isEnabled {
            return
        }

        guard let client = connection.client else {
            throw OpenCodeError.notConnected
        }

        let _ = try await client.replyToPermission(
            sessionID: permission.sessionID,
            requestID: permission.id,
            reply: reply
        )
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

    func respondToForm(_ form: OCFormRequest, answer: [String: OCFormValue]) async throws {
        if ScreenshotFixtures.isEnabled {
            return
        }

        guard InteractiveFormSafety.accepts(answer: answer, for: form) else {
            throw OpenCodeError.invalidPayload("The form reply does not satisfy the server-provided field constraints.")
        }
        guard let client = connection.client else {
            throw OpenCodeError.notConnected
        }

        try await client.replyToForm(sessionID: form.sessionID, formID: form.id, answer: answer)
    }

    func cancelForm(_ form: OCFormRequest) async throws {
        if ScreenshotFixtures.isEnabled {
            return
        }

        guard let client = connection.client else {
            throw OpenCodeError.notConnected
        }

        try await client.cancelForm(sessionID: form.sessionID, formID: form.id)
    }
}

private struct InboxLoadResult<Value> {
    let value: Value?
    let error: Error?
}
