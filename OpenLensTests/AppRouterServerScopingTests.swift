import Testing
@testable import OpenLens

extension MultiServerSuite {
    @Suite struct Routing {
        private let session = OCSession(
            id: "session-1",
            title: "Shared id",
            time: OCSessionTime(created: 0, updated: 0)
        )

        @Test func eachServerKeepsItsOwnPaths() {
            let router = AppRouter()
            router.activate(serverID: "a")
            router.selectChatSession(session)
            router.activate(serverID: "b")

            #expect(router.chatPath.isEmpty)

            router.navigate(to: .archivedSessions, in: .chat)
            router.activate(serverID: "a")

            #expect(router.chatPath == [.chatSession(session: session, serverID: "a")])
        }

        @Test func switchingAwayAndBackRestoresThePreviousPaths() {
            let router = AppRouter()
            router.activate(serverID: "a")
            router.selectChatSession(session)
            router.navigate(to: .sessionInsights(sessionID: session.id), in: .chat)
            router.navigate(to: .reviewFile(path: "x.swift"), in: .review)
            let chat = router.chatPath
            let review = router.reviewPath

            router.activate(serverID: "b")
            router.activate(serverID: "a")

            #expect(router.chatPath == chat)
            #expect(router.reviewPath == review)
        }

        @Test func removingAServerForgetsItsPaths() {
            let router = AppRouter()
            router.activate(serverID: "a")
            router.selectChatSession(session)
            router.activate(serverID: "b")

            router.forgetServer("a")
            router.activate(serverID: "a")

            #expect(router.chatPath.isEmpty)
        }

        @Test func forgettingAServerLeavesOtherServersPathsAlone() {
            let router = AppRouter()
            router.activate(serverID: "a")
            router.selectChatSession(session)
            router.activate(serverID: "b")
            router.selectChatSession(session)

            router.forgetServer("a")

            #expect(router.chatPath == [.chatSession(session: session, serverID: "b")])
        }

        @Test func theSelectedTabIsNotPerServer() {
            let router = AppRouter()
            router.activate(serverID: "a")
            router.selectedTab = .workspace

            router.activate(serverID: "b")

            #expect(router.selectedTab == .workspace)
        }

        @Test func pathAccessorsReadAndWriteTheActiveServersPaths() {
            let router = AppRouter()
            router.activate(serverID: "a")
            router.setPath([.archivedSessions], for: .settings)

            #expect(router.path(for: .settings) == [.archivedSessions])
            #expect(router.settingsPath == [.archivedSessions])

            router.activate(serverID: "b")
            #expect(router.path(for: .settings).isEmpty)
        }
    }
}
