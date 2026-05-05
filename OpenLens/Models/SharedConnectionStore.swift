import Foundation

/// Persists server connection credentials in the shared App Group so the widget
/// extension can make direct API calls (e.g. approving permissions from the lock screen).
struct SharedConnectionStore {
    private static let suiteName = "group.dev.openlens.shared"
    private static let baseURLKey = "server_base_url"
    private static let authHeaderKey = "server_auth_header"

    static func save(baseURL: String, authHeader: String?) {
        let defaults = UserDefaults(suiteName: suiteName)
        defaults?.set(baseURL, forKey: baseURLKey)
        defaults?.set(authHeader, forKey: authHeaderKey)
    }

    static func clear() {
        let defaults = UserDefaults(suiteName: suiteName)
        defaults?.removeObject(forKey: baseURLKey)
        defaults?.removeObject(forKey: authHeaderKey)
    }

    static var baseURL: String? {
        UserDefaults(suiteName: suiteName)?.string(forKey: baseURLKey)
    }

    static var authHeader: String? {
        UserDefaults(suiteName: suiteName)?.string(forKey: authHeaderKey)
    }
}
