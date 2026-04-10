import Foundation

/// Formats tool names and state into human-readable labels for the activity card
/// and Live Activity display.
enum ToolLabelFormatter {

    /// Build a short label describing what the tool is doing (e.g. "Reading main.swift...").
    static func label(toolName: String, state: OCToolState) -> String {
        if let input = state.input?.value as? [String: Any] {
            if let path = input["path"] as? String {
                let filename = (path as NSString).lastPathComponent
                switch toolName.lowercased() {
                case "read":  return "Reading \(filename)..."
                case "write": return "Writing \(filename)..."
                case "edit":  return "Editing \(filename)..."
                default: break
                }
            }
            if let command = input["command"] as? String {
                let short = String(command.prefix(40))
                return "Running: \(short)..."
            }
            if let query = input["query"] as? String {
                return "Searching: \(query.prefix(30))..."
            }
            if let pattern = input["pattern"] as? String {
                return "Finding: \(pattern.prefix(30))..."
            }
        }

        // Question tool
        if toolName.lowercased() == "question" {
            return "Asking a question..."
        }

        if let title = state.title {
            return title
        }
        return "\(toolName)..."
    }

    /// Build a detail string (typically the full path, if available).
    static func detail(state: OCToolState) -> String {
        if let input = state.input?.value as? [String: Any],
           let path = input["path"] as? String {
            return path
        }
        return ""
    }
}
