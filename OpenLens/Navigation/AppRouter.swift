import Foundation

@Observable
final class AppRouter {
    var selectedTab: AppTab = .chat
    var chatPath: [RouterDestination] = []
    var reviewPath: [RouterDestination] = []
    var workspacePath: [RouterDestination] = []
    var settingsPath: [RouterDestination] = []

    func path(for tab: AppTab) -> [RouterDestination] {
        switch tab {
        case .chat: chatPath
        case .review: reviewPath
        case .workspace: workspacePath
        case .settings: settingsPath
        }
    }

    func setPath(_ path: [RouterDestination], for tab: AppTab) {
        switch tab {
        case .chat:
            chatPath = path
        case .review:
            reviewPath = path
        case .workspace:
            workspacePath = path
        case .settings:
            settingsPath = path
        }
    }

    func navigate(to destination: RouterDestination, in tab: AppTab? = nil) {
        let targetTab = tab ?? selectedTab
        var path = path(for: targetTab)
        path.append(destination)
        setPath(path, for: targetTab)
        selectedTab = targetTab
    }
}
