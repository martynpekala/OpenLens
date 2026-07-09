import Foundation
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

    @MainActor
    @Test func coalescedTextDeltasPreservePartIDAndStaySeparatedByPart() async {
        let client = SSEClient(baseURL: URL(string: "http://127.0.0.1:1")!)
        var events: [OCEvent] = []
        client.onEvent = { event in
            events.append(event)
        }

        let dataTask = URLSession.shared.dataTask(with: URL(string: "http://127.0.0.1:1/event")!)
        let reasoningDelta = #"data: {"type":"message.part.delta","properties":{"sessionID":"session","messageID":"message","partID":"reasoning-part","field":"text","delta":"think"}}"#
        let textDelta = #"data: {"type":"message.part.delta","properties":{"sessionID":"session","messageID":"message","partID":"text-part","field":"text","delta":"answer"}}"#
        let payload = reasoningDelta + "\n\n" + textDelta + "\n\n"

        client.urlSession(
            URLSession.shared,
            dataTask: dataTask,
            didReceive: Data(payload.utf8)
        )

        try? await Task.sleep(for: .milliseconds(80))

        #expect(events.count == 2)
        #expect((events.first?.properties?.value as? [String: Any])?["partID"] as? String == "reasoning-part")
        #expect((events.last?.properties?.value as? [String: Any])?["partID"] as? String == "text-part")
    }
}
