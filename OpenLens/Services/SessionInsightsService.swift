import Foundation

struct SessionInsightsSnapshot: Sendable {
    let sessionID: String
    let sessionTitle: String
    let responseCount: Int
    let totalCost: Double
    let averageCost: Double
    let totalInputTokens: Int
    let totalOutputTokens: Int
    let totalReasoningTokens: Int
    let totalCacheReadTokens: Int
    let totalCacheWriteTokens: Int
    let modelBreakdown: [InsightsModelBreakdown]
    let recentResponses: [InsightsMessageSummary]
    let expensiveResponses: [InsightsMessageSummary]

    var totalTokenCount: Int {
        totalInputTokens + totalOutputTokens + totalReasoningTokens + totalCacheReadTokens + totalCacheWriteTokens
    }
}

struct InsightsModelBreakdown: Identifiable, Sendable {
    let id: String
    let label: String
    let responseCount: Int
    let totalCost: Double
    let totalTokens: Int
}

struct InsightsMessageSummary: Identifiable, Sendable {
    let id: String
    let title: String
    let modelLabel: String
    let createdAt: Date
    let cost: Double
    let inputTokens: Int
    let outputTokens: Int
    let reasoningTokens: Int

    var totalTokens: Int {
        inputTokens + outputTokens + reasoningTokens
    }
}

final class SessionInsightsService {

    func makeSnapshot(sessionID: String?, sessionTitle: String?, messages: [ChatMessage]) -> SessionInsightsSnapshot? {
        guard let sessionID else { return nil }

        let assistantMessages = messages.filter { $0.role == .assistant && !$0.isStreaming }

        guard !assistantMessages.isEmpty else {
            return SessionInsightsSnapshot(
                sessionID: sessionID,
                sessionTitle: sessionTitle?.trimmedNilIfBlank ?? "Current Session",
                responseCount: 0,
                totalCost: 0,
                averageCost: 0,
                totalInputTokens: 0,
                totalOutputTokens: 0,
                totalReasoningTokens: 0,
                totalCacheReadTokens: 0,
                totalCacheWriteTokens: 0,
                modelBreakdown: [],
                recentResponses: [],
                expensiveResponses: []
            )
        }

        var totalCost = 0.0
        var totalInput = 0
        var totalOutput = 0
        var totalReasoning = 0
        var totalCacheRead = 0
        var totalCacheWrite = 0
        var grouped: [String: [ChatMessage]] = [:]

        let messageSummaries = assistantMessages.map { message -> InsightsMessageSummary in
            let cost = message.cost ?? 0
            let input = message.tokens?.inputValue ?? 0
            let output = message.tokens?.outputValue ?? 0
            let reasoning = message.tokens?.reasoningValue ?? 0
            let cacheRead = message.tokens?.cacheReadValue ?? 0
            let cacheWrite = message.tokens?.cacheWriteValue ?? 0

            totalCost += cost
            totalInput += input
            totalOutput += output
            totalReasoning += reasoning
            totalCacheRead += cacheRead
            totalCacheWrite += cacheWrite

            let modelLabel = Self.modelLabel(for: message)
            grouped[modelLabel, default: []].append(message)

            return InsightsMessageSummary(
                id: message.id,
                title: Self.messageTitle(for: message),
                modelLabel: modelLabel,
                createdAt: message.createdAt,
                cost: cost,
                inputTokens: input,
                outputTokens: output,
                reasoningTokens: reasoning
            )
        }

        let modelBreakdown = grouped.map { label, messages in
            InsightsModelBreakdown(
                id: label,
                label: label,
                responseCount: messages.count,
                totalCost: messages.reduce(0) { $0 + ($1.cost ?? 0) },
                totalTokens: messages.reduce(0) { $0 + ($1.tokens?.total ?? 0) }
            )
        }
        .sorted { lhs, rhs in
            if lhs.totalCost == rhs.totalCost {
                return lhs.responseCount > rhs.responseCount
            }
            return lhs.totalCost > rhs.totalCost
        }

        let recentResponses = messageSummaries.sorted { $0.createdAt > $1.createdAt }
        let expensiveResponses = messageSummaries.sorted { lhs, rhs in
            if lhs.cost == rhs.cost {
                return lhs.createdAt > rhs.createdAt
            }
            return lhs.cost > rhs.cost
        }

        return SessionInsightsSnapshot(
            sessionID: sessionID,
            sessionTitle: sessionTitle?.trimmedNilIfBlank ?? "Current Session",
            responseCount: assistantMessages.count,
            totalCost: totalCost,
            averageCost: totalCost / Double(assistantMessages.count),
            totalInputTokens: totalInput,
            totalOutputTokens: totalOutput,
            totalReasoningTokens: totalReasoning,
            totalCacheReadTokens: totalCacheRead,
            totalCacheWriteTokens: totalCacheWrite,
            modelBreakdown: modelBreakdown,
            recentResponses: recentResponses,
            expensiveResponses: expensiveResponses
        )
    }

    private static func modelLabel(for message: ChatMessage) -> String {
        if let provider = message.providerID?.trimmedNilIfBlank,
           let model = message.modelID?.trimmedNilIfBlank {
            return "\(provider)/\(model)"
        }
        if let model = message.modelID?.trimmedNilIfBlank {
            return model
        }
        return "Unknown model"
    }

    private static func messageTitle(for message: ChatMessage) -> String {
        let normalized = message.content
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalized.isEmpty else {
            return message.finish?.trimmedNilIfBlank ?? "Assistant response"
        }

        let collapsed = normalized.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        if collapsed.count <= 88 {
            return collapsed
        }

        let cutoff = collapsed.index(collapsed.startIndex, offsetBy: 88)
        return String(collapsed[..<cutoff]) + "..."
    }
}

private extension String {
    var trimmedNilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}