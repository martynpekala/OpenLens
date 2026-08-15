import SwiftUI
import UIKit

/// Chat message bubble view, styled differently for user vs assistant messages.
///
/// Uses a dual-render strategy for assistant messages:
/// - **Streaming** (`isStreaming == true`): plain `Text` — zero markdown parsing cost.
/// - **Completed** (`isStreaming == false`): `MarkdownContentView` — one-time parse.
struct MessageBubbleView: View {
    let message: ChatMessage
    private let assistantSegments: [ChatMessage.AssistantSegment]?
    private let streamingText: ChatMessage.StreamingTextProjection?
    private let animatesSubagentStatus: Bool
    @AppStorage("showThinking") private var showThinking: Bool = true
    @Environment(\.openLensTheme) private var theme
    @Environment(\.chatEasterEgg) private var chatEasterEgg
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        message: ChatMessage,
        assistantSegments: [ChatMessage.AssistantSegment]? = nil,
        streamingText: ChatMessage.StreamingTextProjection? = nil,
        animatesSubagentStatus: Bool = false
    ) {
        self.message = message
        self.assistantSegments = assistantSegments
        self.streamingText = streamingText
        self.animatesSubagentStatus = animatesSubagentStatus
    }

    private var showsTranscriptStyleAssistantContent: Bool {
        message.role == .assistant
    }

    private var visibleAssistantSegments: [ChatMessage.AssistantSegment] {
        assistantSegments ?? message.assistantSegments
    }

    private var canCopyText: Bool {
        switch message.role {
        case .user:
            return !message.content.isEmpty
        case .assistant:
            // A streaming timeline row is created only after its projection
            // first receives text. Do not observe the mutable tail here: that
            // would invalidate this parent bubble on every delta instead of
            // only the dedicated tail subview.
            return streamingText != nil
                || !visibleAssistantSegments.isEmpty
                || !message.content.isEmpty
        }
    }

    private func makeCopyText() -> String? {
        switch message.role {
        case .user:
            return message.content.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        case .assistant:
            return assistantCopyableText().nilIfBlank
        }
    }

    /// Deliberately called only from the Copy action. This is allowed to join
    /// a full response; doing it during every SwiftUI body update is not.
    private func assistantCopyableText() -> String {
        var lines: [String] = []

        for segment in visibleAssistantSegments {
            switch segment.kind {
            case .text(let text):
                appendCopyable(segment.streamingText?.copyText() ?? text, to: &lines)
            case .reasoning(let text):
                if showThinking {
                    appendCopyable(segment.streamingText?.copyText() ?? text, to: &lines)
                }
            case .question(let step):
                appendCopyable(questionTranscriptText(step), to: &lines)
            case .subagent(let step):
                appendCopyable(subagentTranscriptText(step), to: &lines)
            case .tool(let step):
                appendCopyable(toolTranscriptLine(step), to: &lines)
                if let output = step.outputPreview {
                    appendCopyable(output, to: &lines)
                }
            }
        }

        if let streamingText, streamingText.hasText {
            appendCopyable(streamingText.copyText(), to: &lines)
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
        .messageCopyActions(canCopy: canCopyText, makeText: makeCopyText)
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
            ForEach(visibleAssistantSegments) { segment in
                segmentView(segment)
            }

            if let streamingText {
                streamingTextBubble(streamingText)
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
            assistantTextBubble(text, projection: segment.streamingText)
        case .reasoning(let text):
            if showThinking {
                reasoningSegment(text: text, projection: segment.streamingText)
            }
        case .question(let step):
            questionSegment(step)
        case .subagent(let step):
            subagentSegment(step)
        case .tool(let step):
            toolSegment(step)
        }
    }

    private func assistantTextBubble(
        _ text: String,
        projection: ChatMessage.StreamingTextProjection?
    ) -> some View {
        Group {
            if let projection, message.isStreaming {
                StreamingAssistantTextView(
                    projection: projection,
                    font: isRetroChat ? RetroChatStyle.bodyFont : .system(size: 16),
                    color: isRetroChat ? RetroChatStyle.ink : Color.appPrimary
                )
            } else if message.isStreaming {
                Text(text)
                    .font(isRetroChat ? RetroChatStyle.bodyFont : .system(size: 16))
                    .foregroundStyle(isRetroChat ? RetroChatStyle.ink : Color.appPrimary)
            } else {
                DeferredMarkdownTextView(
                    text: text,
                    foregroundColor: isRetroChat ? RetroChatStyle.ink : Color.appPrimary,
                    usesRetroTypography: isRetroChat
                )
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
        .animation(nil, value: message.isStreaming)
    }

    private var isRetroChat: Bool {
        chatEasterEgg.visualMode.isRetro
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

    private func reasoningSegment(
        text: String,
        projection: ChatMessage.StreamingTextProjection?
    ) -> some View {
        Group {
            if let projection, message.isStreaming {
                StreamingAssistantTextView(
                    projection: projection,
                    font: isRetroChat ? RetroChatStyle.smallFont : .system(size: 12, design: .monospaced),
                    color: isRetroChat ? RetroChatStyle.mutedInk : Color.appSecondary
                )
            } else {
                DeferredReasoningTextView(
                    text: text,
                    font: isRetroChat ? RetroChatStyle.smallFont : .system(size: 12, design: .monospaced),
                    color: isRetroChat ? RetroChatStyle.mutedInk : Color.appSecondary,
                    usesRetroTypography: isRetroChat
                )
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.leading, 2)
    }

    private func streamingTextBubble(_ projection: ChatMessage.StreamingTextProjection) -> some View {
        StreamingAssistantTextView(
            projection: projection,
            font: isRetroChat ? RetroChatStyle.bodyFont : .system(size: 16),
            color: isRetroChat ? RetroChatStyle.ink : Color.appPrimary
        )
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
    }

    private func toolSegment(_ step: ChatMessage.PersistedToolStep) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(toolTranscriptLine(step))
                .font(isRetroChat ? RetroChatStyle.smallFont : .system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(step.isError ? (isRetroChat ? RetroChatStyle.danger : .orange) : (isRetroChat ? RetroChatStyle.secondaryInk : Color.appSecondary))
                .fixedSize(horizontal: false, vertical: true)

            if let output = step.outputPreview {
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
        QuestionTranscriptCardView(step: step, usesRetroTypography: isRetroChat)
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

                subagentStatusView(for: step)
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

    /// Full transcript construction remains intentionally on the Copy action.
    /// The visible card is rendered from `QuestionTranscriptPresentation` below.
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

    private func subagentTitle(for step: ChatMessage.PersistedSubagentStep) -> String {
        step.title == "Subagent" ? "Subagent" : "Subagent \(step.title)"
    }

    private func subagentStatusText(for step: ChatMessage.PersistedSubagentStep) -> String {
        if step.isError {
            return "Error"
        }
        return step.isCompleted ? "Done" : "Working"
    }

    @ViewBuilder
    private func subagentStatusView(for step: ChatMessage.PersistedSubagentStep) -> some View {
        let mutedColor = isRetroChat ? RetroChatStyle.mutedInk : Color.appSecondary

        if step.isActive && animatesSubagentStatus {
            WorkingShimmerText(
                label: subagentStatusText(for: step),
                baseColor: mutedColor,
                highlightColor: subagentAccent(for: step),
                font: isRetroChat ? RetroChatStyle.smallFont : .system(size: 11, weight: .medium),
                reduceMotion: reduceMotion
            )
        } else {
            Text(subagentStatusText(for: step))
                .font(isRetroChat ? RetroChatStyle.smallFont : .system(size: 11, weight: .medium))
                .foregroundStyle(mutedColor)
                .lineLimit(1)
        }
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

/// An immutable, bounded representation of a completed reasoning transcript.
/// Building it can walk a large server response, so callers must prepare it off
/// the main executor before SwiftUI receives the individual text chunks.
nonisolated struct CompletedReasoningTextPreparation: Sendable {
    struct Chunk: Identifiable, Sendable {
        let id: Int
        let text: String
    }

    static let maximumChunkLength = 800

    let chunks: [Chunk]

    static func prepare(_ text: String) -> CompletedReasoningTextPreparation {
        guard !text.isEmpty else {
            return CompletedReasoningTextPreparation(chunks: [])
        }

        var chunks: [Chunk] = []
        var start = text.startIndex
        var nextID = 0

        while start < text.endIndex {
            let hardEnd = text.index(
                start,
                offsetBy: maximumChunkLength,
                limitedBy: text.endIndex
            ) ?? text.endIndex

            if hardEnd == text.endIndex {
                chunks.append(Chunk(id: nextID, text: String(text[start..<text.endIndex])))
                break
            }

            let candidate = text[start..<hardEnd]
            let end = candidate.lastIndex(of: "\n")
                .map { text.index(after: $0) }
                ?? candidate.lastIndex(where: { $0.isWhitespace })
                    .map { text.index(after: $0) }
                ?? hardEnd

            chunks.append(Chunk(id: nextID, text: String(text[start..<end])))
            nextID += 1
            start = end
        }

        return CompletedReasoningTextPreparation(chunks: chunks)
    }
}

/// A finished reasoning part can be far larger than an answer. Keep the first
/// frame small, prepare its bounded chunks off-main, then let people reveal the
/// rest intentionally rather than asking a single `Text` to lay out 100 KB.
private struct DeferredReasoningTextView: View {
    private static let initialChunkLimit = 4
    private static let revealStep = 8
    private static let preparationQueue = DispatchQueue(
        label: "com.openlens.DeferredReasoningTextView.prepare",
        qos: .utility
    )

    let text: String
    let font: Font
    let color: Color
    let usesRetroTypography: Bool
    private let fallbackPreview: String
    private let fallbackIsTruncated: Bool

    @State private var prepared: CompletedReasoningTextPreparation?
    @State private var visibleChunkCount: Int?
    @State private var requestID = UUID()

    init(text: String, font: Font, color: Color, usesRetroTypography: Bool) {
        self.text = text
        self.font = font
        self.color = color
        self.usesRetroTypography = usesRetroTypography

        let end = text.index(
            text.startIndex,
            offsetBy: CompletedReasoningTextPreparation.maximumChunkLength,
            limitedBy: text.endIndex
        ) ?? text.endIndex
        self.fallbackPreview = String(text[..<end])
        self.fallbackIsTruncated = end != text.endIndex
    }

    var body: some View {
        Group {
            if let prepared {
                preparedReasoning(prepared)
            } else {
                fallback
            }
        }
        .onAppear {
            requestPreparation(for: text)
        }
        .onChange(of: text) { _, newText in
            requestPreparation(for: newText)
        }
    }

    private func preparedReasoning(_ prepared: CompletedReasoningTextPreparation) -> some View {
        let shownChunkCount = min(
            visibleChunkCount ?? Self.initialChunkLimit,
            prepared.chunks.count
        )

        return VStack(alignment: .leading, spacing: 0) {
            ForEach(prepared.chunks.prefix(shownChunkCount)) { chunk in
                Text(chunk.text)
                    .font(font)
                    .foregroundStyle(color)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if shownChunkCount < prepared.chunks.count {
                Button {
                    visibleChunkCount = min(
                        shownChunkCount + Self.revealStep,
                        prepared.chunks.count
                    )
                } label: {
                    Text(AppText.markdownShowMore(prepared.chunks.count - shownChunkCount))
                        .font(usesRetroTypography ? RetroChatStyle.smallFont : .system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                }
            }
        }
    }

    private var fallback: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(fallbackPreview)
                .font(font)
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)

            if fallbackIsTruncated {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Preparing reasoning")
            }
        }
    }

    private func requestPreparation(for text: String) {
        let nextRequestID = UUID()
        requestID = nextRequestID
        prepared = nil
        visibleChunkCount = nil

        Self.preparationQueue.async {
            let candidate = CompletedReasoningTextPreparation.prepare(text)

            DispatchQueue.main.async {
                guard requestID == nextRequestID else { return }
                prepared = candidate
            }
        }
    }
}

/// Sendable, copy-on-write input for an untrusted question-tool payload. The
/// view creates this tiny wrapper on MainActor, then all traversal of server
/// strings and nested collections happens in `QuestionTranscriptPresentation`.
nonisolated struct QuestionTranscriptSource: Sendable {
    let id: String
    let status: OCToolStatus
    let isError: Bool
    let questions: [OCQuestionInfo]
    let answers: [[String]]

    init(
        id: String,
        status: OCToolStatus,
        isError: Bool,
        questions: [OCQuestionInfo],
        answers: [[String]]
    ) {
        self.id = id
        self.status = status
        self.isError = isError
        self.questions = questions
        self.answers = answers
    }
}

/// A bounded display model for a question tool. It deliberately never exposes
/// raw server strings to SwiftUI: all text is capped before the main queue sees
/// it, and collection traversal is limited even for malformed payloads.
nonisolated struct QuestionTranscriptPresentation: Sendable {
    struct Question: Identifiable, Sendable {
        let id: Int
        let header: String?
        let text: String?
        let options: [Option]
        let customAnswers: [Answer]
        let hiddenOptionCount: Int
        let hiddenAnswerCount: Int
    }

    struct Option: Identifiable, Sendable {
        let id: Int
        let label: String
        let detail: String?
        let isSelected: Bool
    }

    struct Answer: Identifiable, Sendable {
        let id: Int
        let text: String
    }

    static let maximumQuestionCount = 24
    static let maximumOptionCount = 12
    static let maximumAnswerCount = 12
    static let maximumHeaderLength = 120
    static let maximumQuestionLength = 360
    static let maximumOptionLabelLength = 120
    static let maximumOptionDetailLength = 180
    static let maximumAnswerLength = 180

    private static let comparisonLength = 160

    let questions: [Question]
    let hiddenQuestionCount: Int
    let hasAnswers: Bool

    static func prepare(_ source: QuestionTranscriptSource) -> QuestionTranscriptPresentation {
        let visibleQuestionCount = min(source.questions.count, maximumQuestionCount)
        var questions: [Question] = []
        questions.reserveCapacity(visibleQuestionCount)
        var hasAnswers = false

        for questionIndex in 0..<visibleQuestionCount {
            let rawQuestion = source.questions[questionIndex]
            let rawAnswers = questionIndex < source.answers.count ? source.answers[questionIndex] : []
            hasAnswers = hasAnswers || !rawAnswers.isEmpty

            let visibleAnswerCount = min(rawAnswers.count, maximumAnswerCount)
            var answerKeys = Set<String>()
            var answerPreviews: [(id: Int, text: String, key: String?)] = []
            answerPreviews.reserveCapacity(visibleAnswerCount)

            for answerIndex in 0..<visibleAnswerCount {
                let rawAnswer = rawAnswers[answerIndex]
                guard let preview = preview(rawAnswer, limit: maximumAnswerLength) else { continue }
                let key = normalizedKey(rawAnswer)
                if let key {
                    answerKeys.insert(key)
                }
                answerPreviews.append((id: answerIndex, text: preview, key: key))
            }

            let visibleOptionCount = min(rawQuestion.options.count, maximumOptionCount)
            var options: [Option] = []
            options.reserveCapacity(visibleOptionCount)
            var optionKeys = Set<String>()

            for optionIndex in 0..<visibleOptionCount {
                let rawOption = rawQuestion.options[optionIndex]
                guard let label = preview(rawOption.label, limit: maximumOptionLabelLength) else { continue }
                let key = normalizedKey(rawOption.label)
                if let key {
                    optionKeys.insert(key)
                }
                options.append(
                    Option(
                        id: optionIndex,
                        label: label,
                        detail: preview(rawOption.description, limit: maximumOptionDetailLength),
                        isSelected: key.map(answerKeys.contains) ?? false
                    )
                )
            }

            let customAnswers = answerPreviews.compactMap { answer -> Answer? in
                guard answer.key.map({ !optionKeys.contains($0) }) ?? true else { return nil }
                return Answer(id: answer.id, text: answer.text)
            }

            questions.append(
                Question(
                    id: questionIndex,
                    header: preview(rawQuestion.header, limit: maximumHeaderLength),
                    text: preview(rawQuestion.question, limit: maximumQuestionLength),
                    options: options,
                    customAnswers: customAnswers,
                    hiddenOptionCount: max(0, rawQuestion.options.count - visibleOptionCount),
                    hiddenAnswerCount: max(0, rawAnswers.count - visibleAnswerCount)
                )
            )
        }

        return QuestionTranscriptPresentation(
            questions: questions,
            hiddenQuestionCount: max(0, source.questions.count - visibleQuestionCount),
            hasAnswers: hasAnswers
        )
    }

    /// Bounds both traversal and allocation. Trimming applies only to the
    /// already-limited preview, never to the complete untrusted server string.
    private static func preview(_ text: String, limit: Int) -> String? {
        guard !text.isEmpty, limit > 0 else { return nil }

        let end = text.index(text.startIndex, offsetBy: limit, limitedBy: text.endIndex) ?? text.endIndex
        var result = String(text[..<end])
        if end != text.endIndex {
            result.append("…")
        }
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Selection matching is intentionally lossy after a small prefix: the
    /// response remains safe even if a server sends a multi-megabyte answer.
    private static func normalizedKey(_ text: String) -> String? {
        guard !text.isEmpty else { return nil }

        let end = text.index(
            text.startIndex,
            offsetBy: comparisonLength,
            limitedBy: text.endIndex
        ) ?? text.endIndex
        let normalized = String(text[..<end])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized.isEmpty ? nil : normalized
    }
}

/// Owns the small amount of local state required to show question data without
/// letting an incoming tool payload determine a SwiftUI body or layout size.
private struct QuestionTranscriptCardView: View {
    private static let initialQuestionLimit = 3
    private static let questionRevealStep = 4
    private static let preparationQueue = DispatchQueue(
        label: "com.openlens.QuestionTranscriptCardView.prepare",
        qos: .utility
    )

    private struct PreparationKey: Equatable {
        let id: String
        let status: OCToolStatus
        let isError: Bool
        let questionCount: Int
        let answerRowCount: Int
    }

    let usesRetroTypography: Bool
    private let source: QuestionTranscriptSource

    @State private var prepared: QuestionTranscriptPresentation?
    @State private var visibleQuestionCount: Int?
    @State private var requestID = UUID()

    init(step: ChatMessage.PersistedQuestionStep, usesRetroTypography: Bool) {
        self.usesRetroTypography = usesRetroTypography
        self.source = QuestionTranscriptSource(
            id: step.id,
            status: step.status,
            isError: step.isError,
            questions: step.questions,
            answers: step.answers
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if let prepared {
                renderedQuestions(prepared)
            } else {
                loadingPreview
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(cardFill)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(cardStroke, lineWidth: usesRetroTypography ? 1.5 : 1)
        }
        .fixedSize(horizontal: false, vertical: true)
        // Do not let SwiftUI synthesize a label by walking every visible child.
        // This summary is bounded and never includes raw server content.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        .onAppear {
            requestPreparation()
        }
        .onChange(of: preparationKey) { _, _ in
            requestPreparation()
        }
    }

    private var preparationKey: PreparationKey {
        PreparationKey(
            id: source.id,
            status: source.status,
            isError: source.isError,
            questionCount: source.questions.count,
            answerRowCount: source.answers.count
        )
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: iconName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(accent)

            Text(AppText.questionTranscriptTitle)
                .font(usesRetroTypography ? RetroChatStyle.smallFont : .system(size: 13, weight: .semibold))
                .foregroundStyle(usesRetroTypography ? RetroChatStyle.secondaryInk : Color.appPrimary)

            Spacer(minLength: 8)

            Text(statusText)
                .font(usesRetroTypography ? RetroChatStyle.smallFont : .system(size: 11, weight: .medium))
                .foregroundStyle(usesRetroTypography ? RetroChatStyle.mutedInk : Color.appSecondary)
        }
    }

    @ViewBuilder
    private func renderedQuestions(_ prepared: QuestionTranscriptPresentation) -> some View {
        if prepared.questions.isEmpty {
            Text(AppText.questionTranscriptAsking)
                .font(usesRetroTypography ? RetroChatStyle.smallFont : .system(size: 13))
                .foregroundStyle(usesRetroTypography ? RetroChatStyle.mutedInk : Color.appSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            let shownQuestionCount = min(
                visibleQuestionCount ?? Self.initialQuestionLimit,
                prepared.questions.count
            )

            ForEach(prepared.questions.prefix(shownQuestionCount)) { question in
                QuestionTranscriptQuestionView(
                    question: question,
                    hasAnswers: prepared.hasAnswers,
                    usesRetroTypography: usesRetroTypography,
                    accent: accent,
                    mutedColor: mutedColor
                )
            }

            if shownQuestionCount < prepared.questions.count {
                Button {
                    visibleQuestionCount = min(
                        shownQuestionCount + Self.questionRevealStep,
                        prepared.questions.count
                    )
                } label: {
                    Text(AppText.markdownShowMore(prepared.questions.count - shownQuestionCount))
                        .font(usesRetroTypography ? RetroChatStyle.smallFont : .system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            } else if prepared.hiddenQuestionCount > 0 {
                Text("Additional questions are available when copied.")
                    .font(usesRetroTypography ? RetroChatStyle.smallFont : .system(size: 12))
                    .foregroundStyle(mutedColor)
            }
        }
    }

    private var loadingPreview: some View {
        HStack(spacing: 8) {
            Text(AppText.questionTranscriptAsking)
                .font(usesRetroTypography ? RetroChatStyle.smallFont : .system(size: 13))
                .foregroundStyle(usesRetroTypography ? RetroChatStyle.mutedInk : Color.appSecondary)

            if !source.questions.isEmpty {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
            }
        }
    }

    private var accessibilitySummary: String {
        let base = "\(AppText.questionTranscriptTitle): \(statusText)."
        guard let prepared else {
            return "\(base) Preparing question preview."
        }
        if prepared.questions.isEmpty {
            return "\(base) \(AppText.questionTranscriptAsking)"
        }
        let shownQuestionCount = min(
            visibleQuestionCount ?? Self.initialQuestionLimit,
            prepared.questions.count
        )
        if prepared.hiddenQuestionCount > 0 {
            return "\(base) \(shownQuestionCount) question previews shown; additional questions are available when copied."
        }
        return "\(base) \(shownQuestionCount) question previews shown."
    }

    private var statusText: String {
        let hasAnswers = prepared?.hasAnswers ?? (source.status == .completed)
        return hasAnswers || source.status == .completed
            ? AppText.questionTranscriptAnswered
            : AppText.questionTranscriptWaiting
    }

    private var iconName: String {
        if source.isError {
            return "exclamationmark.circle.fill"
        }
        return statusText == AppText.questionTranscriptAnswered
            ? "checkmark.circle.fill"
            : "questionmark.circle"
    }

    private var cardFill: Color {
        if usesRetroTypography {
            return RetroChatStyle.paperWarm
        }
        return source.isError ? Color.appWarning.opacity(0.12) : Color.appTertiary.opacity(0.58)
    }

    private var cardStroke: Color {
        if usesRetroTypography {
            return source.isError ? RetroChatStyle.danger : RetroChatStyle.mutedInk.opacity(0.8)
        }
        return source.isError ? Color.appWarning.opacity(0.42) : Color.appSeparator.opacity(0.68)
    }

    private var accent: Color {
        if source.isError {
            return usesRetroTypography ? RetroChatStyle.danger : Color.appWarning
        }
        return usesRetroTypography ? RetroChatStyle.blueAccent : Color.appAccent
    }

    private var mutedColor: Color {
        usesRetroTypography ? RetroChatStyle.mutedInk.opacity(0.75) : Color.appSecondary.opacity(0.62)
    }

    private func requestPreparation() {
        let nextRequestID = UUID()
        requestID = nextRequestID
        prepared = nil
        visibleQuestionCount = nil
        let source = source

        Self.preparationQueue.async {
            let candidate = QuestionTranscriptPresentation.prepare(source)

            DispatchQueue.main.async {
                guard requestID == nextRequestID else { return }
                prepared = candidate
            }
        }
    }
}

private struct QuestionTranscriptQuestionView: View {
    private static let initialOptionLimit = 4
    private static let initialAnswerLimit = 4
    private static let revealStep = 6

    let question: QuestionTranscriptPresentation.Question
    let hasAnswers: Bool
    let usesRetroTypography: Bool
    let accent: Color
    let mutedColor: Color

    @State private var visibleOptionCount: Int?
    @State private var visibleAnswerCount: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let header = question.header {
                Text(header)
                    .font(usesRetroTypography ? RetroChatStyle.smallFont : .system(size: 12, weight: .semibold))
                    .foregroundStyle(accent)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(question.text ?? AppText.questionTranscriptTitle)
                .font(usesRetroTypography ? RetroChatStyle.bodyFont : .system(size: 14, weight: .medium))
                .foregroundStyle(usesRetroTypography ? RetroChatStyle.ink : Color.appPrimary)
                .fixedSize(horizontal: false, vertical: true)

            optionRows
            answerRows
        }
    }

    @ViewBuilder
    private var optionRows: some View {
        if !question.options.isEmpty {
            let shownOptionCount = min(
                visibleOptionCount ?? Self.initialOptionLimit,
                question.options.count
            )

            VStack(alignment: .leading, spacing: 5) {
                ForEach(question.options.prefix(shownOptionCount)) { option in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: option.isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 13, weight: option.isSelected ? .semibold : .regular))
                            .foregroundStyle(option.isSelected ? accent : mutedColor)
                            .padding(.top, 1)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.label)
                                .font(usesRetroTypography ? RetroChatStyle.smallFont : .system(size: 13, weight: option.isSelected ? .semibold : .regular))
                                .foregroundStyle(usesRetroTypography ? RetroChatStyle.secondaryInk : Color.appPrimary)
                                .fixedSize(horizontal: false, vertical: true)

                            if let detail = option.detail {
                                Text(detail)
                                    .font(usesRetroTypography ? RetroChatStyle.smallFont : .system(size: 12))
                                    .foregroundStyle(usesRetroTypography ? RetroChatStyle.mutedInk : Color.appSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .opacity(hasAnswers && !option.isSelected ? 0.58 : 1)
                }

                if shownOptionCount < question.options.count {
                    Button {
                        visibleOptionCount = min(
                            shownOptionCount + Self.revealStep,
                            question.options.count
                        )
                    } label: {
                        Text(AppText.markdownShowMore(question.options.count - shownOptionCount))
                            .font(usesRetroTypography ? RetroChatStyle.smallFont : .system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                } else if question.hiddenOptionCount > 0 {
                    Text("Additional options are available when copied.")
                        .font(usesRetroTypography ? RetroChatStyle.smallFont : .system(size: 12))
                        .foregroundStyle(mutedColor)
                }
            }
            .padding(.top, 1)
        }
    }

    @ViewBuilder
    private var answerRows: some View {
        if !question.customAnswers.isEmpty {
            let shownAnswerCount = min(
                visibleAnswerCount ?? Self.initialAnswerLimit,
                question.customAnswers.count
            )

            VStack(alignment: .leading, spacing: 5) {
                ForEach(question.customAnswers.prefix(shownAnswerCount)) { answer in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(accent)
                            .padding(.top, 1)

                        Text(answer.text)
                            .font(usesRetroTypography ? RetroChatStyle.smallFont : .system(size: 13, weight: .semibold))
                            .foregroundStyle(usesRetroTypography ? RetroChatStyle.secondaryInk : Color.appPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if shownAnswerCount < question.customAnswers.count {
                    Button {
                        visibleAnswerCount = min(
                            shownAnswerCount + Self.revealStep,
                            question.customAnswers.count
                        )
                    } label: {
                        Text(AppText.markdownShowMore(question.customAnswers.count - shownAnswerCount))
                            .font(usesRetroTypography ? RetroChatStyle.smallFont : .system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                } else if question.hiddenAnswerCount > 0 {
                    Text("Additional answers are available when copied.")
                        .font(usesRetroTypography ? RetroChatStyle.smallFont : .system(size: 12))
                        .foregroundStyle(mutedColor)
                }
            }
            .padding(.top, question.options.isEmpty ? 1 : 3)
        }
    }
}

/// A lightweight shimmer scoped to the small `Working` status label. Keeping the
/// animation here avoids continuously redrawing the whole task/subagent card.
private struct WorkingShimmerText: View {
    let label: String
    let baseColor: Color
    let highlightColor: Color
    let font: Font
    let reduceMotion: Bool

    @State private var phase: CGFloat = -1

    var body: some View {
        Text(label)
            .font(font)
            .foregroundStyle(baseColor)
            .lineLimit(1)
            .overlay {
                if !reduceMotion {
                    GeometryReader { proxy in
                        LinearGradient(
                            colors: [
                                highlightColor.opacity(0),
                                highlightColor.opacity(0.95),
                                highlightColor.opacity(0),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: proxy.size.width * 0.8)
                        .offset(x: phase * proxy.size.width)
                    }
                    .mask(
                        Text(label)
                            .font(font)
                            .lineLimit(1)
                    )
                    .accessibilityHidden(true)
                }
            }
            .onAppear(perform: startShimmer)
            .onChange(of: reduceMotion) { _, _ in
                startShimmer()
            }
            .onDisappear {
                phase = -1
            }
    }

    private func startShimmer() {
        guard !reduceMotion else {
            phase = -1
            return
        }

        phase = -1
        withAnimation(.linear(duration: 1.35).repeatForever(autoreverses: false)) {
            phase = 1.8
        }
    }
}

/// Renders sealed streaming chunks as independent stable text nodes. Appending
/// to a response only changes the small `tail` node rather than laying out the
/// whole accumulated response again.
private struct StreamingAssistantTextView: View {
    let projection: ChatMessage.StreamingTextProjection
    let font: Font
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SealedStreamingTextChunks(projection: projection, font: font, color: color)
            StreamingTextTail(projection: projection, font: font, color: color)
        }
    }
}

/// Separating these observation subtrees prevents every small tail mutation
/// from rebuilding the `ForEach` that owns already-laid-out chunks.
private struct SealedStreamingTextChunks: View {
    let projection: ChatMessage.StreamingTextProjection
    let font: Font
    let color: Color

    var body: some View {
        let liveWindow = projection.liveWindow

        if liveWindow.omittedSealedChunkCount > 0 {
            Text(AppText.streamingEarlierTextHidden(liveWindow.omittedSealedChunkCount))
                .font(.system(size: 11))
                .foregroundStyle(color.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isStaticText)
        }

        ForEach(liveWindow.sealedChunks) { chunk in
            Text(chunk.text)
                .font(font)
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct StreamingTextTail: View {
    let projection: ChatMessage.StreamingTextProjection
    let font: Font
    let color: Color

    var body: some View {
        if !projection.tail.isEmpty {
            Text(projection.tail)
                .font(font)
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct MessageCopyActions: ViewModifier {
    let canCopy: Bool
    let makeText: () -> String?

    func body(content: Content) -> some View {
        if canCopy {
            content
                .textSelection(.enabled)
                .contextMenu {
                    Button {
                        UIPasteboard.general.string = makeText()
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
    func messageCopyActions(
        canCopy: Bool,
        makeText: @escaping () -> String?
    ) -> some View {
        modifier(MessageCopyActions(canCopy: canCopy, makeText: makeText))
    }
}
