import SwiftUI
import UIKit

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

    private var copyableText: String? {
        switch message.role {
        case .user:
            return message.content.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        case .assistant:
            return assistantCopyableText.nilIfBlank
        }
    }

    private var assistantCopyableText: String {
        var lines: [String] = []

        for segment in message.assistantSegments {
            switch segment.kind {
            case .text(let text):
                appendCopyable(text, to: &lines)
            case .reasoning(let text):
                if showThinking {
                    appendCopyable(text, to: &lines)
                }
            case .question(let step):
                appendCopyable(questionTranscriptText(step), to: &lines)
            case .subagent(let step):
                appendCopyable(subagentTranscriptText(step), to: &lines)
            case .tool(let step):
                appendCopyable(toolTranscriptLine(step), to: &lines)
                if let output = transcriptOutput(for: step) {
                    appendCopyable(output, to: &lines)
                }
            }
        }

        if message.isStreaming,
           !message.hasRenderableTextPart,
           let text = message.content.nilIfBlank {
            appendCopyable(text, to: &lines)
        }

        if lines.isEmpty,
           let text = message.content.nilIfBlank {
            appendCopyable(text, to: &lines)
        }

        return lines.joined(separator: "\n\n")
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
        .messageCopyActions(text: copyableText)
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
        case .question(let step):
            questionSegment(step)
        case .subagent(let step):
            subagentSegment(step)
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

    private func questionSegment(_ step: ChatMessage.PersistedQuestionStep) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            questionHeader(step)

            if step.questions.isEmpty {
                Text(AppText.questionTranscriptAsking)
                    .font(isRetroChat ? RetroChatStyle.smallFont : .system(size: 13))
                    .foregroundStyle(isRetroChat ? RetroChatStyle.mutedInk : Color.appSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(Array(step.questions.enumerated()), id: \.offset) { item in
                    questionItem(item.element, index: item.offset, step: step)
                }
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(questionCardFill(for: step))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(questionCardStroke(for: step), lineWidth: isRetroChat ? 1.5 : 1)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(questionTranscriptText(step))
    }

    private func subagentSegment(_ step: ChatMessage.PersistedSubagentStep) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: subagentIconName(for: step))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(subagentAccent(for: step))

                Text(subagentTitle(for: step))
                    .font(isRetroChat ? RetroChatStyle.smallFont : .system(size: 13, weight: .semibold))
                    .foregroundStyle(isRetroChat ? RetroChatStyle.secondaryInk : Color.appPrimary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text(subagentStatusText(for: step))
                    .font(isRetroChat ? RetroChatStyle.smallFont : .system(size: 11, weight: .medium))
                    .foregroundStyle(isRetroChat ? RetroChatStyle.mutedInk : Color.appSecondary)
                    .lineLimit(1)
            }

            if !step.detail.isEmpty {
                Text(step.detail)
                    .font(isRetroChat ? RetroChatStyle.smallFont : .system(size: 12))
                    .foregroundStyle(isRetroChat ? RetroChatStyle.mutedInk : Color.appSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(subagentCardFill(for: step))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(subagentCardStroke(for: step), lineWidth: isRetroChat ? 1.5 : 1)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(subagentTranscriptText(step))
    }

    private func questionHeader(_ step: ChatMessage.PersistedQuestionStep) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: questionIconName(for: step))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(questionAccent(for: step))

            Text(AppText.questionTranscriptTitle)
                .font(isRetroChat ? RetroChatStyle.smallFont : .system(size: 13, weight: .semibold))
                .foregroundStyle(isRetroChat ? RetroChatStyle.secondaryInk : Color.appPrimary)

            Spacer(minLength: 8)

            Text(questionStatusText(for: step))
                .font(isRetroChat ? RetroChatStyle.smallFont : .system(size: 11, weight: .medium))
                .foregroundStyle(isRetroChat ? RetroChatStyle.mutedInk : Color.appSecondary)
        }
    }

    private func questionItem(
        _ question: OCQuestionInfo,
        index: Int,
        step: ChatMessage.PersistedQuestionStep
    ) -> some View {
        let customAnswers = unmatchedAnswers(for: question, index: index, step: step)

        return VStack(alignment: .leading, spacing: 7) {
            if let header = question.header.nilIfBlank {
                Text(header)
                    .font(isRetroChat ? RetroChatStyle.smallFont : .system(size: 12, weight: .semibold))
                    .foregroundStyle(questionAccent(for: step))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(question.question.nilIfBlank ?? AppText.questionTranscriptTitle)
                .font(isRetroChat ? RetroChatStyle.bodyFont : .system(size: 14, weight: .medium))
                .foregroundStyle(isRetroChat ? RetroChatStyle.ink : Color.appPrimary)
                .fixedSize(horizontal: false, vertical: true)

            if !question.options.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(question.options) { option in
                        questionOptionRow(option, questionIndex: index, step: step)
                    }
                }
                .padding(.top, 1)
            }

            if !customAnswers.isEmpty {
                questionAnswerRows(customAnswers, step: step)
                    .padding(.top, question.options.isEmpty ? 1 : 3)
            }
        }
    }

    private func questionOptionRow(
        _ option: OCQuestionOption,
        questionIndex: Int,
        step: ChatMessage.PersistedQuestionStep
    ) -> some View {
        let isSelected = isQuestionOptionSelected(option, questionIndex: questionIndex, step: step)

        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? questionAccent(for: step) : questionMutedColor)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(option.label)
                    .font(isRetroChat ? RetroChatStyle.smallFont : .system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isRetroChat ? RetroChatStyle.secondaryInk : Color.appPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                if let description = option.description.nilIfBlank {
                    Text(description)
                        .font(isRetroChat ? RetroChatStyle.smallFont : .system(size: 12))
                        .foregroundStyle(isRetroChat ? RetroChatStyle.mutedInk : Color.appSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .opacity(step.hasAnswers && !isSelected ? 0.58 : 1)
    }

    private func questionAnswerRows(_ answers: [String], step: ChatMessage.PersistedQuestionStep) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(answers, id: \.self) { answer in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(questionAccent(for: step))
                        .padding(.top, 1)

                    Text(answer)
                        .font(isRetroChat ? RetroChatStyle.smallFont : .system(size: 13, weight: .semibold))
                        .foregroundStyle(isRetroChat ? RetroChatStyle.secondaryInk : Color.appPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func questionTranscriptText(_ step: ChatMessage.PersistedQuestionStep) -> String {
        var lines: [String] = [
            "\(AppText.questionTranscriptTitle): \(questionStatusText(for: step))"
        ]

        if step.questions.isEmpty {
            lines.append(AppText.questionTranscriptAsking)
        }

        for (index, question) in step.questions.enumerated() {
            if let header = question.header.nilIfBlank {
                lines.append(header)
            }

            if let questionText = question.question.nilIfBlank {
                lines.append(questionText)
            }

            for option in question.options {
                let isSelected = isQuestionOptionSelected(option, questionIndex: index, step: step)
                let marker = isSelected ? "[x]" : "[ ]"
                let description = option.description.nilIfBlank.map { ": \($0)" } ?? ""
                lines.append("\(marker) \(option.label)\(description)")
            }

            let answers = selectedAnswers(for: index, in: step)
            if !answers.isEmpty {
                lines.append("\(AppText.questionTranscriptAnswer): \(answers.joined(separator: ", "))")
            }
        }

        return lines.joined(separator: "\n")
    }

    private func selectedAnswers(for questionIndex: Int, in step: ChatMessage.PersistedQuestionStep) -> [String] {
        guard step.answers.indices.contains(questionIndex) else { return [] }
        return step.answers[questionIndex]
    }

    private func unmatchedAnswers(
        for question: OCQuestionInfo,
        index: Int,
        step: ChatMessage.PersistedQuestionStep
    ) -> [String] {
        let optionLabels = Set(question.options.map { normalizedQuestionAnswer($0.label) })
        return selectedAnswers(for: index, in: step)
            .filter { !optionLabels.contains(normalizedQuestionAnswer($0)) }
    }

    private func isQuestionOptionSelected(
        _ option: OCQuestionOption,
        questionIndex: Int,
        step: ChatMessage.PersistedQuestionStep
    ) -> Bool {
        let normalizedOption = normalizedQuestionAnswer(option.label)
        return selectedAnswers(for: questionIndex, in: step)
            .contains { normalizedQuestionAnswer($0) == normalizedOption }
    }

    private func normalizedQuestionAnswer(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func questionStatusText(for step: ChatMessage.PersistedQuestionStep) -> String {
        step.isAnswered ? AppText.questionTranscriptAnswered : AppText.questionTranscriptWaiting
    }

    private func questionIconName(for step: ChatMessage.PersistedQuestionStep) -> String {
        if step.isError {
            return "exclamationmark.circle.fill"
        }
        return step.isAnswered ? "checkmark.circle.fill" : "questionmark.circle"
    }

    private func questionCardFill(for step: ChatMessage.PersistedQuestionStep) -> Color {
        if isRetroChat {
            return RetroChatStyle.paperWarm
        }
        return step.isError ? Color.appWarning.opacity(0.12) : Color.appTertiary.opacity(0.58)
    }

    private func questionCardStroke(for step: ChatMessage.PersistedQuestionStep) -> Color {
        if isRetroChat {
            return step.isError ? RetroChatStyle.danger : RetroChatStyle.mutedInk.opacity(0.8)
        }
        return step.isError ? Color.appWarning.opacity(0.42) : Color.appSeparator.opacity(0.68)
    }

    private func questionAccent(for step: ChatMessage.PersistedQuestionStep) -> Color {
        if step.isError {
            return isRetroChat ? RetroChatStyle.danger : Color.appWarning
        }
        return isRetroChat ? RetroChatStyle.blueAccent : Color.appAccent
    }

    private var questionMutedColor: Color {
        isRetroChat ? RetroChatStyle.mutedInk.opacity(0.75) : Color.appSecondary.opacity(0.62)
    }

    private func subagentTitle(for step: ChatMessage.PersistedSubagentStep) -> String {
        step.title == "Subagent" ? "Subagent" : "Subagent \(step.title)"
    }

    private func subagentStatusText(for step: ChatMessage.PersistedSubagentStep) -> String {
        if step.isError {
            return "Error"
        }
        return step.isCompleted ? "Done" : "Working"
    }

    private func subagentIconName(for step: ChatMessage.PersistedSubagentStep) -> String {
        if step.isError {
            return "exclamationmark.circle.fill"
        }
        return step.isCompleted ? "checkmark.circle.fill" : "person.crop.circle.badge.clock"
    }

    private func subagentCardFill(for step: ChatMessage.PersistedSubagentStep) -> Color {
        if isRetroChat {
            return RetroChatStyle.paperWarm
        }
        if step.isError {
            return Color.appWarning.opacity(0.12)
        }
        return step.isCompleted ? Color.appTertiary.opacity(0.58) : Color.appAccent.opacity(0.10)
    }

    private func subagentCardStroke(for step: ChatMessage.PersistedSubagentStep) -> Color {
        if isRetroChat {
            if step.isError {
                return RetroChatStyle.danger
            }
            return step.isCompleted ? RetroChatStyle.mutedInk.opacity(0.8) : RetroChatStyle.blueAccent.opacity(0.9)
        }
        if step.isError {
            return Color.appWarning.opacity(0.42)
        }
        return step.isCompleted ? Color.appSeparator.opacity(0.68) : Color.appAccent.opacity(0.34)
    }

    private func subagentAccent(for step: ChatMessage.PersistedSubagentStep) -> Color {
        if step.isError {
            return isRetroChat ? RetroChatStyle.danger : Color.appWarning
        }
        if step.isCompleted {
            return isRetroChat ? RetroChatStyle.blueAccent : Color.appSecondary
        }
        return isRetroChat ? RetroChatStyle.magentaAccent : Color.appAccent
    }

    private func subagentTranscriptText(_ step: ChatMessage.PersistedSubagentStep) -> String {
        var lines = [
            "\(subagentTitle(for: step)): \(subagentStatusText(for: step))"
        ]

        if !step.detail.isEmpty {
            lines.append(step.detail)
        }

        return lines.joined(separator: "\n")
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

    private func appendCopyable(_ text: String, to lines: inout [String]) {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        lines.append(normalized)
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

private struct MessageCopyActions: ViewModifier {
    let text: String?

    private var normalizedText: String? {
        text?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfBlank
    }

    func body(content: Content) -> some View {
        if let normalizedText {
            content
                .textSelection(.enabled)
                .contextMenu {
                    Button {
                        UIPasteboard.general.string = normalizedText
                    } label: {
                        Label(AppText.copyMessage, systemImage: "doc.on.doc")
                    }
                }
        } else {
            content
        }
    }
}

private extension View {
    func messageCopyActions(text: String?) -> some View {
        modifier(MessageCopyActions(text: text))
    }
}
