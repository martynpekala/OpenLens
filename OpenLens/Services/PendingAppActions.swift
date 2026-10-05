import Foundation
import Observation

/// A session an App Shortcut asked for, waiting until the app can create it.
struct NewSessionRequest: Equatable {
    /// Nil when the name was blank, so the server picks its default title.
    var title: String?
}

/// Requests made outside the app's UI, such as an App Shortcut run from Spotlight or Siri.
/// They stay pending until the app is connected to a server and can act on them.
@MainActor @Observable
final class PendingAppActions {
    private(set) var newSessionRequest: NewSessionRequest?

    func requestNewSession(title: String) {
        newSessionRequest = NewSessionRequest(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        )
    }

    /// Returns the requested session and clears the request, so it's created once.
    func consumeNewSessionRequest() -> NewSessionRequest? {
        defer { newSessionRequest = nil }
        return newSessionRequest
    }
}
