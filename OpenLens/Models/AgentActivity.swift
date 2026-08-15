import Foundation

// MARK: - AgentActivity

/// Tracks the agent's current turn activity for shimmer + activity card display.
@Observable
final class AgentActivity: Identifiable {
    /// Keeps the visible activity card bounded even for long-running tool-heavy turns.
    static let maximumStepCount = 80

    let id = UUID()
    var currentLabel: String = ""
    var thinkingText: String = ""
    private(set) var steps: [ActivityStep] = []

    /// Cached completed steps maintained incrementally so a tool update never
    /// rebuilds a growing filtered copy of the entire activity history.
    private(set) var completedSteps: [ActivityStep] = []

    @discardableResult
    func recordToolCallIfNeeded(
        label: String,
        detail: String,
        toolCategory: ToolCategory
    ) -> Bool {
        guard !steps.contains(where: { $0.label == label && $0.type == .toolCall }) else {
            return false
        }

        append(ActivityStep(
            type: .toolCall,
            label: label,
            detail: detail,
            toolCategory: toolCategory
        ))
        return true
    }

    func recordCompletedToolResult(label: String, toolCategory: ToolCategory) {
        append(ActivityStep(
            type: .toolResult,
            label: label,
            toolCategory: toolCategory,
            isCompleted: true
        ))
    }

    /// Completes the same candidate selected by the former SSE array lookup:
    /// the matching label when present, otherwise the latest unfinished tool call.
    @discardableResult
    func completeToolCall(matching label: String) -> Bool {
        guard let index = steps.lastIndex(where: {
            $0.label == label || ($0.type == .toolCall && !$0.isCompleted)
        }) else {
            return false
        }

        markCompleted(at: index)
        return true
    }

    @discardableResult
    func completeMostRecentIncompleteStep() -> Bool {
        guard let index = steps.lastIndex(where: { !$0.isCompleted }) else {
            return false
        }

        markCompleted(at: index)
        return true
    }

    /// Exact-label completion used by the deterministic demo player.
    @discardableResult
    func completeStep(labeled label: String) -> Bool {
        guard let index = steps.lastIndex(where: { $0.label == label }) else {
            return false
        }

        markCompleted(at: index)
        return true
    }

    private func append(_ step: ActivityStep) {
        steps.append(step)
        if step.isCompleted {
            completedSteps.append(step)
        }
        trimStepsIfNeeded()
    }

    private func markCompleted(at index: Int) {
        guard !steps[index].isCompleted else { return }

        steps[index].isCompleted = true
        let insertionIndex = steps[..<index].reduce(into: 0) { count, step in
            if step.isCompleted {
                count += 1
            }
        }
        completedSteps.insert(steps[index], at: insertionIndex)
    }

    private func trimStepsIfNeeded() {
        let excess = steps.count - Self.maximumStepCount
        guard excess > 0 else { return }

        let removedCompletedIDs = Set(
            steps.prefix(excess)
                .lazy
                .filter(\.isCompleted)
                .map(\.id)
        )
        steps.removeFirst(excess)

        if !removedCompletedIDs.isEmpty {
            completedSteps.removeAll { removedCompletedIDs.contains($0.id) }
        }
    }
}

// MARK: - ActivityStep

struct ActivityStep: Identifiable {
    let id = UUID()
    let type: StepType
    let label: String
    let detail: String
    let toolCategory: ToolCategory
    let timestamp: Date
    var isCompleted: Bool

    init(
        type: StepType,
        label: String,
        detail: String = "",
        toolCategory: ToolCategory = .unknown,
        isCompleted: Bool = false
    ) {
        self.type = type
        self.label = label
        self.detail = detail
        self.toolCategory = toolCategory
        self.timestamp = Date()
        self.isCompleted = isCompleted
    }

    enum StepType {
        case thinking
        case toolCall
        case toolResult
    }
}

// MARK: - ToolCategory

/// Categorization of tools for icon display.
enum ToolCategory: String {
    case read
    case write
    case edit
    case search
    case bash
    case browser
    case agent
    case question
    case unknown

    var iconName: String {
        switch self {
        case .read: return "doc.text"
        case .write: return "square.and.pencil"
        case .edit: return "pencil.line"
        case .search: return "magnifyingglass"
        case .bash: return "terminal"
        case .browser: return "globe"
        case .agent: return "person.circle"
        case .question: return "questionmark.circle"
        case .unknown: return "gearshape"
        }
    }

    static func from(toolName: String) -> ToolCategory {
        // Categorization runs for every streamed tool update. Never normalize
        // an arbitrary-length server identifier here: the first characters are
        // sufficient for known tool names and keep this display-only path
        // bounded even if a malformed payload is enormous.
        let lower = String(toolName.prefix(96)).lowercased()
        if lower.contains("read") || lower.contains("glob") || lower.contains("grep") {
            return .read
        } else if lower.contains("write") || lower.contains("create") {
            return .write
        } else if lower.contains("edit") || lower.contains("patch") {
            return .edit
        } else if lower.contains("search") || lower.contains("find") {
            return .search
        } else if lower.contains("bash") || lower.contains("shell") || lower.contains("exec") {
            return .bash
        } else if lower.contains("browser") || lower.contains("web") || lower.contains("fetch") {
            return .browser
        } else if lower.contains("agent") || lower.contains("task") {
            return .agent
        } else if lower.contains("question") {
            return .question
        }
        return .unknown
    }
}
