import Foundation
import os

/// HTTP REST client for the OpenCode server API.
/// All methods are async and throw on network/decode errors.
actor OpenCodeClient {

    private let transport: any OpenCodeTransport
    private static let maximumPendingPromptCount = 24
    private static let v2PageSize = 100
    private var baseURL: URL
    private var authHeader: String?
    private var contextDirectory: String?
    private(set) var capabilities: OpenCodeServerCapabilities?

    init(
        baseURL: URL,
        authHeader: String? = nil,
        contextDirectory: String? = nil,
        transport: (any OpenCodeTransport)? = nil
    ) {
        self.baseURL = baseURL
        self.authHeader = authHeader
        self.contextDirectory = contextDirectory?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        self.transport = transport ?? DirectOpenCodeTransport()
        self.capabilities = nil
    }

    func updateConnection(baseURL: URL, authHeader: String?, contextDirectory: String? = nil) {
        self.baseURL = baseURL
        self.authHeader = authHeader
        self.contextDirectory = contextDirectory?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        self.capabilities = nil
    }

    func updateContextDirectory(_ directory: String?) {
        self.contextDirectory = directory?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
    }

    func currentContextDirectory() -> String? {
        contextDirectory
    }

    // MARK: - Health

    func checkHealth() async throws -> OCHealthResponse {
        try await get("/global/health")
    }

    /// Negotiate the wire protocol from endpoint capability evidence.
    ///
    /// A successful, usable `/api/info` response selects v2. A missing v2
    /// capability endpoint selects the legacy v1 health contract. Other
    /// failures are surfaced as compatibility or connectivity failures instead
    /// of being hidden by an unsafe downgrade.
    func probeCapabilities() async throws -> OpenCodeServerCapabilities {
        do {
            let info: OCV2ServerInfo = try await getV2(
                "/api/info",
                includesLocation: false
            )
            guard info.isUsable else {
                throw OpenCodeError.invalidPayload("The v2 server-info response did not contain a usable version.")
            }

            let capabilities = OpenCodeServerCapabilities.v2(info)
            self.capabilities = capabilities
            return capabilities
        } catch {
            guard shouldFallbackToV1(afterV2ProbeError: error) else {
                throw error
            }

            let health = try await checkHealth()
            let capabilities = OpenCodeServerCapabilities.v1(health)
            self.capabilities = capabilities
            return capabilities
        }
    }

    // MARK: - Sessions

    func listSessions() async throws -> [OCSession] {
        if usesV2 {
            return try await getAllV2Pages(
                endpoint: "/api/session",
                order: "desc"
            )
        }
        return try await get("/session")
    }

    func getSession(id: String) async throws -> OCSession {
        if usesV2 {
            let response: OCV2Envelope<OCSession> = try await getV2(
                "/api/session",
                pathParameter: id,
                includesLocation: false
            )
            return response.data
        }
        return try await get("/session/\(id)")
    }

    func createSession(title: String? = nil, parentID: String? = nil) async throws -> OCSession {
        if usesV2 {
            // V2 session creation is location-scoped and returns its session
            // in the standard data envelope. Supplying an ID also lets us
            // recover the canonical session if a compatible server returns
            // only a no-content acknowledgement. Parent sessions are a legacy
            // creation concern and are not part of the v2 create contract.
            let sessionID = "ses_\(UUID().uuidString)"
            var body = ["id": sessionID]
            if let title { body["title"] = title }
            let data = try await sendV2RequestData(
                method: "POST",
                path: "/api/session",
                body: body
            )
            guard !data.isEmpty else {
                return try await getSession(id: sessionID)
            }
            let response: OCV2Envelope<OCSession> = try decode(data)
            return response.data
        }

        var body: [String: Any] = [:]
        if let title { body["title"] = title }
        if let parentID { body["parentID"] = parentID }
        return try await post("/session", body: body)
    }

    func deleteSession(id: String) async throws -> Bool {
        if usesV2 {
            try await sendV2RequestDiscardingResponse(
                method: "DELETE",
                path: "/api/session",
                pathParameter: id,
                includesLocation: false
            )
            return true
        }
        return try await delete("/session/\(id)")
    }

    func updateSession(id: String, title: String) async throws -> OCSession {
        if usesV2 {
            // V2 acknowledges this mutation with 204. Fetch the canonical
            // session afterwards so callers can immediately refresh their UI.
            try await sendV2RequestDiscardingResponse(
                method: "PATCH",
                path: "/api/session",
                pathParameter: id,
                body: ["title": title],
                includesLocation: false
            )
            return try await getSession(id: id)
        }
        return try await patch("/session/\(id)", body: ["title": title])
    }

    func getSessionStatus() async throws -> [String: OCSessionStatus] {
        if usesV2 {
            let response: OCV2Envelope<[String: OCV2ActiveSession]> = try await getV2(
                "/api/session/active",
                includesLocation: false
            )
            return Dictionary(
                uniqueKeysWithValues: response.data.keys.map {
                    (
                        $0,
                        OCSessionStatus(type: .busy, attempt: nil, message: nil, next: nil)
                    )
                }
            )
        }
        return try await get("/session/status")
    }

    func abortSession(id: String) async throws -> Bool {
        if usesV2 {
            let response: OCV2InterruptResponse = try await sendV2Request(
                method: "POST",
                path: "/api/session/\(id)/interrupt",
                includesLocation: false
            )
            return response.interrupted
        }
        return try await post("/session/\(id)/abort", body: [:] as [String: String])
    }

    // MARK: - Messages

    func listMessages(sessionID: String, limit: Int? = nil) async throws -> [OCMessageWithParts] {
        if usesV2 {
            let messages: [OCV2SessionMessage] = try await getAllV2Pages(
                endpoint: "/api/session/\(sessionID)/message",
                limit: limit ?? Self.v2PageSize,
                order: "asc",
                includesLocation: false
            )
            return messages.compactMap { $0.asMessage(sessionID: sessionID) }
        }
        var path = "/session/\(sessionID)/message"
        if let limit { path += "?limit=\(limit)" }
        return try await get(path)
    }

    func getMessage(sessionID: String, messageID: String) async throws -> OCMessageWithParts {
        if usesV2 {
            let response: OCV2Envelope<OCV2SessionMessage> = try await getV2(
                "/api/session/\(sessionID)/message",
                pathParameter: messageID,
                includesLocation: false
            )
            guard let message = response.data.asMessage(sessionID: sessionID) else {
                throw OpenCodeError.invalidPayload("The v2 response did not contain a supported chat message.")
            }
            return message
        }
        return try await get("/session/\(sessionID)/message/\(messageID)")
    }

    // MARK: - Todos

    func listTodos(sessionID: String) async throws -> TodoDisplaySnapshot {
        guard supports(.todos) else {
            return TodoDisplaySafety.prepare([])
        }
        let todos: [OCTodo] = try await get("/session/\(sessionID)/todo")
        return TodoDisplaySafety.prepare(todos)
    }

    /// Send a prompt asynchronously (fire and forget, monitor via SSE).
    func sendPromptAsync(
        sessionID: String,
        text: String,
        model: OCPromptInput.OCModelRef? = nil,
        agent: String? = nil,
        variant: String? = nil,
        messageID: String? = nil
    ) async throws {
        if usesV2 {
            // v2 records selection changes as session mutations. They must be
            // accepted before the prompt is admitted, otherwise the runner may
            // begin this turn with the previous selection.
            try await applyV2PromptSelection(
                sessionID: sessionID,
                model: model,
                agent: agent,
                variant: variant
            )

            try await sendV2RequestDiscardingResponse(
                method: "POST",
                path: "/api/session/\(sessionID)/prompt",
                body: OCV2PromptInput(id: messageID, text: text, delivery: .steer),
                includesLocation: false
            )
            return
        }

        let part = OCPromptPart(type: "text", text: text)
        let input = OCPromptInput(parts: [part], model: model, agent: agent, messageID: nil, variant: variant)
        let _: EmptyResponse = try await postCodable("/session/\(sessionID)/prompt_async", body: input, expect204: true)
    }

    /// Admit a prompt behind the active session turn without interrupting it.
    /// The scheduler responds with admission metadata. The chat only needs the
    /// successful admission signal, so its response body is intentionally ignored.
    func queuePrompt(
        sessionID: String,
        text: String,
        model: OCPromptInput.OCModelRef? = nil,
        agent: String? = nil,
        variant: String? = nil,
        messageID: String? = nil
    ) async throws {
        if usesV2 {
            try await applyV2PromptSelection(
                sessionID: sessionID,
                model: model,
                agent: agent,
                variant: variant
            )
            try await sendV2RequestDiscardingResponse(
                method: "POST",
                path: "/api/session/\(sessionID)/prompt",
                body: OCV2PromptInput(id: messageID, text: text, delivery: .queue),
                includesLocation: false
            )
            return
        }

        let input = OCQueuedPromptInput(
            prompt: .init(text: text),
            delivery: .queue
        )
        try await postDiscardingResponse("/api/session/\(sessionID)/prompt", body: input)
    }

    /// Send a prompt synchronously (blocks until response is complete).
    func sendPrompt(
        sessionID: String,
        text: String,
        model: OCPromptInput.OCModelRef? = nil,
        agent: String? = nil,
        variant: String? = nil
    ) async throws -> OCMessageWithParts {
        guard supports(.synchronousPrompt) else {
            throw OpenCodeError.invalidPayload("Synchronous prompts are not available on this v2 OpenCode server.")
        }
        let part = OCPromptPart(type: "text", text: text)
        let input = OCPromptInput(parts: [part], model: model, agent: agent, messageID: nil, variant: variant)
        return try await postCodable("/session/\(sessionID)/message", body: input)
    }

    // MARK: - Providers

    func listProviders() async throws -> OCProviderResponse {
        if usesV2 {
            let modelsResponse: OCV2Located<[OCV2ModelInfo]> = try await getV2Located("/api/model")
            let defaultResponse: OCV2Located<OCV2ModelInfo>? = try? await getV2Located("/api/model/default")
            let providersResponse: OCV2Located<[OCV2ProviderInfo]>? = try? await getV2Located("/api/provider")
            let providerNames = Dictionary(
                uniqueKeysWithValues: (providersResponse?.data ?? []).map { ($0.id, $0.name?.nilIfBlank ?? $0.id) }
            )
            let providers = Dictionary(grouping: modelsResponse.data, by: \.providerID)
                .map { providerID, models in
                    OCProvider(
                        id: providerID,
                        name: providerNames[providerID] ?? providerID,
                        models: Dictionary(
                            uniqueKeysWithValues: models.map { model in
                                (
                                    model.id,
                                    OCProviderModel(
                                        id: model.id,
                                        legacyModelID: model.modelID == model.id ? nil : model.modelID,
                                        name: model.name ?? model.id,
                                        attachment: model.capabilities?.attachment,
                                        reasoning: model.capabilities?.reasoning,
                                        toolCall: model.capabilities?.toolCall,
                                        limit: model.limit,
                                        variants: model.variants
                                    )
                                )
                            }
                        )
                    )
                }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            return OCProviderResponse(
                all: providers,
                default: defaultResponse.map {
                    ["id": $0.data.providerID, "model": $0.data.id]
                },
                connected: nil
            )
        }
        return try await get("/provider")
    }

    /// Fetch raw JSON from /provider for debugging decode issues.
    func listProvidersRaw() async throws -> Data {
        let request = makeRequest(path: "/provider", method: "GET")
        let (data, response) = try await transport.data(for: request)
        try validateResponse(response, data: data)
        return data
    }

    // MARK: - Config

    func getConfig() async throws -> OCConfig {
        guard !usesV2 else {
            return OCConfig(model: nil, provider: nil, enabledProviders: nil, disabledProviders: nil)
        }
        return try await get("/config")
    }

    // MARK: - Agents

    func listAgents() async throws -> [OCAgent] {
        if usesV2 {
            let response: OCV2Located<[OCAgent]> = try await getV2Located("/api/agent")
            return response.data
        }
        return try await get("/agent")
    }

    // MARK: - Commands

    func listCommands() async throws -> [OCCommand] {
        if usesV2 {
            let response: OCV2Located<[OCCommand]> = try await getV2Located("/api/command")
            return response.data
        }
        return try await get("/command")
    }

    func sendCommand(
        sessionID: String,
        command: String,
        arguments: String,
        model: OCPromptInput.OCModelRef? = nil,
        agent: String? = nil,
        variant: String? = nil,
        files: [String] = [],
        agents: [String] = [],
        skills: [String] = [],
        delivery: OCV2PromptInput.Delivery = .steer
    ) async throws {
        if usesV2 {
            try await applyV2PromptSelection(
                sessionID: sessionID,
                model: model,
                agent: agent,
                variant: variant
            )
            try await sendV2RequestDiscardingResponse(
                method: "POST",
                path: "/api/session/\(sessionID)/command",
                body: OCV2CommandInput(
                    name: command,
                    text: arguments,
                    files: files,
                    agents: agents,
                    skills: skills,
                    delivery: delivery
                ),
                includesLocation: false
            )
            return
        }

        var body: [String: Any] = [
            "command": command,
            "arguments": arguments,
        ]

        if let model {
            body["model"] = "\(model.providerID)/\(model.modelID)"
        }
        if let agent, !agent.isEmpty {
            body["agent"] = agent
        }
        if let variant, !variant.isEmpty {
            body["variant"] = variant
        }

        let _: OCMessageWithParts = try await post("/session/\(sessionID)/command", body: body)
    }

    // MARK: - Files

    func listFiles(path: String? = nil) async throws -> [OCWorkspaceFileEntry] {
        if usesV2 {
            let response: OCV2Located<[OCV2FileSystemEntry]> = try await getV2Located(
                "/api/fs/list",
                path: path
            )
            return response.data.map { entry in
                OCWorkspaceFileEntry(
                    name: (entry.path as NSString).lastPathComponent,
                    path: entry.path,
                    absolute: nil,
                    type: entry.type,
                    ignored: false
                )
            }
        }

        var urlPath = "/file"
        if let path { urlPath += "?path=\(path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? path)" }
        return try await get(urlPath)
    }

    func listFileStatus() async throws -> [OCWorkspaceFileStatus] {
        if usesV2 {
            let response: OCV2Located<[OCV2VCSFileStatus]> = try await getV2Located("/api/vcs/status")
            return response.data.map {
                OCWorkspaceFileStatus(
                    path: $0.file,
                    added: $0.additions,
                    removed: $0.deletions,
                    status: $0.status
                )
            }
        }

        return try await get("/file/status")
    }

    func readFileContent(path: String) async throws -> OCFileContent {
        if usesV2 {
            return try await readV2FileContent(path: path)
        }

        let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? path
        return try await get("/file/content?path=\(encodedPath)")
    }

    // MARK: - Project

    func listProjects() async throws -> [OCProject] {
        if usesV2 {
            return try await getV2("/api/project")
        }

        return try await get("/project")
    }

    func getCurrentProject() async throws -> OCProject {
        if usesV2 {
            let location: OCV2LocationInfo = try await getV2("/api/location")
            contextDirectory = location.directory
            guard let project = location.project else {
                throw OpenCodeError.invalidPayload("The v2 location response did not contain a project.")
            }
            return OCProject(id: project.id, worktree: project.directory)
        }

        return try await get("/project/current")
    }

    func getPath() async throws -> OCPathInfo {
        if usesV2 {
            let location: OCV2LocationInfo = try await getV2("/api/location")
            contextDirectory = location.directory
            return OCPathInfo(
                state: nil,
                config: nil,
                worktree: location.project?.directory ?? location.directory,
                directory: location.directory
            )
        }

        return try await get("/path")
    }

    func getVCS() async throws -> OCVCSInfo {
        if usesV2 {
            let response: OCV2Located<OCVCSInfo> = try await getV2Located("/api/vcs")
            return response.data
        }

        return try await get("/vcs")
    }

    func getWorkingTreeDiff() async throws -> [OCFileDiff] {
        guard usesV2 else { return [] }
        let response: OCV2Located<[OCFileDiff]> = try await getV2Located(
            "/api/vcs/diff",
            queryItems: [
                URLQueryItem(name: "mode", value: "working"),
                URLQueryItem(name: "format", value: "json")
            ]
        )
        return response.data
    }

    // MARK: - Diffs

    func getSessionDiff(sessionID: String, messageID: String? = nil) async throws -> [OCFileDiff] {
        if usesV2 {
            // V2 names the selected user-turn boundary `from`; v1 keeps its
            // legacy `messageID` query parameter below.
            let queryItems = messageID.map { [URLQueryItem(name: "from", value: $0)] } ?? []
            let response: OCV2Located<[OCFileDiff]> = try await getV2Located(
                "/api/session/\(sessionID)/diff",
                queryItems: queryItems
            )
            return response.data
        }

        var path = "/session/\(sessionID)/diff"
        if let messageID { path += "?messageID=\(messageID)" }
        return try await get(path)
    }

    // MARK: - Permissions

    func listPermissions(sessionID: String? = nil) async throws -> [OCPermissionRequest] {
        let requests: [OCPermissionRequest]
        if usesV2 {
            if let sessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank {
                let response: OCV2Envelope<[OCPermissionRequest]> = try await getV2(
                    "/api/session/\(sessionID)/permission",
                    includesLocation: false
                )
                requests = response.data.map { $0.assigned(toSessionID: sessionID) }
            } else {
                let response: OCV2Located<[OCPermissionRequest]> = try await getV2Located(
                    "/api/permission/request"
                )
                requests = response.data
            }
        } else {
            requests = try await get("/permission")
        }
        return sanitizedPermissions(requests)
    }

    func replyToPermission(
        sessionID: String?,
        requestID: String,
        reply: OCPermissionReply
    ) async throws -> Bool {
        if usesV2 {
            guard let sessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank else {
                throw OpenCodeError.invalidPayload("A session ID is required to reply to a v2 permission request.")
            }
            try await sendV2RequestDiscardingResponse(
                method: "POST",
                path: "/api/session/\(sessionID)/permission/\(requestID)/reply",
                body: OCV2PermissionReplyInput(reply: reply),
                includesLocation: false
            )
            return true
        }

        return try await post("/permission/\(requestID)/reply", body: [
            "reply": reply.rawValue,
        ] as [String: Any])
    }

    private func sanitizedPermissions(_ requests: [OCPermissionRequest]) -> [OCPermissionRequest] {
        var safeRequests: [OCPermissionRequest] = []
        safeRequests.reserveCapacity(min(requests.count, Self.maximumPendingPromptCount))

        for request in requests {
            guard let sanitized = PermissionRequestDisplaySafety.sanitize(request) else {
                continue
            }
            safeRequests.append(sanitized)
            if safeRequests.count == Self.maximumPendingPromptCount {
                break
            }
        }

        return safeRequests
    }

    // MARK: - Questions

    /// Fetch any pending (unanswered) questions from the server.
    /// Used after reconnection to recover questions that arrived while disconnected.
    func listPendingQuestions() async throws -> [OCQuestionRequest] {
        // V2 replaces question operations with typed forms. Never fall through
        // to a legacy route once capability negotiation selected v2.
        guard !usesV2 else { return [] }

        let requests: [OCQuestionRequest] = try await get("/question")
        var safeRequests: [OCQuestionRequest] = []
        safeRequests.reserveCapacity(min(requests.count, Self.maximumPendingPromptCount))

        for request in requests where InteractiveQuestionSafety.accepts(request) {
            safeRequests.append(request)
            if safeRequests.count == Self.maximumPendingPromptCount {
                break
            }
        }

        return safeRequests
    }

    /// Reply to a question request with selected answers.
    /// Each element in `answers` is an array of selected option labels for the corresponding question.
    func replyToQuestion(requestID: String, answers: [[String]]) async throws -> Bool {
        guard !usesV2 else {
            throw OpenCodeError.invalidPayload("V2 servers use form replies instead of legacy question replies.")
        }

        let reply = OCQuestionReply(answers: answers)
        return try await postCodable("/question/\(requestID)/reply", body: reply)
    }

    /// Reject/dismiss a question request.
    func rejectQuestion(requestID: String) async throws -> Bool {
        guard !usesV2 else {
            throw OpenCodeError.invalidPayload("V2 servers use form cancellation instead of legacy question rejection.")
        }

        return try await post(
            "/question/\(requestID)/reject",
            body: [:] as [String: String]
        )
    }

    // MARK: - Forms

    /// Fetches pending v2 forms. Session-scoped reads preserve the owning
    /// session without accepting a caller-supplied location; inbox reads use
    /// the active location and receive the server-owned session identities.
    func listPendingForms(sessionID: String? = nil) async throws -> [OCFormRequest] {
        guard usesV2 else { return [] }

        let forms: [OCFormRequest]
        if let sessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank {
            guard InteractiveFormSafety.fitsIdentifier(sessionID) else {
                throw OpenCodeError.invalidPayload("A valid session ID is required to recover v2 forms.")
            }
            let response: OCV2Envelope<[OCFormRequest]> = try await getV2(
                "/api/session/\(sessionID)/form",
                includesLocation: false
            )
            forms = response.data.map { form in
                form.sessionID.isEmpty
                    ? OCFormRequest(
                        id: form.id,
                        sessionID: sessionID,
                        title: form.title,
                        fields: form.fields,
                        state: form.state
                    )
                    : form
            }
        } else {
            let response: OCV2Located<[OCFormRequest]> = try await getV2Located("/api/form")
            forms = response.data
        }

        var safeForms: [OCFormRequest] = []
        safeForms.reserveCapacity(min(forms.count, Self.maximumPendingPromptCount))
        for form in forms {
            guard let form = InteractiveFormSafety.sanitize(form) else { continue }
            safeForms.append(form)
            if safeForms.count == Self.maximumPendingPromptCount {
                break
            }
        }
        return safeForms
    }

    func replyToForm(
        sessionID: String,
        formID: String,
        answer: [String: OCFormValue]
    ) async throws {
        guard usesV2 else {
            throw OpenCodeError.invalidPayload("Form replies require a v2 server.")
        }
        guard InteractiveFormSafety.fitsIdentifier(sessionID),
              InteractiveFormSafety.fitsIdentifier(formID)
        else {
            throw OpenCodeError.invalidPayload("A valid session and form ID are required to reply to a v2 form.")
        }

        try await sendV2RequestDiscardingResponse(
            method: "POST",
            path: "/api/session/\(sessionID)/form/\(formID)/reply",
            body: OCV2FormReplyInput(answer: answer),
            includesLocation: false
        )
    }

    func cancelForm(sessionID: String, formID: String) async throws {
        guard usesV2 else {
            throw OpenCodeError.invalidPayload("Form cancellation requires a v2 server.")
        }
        guard InteractiveFormSafety.fitsIdentifier(sessionID),
              InteractiveFormSafety.fitsIdentifier(formID)
        else {
            throw OpenCodeError.invalidPayload("A valid session and form ID are required to cancel a v2 form.")
        }

        try await sendV2RequestDiscardingResponse(
            method: "DELETE",
            path: "/api/session/\(sessionID)/form/\(formID)",
            includesLocation: false
        )
    }

    // MARK: - Session actions

    func shareSession(id: String) async throws -> OCSession {
        guard supports(.sessionSharing) else {
            throw OpenCodeError.invalidPayload("Session sharing is not available on this v2 OpenCode server.")
        }
        return try await post("/session/\(id)/share", body: [:] as [String: String])
    }

    /// Reverts a message and returns the updated session when the server includes
    /// it. Older OpenCode versions returned a boolean acknowledgement, which is
    /// also accepted for compatibility.
    func revertMessage(sessionID: String, messageID: String, partID: String? = nil) async throws -> OCSession? {
        if usesV2 {
            do {
                // Clear a previous, uncommitted preview before creating the new
                // boundary. This makes the one-tap action safe to retry after a
                // disrupted revert attempt.
                try await sendV2RequestDiscardingResponse(
                    method: "DELETE",
                    path: "/api/session/\(sessionID)/revert",
                    includesLocation: false
                )
                try await sendV2RequestDiscardingResponse(
                    method: "POST",
                    path: "/api/session/\(sessionID)/revert/stage",
                    body: OCV2RevertStageInput(messageID: messageID, files: true),
                    includesLocation: false
                )
                try await sendV2RequestDiscardingResponse(
                    method: "POST",
                    path: "/api/session/\(sessionID)/revert/commit",
                    includesLocation: false
                )

                // The mutation endpoints acknowledge without the canonical
                // session projection, so refetch before callers refresh their
                // transcript and diff state.
                return try await getSession(id: sessionID)
            } catch {
                // Stage/commit can race a busy session. If any part of the
                // sequence already changed server state, surface that latest
                // snapshot so the UI can recover rather than retaining a stale
                // transcript or diff.
                if let session = try? await getSession(id: sessionID) {
                    throw OpenCodeError.incompleteRevert(
                        session: session,
                        reason: error.localizedDescription
                    )
                }
                throw error
            }
        }

        var body: [String: Any] = ["messageID": messageID]
        if let partID { body["partID"] = partID }
        return try await postOptionallyDecoding("/session/\(sessionID)/revert", body: body)
    }

    // MARK: - Private HTTP helpers

    private var usesV2: Bool {
        capabilities?.protocolVersion == .v2
    }

    private func supports(_ feature: OpenCodeOptionalFeature) -> Bool {
        capabilities?.supports(feature) ?? true
    }

    private func applyV2PromptSelection(
        sessionID: String,
        model: OCPromptInput.OCModelRef?,
        agent: String?,
        variant: String?
    ) async throws {
        if let model {
            let selection = OCV2ModelRef(
                id: model.modelID,
                providerID: model.providerID,
                variant: variant
            )
            try await sendV2RequestDiscardingResponse(
                method: "POST",
                path: "/api/session/\(sessionID)/model",
                body: ["model": selection],
                includesLocation: false
            )
        }
        if let agent = agent?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank {
            try await sendV2RequestDiscardingResponse(
                method: "POST",
                path: "/api/session/\(sessionID)/agent",
                body: ["agent": agent],
                includesLocation: false
            )
        }
    }

    private func getV2<T: Decodable>(
        _ path: String,
        pathParameter: String? = nil,
        queryItems: [URLQueryItem] = [],
        includesLocation: Bool = true
    ) async throws -> T {
        let request = makeV2Request(
            path: path,
            pathParameter: pathParameter,
            queryItems: queryItems,
            includesLocation: includesLocation
        )
        Logger.api.debug("GET \(request.url?.absoluteString ?? "nil", privacy: .public) → \(String(describing: T.self), privacy: .public)")
        let (data, response) = try await transport.data(for: request)
        try validateResponse(response, data: data)
        return try decode(data)
    }

    private func sendV2Request<T: Decodable, B: Encodable>(
        method: String,
        path: String,
        pathParameter: String? = nil,
        body: B,
        includesLocation: Bool = true
    ) async throws -> T {
        let data = try await sendV2RequestData(
            method: method,
            path: path,
            pathParameter: pathParameter,
            body: body,
            includesLocation: includesLocation
        )
        return try decode(data)
    }

    private func sendV2Request<T: Decodable>(
        method: String,
        path: String,
        pathParameter: String? = nil,
        includesLocation: Bool = true
    ) async throws -> T {
        let data = try await sendV2RequestData(
            method: method,
            path: path,
            pathParameter: pathParameter,
            body: Optional<EmptyResponse>.none,
            includesLocation: includesLocation
        )
        let response: T = try decode(data)
        return response
    }

    private func sendV2RequestDiscardingResponse(
        method: String,
        path: String,
        pathParameter: String? = nil,
        includesLocation: Bool = true
    ) async throws {
        var request = makeV2Request(
            path: path,
            pathParameter: pathParameter,
            includesLocation: includesLocation
        )
        request.httpMethod = method
        Logger.api.debug("\(method, privacy: .public) \(request.url?.absoluteString ?? "nil", privacy: .public)")
        let (data, response) = try await transport.data(for: request)
        try validateResponse(response, data: data)
    }

    private func sendV2RequestDiscardingResponse<B: Encodable>(
        method: String,
        path: String,
        pathParameter: String? = nil,
        body: B,
        includesLocation: Bool = true
    ) async throws {
        _ = try await sendV2RequestData(
            method: method,
            path: path,
            pathParameter: pathParameter,
            body: body,
            includesLocation: includesLocation
        )
    }

    private func sendV2RequestData<B: Encodable>(
        method: String,
        path: String,
        pathParameter: String? = nil,
        body: B?,
        includesLocation: Bool = true
    ) async throws -> Data {
        var request = makeV2Request(
            path: path,
            pathParameter: pathParameter,
            includesLocation: includesLocation
        )
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        Logger.api.debug("\(method, privacy: .public) \(request.url?.absoluteString ?? "nil", privacy: .public)")
        let (data, response) = try await transport.data(for: request)
        try validateResponse(response, data: data)
        return data
    }

    private func getV2Located<T: Decodable>(
        _ endpoint: String,
        path: String? = nil,
        queryItems: [URLQueryItem] = []
    ) async throws -> OCV2Located<T> {
        let request = makeV2Request(path: endpoint, queryPath: path, queryItems: queryItems)
        Logger.api.debug("GET \(request.url?.absoluteString ?? "nil", privacy: .public) → \(String(describing: T.self), privacy: .public)")
        let (data, response) = try await transport.data(for: request)
        try validateResponse(response, data: data)
        return try decode(data)
    }

    /// Follows opaque v2 cursors until the server ends the snapshot. Servers
    /// may return an empty terminal page after a non-empty page, so only an
    /// empty page with another cursor is invalid.
    private func getAllV2Pages<T: Decodable & Sendable>(
        endpoint: String,
        limit: Int = v2PageSize,
        order: String,
        includesLocation: Bool = true
    ) async throws -> [T] {
        var values: [T] = []
        var cursor: String?
        var seenCursors: Set<String> = []

        while true {
            var queryItems = [URLQueryItem(name: "limit", value: String(limit))]
            if let cursor {
                guard seenCursors.insert(cursor).inserted else {
                    throw OpenCodeError.invalidPayload("The v2 response repeated a pagination cursor.")
                }
                queryItems.append(URLQueryItem(name: "cursor", value: cursor))
            } else {
                queryItems.append(URLQueryItem(name: "order", value: order))
            }

            let page: OCV2CursorPage<[T]>
            do {
                page = try await getV2(
                    endpoint,
                    queryItems: queryItems,
                    includesLocation: includesLocation
                )
            } catch let error as OpenCodeError {
                throw error
            } catch is DecodingError {
                throw OpenCodeError.invalidPayload("The v2 response did not contain a valid cursor page.")
            } catch {
                throw error
            }
            let next: String?
            if let rawNext = page.cursor.next {
                guard let cursor = rawNext.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank else {
                    throw OpenCodeError.invalidPayload("The v2 response contained a blank pagination cursor.")
                }
                next = cursor
            } else {
                next = nil
            }

            guard !page.data.isEmpty else {
                guard next == nil else {
                    throw OpenCodeError.invalidPayload("The v2 response contained an empty continuation page.")
                }
                return values
            }

            values.append(contentsOf: page.data)
            guard let next else {
                return values
            }
            guard !seenCursors.contains(next) else {
                throw OpenCodeError.invalidPayload("The v2 response repeated a pagination cursor.")
            }
            cursor = next
        }
    }

    private func readV2FileContent(path: String) async throws -> OCFileContent {
        let request = makeV2Request(path: "/api/fs/read", pathParameter: path)
        let (data, response) = try await transport.data(for: request)
        try validateResponse(response, data: data)

        let mimeType = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Type")?
            .split(separator: ";", maxSplits: 1)
            .first
            .map(String.init)
        guard let content = String(data: data, encoding: .utf8)
        else {
            return OCFileContent(type: "binary", mimeType: mimeType)
        }
        return OCFileContent(type: "text", content: content, mimeType: mimeType)
    }

    private func makeV2Request(
        path: String,
        pathParameter: String? = nil,
        queryPath: String? = nil,
        queryItems additionalQueryItems: [URLQueryItem] = [],
        includesLocation: Bool = true
    ) -> URLRequest {
        let rawPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        var url = baseURL.appending(path: rawPath)

        if let pathParameter {
            let segments = pathParameter.split(separator: "/", omittingEmptySubsequences: true)
            let encodedSegments = segments.map {
                $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
            }
            url.append(path: encodedSegments.joined(separator: "/"))
        }

        if var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            var queryItems = additionalQueryItems
            if includesLocation, let contextDirectory {
                queryItems.append(URLQueryItem(name: "location[directory]", value: contextDirectory))
            }
            if let queryPath {
                queryItems.append(URLQueryItem(name: "path", value: queryPath))
            }
            components.queryItems = queryItems.isEmpty ? nil : queryItems
            url = components.url ?? url
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if let authHeader {
            request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        let request = makeRequest(path: path, method: "GET")
        Logger.api.debug("GET \(request.url?.absoluteString ?? "nil", privacy: .public) → \(String(describing: T.self), privacy: .public)")
        let (data, response) = try await transport.data(for: request)
        try validateResponse(response, data: data)
        return try decode(data)
    }

    private func post<T: Decodable>(_ path: String, body: Any) async throws -> T {
        var request = makeRequest(path: path, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await transport.data(for: request)
        try validateResponse(response, data: data)
        return try decode(data)
    }

    /// Validates a successful action response while tolerating older response
    /// shapes. Used when the current API returns useful state but earlier server
    /// versions returned only an acknowledgement.
    private func postOptionallyDecoding<T: Decodable>(_ path: String, body: Any) async throws -> T? {
        var request = makeRequest(path: path, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await transport.data(for: request)
        try validateResponse(response, data: data)
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func postCodable<T: Decodable, B: Encodable>(_ path: String, body: B, expect204: Bool = false) async throws -> T {
        var request = makeRequest(path: path, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await transport.data(for: request)
        try validateResponse(response, data: data)
        if expect204 {
            guard let result = EmptyResponse() as? T else {
                throw OpenCodeError.invalidResponse
            }
            return result
        }
        return try decode(data)
    }

    private func postDiscardingResponse<B: Encodable>(_ path: String, body: B) async throws {
        var request = makeRequest(path: path, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await transport.data(for: request)
        try validateResponse(response, data: data)
    }

    private func patch<T: Decodable>(_ path: String, body: Any) async throws -> T {
        var request = makeRequest(path: path, method: "PATCH")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await transport.data(for: request)
        try validateResponse(response, data: data)
        return try decode(data)
    }

    private func delete<T: Decodable>(_ path: String) async throws -> T {
        let request = makeRequest(path: path, method: "DELETE")
        let (data, response) = try await transport.data(for: request)
        try validateResponse(response, data: data)
        return try decode(data)
    }

    private func makeRequest(path: String, method: String) -> URLRequest {
        let url = resolvedURL(for: path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let authHeader {
            request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        }
        if let contextDirectory {
            request.setValue(contextDirectory, forHTTPHeaderField: "x-opencode-directory")
        }
        return request
    }

    private func resolvedURL(for path: String) -> URL {
        let components = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let rawPath = String(components.first ?? "")
        let cleanPath = rawPath.hasPrefix("/") ? String(rawPath.dropFirst()) : rawPath
        let url = baseURL.appending(path: cleanPath)

        guard components.count == 2,
              var urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }

        urlComponents.percentEncodedQuery = String(components[1])
        return urlComponents.url ?? url
    }

    private func validateResponse(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw OpenCodeError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            if let payload = try? JSONDecoder().decode(OpenCodeAPIErrorPayload.self, from: data) {
                throw OpenCodeError.apiError(statusCode: http.statusCode, payload: payload)
            }
            throw OpenCodeError.httpError(statusCode: http.statusCode)
        }
    }

    private func shouldFallbackToV1(afterV2ProbeError error: Error) -> Bool {
        if let openCodeError = error as? OpenCodeError {
            switch openCodeError {
            case let .httpError(statusCode),
                 let .apiError(statusCode, _):
                return statusCode == 404 || statusCode == 405
            default:
                break
            }
        }

        // The pre-v2 remote relay rejects unknown routes before forwarding
        // them. Treat that rejection exactly like a missing v2 endpoint so
        // existing paired v1 servers keep connecting until the relay itself is
        // upgraded in the remote-v2 migration step.
        if let remoteError = error as? RemoteProtocolError {
            return remoteError == .invalidRequest
        }

        return false
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            if let json = String(data: data, encoding: .utf8) {
                let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("<!doctype html") || trimmed.hasPrefix("<html") {
                    throw OpenCodeError.invalidPayload("Server returned HTML instead of JSON. The request likely hit the OpenCode web app route instead of the API endpoint.")
                }
                Logger.api.error("Failed to decode \(String(describing: T.self), privacy: .public): \(error, privacy: .public)\nJSON preview: \(json.prefix(2000), privacy: .private)")
            }
            throw error
        }
    }
}

// MARK: - Errors

enum OpenCodeError: LocalizedError {
    case invalidResponse
    case httpError(statusCode: Int)
    case apiError(statusCode: Int, payload: OpenCodeAPIErrorPayload)
    case notConnected
    case invalidURL
    case invalidPayload(String)
    case incompleteRevert(session: OCSession, reason: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid server response."
        case .httpError(let code): return "HTTP error \(code)."
        case let .apiError(statusCode, payload):
            return payload.message ?? "\(payload.tag) (HTTP \(statusCode))."
        case .notConnected: return "Not connected to server."
        case .invalidURL: return "Invalid server URL."
        case .invalidPayload(let message): return message
        case .incompleteRevert(_, let reason):
            return "Revert did not finish. The latest session state was refreshed: \(reason)"
        }
    }
}

/// Error document returned by OpenCode v2 endpoints. Endpoint-specific
/// properties are optional so future server errors remain inspectable.
nonisolated struct OpenCodeAPIErrorPayload: Codable, Equatable, Sendable {
    let tag: String
    let message: String?
    let kind: String?
    let field: String?
    let resource: String?
    let service: String?
    let reference: String?

    enum CodingKeys: String, CodingKey {
        case tag = "_tag"
        case message, kind, field, resource, service
        case reference = "ref"
    }
}

// MARK: - Empty response for 204s

struct EmptyResponse: Codable {}
