import Testing
@testable import OpenLens

@MainActor
struct PendingAppActionsTests {

    @Test func aNewSessionRequestIsConsumedOnlyOnce() {
        let actions = PendingAppActions()

        actions.requestNewSession(title: "Fix login bug")

        #expect(actions.newSessionRequest == NewSessionRequest(title: "Fix login bug"))
        #expect(actions.consumeNewSessionRequest() == NewSessionRequest(title: "Fix login bug"))
        #expect(actions.newSessionRequest == nil)
        #expect(actions.consumeNewSessionRequest() == nil)
    }

    @Test func consumingWithoutARequestDoesNothing() {
        let actions = PendingAppActions()

        #expect(actions.consumeNewSessionRequest() == nil)
        #expect(actions.newSessionRequest == nil)
    }

    @Test func theNameIsTrimmed() {
        let actions = PendingAppActions()

        actions.requestNewSession(title: "  Release notes\n")

        #expect(actions.consumeNewSessionRequest()?.title == "Release notes")
    }

    @Test func aBlankNameLeavesTheSessionUntitled() {
        let actions = PendingAppActions()

        actions.requestNewSession(title: "   ")

        let request = actions.consumeNewSessionRequest()
        #expect(request != nil)
        #expect(request?.title == nil)
    }

    @Test func theLatestRequestBeforeConnectingWins() {
        let actions = PendingAppActions()

        actions.requestNewSession(title: "First")
        actions.requestNewSession(title: "Second")

        #expect(actions.consumeNewSessionRequest()?.title == "Second")
        #expect(actions.consumeNewSessionRequest() == nil)
    }

    @Test func newSessionShortcutIsOfferedToSpotlightAndSiri() {
        #expect(OpenLensShortcuts.appShortcuts.count == 1)
    }
}
