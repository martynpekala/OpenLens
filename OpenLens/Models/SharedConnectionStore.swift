import Foundation

/// Persists server connection credentials in the shared App Group so the widget
/// extension can make direct API calls (e.g. approving permissions from the lock screen).
struct SharedConnectionStore {
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

    static func permissionReplyRequest(
        baseURL: URL, authHeader: String?, usesV2: Bool,
        sessionID: String, requestID: String, approve: Bool
    ) throws -> URLRequest {
        let permissionBase = usesV2
            ? baseURL.appendingPathComponent("api/session").appendingPathComponent(sessionID)
            : baseURL
        let url = permissionBase.appendingPathComponent("permission")
            .appendingPathComponent(requestID).appendingPathComponent("reply")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let authHeader { request.setValue(authHeader, forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONEncoder().encode([
            usesV2 ? "decision" : "reply": approve ? "once" : "reject"
        ])
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
