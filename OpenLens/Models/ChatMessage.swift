import Foundation
import Observation

/// Represents a single chat message for display purposes.
/// This is a local model that combines OCMessage + OCPart data
/// into a flat structure suitable for the UI.
///
/// Using `@Observable` class instead of struct so that mutations to individual
/// message properties (content, isStreaming, parts) only invalidate the views
/// observing *that specific message* — NOT the entire ForEach list.
@Observable
final class ChatMessage: Identifiable {
    struct AssistantSegment: Identifiable {
        enum Kind {
            case text(String)
            case reasoning(String)
            case question(PersistedQuestionStep)
            case subagent(PersistedSubagentStep)
            case tool(PersistedToolStep)
        }

        let id: String
        let kind: Kind
    }

    struct PersistedToolStep: Identifiable {
        let id: String
        let toolName: String
        let label: String
        let detail: String
        let output: String?
        let isError: Bool
        let toolCategory: ToolCategory
    }

    struct PersistedQuestionStep: Identifiable {
        let id: String
        let questions: [OCQuestionInfo]
        let answers: [[String]]
        let status: OCToolStatus
        let isError: Bool

        var hasAnswers: Bool {
            answers.contains { !$0.isEmpty }
        }

        var isAnswered: Bool {
            hasAnswers || status == .completed
        }
    }

    struct PersistedSubagentStep: Identifiable {
        let id: String
        let agentName: String?
        let title: String
        let detail: String
        let prompt: String?
        let isCompleted: Bool
        let isError: Bool
        let cost: Double?
    }

    let id: String
    let role: OCMessageRole

    var content: String {
        didSet {
            if !isStreaming { rebuildDerivedState() }
        }
    }
    var parts: [OCPart] {
        didSet { rebuildDerivedState() }
    }
    var isStreaming: Bool {
        didSet { rebuildDerivedState() }
    }
    let createdAt: Date
    var cost: Double?
    var tokens: OCTokenUsage?

    var modelID: String?
    var providerID: String?
    var finish: String?

    private(set) var assistantSegments: [AssistantSegment] = []

    init(
        id: String = UUID().uuidString,
        role: OCMessageRole,
        content: String,
        parts: [OCPart] = [],
        isStreaming: Bool = false,
        createdAt: Date = Date(),
        cost: Double? = nil,
        tokens: OCTokenUsage? = nil,
        modelID: String? = nil,
        providerID: String? = nil,
        finish: String? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.parts = parts
        self.isStreaming = isStreaming
        self.createdAt = createdAt
        self.cost = cost
        self.tokens = tokens
        self.modelID = modelID
        self.providerID = providerID
        self.finish = finish
        rebuildDerivedState()
    }

    /// Display-friendly model name for assistant messages.
    var modelDisplayName: String? {
        guard let modelID, !modelID.isEmpty else { return nil }
        return modelID
    }

    /// Extract all tool call parts from this message.
    var toolParts: [OCPart] {
        parts.filter { $0.type == .tool }
    }

    var hasRenderableTextPart: Bool {
        parts.contains { $0.renderableText?.nilIfBlank != nil }
    }

    /// Whether the message has any active (running) tool calls.
    var hasRunningTools: Bool {
        toolParts.contains { $0.state?.status == .running }
    }

    var reasoningText: String {
        parts
            .filter { $0.type == .reasoning }
            .compactMap(\.text)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
    }

    var persistedToolSteps: [PersistedToolStep] {
        parts.compactMap(makePersistedToolStep)
    }

    func rebuildDerivedState() {
        assistantSegments = buildAssistantSegments()
    }

