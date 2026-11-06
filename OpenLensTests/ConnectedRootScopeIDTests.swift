import Testing
@testable import OpenLens

extension MultiServerSuite {
    @Suite struct ViewScoping {
        @Test func sessionsAndSettingsKeepTheirIdentityAcrossAServerSwitch() {
            for tab in [AppTab.chat, .settings] {
                #expect(scopeID(for: tab, activeServerID: "a") == scopeID(for: tab, activeServerID: "b"))
                #expect(scopeID(for: tab, activeServerID: nil) == scopeID(for: tab, activeServerID: "b"))
            }
        }

        @Test func serverScopedTabsGetANewIdentityPerServer() {
            for tab in [AppTab.review, .workspace, .micro] {
                #expect(scopeID(for: tab, activeServerID: "a") != scopeID(for: tab, activeServerID: "b"))
            }
        }

        @Test func serverScopedTabsKeepTheirIdentityWhileTheServerStaysTheSame() {
            #expect(scopeID(for: .review, activeServerID: "a") == scopeID(for: .review, activeServerID: "a"))
        }

        @Test func differentTabsNeverShareAnIdentity() {
            let ids = AppTab.allCases.map { scopeID(for: $0, activeServerID: "a") }
            #expect(Set(ids).count == ids.count)
        }

        @Test func sameSessionIDOnDifferentServersIsADifferentDestination() {
            let session = OCSession(id: "s", title: "t", time: OCSessionTime(created: 0, updated: 0))
            let a = RouterDestination.chatSession(session: session, serverID: "a")
            let b = RouterDestination.chatSession(session: session, serverID: "b")

            #expect(a != b)
            #expect(a.hashValue != b.hashValue)
            #expect(Set([a, b]).count == 2)
        }
    }
}
