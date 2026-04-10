import SwiftUI

private enum InsightsLayout {
    static let screenInset: CGFloat = 20
    static let screenVerticalPadding: CGFloat = 24
    static let sectionGap: CGFloat = 24
    static let groupGap: CGFloat = 12
    static let rowPaddingHorizontal: CGFloat = 16
    static let rowPaddingVertical: CGFloat = 14
    static let cardCornerRadius: CGFloat = 10
    static let metricCornerRadius: CGFloat = 8
}

struct InsightsRootView: View {
    @Bindable var chatClient: ChatClient
    let sessionID: String?

    @Environment(\.sessionInsightsService) private var sessionInsightsService
    @State private var snapshot: SessionInsightsSnapshot?

    private struct SnapshotRefreshToken: Equatable {
        let sessionID: String?
        let sessionTitle: String?
        let messageCount: Int
        let lastMessageID: String?
    }

    private var snapshotRefreshToken: SnapshotRefreshToken {
        let messages = chatClient.messages
        return SnapshotRefreshToken(
            sessionID: sessionID ?? chatClient.currentSession?.id,
            sessionTitle: chatClient.currentSession?.title,
            messageCount: messages.count,
            lastMessageID: messages.last?.id
        )
    }

    var body: some View {
        Group {
            if let snapshot {
                content(snapshot)
            } else {
                FeaturePlaceholderView(
                    title: "Insights",
                    subtitle: "Open a session with assistant responses to inspect local cost and token usage.",
                    symbol: "chart.bar.xaxis",
                    highlights: [
                        "Session cost overview",
                        "Token usage by type",
                        "Model and response-level breakdown"
                    ]
                )
            }
        }
        .task(id: snapshotRefreshToken) {
            refreshSnapshot()
        }
    }

