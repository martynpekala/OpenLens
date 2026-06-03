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

    @Test func hidesTabBarWhenReturningFromSettingsIntoChatSession() {
        #expect(shouldHideConnectedRootTabBar(
            selectedTab: .chat,
            chatPath: [.chatSession(session: session)]
        ))
    }
}
