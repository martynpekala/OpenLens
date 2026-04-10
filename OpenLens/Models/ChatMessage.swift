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
            case reasoning(String, [TodoListCardView.Item])
            case tool(PersistedToolStep)
        }

        let id: String
        let kind: Kind
    }

    struct PersistedToolStep: Identifiable {
        let id: String
        let label: String
        let detail: String
        let output: String?
        let todoItems: [TodoListCardView.Item]
        let isError: Bool
        let toolCategory: ToolCategory
    }

    let id: String
    let role: OCMessageRole

    var content: String {
        didSet { rebuildDerivedState() }
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
        let hasTextPart = parts.contains { part in
            part.type == .text && part.text?.nilIfBlank != nil
        }

        for part in parts {
            switch part.type {
            case .text:
                let rawText = part.text?.nilIfBlank
                if let rawText {
                    segments.append(AssistantSegment(id: part.id, kind: .text(rawText)))
                }

            case .reasoning:
                guard let text = part.text?.nilIfBlank else { continue }
                segments.append(
                    AssistantSegment(
                        id: part.id,
                        kind: .reasoning(text, TodoListParser.parse(from: text))
                    )
                )

            case .tool:
                guard let step = makePersistedToolStep(from: part) else { continue }
                segments.append(AssistantSegment(id: part.id, kind: .tool(step)))

            default:
                continue
            }
        }

          if isStreaming,
              !hasTextPart,
              let content = content.nilIfBlank {
            segments.append(AssistantSegment(id: "streaming-text-\(id)", kind: .text(content)))
        }

        if isStreaming, segments.isEmpty {
            return [
                AssistantSegment(
                    id: "streaming-thinking-\(id)",
                    kind: .reasoning("Thinking...", [])
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

        switch state.status {
        case .pending, .unknown:
            return nil
        case .running, .completed, .error:
            let detail = ToolLabelFormatter.detail(state: state).nilIfBlank
            let primaryOutput = state.output?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
            let fallbackOutput = state.error?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank

            return PersistedToolStep(
                id: part.id,
                label: ToolLabelFormatter.label(toolName: toolName, state: state),
                detail: detail ?? "",
                output: primaryOutput ?? fallbackOutput,
                todoItems: TodoListParser.parse(from: primaryOutput ?? fallbackOutput ?? ""),
                isError: state.status == .error,
                toolCategory: ToolCategory.from(toolName: toolName)
            )
        }
    }

}