    private func content(_ snapshot: SessionInsightsSnapshot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: InsightsLayout.sectionGap) {
                SectionLabel(text: "INSIGHTS")

                overviewCard(snapshot)
                tokenCard(snapshot)
                modelsCard(snapshot)
                expensiveResponsesCard(snapshot)
                recentResponsesCard(snapshot)
            }
            .padding(.horizontal, InsightsLayout.screenInset)
            .padding(.vertical, InsightsLayout.screenVerticalPadding)
        }
        .background(Color.appBackground)
        .navigationTitle("Insights")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func overviewCard(_ snapshot: SessionInsightsSnapshot) -> some View {
        SurfaceCard(padding: 18, cornerRadius: InsightsLayout.cardCornerRadius) {
            VStack(alignment: .leading, spacing: InsightsLayout.groupGap) {
                Text(snapshot.sessionTitle.isEmpty ? "Current Session" : snapshot.sessionTitle)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Color.appPrimary)

                Text("Local session usage summary")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.appSecondary)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        metricPanel(title: "Responses", value: numberString(snapshot.responseCount))
                        metricPanel(title: "Models", value: numberString(snapshot.modelBreakdown.count))
                        metricPanel(title: "Avg cost", value: currencyString(snapshot.averageCost))
                    }

                    VStack(spacing: 10) {
                        metricPanel(title: "Responses", value: numberString(snapshot.responseCount))
                        metricPanel(title: "Models", value: numberString(snapshot.modelBreakdown.count))
                        metricPanel(title: "Avg cost", value: currencyString(snapshot.averageCost))
                    }
                }

                SurfaceDivider()

                summaryRow(title: "Total cost", value: currencyString(snapshot.totalCost), emphasis: true)
                summaryRow(title: "Total tokens", value: numberString(snapshot.totalTokenCount), emphasis: false)
            }
        }
    }

    private func tokenCard(_ snapshot: SessionInsightsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "TOKENS")
            SurfaceCard(padding: 0, cornerRadius: InsightsLayout.cardCornerRadius) {
                VStack(spacing: 0) {
                    tokenRow(title: "Input", value: numberString(snapshot.totalInputTokens))
                    SurfaceDivider()
                    tokenRow(title: "Output", value: numberString(snapshot.totalOutputTokens))
                    SurfaceDivider()
                    tokenRow(title: "Reasoning", value: numberString(snapshot.totalReasoningTokens))
                    SurfaceDivider()
                    tokenRow(title: "Cache read", value: numberString(snapshot.totalCacheReadTokens))
                    SurfaceDivider()
                    tokenRow(title: "Cache write", value: numberString(snapshot.totalCacheWriteTokens))
                }
            }
        }
    }

    private func modelsCard(_ snapshot: SessionInsightsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "MODELS")
            SurfaceCard(padding: 0, cornerRadius: InsightsLayout.cardCornerRadius) {
                if snapshot.modelBreakdown.isEmpty {
                    emptyRow("No model usage data available.")
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(snapshot.modelBreakdown.enumerated()), id: \.element.id) { index, item in
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.label)
                                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(Color.appPrimary)
                                    Text("\(numberString(item.responseCount)) responses")
                                        .font(.system(size: 12))
                                        .foregroundStyle(Color.appSecondary)
                                }

                                Spacer()

                                VStack(alignment: .trailing, spacing: 4) {
                                    Text(currencyString(item.totalCost))
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(Color.appPrimary)
                                    Text(numberString(item.totalTokens) + " tokens")
                                        .font(.system(size: 12))
                                        .foregroundStyle(Color.appSecondary)
                                }
                            }
                            .padding(.horizontal, InsightsLayout.rowPaddingHorizontal)
                            .padding(.vertical, InsightsLayout.rowPaddingVertical)

                            if index < snapshot.modelBreakdown.count - 1 {
                                SurfaceDivider()
                            }
                        }
                    }
                }
            }
        }
    }

    private func expensiveResponsesCard(_ snapshot: SessionInsightsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "MOST EXPENSIVE")
            responsesCard(Array(snapshot.expensiveResponses.prefix(5)))
        }
    }

    private func recentResponsesCard(_ snapshot: SessionInsightsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "RECENT RESPONSES")
            responsesCard(Array(snapshot.recentResponses.prefix(5)))
        }
    }

    private func responsesCard(_ responses: [InsightsMessageSummary]) -> some View {
        SurfaceCard(padding: 0, cornerRadius: InsightsLayout.cardCornerRadius) {
            if responses.isEmpty {
                emptyRow("No assistant responses available yet.")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(responses.enumerated()), id: \.element.id) { index, response in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(response.title)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Color.appPrimary)
                                .lineLimit(2)

                            HStack(spacing: 10) {
                                Text(response.modelLabel)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(Color.appSecondary)
                                    .lineLimit(1)

                                Spacer()

                                Text(response.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.appSecondary)
                            }

                            HStack(spacing: 10) {
                                metricTag(currencyString(response.cost))
                                metricTag(numberString(response.totalTokens) + " tok")

                                if response.reasoningTokens > 0 {
                                    metricTag(numberString(response.reasoningTokens) + " reas")
                                }
                            }
                        }
                        .padding(.horizontal, InsightsLayout.rowPaddingHorizontal)
                        .padding(.vertical, InsightsLayout.rowPaddingVertical)

                        if index < responses.count - 1 {
                            SurfaceDivider()
                        }
                    }
                }
            }
        }
    }

    private func tokenRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.appPrimary)
            Spacer()
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.appSecondary)
        }
        .padding(.horizontal, InsightsLayout.rowPaddingHorizontal)
        .padding(.vertical, InsightsLayout.rowPaddingVertical)
    }

    private func metricPanel(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.appSecondary)
            Text(value)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Color.appPrimary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: InsightsLayout.metricCornerRadius, style: .continuous)
                .fill(Color.appTertiary)
        )
    }

    private func metricTag(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.appPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: InsightsLayout.metricCornerRadius, style: .continuous)
                    .fill(Color.appTertiary)
            )
    }

    private func summaryRow(title: String, value: String, emphasis: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.appSecondary)
                .kerning(0.4)

            Spacer(minLength: 8)

            Text(value)
                .font(.system(size: emphasis ? 24 : 16, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.appPrimary)
        }
    }

    private func emptyRow(_ text: String) -> some View {
        HStack {
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(Color.appSecondary)
            Spacer()
        }
        .padding(.horizontal, InsightsLayout.rowPaddingHorizontal)
        .padding(.vertical, InsightsLayout.rowPaddingVertical)
    }

    private func numberString(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    private func currencyString(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }

    private func refreshSnapshot() {
        snapshot = sessionInsightsService.makeSnapshot(
            sessionID: sessionID ?? chatClient.currentSession?.id,
            sessionTitle: chatClient.currentSession?.title,
            messages: chatClient.messages
        )
    }
}
