import Foundation
import Testing
@testable import OpenLens

struct SessionInsightsServiceTests {

    @Test func aggregatesAssistantResponseUsage() {
        let service = SessionInsightsService()
        let messages = [
            ChatMessage(
                id: "assistant-1",
                role: .assistant,
                content: "First response",
                createdAt: Date(timeIntervalSince1970: 100),
                cost: 1.25,
                tokens: OCTokenUsage(input: 120, output: 80, reasoning: 20, cache: OCCacheTokens(read: 10, write: 5)),
                modelID: "gpt-5",
                providerID: "openai"
            ),
            ChatMessage(
                id: "assistant-2",
                role: .assistant,
                content: "Second response",
                createdAt: Date(timeIntervalSince1970: 200),
                cost: 0.75,
                tokens: OCTokenUsage(input: 60, output: 40, reasoning: 0, cache: OCCacheTokens(read: 0, write: 0)),
                modelID: "gpt-5",
                providerID: "openai"
            ),
            ChatMessage(
                id: "user-1",
                role: .user,
                content: "Ignored user message",
                createdAt: Date(timeIntervalSince1970: 150)
            )
        ]

        let snapshot = service.makeSnapshot(sessionID: "session-1", sessionTitle: "Test Session", messages: messages)

        let resolvedSnapshot = snapshot
        #expect(resolvedSnapshot != nil)
        #expect(resolvedSnapshot?.responseCount == 2)
        #expect(resolvedSnapshot?.totalCost == 2.0)
        #expect(resolvedSnapshot?.averageCost == 1.0)
        #expect(resolvedSnapshot?.totalInputTokens == 180)
        #expect(resolvedSnapshot?.totalOutputTokens == 120)
        #expect(resolvedSnapshot?.totalReasoningTokens == 20)
        #expect(resolvedSnapshot?.totalCacheReadTokens == 10)
        #expect(resolvedSnapshot?.totalCacheWriteTokens == 5)
        #expect(resolvedSnapshot?.totalTokenCount == 335)
        #expect(resolvedSnapshot?.modelBreakdown.count == 1)
        #expect(resolvedSnapshot?.modelBreakdown.first?.label == "openai/gpt-5")
        #expect(resolvedSnapshot?.recentResponses.first?.id == "assistant-2")
        #expect(resolvedSnapshot?.expensiveResponses.first?.id == "assistant-1")
    }
}