import Foundation

/// Parsed connection data from an `openlens://connect` deep link or QR code scan.
struct DeepLinkConnection: Equatable {
    let serverURL: String
    let username: String
    let password: String
    let sessionID: String?

    /// Attempts to parse an `openlens://connect?url=...&user=...&pass=...&sessionID=...` URL.
    /// Returns `nil` if the URL doesn't match the expected format.
    init?(from url: URL) {
        guard url.scheme == "openlens",
              url.host == "connect",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems,
              let serverURL = items.first(where: { $0.name == "url" })?.value,
              !serverURL.isEmpty
        else { return nil }

        self.serverURL = serverURL
        self.username = items.first(where: { $0.name == "user" })?.value ?? "opencode"
        self.password = items.first(where: { $0.name == "pass" })?.value ?? ""
        self.sessionID = items.first(where: { $0.name == "sessionID" })?.value?.nilIfBlank
    }

    init(serverURL: String, username: String, password: String, sessionID: String? = nil) {
        self.serverURL = serverURL
        self.username = username
        self.password = password
        self.sessionID = sessionID?.nilIfBlank
    }
}