    private func buildAssistantSegments() -> [AssistantSegment] {
        guard role == .assistant else { return [] }

        var segments: [AssistantSegment] = []
        let hasTextPart = hasRenderableTextPart

        for part in parts {
            switch part.type {
            case .text:
                let rawText = part.renderableText?.nilIfBlank
                if let rawText {
                    segments.append(AssistantSegment(id: part.id, kind: .text(rawText)))
                }

            case .reasoning:
                guard let text = part.text?.nilIfBlank else { continue }
                segments.append(
                    AssistantSegment(
                        id: part.id,
                        kind: .reasoning(text)
                    )
                )

            case .tool:
                if let questionStep = makePersistedQuestionStep(from: part) {
                    segments.append(AssistantSegment(id: part.id, kind: .question(questionStep)))
                    continue
                }

                if let subagentStep = makePersistedSubagentStep(from: part) {
                    segments.append(AssistantSegment(id: part.id, kind: .subagent(subagentStep)))
                    continue
                }

                guard let step = makePersistedToolStep(from: part) else { continue }
                segments.append(AssistantSegment(id: part.id, kind: .tool(step)))

            case .agent,
                 .subtask:
                guard let step = makePersistedSubagentStep(from: part) else { continue }
                segments.append(AssistantSegment(id: part.id, kind: .subagent(step)))

            case .file,
                 .stepStart,
                 .stepFinish,
                 .snapshot,
                 .patch,
                 .retry,
                 .compaction,
                 .unknown:
                continue
            }
        }

        if !isStreaming,
           !hasTextPart,
           let content = content.nilIfBlank {
            segments.append(AssistantSegment(id: "content-text-\(id)", kind: .text(content)))
        }

        if isStreaming, segments.isEmpty {
            return [
                AssistantSegment(
                    id: "streaming-thinking-\(id)",
                    kind: .reasoning("Thinking...")
                )
            ]
        }

        if segments.isEmpty,
           let content = content.nilIfBlank {
            return [AssistantSegment(id: "fallback-text-\(id)", kind: .text(content))]
        }

        return segments
    }

    private func makePersistedToolStep(from part: OCPart) -> PersistedToolStep? {
        guard part.type == .tool,
              let toolName = part.tool,
              let state = part.state else { return nil }

        let normalizedName = toolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedName != "question" else { return nil }

        switch state.status {
        case .pending, .unknown:
            return nil
        case .running, .completed, .error:
            let detail = ToolLabelFormatter.detail(state: state).nilIfBlank
            let primaryOutput = state.output?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
            let fallbackOutput = state.error?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank

            let isTodoTool = normalizedName.contains("todo")

            return PersistedToolStep(
                id: part.id,
                toolName: toolName,
                label: ToolLabelFormatter.label(toolName: toolName, state: state),
                detail: detail ?? "",
                output: isTodoTool ? nil : (primaryOutput ?? fallbackOutput),
                isError: state.status == .error,
                toolCategory: ToolCategory.from(toolName: toolName)
            )
        }
    }

    private func makePersistedQuestionStep(from part: OCPart) -> PersistedQuestionStep? {
        guard part.type == .tool,
              part.tool?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "question",
              let state = part.state else { return nil }

        guard state.status != .unknown else { return nil }

        return PersistedQuestionStep(
            id: part.id,
            questions: questionInfos(from: state.input),
            answers: questionAnswers(from: state.metadata),
            status: state.status,
            isError: state.status == .error
        )
    }

    private func makePersistedSubagentStep(from part: OCPart) -> PersistedSubagentStep? {
        let taskState = subagentToolState(from: part)
        guard part.type == .agent || part.type == .subtask || taskState != nil else { return nil }

        let taskInput = taskState?.input?.value as? [String: Any]
        let agentName = subagentName(from: part) ?? taskInputString(in: taskInput, keys: ["subagent_type", "agent", "agentID", "name"])
        let description = part.partDescription?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
            ?? taskInputString(in: taskInput, keys: ["description", "task"])
        let prompt = part.prompt?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
            ?? taskInputString(in: taskInput, keys: ["prompt", "message"])
        let source = stringValue(from: part.source)
        let stateTitle = taskState?.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        let stateError = taskState?.error?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        let fallbackName = part.name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank

        let title = agentName ?? fallbackName ?? "Subagent"
        let detail = description ?? prompt ?? stateTitle ?? source ?? stateError ?? ""

        guard title != "Subagent" || !detail.isEmpty else { return nil }

        return PersistedSubagentStep(
            id: part.id,
            agentName: agentName,
            title: title,
            detail: detail,
            prompt: prompt,
            isCompleted: isSubagentPartCompleted(part, taskState: taskState),
            isError: taskState?.status == .error,
            cost: part.cost
        )
    }

    private func subagentToolState(from part: OCPart) -> OCToolState? {
        guard part.type == .tool,
              part.tool?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "task",
              let state = part.state else { return nil }
        return state
    }

