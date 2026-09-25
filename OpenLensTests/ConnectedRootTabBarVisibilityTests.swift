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

    @Test func compactWidthKeepsPhoneTabBar() {
        #expect(!shouldUseConnectedRootSidebarLayout(horizontalSizeClass: .compact))
        #expect(!shouldUseConnectedRootSidebarLayout(horizontalSizeClass: nil))
    }
}
