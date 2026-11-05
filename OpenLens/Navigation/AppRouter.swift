import Foundation

/// One router for the life of the app. Which tab is selected is global; the navigation paths are
/// kept per server, so switching server swaps what the stacks show without replacing the router
/// (replacing it would change the tab, every path and the tab bar's visibility in one go).
@Observable
final class AppRouter {
    /// Key used until a server is active: unit tests, and the moment before the registry has one.
    static let unscopedServerID = ""

    var selectedTab: AppTab = .chat
    /// The server whose paths the stacks currently show.
    private(set) var activeServerID: String = AppRouter.unscopedServerID
    private var pathsByServer: [String: [AppTab: [RouterDestination]]] = [:]

    var chatPath: [RouterDestination] {
        get { path(for: .chat) }
        set { setPath(newValue, for: .chat) }
    }
    var microPath: [RouterDestination] {
        get { path(for: .micro) }
        set { setPath(newValue, for: .micro) }
    }
    var reviewPath: [RouterDestination] {
        get { path(for: .review) }
        set { setPath(newValue, for: .review) }
    }
    var workspacePath: [RouterDestination] {
        get { path(for: .workspace) }
        set { setPath(newValue, for: .workspace) }
    }
    var settingsPath: [RouterDestination] {
        get { path(for: .settings) }
        set { setPath(newValue, for: .settings) }
    }

    var selectedChatSessionID: String? {
        guard let firstDestination = chatPath.first,
              case .chatSession(let session, _) = firstDestination else { return nil }
        return session.id
    }

    func path(for tab: AppTab) -> [RouterDestination] {
        pathsByServer[activeServerID]?[tab] ?? []
    }

    func setPath(_ path: [RouterDestination], for tab: AppTab) {
        pathsByServer[activeServerID, default: [:]][tab] = path
    }

    /// Makes `serverID`'s paths the visible ones. Its previous paths are kept, so coming back
    /// lands where the user left off.
    func activate(serverID: String) {
        guard serverID != activeServerID else { return }
        activeServerID = serverID
    }

    /// Drops everything remembered for a server that has been removed.
    func forgetServer(_ serverID: String) {
        pathsByServer[serverID] = nil
    }

    func chatSessionDestination(for session: OCSession) -> RouterDestination {
        .chatSession(session: session, serverID: activeServerID)
    }

    func navigate(to destination: RouterDestination, in tab: AppTab? = nil) {
        let targetTab = tab ?? selectedTab
        var path = path(for: targetTab)
        path.append(destination)
        setPath(path, for: targetTab)
        selectedTab = targetTab
    }

    func selectChatSession(_ session: OCSession) {
        chatPath = [chatSessionDestination(for: session)]
        selectedTab = .chat
    }

    func clearChatSession(ifMatching sessionID: String) {
        guard selectedChatSessionID == sessionID else { return }
        chatPath = []
    }
}
