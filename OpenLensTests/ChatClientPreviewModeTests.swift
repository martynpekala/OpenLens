import Testing
@testable import OpenLens

struct ChatClientPreviewModeTests {

    @Test func recognizesOnlyTheDedicatedUndoSlashCommand() {
        #expect(ChatClient.isUndoCommand("/undo"))
        #expect(ChatClient.isUndoCommand("  /UNDO  "))
        #expect(!ChatClient.isUndoCommand("/undo this"))
        #expect(!ChatClient.isUndoCommand("undo"))
    }

    @Test func revertedTurnAndLaterMessagesAreHidden() {
        let messages = [
            ChatMessage(id: "message-1", role: .user, content: "Keep"),
            ChatMessage(id: "message-2", role: .assistant, content: "Keep too"),
            ChatMessage(id: "message-3", role: .user, content: "Undo"),
            ChatMessage(id: "message-4", role: .assistant, content: "Remove")
        ]

        let visible = ChatClient.messagesBeforeRevert(
            messages,
            revert: OCSessionRevert(messageID: "message-3")
        )

        #expect(visible.map(\.id) == ["message-1", "message-2"])
    }

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

    @Test func modelPickerSearchMatchesProviderNameModelNameAndIDs() {
        let models = [
            ChatClient.SelectableModel(
                providerID: "anthropic",
                providerName: "Anthropic",
                modelID: "claude-sonnet",
                modelName: "Claude Sonnet",
                reasoning: true,
                attachment: false,
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
                attachment: false,
                toolCall: true,
                cost: nil,
                limit: nil,
                variants: []
            ),
        ]

        #expect(ModelPickerView.models(matching: "Anthropic", from: models).map(\.id) == ["anthropic/claude-sonnet"])
        #expect(ModelPickerView.models(matching: "GPT-5", from: models).map(\.id) == ["openai/gpt-5"])
        #expect(ModelPickerView.models(matching: "anthropic", from: models).map(\.id) == ["anthropic/claude-sonnet"])
        #expect(ModelPickerView.models(matching: "openai/gpt-5", from: models).map(\.id) == ["openai/gpt-5"])
        #expect(ModelPickerView.models(matching: "", from: models).map(\.id) == models.map(\.id))
    }

    @Test func modelPickerOrdersAvailableRecentModelsAndSkipsUnavailableIDs() {
        let models = [
            ChatClient.SelectableModel(
                providerID: "anthropic",
                providerName: "Anthropic",
                modelID: "claude-sonnet",
                modelName: "Claude Sonnet",
                reasoning: true,
                attachment: false,
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
                attachment: false,
                toolCall: true,
                cost: nil,
                limit: nil,
                variants: []
            ),
        ]

        let recent = ModelPickerView.orderedRecentModels(
            from: models,
            recentModelIDs: ["missing/model", "openai/gpt-5", "openai/gpt-5", "anthropic/claude-sonnet"]
        )

        #expect(recent.map(\.id) == ["openai/gpt-5", "anthropic/claude-sonnet"])
    }

