import Foundation

struct InboxSnapshot: Sendable {
    let permissions: [OCPermissionRequest]
    let questions: [OCQuestionRequest]
    let forms: [OCFormRequest]
    var globalForms: [OCFormRequest] { forms.filter(\.isGlobal) }
    var sessionForms: [OCFormRequest] { forms.filter { !$0.isGlobal } }
    var pendingRequestCount: Int { permissions.count + questions.count + forms.count }
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

@MainActor
final class InboxService {

    private let connection: ConnectionManager
    private var formsClient: OpenCodeClient?
    private var globalFormsByDirectory: [String: [OCFormRequest]] = [:]
    private var formsLoadTask: Task<InboxLoadResult<[OCFormRequest]>, Never>?
    private var formsLoadDirectory: String?
    private var formsRevision: UInt = 0
    private var formsLoadRevision: UInt?
    private var formsLoadID: UInt = 0

    init(connection: ConnectionManager) {
        self.connection = connection
    }

    func loadInbox() async throws -> InboxSnapshot {
        if ScreenshotFixtures.isEnabled {
            return ScreenshotFixtures.inboxSnapshot
        }

        guard let client = connection.client else {
            formsClient = nil
            globalFormsByDirectory = [:]
            formsLoadTask = nil
            throw OpenCodeError.notConnected
        }

        async let permissionsTask = loadPermissions(using: client)
        async let questionsTask = loadQuestions(using: client)
        async let formsTask = loadForms(using: client)

        let permissionsResult = await permissionsTask
        let questionsResult = await questionsTask
        var formsResult = await formsTask
        // Permissions may finish after the form read. Revalidate its revision
        // at publication as well as when the shared form task completes.
        while let revision = formsResult.formsRevision, revision != formsRevision {
            formsResult = await loadForms(using: client)
        }
        guard connection.client === client else { throw OpenCodeError.notConnected }

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
        guard connection.client === client else {
            return InboxLoadResult(value: nil, error: OpenCodeError.notConnected)
        }
        if formsClient !== client {
            formsClient = client
            globalFormsByDirectory = [:]
            formsLoadTask = nil
            formsRevision &+= 1
        }
        // Share reads only within a revision. A successful reply/cancel starts
        // a new revision, whose loads cannot join or publish the older read.
        while true {
            let activeDirectory = await client.currentContextDirectory()
            guard formsClient === client, connection.client === client else {
                return InboxLoadResult(value: nil, error: OpenCodeError.notConnected)
            }
            let revision = formsRevision
            let task: Task<InboxLoadResult<[OCFormRequest]>, Never>
            let loadedDirectory: String?
            if let sharedTask = formsLoadTask, formsLoadRevision == revision {
                task = sharedTask
                loadedDirectory = formsLoadDirectory
            } else {
                task = Task { await recoverForms(using: client, activeDirectory: activeDirectory, revision: revision) }
                formsLoadTask = task
                formsLoadDirectory = activeDirectory
                formsLoadRevision = revision
                formsLoadID &+= 1
                loadedDirectory = activeDirectory
            }
            let loadID = formsLoadID
            let result = await task.value
            guard formsClient === client, connection.client === client else {
                return InboxLoadResult(value: nil, error: OpenCodeError.notConnected)
            }
            guard formsRevision == revision else { continue }
            // An old caller must not clear a newer workspace's shared task.
            if formsLoadID == loadID {
                formsLoadTask = nil
                formsLoadDirectory = nil
                formsLoadRevision = nil
            }
            if await client.currentContextDirectory() != loadedDirectory {
                continue
            }
            guard formsRevision == revision else { continue }
            return result
        }
    }

