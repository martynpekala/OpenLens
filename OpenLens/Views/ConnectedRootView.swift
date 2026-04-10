import SwiftUI

struct ConnectedRootView: View {
    @Bindable var chatClient: ChatClient

    @Environment(AppRouter.self) private var router

    var body: some View {
        @Bindable var router = router

        TabView(selection: $router.selectedTab) {
            Tab(AppTab.chat.title, systemImage: AppTab.chat.icon, value: .chat) {
                tabNavigationView(for: .chat)
            }
            Tab(AppTab.review.title, systemImage: AppTab.review.icon, value: .review) {
                tabNavigationView(for: .review)
            }
            Tab(AppTab.workspace.title, systemImage: AppTab.workspace.icon, value: .workspace) {
                tabNavigationView(for: .workspace)
            }
            Tab(AppTab.settings.title, systemImage: AppTab.settings.icon, value: .settings, role: .search) {
                tabNavigationView(for: .settings)
            }
        }
        .tint(Color.appPrimary)
    }

    private func tabNavigationView(for tab: AppTab) -> some View {
        NavigationStack(path: pathBinding(for: tab)) {
            tabRootView(for: tab)
                .navigationDestination(for: RouterDestination.self) { destination in
                    destinationView(for: destination)
                }
        }
        .toolbar(tab == .chat && !router.chatPath.isEmpty ? .hidden : .visible, for: .tabBar)
    }

    private func pathBinding(for tab: AppTab) -> Binding<[RouterDestination]> {
        Binding(
            get: { router.path(for: tab) },
            set: { router.setPath($0, for: tab) }
        )
    }

    @ViewBuilder
    private func tabRootView(for tab: AppTab) -> some View {
        switch tab {
        case .chat:
            SessionsListView { session in
                router.navigate(to: .chatSession(session: session), in: .chat)
            }
        case .review:
            ReviewRootView(chatClient: chatClient)
        case .workspace:
            WorkspaceRootView(chatClient: chatClient)
        case .settings:
            SettingsView()
        }
    }

    @ViewBuilder
    private func destinationView(for destination: RouterDestination) -> some View {
        switch destination {
        case .chatSession(let session):
            SessionChatDestinationView(chatClient: chatClient, session: session)
        case .sessionInsights(let sessionID):
            InsightsRootView(chatClient: chatClient, sessionID: sessionID)
        case .reviewMessage, .reviewFile, .workspacePath:
            EmptyView()
        }
    }
}

private struct SessionChatDestinationView: View {
    @Bindable var chatClient: ChatClient
    let session: OCSession

    @State private var isReady = false

    var body: some View {
        Group {
            if isReady {
                ChatView(chatClient: chatClient)
            } else {
                ProgressView()
                    .tint(Color.appSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.appBackground)
            }
        }
        .task(id: session.id) {
            if chatClient.currentSession?.id != session.id {
                await chatClient.loadSession(session)
            }
            isReady = true
        }
    }
}
