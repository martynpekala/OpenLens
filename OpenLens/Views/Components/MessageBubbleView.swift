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

    private static let markdownHandoffDelay: Duration = .milliseconds(120)
    private static let deferredMarkdownThreshold = 600

    private var showsTranscriptStyleAssistantContent: Bool {
        message.role == .assistant
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if message.role == .user {
                Spacer(minLength: 64)
                userBubble
            } else {
                assistantBubble
                Spacer(minLength: 32)
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
                .font(.system(size: 16))
                .foregroundStyle(Color.appOnAccent)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.appAccent)
                )
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
        case .reasoning(let text, let todoItems):
            reasoningSegment(text: text, todoItems: todoItems)
        case .tool(let step):
            toolSegment(step)
        }
    }

    private func assistantTextBubble(_ text: String, usesDeferredMarkdownHandoff: Bool) -> some View {
        Group {
            if shouldRenderMarkdown(text, usesDeferredMarkdownHandoff: usesDeferredMarkdownHandoff) {
                MarkdownContentView(text, foregroundColor: Color.appPrimary)
            } else {
                Text(text)
                    .font(.system(size: 16))
                    .foregroundStyle(Color.appPrimary)
            }
        }
        .padding(.horizontal, showsTranscriptStyleAssistantContent ? 0 : 16)
        .padding(.vertical, showsTranscriptStyleAssistantContent ? 0 : 12)
        .background {
            if !showsTranscriptStyleAssistantContent {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.appSurface)
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

    private func shouldDeferMarkdownHandoff(for text: String) -> Bool {
        guard text.count >= Self.deferredMarkdownThreshold else { return false }
        return text.contains("\n") ||
            text.contains("`") ||
            text.contains("*") ||
            text.contains("#") ||
            text.contains("- ") ||
            text.contains("> ")
    }

    private func reasoningSegment(text: String, todoItems: [TodoListCardView.Item]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if todoItems.count >= 2 {
                TodoListCardView(title: "Todos", items: todoItems, compact: true)
            } else {
                Text(text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.appSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.leading, 2)
    }

    private func toolSegment(_ step: ChatMessage.PersistedToolStep) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(toolTranscriptLine(step))
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(step.isError ? .orange : Color.appSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if step.todoItems.count >= 2 {
                TodoListCardView(title: "Todos", items: step.todoItems, compact: true)
                    .padding(.leading, 2)
            } else if let output = transcriptOutput(for: step) {
                Text(output)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.appSecondary)
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
