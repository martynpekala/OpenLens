import Foundation

// MARK: - AgentActivity

/// Tracks the agent's current turn activity for shimmer + activity card display.
@Observable
final class AgentActivity: Identifiable {
    let id = UUID()
    var currentLabel: String = ""
    var thinkingText: String = ""
    var steps: [ActivityStep] = [] {
        didSet { rebuildCompletedSteps() }
    }

    /// Cached completed steps — rebuilt only when the completed subset actually changes.
    /// Views reading `completedSteps` are only invalidated when this array mutates,
    /// not when unrelated steps are appended or non-completed fields change.
    private(set) var completedSteps: [ActivityStep] = []

    /// Track the last known completed count to avoid unnecessary array rebuilds.
    @ObservationIgnored private var lastCompletedCount: Int = 0

    private func rebuildCompletedSteps() {
        let filtered = steps.filter { $0.isCompleted }
        // Only assign (triggering observation) when the completed set actually changed.
        if filtered.count != lastCompletedCount {
            lastCompletedCount = filtered.count
            completedSteps = filtered
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
        let lower = toolName.lowercased()
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
