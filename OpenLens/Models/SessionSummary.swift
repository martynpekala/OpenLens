import Foundation

/// What a transient, model-generated catch-up explains about a session.
enum SessionSummaryKind: String, CaseIterable, Identifiable, Sendable {
    case summary
    case nextStep

    var id: String { rawValue }

    var title: String {
        switch self {
        case .summary: AppText.sessionSummaryKindSummary
        case .nextStep: AppText.sessionSummaryKindNextStep
        }
    }

    /// Fixed prompts keep results comparable between regenerations.
    var prompt: String {
        switch self {
        case .summary:
            "Summarize this session for someone returning to it on a phone: the goal, what has been done, the current state, and any open problems. Be concise and use short bullet points."
        case .nextStep:
            "Based on this session, what is the most useful next step? Explain briefly why, and point out anything that needs the user's decision."
        }
    }
}

/// A generated explanation and the transcript revision it was produced from.
struct SessionSummary: Equatable, Sendable {
    let kind: SessionSummaryKind
    let text: String
    let revision: String
    let generatedAt: Date
}

/// Per session and kind: the last result is kept while a regeneration runs or
/// fails, so an optional explanation never replaces useful text with nothing.
struct SessionSummaryEntry: Equatable, Sendable {
    var summary: SessionSummary?
    var isGenerating = false
    var error: String?
}
