import Foundation

/// A single-use link issued by `opencode pair`, not a server base URL.
struct OpenCodePairingLink: Equatable {
    let url: URL
    let serverURL: URL

    init?(url: URL) {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil
        else { return nil }

        let prefix = "/auth/connect/"
        let path = components.percentEncodedPath
        guard path.hasPrefix(prefix) else { return nil }
        let code = path.dropFirst(prefix.count)
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        guard !code.isEmpty, code.allSatisfy({ allowed.contains($0) }) else { return nil }

        self.url = url
        components.path = ""
        guard let serverURL = components.url else { return nil }
        self.serverURL = serverURL
    }
}
