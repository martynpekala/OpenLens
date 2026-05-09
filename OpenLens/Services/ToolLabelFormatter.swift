import Foundation

/// Formats tool names and state into human-readable labels for the activity card
/// and Live Activity display.
enum ToolLabelFormatter {

    /// Build a short label describing what the tool is doing (e.g. "Reading main.swift...").
    static func label(toolName: String, state: OCToolState) -> String {
        let normalizedToolName = toolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let input = state.input?.value as? [String: Any]

        switch normalizedToolName {
        case "read":
            if let path = toolPath(input) {
                return "Read \(compactPath(path))"
            }
        case "write":
            if let path = toolPath(input) {
                return "Write \(compactPath(path))"
            }
        case "edit":
            if let path = toolPath(input) {
                return "Edit \(compactPath(path))"
            }
        case "glob":
            if let pattern = input?["pattern"] as? String {
                let scope = compactScope(input?["path"] as? String)
                return scope == "." ? "Glob \"\(pattern)\"" : "Glob \"\(pattern)\" in \(scope)"
            }
        case "grep":
            if let pattern = input?["pattern"] as? String {
                let scope = compactScope(input?["path"] as? String)
                return scope == "." ? "Grep \"\(pattern)\"" : "Grep \"\(pattern)\" in \(scope)"
            }
        case "bash":
            if let command = input?["command"] as? String {
                return "Bash \(commandPreview(command))"
            }
        case "question":
            if let title = state.title?.nilIfBlank {
                return title
            }
            return "Question"
        default:
            break
        }

        if let query = input?["query"] as? String {
            return "Search \(String(query.prefix(40)))"
        }

        if let pattern = input?["pattern"] as? String {
            return "Find \(String(pattern.prefix(40)))"
        }

        if let title = state.title?.nilIfBlank {
            return title
        }
        return normalizedToolName
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }

    /// Build a detail string (typically the full path, if available).
    static func detail(state: OCToolState) -> String {
        if let input = state.input?.value as? [String: Any],
           let path = toolPath(input) {
            return path
        }
        return ""
    }

    private static func toolPath(_ input: [String: Any]?) -> String? {
        (input?["filePath"] as? String)?.nilIfBlank ??
        (input?["path"] as? String)?.nilIfBlank
    }

    private static func compactPath(_ path: String) -> String {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count > 3 else { return path }
        return parts.suffix(3).joined(separator: "/")
    }

    private static func compactScope(_ path: String?) -> String {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            return "."
        }

        if path == "." {
            return path
        }

        let compact = compactPath(path)
        let last = (compact as NSString).lastPathComponent
        return last.isEmpty ? compact : last
    }

    private static func commandPreview(_ command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 52 else { return trimmed }
        return String(trimmed.prefix(52)) + "..."
    }
}
