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

        let hasTaskPart = events.contains { event in
            if case .toolCallPart(let name, _, _, _, _) = event {
                return name.lowercased() == "task"
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
        #expect(hasTaskPart)
        #expect(hasLongResponse)
        #expect(hasRapidDeltaCadence)
    }

    @Test func heavyLoadProfileSeedsHistoryBeforeStreaming() {
        let events = DemoScript.heavyLoad.events

        #expect(events.contains { event in
            if case .seedHistory(let messageCount) = event {
                return messageCount >= 100
            }
            return false
        })
        #expect(events.contains { event in
            if case .streamReasoning(_, let chunkSize, let delay) = event {
                return chunkSize > 1 && delay < 0.02
            }
            return false
        })
        #expect(events.contains { event in
            if case .streamText(_, let chunkSize, let delay) = event {
                return chunkSize > 1 && delay < 0.02
            }
            return false
        })
    }

    @Test func concurrentSendProfileInjectsAUserMessageDuringStreaming() {
        let events = DemoScript.concurrentSend.events

        guard let event = events.first(where: { event in
            if case .streamTextWithConcurrentSend = event { return true }
            return false
        }) else {
            Issue.record("Expected the concurrent-send stress event")
            return
        }

        guard case .streamTextWithConcurrentSend(
            _,
            let chunkSize,
            let delay,
            let userMessage,
            let after
        ) = event else {
            Issue.record("Expected the concurrent-send stress event payload")
            return
        }

        #expect(chunkSize > 1)
        #expect(delay < 0.02)
        #expect(after > 0)
        #expect(userMessage.contains("streaming"))
    }

    @Test func resolveDefaultModelSelectionPrefersSavedDefaultWhenAvailable() {
        let models = [
            ChatClient.SelectableModel(
                providerID: "anthropic",
                providerName: "Anthropic",
                modelID: "claude-sonnet-4-20250514",
                modelName: "Claude Sonnet 4",
                reasoning: true,
                attachment: true,
                toolCall: true,
                cost: nil,
                limit: nil,
                variants: []
            ),
            ChatClient.SelectableModel(
                providerID: "openai",
                providerName: "OpenAI",
                modelID: "gpt-5",
                modelName: "GPT-5",
                reasoning: true,
                attachment: true,
                toolCall: true,
                cost: nil,
                limit: nil,
                variants: []
            )
        ]

        let selection = ChatClient.resolveDefaultModelSelection(
            savedDefault: (providerID: "anthropic", modelID: "claude-sonnet-4-20250514"),
            serverDefault: (providerID: "openai", modelID: "gpt-5"),
            configDefault: nil,
            availableModels: models
        )

        #expect(selection.providerID == "anthropic")
        #expect(selection.modelID == "claude-sonnet-4-20250514")
        #expect(selection.unavailableDefaultModelID == nil)
    }

    @Test func resolveDefaultModelSelectionFallsBackFromUnavailableSavedDefault() {
        let models = [
            ChatClient.SelectableModel(
                providerID: "openai",
                providerName: "OpenAI",
                modelID: "gpt-5",
                modelName: "GPT-5",
                reasoning: true,
                attachment: true,
                toolCall: true,
                cost: nil,
                limit: nil,
                variants: []
            )
        ]

        let selection = ChatClient.resolveDefaultModelSelection(
            savedDefault: (providerID: "anthropic", modelID: "claude-sonnet-4-20250514"),
            serverDefault: (providerID: "openai", modelID: "gpt-5"),
            configDefault: nil,
            availableModels: models
        )

        #expect(selection.providerID == "openai")
        #expect(selection.modelID == "gpt-5")
        #expect(selection.unavailableDefaultModelID == "claude-sonnet-4-20250514")
    }

    @Test func resolveDefaultModelSelectionFallsBackToConfigDefault() {
        let models = [
            ChatClient.SelectableModel(
                providerID: "anthropic",
                providerName: "Anthropic",
                modelID: "claude-sonnet-4-20250514",
                modelName: "Claude Sonnet 4",
                reasoning: true,
                attachment: true,
                toolCall: true,
                cost: nil,
                limit: nil,
                variants: []
            )
        ]

        let selection = ChatClient.resolveDefaultModelSelection(
            savedDefault: nil,
            serverDefault: nil,
            configDefault: (providerID: "anthropic", modelID: "claude-sonnet-4-20250514"),
            availableModels: models
        )

        #expect(selection.providerID == "anthropic")
        #expect(selection.modelID == "claude-sonnet-4-20250514")
        #expect(selection.unavailableDefaultModelID == nil)
    }

    @Test func resolveDefaultModelSelectionReturnsUnavailableSignalWithoutFallback() {
        let selection = ChatClient.resolveDefaultModelSelection(
            savedDefault: (providerID: "anthropic", modelID: "claude-sonnet-4-20250514"),
            serverDefault: nil,
            configDefault: nil,
            availableModels: []
        )

        #expect(selection.providerID == nil)
        #expect(selection.modelID == nil)
        #expect(selection.unavailableDefaultModelID == "claude-sonnet-4-20250514")
    }
}
