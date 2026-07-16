import Foundation
import os

/// HTTP REST client for the OpenCode server API.
/// All methods are async and throw on network/decode errors.
actor OpenCodeClient {

    private let transport: any OpenCodeTransport
    private static let maximumPendingPromptCount = 24
    private var baseURL: URL
    private var authHeader: String?
    private var contextDirectory: String?

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
    }

    func updateConnection(baseURL: URL, authHeader: String?, contextDirectory: String? = nil) {
        self.baseURL = baseURL
        self.authHeader = authHeader
        self.contextDirectory = contextDirectory?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
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

    // MARK: - Sessions

    func listSessions() async throws -> [OCSession] {
        try await get("/session")
    }

    func getSession(id: String) async throws -> OCSession {
        try await get("/session/\(id)")
    }

    func createSession(title: String? = nil, parentID: String? = nil) async throws -> OCSession {
        var body: [String: Any] = [:]
        if let title { body["title"] = title }
        if let parentID { body["parentID"] = parentID }
        return try await post("/session", body: body)
    }

    func deleteSession(id: String) async throws -> Bool {
        try await delete("/session/\(id)")
    }

    func updateSession(id: String, title: String) async throws -> OCSession {
        try await patch("/session/\(id)", body: ["title": title])
    }

    func getSessionStatus() async throws -> [String: OCSessionStatus] {
        try await get("/session/status")
    }

    func abortSession(id: String) async throws -> Bool {
        try await post("/session/\(id)/abort", body: [:] as [String: String])
    }

    // MARK: - Messages

    func listMessages(sessionID: String, limit: Int? = nil) async throws -> [OCMessageWithParts] {
        var path = "/session/\(sessionID)/message"
        if let limit { path += "?limit=\(limit)" }
        return try await get(path)
    }

    func getMessage(sessionID: String, messageID: String) async throws -> OCMessageWithParts {
        try await get("/session/\(sessionID)/message/\(messageID)")
    }

    // MARK: - Todos

    func listTodos(sessionID: String) async throws -> TodoDisplaySnapshot {
        let todos: [OCTodo] = try await get("/session/\(sessionID)/todo")
        return TodoDisplaySafety.prepare(todos)
    }

    /// Send a prompt asynchronously (fire and forget, monitor via SSE).
    func sendPromptAsync(
        sessionID: String,
        text: String,
        model: OCPromptInput.OCModelRef? = nil,
        agent: String? = nil,
        variant: String? = nil
    ) async throws {
        let part = OCPromptPart(type: "text", text: text)
        let input = OCPromptInput(parts: [part], model: model, agent: agent, messageID: nil, variant: variant)
        let _: EmptyResponse = try await postCodable("/session/\(sessionID)/prompt_async", body: input, expect204: true)
    }

    /// Send a prompt synchronously (blocks until response is complete).
    func sendPrompt(
        sessionID: String,
        text: String,
        model: OCPromptInput.OCModelRef? = nil,
        agent: String? = nil,
        variant: String? = nil
    ) async throws -> OCMessageWithParts {
        let part = OCPromptPart(type: "text", text: text)
        let input = OCPromptInput(parts: [part], model: model, agent: agent, messageID: nil, variant: variant)
        return try await postCodable("/session/\(sessionID)/message", body: input)
    }

    // MARK: - Providers

    func listProviders() async throws -> OCProviderResponse {
        try await get("/provider")
    }

    /// Fetch raw JSON from /provider for debugging decode issues.
    func listProvidersRaw() async throws -> Data {
        let request = makeRequest(path: "/provider", method: "GET")
        let (data, response) = try await transport.data(for: request)
        try validateResponse(response)
        return data
    }

    // MARK: - Config

    func getConfig() async throws -> OCConfig {
        try await get("/config")
    }

    // MARK: - Agents

    func listAgents() async throws -> [OCAgent] {
        try await get("/agent")
    }

    // MARK: - Commands

    func listCommands() async throws -> [OCCommand] {
        try await get("/command")
    }

    func sendCommand(
        sessionID: String,
        command: String,
        arguments: String,
        model: String? = nil,
        agent: String? = nil,
        variant: String? = nil
    ) async throws -> OCMessageWithParts {
        var body: [String: Any] = [
            "command": command,
            "arguments": arguments,
        ]

        if let model, !model.isEmpty {
            body["model"] = model
        }
        if let agent, !agent.isEmpty {
            body["agent"] = agent
        }
        if let variant, !variant.isEmpty {
            body["variant"] = variant
        }

        return try await post("/session/\(sessionID)/command", body: body)
    }

    // MARK: - Files

    func listFiles(path: String? = nil) async throws -> [OCWorkspaceFileEntry] {
        var urlPath = "/file"
        if let path { urlPath += "?path=\(path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? path)" }
        return try await get(urlPath)
    }

    func listFileStatus() async throws -> [OCWorkspaceFileStatus] {
        try await get("/file/status")
    }

    func readFileContent(path: String) async throws -> OCFileContent {
        let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? path
        return try await get("/file/content?path=\(encodedPath)")
    }

    // MARK: - Project

    func listProjects() async throws -> [OCProject] {
        try await get("/project")
    }

    func getCurrentProject() async throws -> OCProject {
        try await get("/project/current")
    }

    func getPath() async throws -> OCPathInfo {
        try await get("/path")
    }

    func getVCS() async throws -> OCVCSInfo {
        try await get("/vcs")
    }

    // MARK: - Diffs

    func getSessionDiff(sessionID: String, messageID: String? = nil) async throws -> [OCFileDiff] {
        var path = "/session/\(sessionID)/diff"
        if let messageID { path += "?messageID=\(messageID)" }
        return try await get(path)
    }

    // MARK: - Permissions

    func listPermissions() async throws -> [OCPermissionRequest] {
        let requests: [OCPermissionRequest] = try await get("/permission")
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

    func replyToPermission(requestID: String, reply: OCPermissionReply) async throws -> Bool {
        try await post("/permission/\(requestID)/reply", body: [
            "reply": reply.rawValue,
        ] as [String: Any])
    }

    // MARK: - Questions

    /// Fetch any pending (unanswered) questions from the server.
    /// Used after reconnection to recover questions that arrived while disconnected.
    func listPendingQuestions() async throws -> [OCQuestionRequest] {
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
        let reply = OCQuestionReply(answers: answers)
        return try await postCodable("/question/\(requestID)/reply", body: reply)
    }

    /// Reject/dismiss a question request.
    func rejectQuestion(requestID: String) async throws -> Bool {
        try await post("/question/\(requestID)/reject", body: [:] as [String: String])
    }

    // MARK: - Session actions

    func shareSession(id: String) async throws -> OCSession {
        try await post("/session/\(id)/share", body: [:] as [String: String])
    }

    func revertMessage(sessionID: String, messageID: String, partID: String? = nil) async throws -> Bool {
        var body: [String: Any] = ["messageID": messageID]
        if let partID { body["partID"] = partID }
        return try await post("/session/\(sessionID)/revert", body: body)
    }

    // MARK: - Private HTTP helpers

    private func get<T: Decodable>(_ path: String) async throws -> T {
        let request = makeRequest(path: path, method: "GET")
        Logger.api.debug("GET \(request.url?.absoluteString ?? "nil", privacy: .public) → \(String(describing: T.self), privacy: .public)")
        let (data, response) = try await transport.data(for: request)
        try validateResponse(response)
        return try decode(data)
    }

    private func post<T: Decodable>(_ path: String, body: Any) async throws -> T {
        var request = makeRequest(path: path, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await transport.data(for: request)
        try validateResponse(response)
        return try decode(data)
    }

    private func postCodable<T: Decodable, B: Encodable>(_ path: String, body: B, expect204: Bool = false) async throws -> T {
        var request = makeRequest(path: path, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await transport.data(for: request)
        try validateResponse(response)
        if expect204 {
            guard let result = EmptyResponse() as? T else {
                throw OpenCodeError.invalidResponse
            }
            return result
        }
        return try decode(data)
    }

    private func patch<T: Decodable>(_ path: String, body: Any) async throws -> T {
        var request = makeRequest(path: path, method: "PATCH")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await transport.data(for: request)
        try validateResponse(response)
        return try decode(data)
    }

    private func delete<T: Decodable>(_ path: String) async throws -> T {
        let request = makeRequest(path: path, method: "DELETE")
        let (data, response) = try await transport.data(for: request)
        try validateResponse(response)
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

    private func validateResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw OpenCodeError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw OpenCodeError.httpError(statusCode: http.statusCode)
        }
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
    case notConnected
    case invalidURL
    case invalidPayload(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid server response."
        case .httpError(let code): return "HTTP error \(code)."
        case .notConnected: return "Not connected to server."
        case .invalidURL: return "Invalid server URL."
        case .invalidPayload(let message): return message
        }
    }
}

// MARK: - Empty response for 204s

struct EmptyResponse: Decodable {}
