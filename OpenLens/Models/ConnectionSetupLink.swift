import Foundation

/// Parses `openlens://setup`, the OpenCode v2 support link: it opens connection setup,
/// or the v2 support sheet when connected. It carries no server details, so it is safe
/// to publish, e.g. as an App Store in-app event deep link.
enum ConnectionSetupLink {
    static let host = "setup"

    static func matches(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "openlens" && url.host?.lowercased() == host
    }
}
