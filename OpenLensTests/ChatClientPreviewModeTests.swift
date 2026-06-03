import Testing
@testable import OpenLens

struct ChatClientPreviewModeTests {

    @Test func recentSessionModelSelectionUsesLatestMessageWithResolvedModel() {
        let messages = [
            ChatMessage(
                id: "assistant-1",
                role: .assistant,
                content: "Earlier",
                modelID: "gpt-4.1",
                providerID: "openai"
            ),
            ChatMessage(
                id: "user-1",
                role: .user,
                content: "Later",
                modelID: "claude-sonnet-4-20250514",
                providerID: "anthropic"
            )
        ]

        let selection = ChatClient.recentSessionModelSelection(from: messages)

        #expect(selection?.providerID == "anthropic")
        #expect(selection?.modelID == "claude-sonnet-4-20250514")
    }

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
