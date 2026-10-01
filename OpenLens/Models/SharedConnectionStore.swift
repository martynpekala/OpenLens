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

    private static let suiteName = "group.dev.openlens.shared"
    private static let baseURLKey = "server_base_url"
    private static let authHeaderKey = "server_auth_header"

    private static let protocolKey = "server_api_protocol"

    static func save(baseURL: String, authHeader: String?, protocolVersion: String = "v1") {
        let defaults = UserDefaults(suiteName: suiteName)
        defaults?.set(protocolVersion, forKey: protocolKey)
        defaults?.set(baseURL, forKey: baseURLKey)
        defaults?.set(authHeader, forKey: authHeaderKey)
    }

    static func clear() {
        let defaults = UserDefaults(suiteName: suiteName)
        defaults?.removeObject(forKey: protocolKey)
        defaults?.removeObject(forKey: baseURLKey)
        defaults?.removeObject(forKey: authHeaderKey)
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

    static var usesV2: Bool {
        UserDefaults(suiteName: suiteName)?.string(forKey: protocolKey) == "v2"
    }

    static var baseURL: String? {
        UserDefaults(suiteName: suiteName)?.string(forKey: baseURLKey)
    }

    static var authHeader: String? {
        UserDefaults(suiteName: suiteName)?.string(forKey: authHeaderKey)
    }
}