    private func recoverForms(using client: OpenCodeClient, activeDirectory: String?, revision: UInt) async -> InboxLoadResult<[OCFormRequest]> {
        guard formsClient === client, connection.client === client, formsRevision == revision else {
            return InboxLoadResult(value: nil, error: nil, formsRevision: revision)
        }
        for directory in connection.takeGlobalFormRecoveryDirectories(using: client) {
            // An empty cache entry is a location to probe, not a fabricated form.
            if globalFormsByDirectory[directory] == nil { globalFormsByDirectory[directory] = [] }
        }
        let rememberedDirectories = globalFormsByDirectory.keys.sorted()
        var currentForms: [OCFormRequest] = []
        var errors: [String] = []
        let directories: [String?] = [activeDirectory] + rememberedDirectories.filter { $0 != activeDirectory }.map(Optional.some)
        for (index, directory) in directories.enumerated() {
            do {
                let recovered = try await client.listPendingForms(directory: directory)
                guard formsClient === client, connection.client === client else {
                    return InboxLoadResult(value: nil, error: OpenCodeError.notConnected)
                }
                guard formsRevision == revision else {
                    return InboxLoadResult(value: nil, error: nil, formsRevision: revision)
                }
                // A successful read is authoritative even if ordinary forms
                // remain. Never carry another workspace's session forms over.
                if let directory { globalFormsByDirectory.removeValue(forKey: directory) }
                var resolvedDirectories = Set<String>()
                for form in recovered where form.isGlobal {
                    guard let resolved = form.globalDirectory,
                          InteractiveFormSafety.fitsGlobalDirectory(resolved) else { continue }
                    if resolvedDirectories.insert(resolved).inserted {
                        globalFormsByDirectory[resolved] = []
                    }
                    if !globalFormsByDirectory[resolved, default: []].contains(where: { $0.id == form.id }) {
                        globalFormsByDirectory[resolved, default: []].append(form)
                    }
                }
                if index == 0 { currentForms = recovered }
            } catch {
                guard formsClient === client, connection.client === client else {
                    return InboxLoadResult(value: nil, error: OpenCodeError.notConnected)
                }
                guard formsRevision == revision else {
                    return InboxLoadResult(value: nil, error: nil, formsRevision: revision)
                }
                // A failed read cannot prove settlement. Keep the last known
                // global interactions reachable and expose a retry warning.
                errors.append(error.localizedDescription)
            }
        }
        var forms: [OCFormRequest] = []
        var identities = Set<OCFormRequest.Identity>()
        for form in currentForms where identities.insert(form.identity).inserted {
            forms.append(form)
        }
        for directory in globalFormsByDirectory.keys.sorted() {
            for form in globalFormsByDirectory[directory] ?? [] {
                if identities.insert(form.identity).inserted {
                    forms.append(form)
                }
            }
        }
        return InboxLoadResult(value: forms,
            error: errors.isEmpty ? nil : OpenCodeError.invalidPayload(errors.joined(separator: "\n")), formsRevision: revision)
    }

    func respondToPermission(
        _ permission: OCPermissionRequest,
        reply: OCPermissionReply,
        message: String? = nil
    ) async throws {
        if ScreenshotFixtures.isEnabled {
            return
        }

        guard let client = connection.client else {
            throw OpenCodeError.notConnected
        }

        let _ = try await client.replyToPermission(
            sessionID: permission.sessionID,
            requestID: permission.id,
            reply: reply,
            message: message
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

        guard let answer = InteractiveFormSafety.submissionAnswer(answer, for: form) else {
            throw OpenCodeError.invalidPayload("The form reply does not satisfy the server-provided field constraints.")
        }
        guard let client = connection.client else {
            throw OpenCodeError.notConnected
        }

        try await client.replyToForm(owner: form.owner, formID: form.id, answer: answer)
        resolvedForm(form, using: client)
    }

    func cancelForm(_ form: OCFormRequest) async throws {
        if ScreenshotFixtures.isEnabled {
            return
        }

        guard let client = connection.client else {
            throw OpenCodeError.notConnected
        }

        try await client.cancelForm(owner: form.owner, formID: form.id)
        resolvedForm(form, using: client)
    }

    private func resolvedForm(_ form: OCFormRequest, using client: OpenCodeClient) {
        guard connection.client === client else { return }
        formsRevision &+= 1
        formsLoadTask = nil
        formsLoadDirectory = nil
        formsLoadRevision = nil
        for directory in globalFormsByDirectory.keys {
            globalFormsByDirectory[directory]?.removeAll { $0.identity == form.identity }
        }
    }
}

private struct InboxLoadResult<Value> {
    let value: Value?
    let error: Error?
    var formsRevision: UInt? = nil
}
