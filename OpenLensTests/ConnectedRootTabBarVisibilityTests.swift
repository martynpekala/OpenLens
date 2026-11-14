import SwiftUI
import Testing
@testable import OpenLens

struct ConnectedRootTabBarVisibilityTests {
    private let session = OCSession(
        id: "session-1",
        title: "Fix tab bar visibility",
        time: OCSessionTime(created: 0, updated: 0)
    )

    @Test func hidesTabBarWhenChatSessionIsPresented() {
        #expect(shouldHideConnectedRootTabBar(
            selectedTab: .chat,
            chatPath: [.chatSession(session: session)]
        ))
    }

    @Test func showsTabBarOnChatRoot() {
        #expect(!shouldHideConnectedRootTabBar(
            selectedTab: .chat,
            chatPath: []
        ))
    }

    @Test func showsTabBarWhenChatSessionIsBackgrounded() {
        #expect(!shouldHideConnectedRootTabBar(
            selectedTab: .settings,
            chatPath: [.chatSession(session: session)]
        ))
    }

    @Test func selectingAnotherChatSessionReplacesTheDetailRoute() {
        let router = AppRouter()
        let replacement = OCSession(
            id: "session-2",
            title: "Implement iPad split view",
            time: OCSessionTime(created: 0, updated: 1)
        )

        router.selectChatSession(session)
        router.selectChatSession(replacement)

        #expect(router.chatPath == [.chatSession(session: replacement)])
        #expect(router.selectedChatSessionID == replacement.id)
    }

    @Test func deletingTheSelectedChatSessionClearsTheDetailRoute() {
        let router = AppRouter()
        router.selectChatSession(session)

        router.clearChatSession(ifMatching: session.id)

        #expect(router.chatPath.isEmpty)
        #expect(router.selectedChatSessionID == nil)
    }

    @Test func deletingAnotherChatSessionKeepsTheDetailRoute() {
        let router = AppRouter()
        router.selectChatSession(session)

        router.clearChatSession(ifMatching: "another-session")

        #expect(router.chatPath == [.chatSession(session: session)])
    }

    @Test func regularWidthUsesPersistentSidebarInsteadOfTabBar() {
        #expect(shouldUseConnectedRootSidebarLayout(horizontalSizeClass: .regular))
    }

    @Test func sidebarDetailShowsSelectedChatAsRootWithoutBackButton() {
        let insights = RouterDestination.sessionInsights(sessionID: session.id)

        #expect(sidebarChatDetailPath(chatPath: [.chatSession(session: session)]).isEmpty)
        #expect(sidebarChatDetailPath(chatPath: [.chatSession(session: session), insights]) == [insights])
        #expect(sidebarChatDetailPath(chatPath: []).isEmpty)
    }

    @Test func sidebarDetailPopsKeepTheSelectedChatForFolding() {
        let insights = RouterDestination.sessionInsights(sessionID: session.id)
        let fullPath: [RouterDestination] = [.chatSession(session: session), insights]

        #expect(chatPath(fromSidebarDetailPath: [], chatPath: fullPath) == [.chatSession(session: session)])
        #expect(chatPath(fromSidebarDetailPath: [insights], chatPath: [.chatSession(session: session)]) == fullPath)
    }

    @Test func compactWidthKeepsPhoneTabBar() {
        #expect(!shouldUseConnectedRootSidebarLayout(horizontalSizeClass: .compact))
        #expect(!shouldUseConnectedRootSidebarLayout(horizontalSizeClass: nil))
    }
}
