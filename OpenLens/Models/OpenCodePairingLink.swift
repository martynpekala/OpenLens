import Foundation

/// A link issued by `opencode pair`, not a server base URL.
struct OpenCodePairingLink: Equatable {
    let url: URL
    let serverURL: URL
    let credentials: OpenCodePairingCredentials?

    init?(url: URL) {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil
        else { return nil }

        let path = components.percentEncodedPath
        let credentials: OpenCodePairingCredentials?

        if path == "/connect" {
            guard let fragment = components.fragment,
                  let decodedCredentials = Self.decodeCredentials(from: fragment) else {
                return nil
            }
            credentials = decodedCredentials
        } else {
            guard components.fragment == nil else { return nil }

            let prefix = "/auth/connect/"
            guard path.hasPrefix(prefix) else { return nil }
            let code = path.dropFirst(prefix.count)
            let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
            guard !code.isEmpty, code.allSatisfy({ allowed.contains($0) }) else { return nil }
            credentials = nil
        }

        self.url = url
        self.credentials = credentials
        components.fragment = nil
        components.path = ""
        guard let serverURL = components.url else { return nil }
        self.serverURL = serverURL
    }

    private static func decodeCredentials(from fragment: String) -> OpenCodePairingCredentials? {
        let base64 = fragment
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = String(repeating: "=", count: (4 - base64.count % 4) % 4)

        guard let data = Data(base64Encoded: base64 + padding),
              let credentials = try? JSONDecoder().decode(OpenCodePairingCredentials.self, from: data),
              !credentials.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !credentials.password.isEmpty
        else {
            return nil
        }

        return credentials
    }
}

struct OpenCodePairingCredentials: Decodable, Equatable {
    let username: String
    let password: String
}
