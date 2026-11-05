import Foundation

/// A reply sent from a Live Activity button.
enum LiveActivityReply: Hashable {
    case allow
    case deny
    /// The quick reply at this index of the pending prompt.
    case quickReply(Int)
}

/// Persists server connection credentials in the shared App Group so Live Activity buttons
/// can make direct API calls (e.g. approving permissions from the lock screen).
struct SharedConnectionStore {
    struct UnsupportedReply: Error {}

    /// What a Live Activity button needs to reach one server.
    struct ServerCredentials: Codable, Equatable {
        var baseURL: String
        var authHeader: String?
        var usesV2: Bool
    }

    static let suiteName = "group.dev.openlens.shared"
    private static let baseURLKey = "server_base_url"
    private static let authHeaderKey = "server_auth_header"
    private static let protocolKey = "server_api_protocol"
    private static let credentialsKey = "server_credentials_v2"

    /// The App Group suite shared with the widget extension; tests pass an ephemeral suite instead.
    static var appGroupDefaults: UserDefaults {
        UserDefaults(suiteName: suiteName) ?? .standard
    }

    private static func storedCredentials(in defaults: UserDefaults) -> [String: ServerCredentials] {
        guard let data = defaults.data(forKey: credentialsKey),
              let decoded = try? JSONDecoder().decode([String: ServerCredentials].self, from: data)
        else { return [:] }
        return decoded
    }

    private static func store(_ credentials: [String: ServerCredentials], in defaults: UserDefaults) {
        if credentials.isEmpty {
            defaults.removeObject(forKey: credentialsKey)
        } else if let data = try? JSONEncoder().encode(credentials) {
            defaults.set(data, forKey: credentialsKey)
        }
    }

    /// Saves one server's credentials and mirrors them into the legacy single slots, which
    /// activities started before per-server storage (no `serverID`) still resolve through.
    static func save(
        serverID: String, baseURL: String, authHeader: String?, protocolVersion: String = "v1",
        defaults: UserDefaults = appGroupDefaults
    ) {
        var all = storedCredentials(in: defaults)
        all[serverID] = ServerCredentials(baseURL: baseURL, authHeader: authHeader, usesV2: protocolVersion == "v2")
        store(all, in: defaults)
        writeLegacySlots(baseURL: baseURL, authHeader: authHeader, protocolVersion: protocolVersion, in: defaults)
    }

    /// Removes one server. The legacy slots go too when they still hold that server's credentials.
    static func clear(serverID: String, defaults: UserDefaults = appGroupDefaults) {
        var all = storedCredentials(in: defaults)
        let removed = all.removeValue(forKey: serverID)
        store(all, in: defaults)
        if let removed, defaults.string(forKey: baseURLKey) == removed.baseURL {
            clearLegacySlots(in: defaults)
        }
    }

    static func clearAll(defaults: UserDefaults = appGroupDefaults) {
        defaults.removeObject(forKey: credentialsKey)
        clearLegacySlots(in: defaults)
    }

    /// Resolves the server a Live Activity talks to. Only an activity with no `serverID` -- one
    /// started before per-server storage existed -- falls back to the legacy slots. An attributed
    /// activity resolves to its own server or to nothing, never to a different one: answering a
    /// permission prompt against the wrong server is worse than not answering it.
    static func credentials(for serverID: String?, defaults: UserDefaults = appGroupDefaults) -> ServerCredentials? {
        if let serverID { return storedCredentials(in: defaults)[serverID] }
        guard let baseURL = defaults.string(forKey: baseURLKey) else { return nil }
        return ServerCredentials(
            baseURL: baseURL,
            authHeader: defaults.string(forKey: authHeaderKey),
            usesV2: defaults.string(forKey: protocolKey) == "v2"
        )
    }

    private static func writeLegacySlots(
        baseURL: String, authHeader: String?, protocolVersion: String, in defaults: UserDefaults
    ) {
        defaults.set(protocolVersion, forKey: protocolKey)
        defaults.set(baseURL, forKey: baseURLKey)
        defaults.set(authHeader, forKey: authHeaderKey)
    }

    private static func clearLegacySlots(in defaults: UserDefaults) {
        defaults.removeObject(forKey: protocolKey)
        defaults.removeObject(forKey: baseURLKey)
        defaults.removeObject(forKey: authHeaderKey)
    }

    /// Builds the reply to the prompt a Live Activity shows, following the negotiated contract:
    /// v1 answers permissions and questions within the prompt's project directory, v2 answers
    /// permissions and forms within the prompt's session.
    static func replyRequest(
        to prompt: OpenLensActivityAttributes.PendingUserResponse,
        with reply: LiveActivityReply,
        directory: String?,
        baseURL: URL, authHeader: String?, usesV2: Bool
    ) throws -> URLRequest {
        guard let requestID = prompt.requestID, !requestID.isEmpty else { throw UnsupportedReply() }
        let sessionID = prompt.sessionID.flatMap { $0.isEmpty ? nil : $0 }

        let pathComponents: [String]
        let body: [String: Any]
        switch (prompt.kind, reply) {
        case (.permission, .allow), (.permission, .deny):
            let decision = reply == .allow ? "once" : "reject"
            if usesV2 {
                guard let sessionID else { throw UnsupportedReply() }
                pathComponents = ["api", "session", sessionID, "permission", requestID, "reply"]
                body = ["decision": decision]
            } else {
                pathComponents = ["permission", requestID, "reply"]
                body = ["reply": decision]
            }
        case (.question, .quickReply(let index)) where !usesV2:
            guard prompt.quickReplies.indices.contains(index),
                  case .text(let label) = prompt.quickReplies[index].value
            else { throw UnsupportedReply() }
            pathComponents = ["question", requestID, "reply"]
            body = ["answers": [[label]]]
        case (.form, .quickReply(let index)) where usesV2:
            guard let sessionID, let fieldKey = prompt.fieldKey, prompt.quickReplies.indices.contains(index)
            else { throw UnsupportedReply() }
            let value: Any = switch prompt.quickReplies[index].value {
            case .text(let text): text
            case .flag(let flag): flag
            }
            pathComponents = ["api", "session", sessionID, "form", requestID, "reply"]
            body = ["answer": [fieldKey: value]]
        default:
            throw UnsupportedReply()
        }

        let url = pathComponents.reduce(baseURL) { $0.appendingPathComponent($1) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let authHeader { request.setValue(authHeader, forHTTPHeaderField: "Authorization") }
        if !usesV2, let directory, !directory.isEmpty {
            request.setValue(directory, forHTTPHeaderField: "x-opencode-directory")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
}