    @MainActor
    @Test func modelPickerShowsRuntimeInputMediaAndEveryReportedPriceTier() {
        let model = ChatClient.SelectableModel(
            providerID: "openai",
            providerName: "OpenAI",
            modelID: "gpt-5.2",
            modelName: "GPT-5.2",
            reasoning: false,
            attachment: true,
            toolCall: true,
            cost: nil,
            limit: nil,
            variants: [],
            inputMedia: ["text", "image"],
            costTiers: [
                OCModelCost(input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3),
                OCModelCost(tier: 200_000, input: 6, output: 22, cacheRead: 0.6, cacheWrite: 1.25),
            ]
        )

        #expect(ModelPickerView.inputMediaLabels(for: model) == ["Image"])
        #expect(ModelPickerView.priceTierLabels(for: model) == [
            "$3 in / $15 out / $0.30 cache read / $3 cache write / M",
            "200K ctx: $6 in / $22 out / $0.60 cache read / $1.25 cache write / M",
        ])
    }

    @MainActor
    @Test func modelPickerKeepsLegacyAttachmentAndPricePresentation() {
        let model = ChatClient.SelectableModel(
            providerID: "anthropic",
            providerName: "Anthropic",
            modelID: "claude-sonnet",
            modelName: "Claude Sonnet",
            reasoning: true,
            attachment: true,
            toolCall: true,
            cost: OCModelCost(input: 3, output: nil),
            limit: nil,
            variants: []
        )

        #expect(ModelPickerView.inputMediaLabels(for: model) == [AppText.files])
        #expect(ModelPickerView.priceTierLabels(for: model) == ["$3/M"])
    }

    @MainActor
    @Test func createsDebugPreviewSessionFromSelectedScript() async {
        let client = ChatClient(demoMode: true, script: .debugBaseline)

        await client.ensureSession()

        #expect(client.currentSession?.title == DemoScript.debugBaseline.sessionTitle)
    }

    @MainActor
    @Test func demoModelSelectionTracksRecentModelsWithoutAConnectionStore() {
        let client = ChatClient(demoMode: true)
        let firstModel = ChatClient.SelectableModel(
            providerID: "anthropic",
            providerName: "Anthropic",
            modelID: "claude-sonnet",
            modelName: "Claude Sonnet",
            reasoning: true,
            attachment: false,
            toolCall: true,
            cost: nil,
            limit: nil,
            variants: []
        )
        let secondModel = ChatClient.SelectableModel(
            providerID: "openai",
            providerName: "OpenAI",
            modelID: "gpt-5",
            modelName: "GPT-5",
            reasoning: true,
            attachment: false,
            toolCall: true,
            cost: nil,
            limit: nil,
            variants: []
        )

        client.selectModel(firstModel)
        client.selectModel(secondModel)

        #expect(client.recentModelIDs == ["openai/gpt-5", "anthropic/claude-sonnet"])
    }

    @MainActor
    @Test func quickActionsRememberTheirGlobalModelAssignments() {
        let client = ChatClient(demoMode: true)
        client.clearQuickModelAssignment(for: .code)
        client.clearQuickModelAssignment(for: .review)
        client.clearQuickModelAssignment(for: .prsAndStuff)
        defer {
            client.clearQuickModelAssignment(for: .code)
            client.clearQuickModelAssignment(for: .review)
            client.clearQuickModelAssignment(for: .prsAndStuff)
        }
        let codeModel = ChatClient.SelectableModel(
            providerID: "anthropic",
            providerName: "Anthropic",
            modelID: "claude-sonnet",
            modelName: "Claude Sonnet",
            reasoning: true,
            attachment: false,
            toolCall: true,
            cost: nil,
            limit: nil,
            variants: []
        )
        let reviewModel = ChatClient.SelectableModel(
            providerID: "openai",
            providerName: "OpenAI",
            modelID: "gpt-5",
            modelName: "GPT-5",
            reasoning: true,
            attachment: false,
            toolCall: true,
            cost: nil,
            limit: nil,
            variants: []
        )
        let prsModel = ChatClient.SelectableModel(
            providerID: "google",
            providerName: "Google",
            modelID: "gemini-pro",
            modelName: "Gemini Pro",
            reasoning: true,
            attachment: false,
            toolCall: true,
            cost: nil,
            limit: nil,
            variants: []
        )

        client.assignQuickModel(codeModel, variant: nil, for: .code)
        client.assignQuickModel(reviewModel, variant: nil, for: .review)
        client.assignQuickModel(prsModel, variant: nil, for: .prsAndStuff)

        #expect(client.quickModelAssignment(for: .code)?.id == "anthropic/claude-sonnet")
        #expect(client.quickModelAssignment(for: .review)?.id == "openai/gpt-5")
        #expect(client.quickModelAssignment(for: .prsAndStuff)?.id == "google/gemini-pro")

        client.clearQuickModelAssignment(for: .review)

        #expect(client.quickModelAssignment(for: .review) == nil)
        #expect(client.quickModelAssignment(for: .code)?.id == "anthropic/claude-sonnet")
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

    @Test func resolvesLegacySavedModelIDToAvailableV2CatalogAlias() {
        let catalogModel = ChatClient.SelectableModel(
            providerID: "openai",
            providerName: "OpenAI",
            modelID: "coding-default",
            modelName: "Coding Default",
            reasoning: true,
            attachment: true,
            toolCall: true,
            cost: nil,
            limit: nil,
            variants: []
        )

        let selection = ChatClient.resolveSavedModelSelection(
            providerID: "openai",
            modelID: "gpt-5.2",
            availableModels: [catalogModel],
            legacyModelIDs: ["openai/gpt-5.2": "coding-default"]
        )

        #expect(selection?.id == "openai/coding-default")
    }
}
