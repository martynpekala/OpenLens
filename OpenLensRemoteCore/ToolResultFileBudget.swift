import Foundation

/// Files that OpenCode tools return (screenshots, PDFs, MCP blobs) travel
/// inline as `data:` URIs inside tool content. The app and the Remote
/// gateway apply this same budget, so a tool result shows the same files
/// whether it arrived directly or through Remote, and an oversized file
/// is withheld explicitly instead of breaking the stream or the page.
nonisolated enum ToolResultFileBudget {
    /// Files shown per tool result; any further files are only counted.
    static let maximumFiles = 4
    /// Inline URI bytes kept across one tool result. An encrypted Remote
    /// event must stay under the wire limit after two base64 expansions.
    static let maximumURIBytes = 1_536 * 1_024
    /// Largest upstream event record or history page the gateway reads
    /// before compacting it.
    static let maximumUpstreamBytes = 32 * 1_024 * 1_024

    /// For each file URI size, in order, whether that file's URI is kept.
    static func keepsURIs(ofSizes sizes: [Int]) -> [Bool] {
        var remaining = maximumURIBytes
        return sizes.enumerated().map { index, size in
            guard index < maximumFiles, size <= remaining else { return false }
            remaining -= size
            return true
        }
    }

    /// Removes the `uri` of every tool file that doesn't fit the budget from
    /// each `content` array in `value`, keeping its MIME and name so the app
    /// can say what was left out. Text content is never changed.
    static func compact(_ value: Any) -> Any {
        transformContent(value, with: compactContent)
    }

    /// `value` compacted, then with the largest remaining file URIs withheld
    /// one at a time until its JSON fits `maximumBytes` (one Remote message).
    /// Decisions depend only on sizes and a key-sorted walk, so the app and
    /// the gateway withhold the same files.
    static func fitted(_ value: Any, maximumBytes: Int) throws -> Any {
        guard !uriSizes(in: value).isEmpty else { return value }
        var current = compact(value)
        while try JSONSerialization.data(withJSONObject: current).count > maximumBytes {
            let sizes = uriSizes(in: current)
            guard let largest = sizes.indices.max(by: { sizes[$0] < sizes[$1] || (sizes[$0] == sizes[$1] && $0 > $1) })
            else { break }
            current = withholdingURI(at: largest, in: current)
        }
        return current
    }

    /// `fitted(_:maximumBytes:)` as JSON.
    static func compactedJSON(_ value: Any, maximumBytes: Int) throws -> Data {
        try JSONSerialization.data(withJSONObject: fitted(value, maximumBytes: maximumBytes))
    }

    /// Whether a GET to `path` returns session transcript messages, whose
    /// tool files both transports fit to one Remote message.
    static func isTranscriptPath(_ path: String) -> Bool {
        let segments = path.split(separator: "/")
        return segments.count >= 4 && segments[0] == "api" && segments[1] == "session"
            && segments[2] != "active" && segments[3] == "message"
    }

    /// URI sizes of kept tool files, in key-sorted walk order.
    private static func uriSizes(in value: Any) -> [Int] {
        var sizes: [Int] = []
        walkFiles(in: value) { file in
            if let uri = file["uri"] as? String { sizes.append(uri.utf8.count) }
            return file
        }
        return sizes
    }

    private static func withholdingURI(at target: Int, in value: Any) -> Any {
        var position = 0
        return walkFiles(in: value) { file in
            guard file["uri"] != nil else { return file }
            defer { position += 1 }
            guard position == target else { return file }
            var withheld = file
            withheld.removeValue(forKey: "uri")
            return withheld
        }
    }

    /// Visits every tool file in each `content` array, walking object keys in
    /// sorted order so the visit order is the same in every process.
    @discardableResult
    private static func walkFiles(in value: Any, _ visit: ([String: Any]) -> [String: Any]) -> Any {
        if let array = value as? [Any] {
            return array.map { walkFiles(in: $0, visit) }
        }
        guard var object = value as? [String: Any] else { return value }
        for key in object.keys.sorted() {
            if key == "content", let content = object[key] as? [Any] {
                object[key] = content.map { item -> Any in
                    guard isFile(item), let file = item as? [String: Any] else { return walkFiles(in: item, visit) }
                    return visit(file)
                }
            } else {
                object[key] = walkFiles(in: object[key]!, visit)
            }
        }
        return object
    }

    private static func transformContent(_ value: Any, with transform: ([Any]) -> [Any]) -> Any {
        if let array = value as? [Any] {
            return array.map { transformContent($0, with: transform) }
        }
        guard var object = value as? [String: Any] else { return value }
        for (key, child) in object {
            object[key] = transformContent(child, with: transform)
        }
        if let content = object["content"] as? [Any] {
            object["content"] = transform(content)
        }
        return object
    }

    private static func compactContent(_ content: [Any]) -> [Any] {
        let fileIndices = content.indices.filter { isFile(content[$0]) }
        guard !fileIndices.isEmpty else { return content }
        let sizes = fileIndices.map { ((content[$0] as? [String: Any])?["uri"] as? String)?.utf8.count ?? 0 }
        var result = content
        for (index, keeps) in zip(fileIndices, keepsURIs(ofSizes: sizes)) where !keeps {
            guard var file = result[index] as? [String: Any] else { continue }
            file.removeValue(forKey: "uri")
            result[index] = file
        }
        return result
    }

    private static func isFile(_ item: Any) -> Bool {
        (item as? [String: Any])?["type"] as? String == "file"
    }
}
