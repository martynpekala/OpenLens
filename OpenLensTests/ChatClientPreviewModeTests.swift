import Testing
@testable import OpenLens

struct ChatClientPreviewModeTests {

    @MainActor
    @Test func createsDebugPreviewSessionFromSelectedScript() async {
        let client = ChatClient(demoMode: true, script: .debugBaseline)

        await client.ensureSession()

        #expect(client.currentSession?.title == DemoScript.debugBaseline.sessionTitle)
    }

    @Test func debugBaselineIncludesLongStreamingReasoningAndTools() {
        let events = DemoScript.debugBaseline.events

        let hasReasoning = events.contains { event in
            if case .reasoning(let text) = event {
                return !text.isEmpty
            }
            return false
        }

        let hasToolCallPart = events.contains { event in
            if case .toolCallPart(_, _, _, _, _) = event {
                return true
            }
            return false
        }

        let hasLongResponse = events.contains { event in
            if case .streamText(let text, _, _) = event {
                return text.count > 1_500
            }
            return false
        }

        let hasRapidDeltaCadence = events.contains { event in
            if case .streamText(_, let chunkSize, let delay) = event {
                return chunkSize == 1 && delay <= 0.005
            }
            return false
        }

        #expect(hasReasoning)
        #expect(hasToolCallPart)
        #expect(hasLongResponse)
        #expect(hasRapidDeltaCadence)
    }
}
