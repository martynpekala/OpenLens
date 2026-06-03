import SwiftUI

func shouldHideConnectedRootTabBar(selectedTab: AppTab, chatPath: [RouterDestination]) -> Bool {
    selectedTab == .chat && !chatPath.isEmpty
}

struct ConnectedRootView: View {
    @Bindable var chatClient: ChatClient

    @Environment(AppRouter.self) private var router

    var body: some View {
        @Bindable var router = router

        TabView(selection: $router.selectedTab) {
            Tab(value: AppTab.chat) {
                tabNavigationView(for: .chat)
            } label: {
                tabLabel(for: .chat, selectedTab: router.selectedTab)
            }
            Tab(value: AppTab.review) {
                tabNavigationView(for: .review)
            } label: {
                tabLabel(for: .review, selectedTab: router.selectedTab)
            }
            Tab(value: AppTab.workspace) {
                tabNavigationView(for: .workspace)
            } label: {
                tabLabel(for: .workspace, selectedTab: router.selectedTab)
            }
            Tab(value: AppTab.settings, role: .search) {
                tabNavigationView(for: .settings)
            } label: {
                tabLabel(for: .settings, selectedTab: router.selectedTab)
            }
        }
        .tint(Color.appPrimary)
    }

    private func tabLabel(for tab: AppTab, selectedTab: AppTab) -> some View {
        Label(tab.title, systemImage: tab.icon)
            .environment(\.symbolVariants, selectedTab == tab ? .fill : .none)
    }

    private var tabBarVisibility: Visibility {
        shouldHideConnectedRootTabBar(
            selectedTab: router.selectedTab,
            chatPath: router.chatPath
        ) ? .hidden : .visible
    }

    private func tabNavigationView(for tab: AppTab) -> some View {
        NavigationStack(path: pathBinding(for: tab)) {
            tabRootView(for: tab)
                .navigationDestination(for: RouterDestination.self) { destination in
                    destinationView(for: destination)
                }
        }
        // Keep this on the tab NavigationStack so TabView reliably hides the bar when Chat pushes a session.
        .toolbar(tabBarVisibility, for: .tabBar)
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
