import SwiftUI

/// Chat message bubble view, styled differently for user vs assistant messages.
///
/// Uses a dual-render strategy for assistant messages:
/// - **Streaming** (`isStreaming == true`): plain `Text` — zero markdown parsing cost.
/// - **Completed** (`isStreaming == false`): `MarkdownContentView` — one-time parse.
struct MessageBubbleView: View {
    let message: ChatMessage
    @State private var preparedMarkdownText: String?
    @State private var markdownHandoffTask: Task<Void, Never>?
    @AppStorage("showThinking") private var showThinking: Bool = true
    @Environment(\.openLensTheme) private var theme
    @Environment(\.chatEasterEgg) private var chatEasterEgg

    private static let markdownHandoffDelay: Duration = .milliseconds(120)
    private static let deferredMarkdownThreshold = 600

    private var showsTranscriptStyleAssistantContent: Bool {
        message.role == .assistant
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: isRetroChat ? 6 : 8) {
            if message.role == .user {
                Spacer(minLength: isRetroChat ? 42 : 64)
                userBubble
            } else {
                assistantBubble
                Spacer(minLength: isRetroChat ? 24 : 32)
            }
        }
        .onAppear {
            if message.isStreaming {
                preparedMarkdownText = nil
            } else {
                prepareMarkdownHandoff(deferred: false)
            }
        }
        .onDisappear {
            markdownHandoffTask?.cancel()
            markdownHandoffTask = nil
        }
        .onChange(of: message.isStreaming) { _, isStreaming in
            if isStreaming {
                markdownHandoffTask?.cancel()
                markdownHandoffTask = nil
                preparedMarkdownText = nil
            } else {
                prepareMarkdownHandoff(deferred: true)
            }
        }
        .onChange(of: message.content) { _, _ in
            guard !message.isStreaming else { return }
            prepareMarkdownHandoff(deferred: false)
        }
    }

    // MARK: - User Bubble

    private var userBubble: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(message.content)
                .font(isRetroChat ? RetroChatStyle.bodyFont : .system(size: 16))
                .foregroundStyle(isRetroChat ? RetroChatStyle.ink : Color.appOnAccent)
                .padding(.horizontal, isRetroChat ? 14 : 16)
                .padding(.vertical, isRetroChat ? 10 : 11)
                .background {
                    if isRetroChat {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(RetroChatStyle.playerFill)
                            .shadow(color: RetroChatStyle.shadow, radius: 0, x: 3, y: 3)
                    } else {
                        bubbleFill(theme.colors.accent.color)
                    }
                }
                .overlay {
                    if isRetroChat {
                        RetroChatDoubleBorder(cornerRadius: 7)
                    } else {
                        bubbleStroke(theme.components.controlBorder)
                    }
                }
        }
    }

    // MARK: - Assistant Bubble

    private var assistantBubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(message.assistantSegments) { segment in
                segmentView(segment)
            }

            if message.isStreaming,
               !message.hasRenderableTextPart,
               let text = message.content.nilIfBlank {
                assistantTextBubble(text, usesDeferredMarkdownHandoff: true)
            }

            if let cost = message.cost, cost > 0 {
                if !showsTranscriptStyleAssistantContent {
                    Text(String(format: "$%.4f", cost))
                        .font(.system(size: 11))
                        .foregroundStyle(Color.appSecondary.opacity(0.5))
                }
            }
        }
        .padding(isRetroChat ? 12 : 0)
        .background {
            if isRetroChat {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(RetroChatStyle.paper)
                    .shadow(color: RetroChatStyle.shadow, radius: 0, x: 3, y: 3)
            }
        }
        .overlay {
            if isRetroChat {
                RetroChatDoubleBorder(cornerRadius: 7)
            }
        }
    }

    // MARK: - Segments

    @ViewBuilder
    private func segmentView(_ segment: ChatMessage.AssistantSegment) -> some View {
        switch segment.kind {
        case .text(let text):
            assistantTextBubble(
                text,
                usesDeferredMarkdownHandoff: !message.hasRenderableTextPart
            )
        case .reasoning(let text):
            if showThinking {
                reasoningSegment(text: text)
            }
        case .tool(let step):
            toolSegment(step)
        }
    }

    private func assistantTextBubble(_ text: String, usesDeferredMarkdownHandoff: Bool) -> some View {
        Group {
            if shouldRenderMarkdown(text, usesDeferredMarkdownHandoff: usesDeferredMarkdownHandoff) {
                MarkdownContentView(
                    text,
                    foregroundColor: isRetroChat ? RetroChatStyle.ink : Color.appPrimary,
                    usesRetroTypography: isRetroChat
                )
            } else {
                Text(text)
                    .font(isRetroChat ? RetroChatStyle.bodyFont : .system(size: 16))
                    .foregroundStyle(isRetroChat ? RetroChatStyle.ink : Color.appPrimary)
            }
        }
        .padding(.horizontal, showsTranscriptStyleAssistantContent ? 0 : 16)
        .padding(.vertical, showsTranscriptStyleAssistantContent ? 0 : 12)
        .background {
            if !showsTranscriptStyleAssistantContent {
                bubbleFill(theme.colors.surface.color)
            }
        }
        .overlay {
            if !showsTranscriptStyleAssistantContent {
                bubbleStroke(theme.components.surfaceBorder)
            }
        }
        .overlay {
            if !showsTranscriptStyleAssistantContent {
                bubbleInnerStroke(
                    theme.components.surfaceInnerBorder,
                    outerWidth: theme.components.surfaceBorder.width
                )
            }
        }
        .modifier(AssistantTranscriptShadow(enabled: !showsTranscriptStyleAssistantContent))
        .animation(nil, value: text)
    }

    private func shouldRenderMarkdown(_ text: String, usesDeferredMarkdownHandoff: Bool) -> Bool {
        guard !message.isStreaming else { return false }
        guard usesDeferredMarkdownHandoff else { return true }
        return preparedMarkdownText == text
    }

    private func prepareMarkdownHandoff(deferred: Bool) {
        markdownHandoffTask?.cancel()
        markdownHandoffTask = nil

        guard let text = deferredMarkdownText else {
            preparedMarkdownText = nil
            return
        }

        guard deferred,
              shouldDeferMarkdownHandoff(for: text),
              !MarkdownContentView.isCached(text)
        else {
            preparedMarkdownText = text
            return
        }

        preparedMarkdownText = nil
        MarkdownContentView.prewarm(text)

        markdownHandoffTask = Task { [messageID = message.id, text] in
            try? await Task.sleep(for: Self.markdownHandoffDelay)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard message.id == messageID,
                      !message.isStreaming,
                      deferredMarkdownText == text else { return }
                preparedMarkdownText = text
            }
        }
    }

    private var deferredMarkdownText: String? {
        guard message.role == .assistant, !message.hasRenderableTextPart else { return nil }
        return message.content.nilIfBlank
    }

    private var isRetroChat: Bool {
        chatEasterEgg.visualMode.isRetro
    }

    private func shouldDeferMarkdownHandoff(for text: String) -> Bool {
        guard text.count >= Self.deferredMarkdownThreshold else { return false }
        return text.contains("\n") ||
            text.contains("`") ||
            text.contains("*") ||
            text.contains("#") ||
            text.contains("- ") ||
            text.contains("> ")
    }

    private func bubbleFill(_ fill: Color) -> some View {
        RoundedRectangle(cornerRadius: theme.radius.card, style: .continuous)
            .fill(fill)
    }

    private func bubbleStroke(_ stroke: OpenLensStrokeStyle) -> some View {
        RoundedRectangle(cornerRadius: theme.radius.card, style: .continuous)
            .stroke(stroke.color.color, lineWidth: stroke.width)
    }

    private func bubbleInnerStroke(_ stroke: OpenLensStrokeStyle, outerWidth: CGFloat) -> some View {
        let inset = outerWidth + stroke.width / 2

        return RoundedRectangle(cornerRadius: max(theme.radius.card - inset, 0), style: .continuous)
            .inset(by: inset)
            .stroke(stroke.color.color, lineWidth: stroke.width)
    }

    private func reasoningSegment(text: String) -> some View {
        Text(text)
            .font(isRetroChat ? RetroChatStyle.smallFont : .system(size: 12, design: .monospaced))
            .foregroundStyle(isRetroChat ? RetroChatStyle.mutedInk : Color.appSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 2)
    }

    private func toolSegment(_ step: ChatMessage.PersistedToolStep) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(toolTranscriptLine(step))
                .font(isRetroChat ? RetroChatStyle.smallFont : .system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(step.isError ? (isRetroChat ? RetroChatStyle.danger : .orange) : (isRetroChat ? RetroChatStyle.secondaryInk : Color.appSecondary))
                .fixedSize(horizontal: false, vertical: true)

            if let output = transcriptOutput(for: step) {
                Text(output)
                    .font(isRetroChat ? RetroChatStyle.smallFont : .system(size: 12, design: .monospaced))
                    .foregroundStyle(isRetroChat ? RetroChatStyle.mutedInk : Color.appSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 2)
            }
        }
        .padding(.leading, 2)
    }

    private func toolTranscriptLine(_ step: ChatMessage.PersistedToolStep) -> String {
        let prefix = step.toolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "question" ? "?" : "→"
        return "\(prefix) \(step.label)"
    }

    private func transcriptOutput(for step: ChatMessage.PersistedToolStep) -> String? {
        if let detail = step.detail.nilIfBlank,
           shouldShowDetailInline(for: step, detail: detail) {
            return detail
        }

        return step.output?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfBlank
            .map { compactOutput($0) }
    }

    private func shouldShowDetailInline(for step: ChatMessage.PersistedToolStep, detail: String) -> Bool {
        let toolName = step.toolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["read", "write", "edit"].contains(toolName)
    }

    private func compactOutput(_ output: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let collapsed = trimmed.replacingOccurrences(of: "\n\n+", with: "\n", options: .regularExpression)
        guard collapsed.count > 140 else { return collapsed }
        return String(collapsed.prefix(140)) + "..."
    }
}

private struct AssistantTranscriptShadow: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.surfaceShadow()
        } else {
            content
        }
    }
}