    private func isSubagentPartCompleted(_ part: OCPart, taskState: OCToolState?) -> Bool {
        if let taskState {
            return taskState.status == .completed || taskState.status == .error
        }

        return !isStreaming || part.cost != nil || part.tokens != nil || hasEndTime(part.time)
    }

    private func hasEndTime(_ time: AnyCodable?) -> Bool {
        guard let dictionary = time?.value as? [String: Any] else { return false }
        return dictionary["end"] != nil || dictionary["completed"] != nil
    }

    private func subagentName(from part: OCPart) -> String? {
        part.name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
            ?? stringValue(from: part.agent)
            ?? dictionaryStringValue(for: "name", in: part.agent)
            ?? dictionaryStringValue(for: "id", in: part.agent)
            ?? dictionaryStringValue(for: "title", in: part.agent)
    }

    private func stringValue(from value: AnyCodable?) -> String? {
        (value?.value as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfBlank
    }

    private func taskInputString(in input: [String: Any]?, keys: [String]) -> String? {
        guard let input else { return nil }

        for key in keys {
            if let value = (input[key] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfBlank {
                return value
            }
        }

        return nil
    }

    private func dictionaryStringValue(for key: String, in value: AnyCodable?) -> String? {
        guard let dictionary = value?.value as? [String: Any] else { return nil }
        return (dictionary[key] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfBlank
    }

    private func questionInfos(from input: AnyCodable?) -> [OCQuestionInfo] {
        guard let rawInput = input?.value else { return [] }

        let compatibleInput = jsonCompatibleValue(rawInput)
        let rawQuestions: Any?
        if let input = compatibleInput as? [String: Any] {
            rawQuestions = input["questions"]
        } else {
            rawQuestions = compatibleInput
        }

        guard let rawQuestions else { return [] }
        let compatibleQuestions = jsonCompatibleValue(rawQuestions)
        guard JSONSerialization.isValidJSONObject(compatibleQuestions),
              let data = try? JSONSerialization.data(withJSONObject: compatibleQuestions),
              let questions = try? JSONDecoder().decode([OCQuestionInfo].self, from: data) else {
            return []
        }

        return questions
    }

    private func questionAnswers(from metadata: [String: AnyCodable]?) -> [[String]] {
        guard let rawAnswers = metadata?["answers"]?.value else { return [] }
        return answerRows(from: rawAnswers)
    }

    private func answerRows(from value: Any) -> [[String]] {
        let compatibleValue = jsonCompatibleValue(value)

        if let rows = compatibleValue as? [[String]] {
            return rows
                .map(normalizedAnswerStrings)
                .filter { !$0.isEmpty }
        }

        if let rows = compatibleValue as? [[Any]] {
            return rows
                .map(answerStrings)
                .filter { !$0.isEmpty }
        }

        if let row = compatibleValue as? [String] {
            let answers = normalizedAnswerStrings(row)
            return answers.isEmpty ? [] : [answers]
        }

        if let values = compatibleValue as? [Any] {
            let containsNestedRows = values.contains { $0 is [Any] || $0 is [String] }
            if containsNestedRows {
                return values
                    .map(answerStrings)
                    .filter { !$0.isEmpty }
            }

            let answers = answerStrings(values)
            return answers.isEmpty ? [] : [answers]
        }

        if let answer = answerString(compatibleValue) {
            return [[answer]]
        }

        return []
    }

    private func answerStrings(_ value: Any) -> [String] {
        if let values = value as? [String] {
            return normalizedAnswerStrings(values)
        }

        if let values = value as? [Any] {
            return values.compactMap(answerString)
        }

        return answerString(value).map { [$0] } ?? []
    }

    private func normalizedAnswerStrings(_ values: [String]) -> [String] {
        values.compactMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank }
    }

    private func answerString(_ value: Any) -> String? {
        (value as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfBlank
    }

    private func jsonCompatibleValue(_ value: Any) -> Any {
        switch value {
        case let wrapped as AnyCodable:
            return jsonCompatibleValue(wrapped.value)
        case let array as [AnyCodable]:
            return array.map { jsonCompatibleValue($0.value) }
        case let dictionary as [String: AnyCodable]:
            return dictionary.mapValues { jsonCompatibleValue($0.value) }
        case let array as [Any]:
            return array.map(jsonCompatibleValue)
        case let dictionary as [String: Any]:
            return dictionary.mapValues(jsonCompatibleValue)
        default:
            return value
        }
    }
}
