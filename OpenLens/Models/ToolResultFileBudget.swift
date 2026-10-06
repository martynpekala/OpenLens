import Foundation

/// Files that OpenCode tools return (screenshots, PDFs, MCP blobs) travel
/// inline as `data:` URIs inside tool content. This budget bounds how many
/// are kept per tool result; any file over it is withheld explicitly.
nonisolated enum ToolResultFileBudget {
    /// Files shown per tool result; any further files are only counted.
    static let maximumFiles = 4
    /// Inline URI bytes kept across one tool result.
    static let maximumURIBytes = 1_536 * 1_024

    /// For each file URI size, in order, whether that file's URI is kept.
    static func keepsURIs(ofSizes sizes: [Int]) -> [Bool] {
        var remaining = maximumURIBytes
        return sizes.enumerated().map { index, size in
            guard index < maximumFiles, size <= remaining else { return false }
            remaining -= size
            return true
        }
    }
}
