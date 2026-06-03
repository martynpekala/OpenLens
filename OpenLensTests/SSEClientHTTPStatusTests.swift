import Testing
@testable import OpenLens

struct SSEClientHTTPStatusTests {

    @Test func treats401AsTerminalAuthFailure() {
        #expect(isTerminalSSEHTTPStatus(401))
    }

    @Test func treats403AsTerminalAuthFailure() {
        #expect(isTerminalSSEHTTPStatus(403))
    }

    @Test func keepsReconnectableStatusesNonTerminal() {
        #expect(!isTerminalSSEHTTPStatus(200))
        #expect(!isTerminalSSEHTTPStatus(429))
        #expect(!isTerminalSSEHTTPStatus(500))
    }
}