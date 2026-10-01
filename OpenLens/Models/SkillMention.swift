import Foundation

/// `@skill` mentions in composer text, matching how the OpenCode TUI attaches
/// skills to a v2 prompt. A mention starts at the beginning of the text or
/// after whitespace, so addresses like `me@example.com` are left alone.
nonisolated enum SkillMention {
    private static let trailingPunctuation: Set<Character> = [".", ",", ";", ":", "!", "?", ")", "]", "}", "\"", "'"]

    /// The skills mentioned in `text`, once each, in the order they first
    /// appear. Names are matched case-insensitively against `skillIDs`;
    /// anything else after an `@` is treated as plain text. Offsets are UTF-16
    /// code units, which is what the server expects.
    static func attachments(in text: String, skillIDs: some Sequence<String>) -> [OCV2SkillAttachment] {
        var catalog: [String: String] = [:]
        for id in skillIDs where catalog[id.lowercased()] == nil {
            catalog[id.lowercased()] = id
        }
        guard !catalog.isEmpty else { return [] }

        var attachments: [OCV2SkillAttachment] = []
        var seen = Set<String>()
        var index = text.startIndex

        while let at = text[index...].firstIndex(of: "@") {
            index = text.index(after: at)
            guard at == text.startIndex || text[text.index(before: at)].isWhitespace else { continue }

            let tokenEnd = text[index...].firstIndex(where: \.isWhitespace) ?? text.endIndex
            var name = text[index..<tokenEnd]
            while catalog[name.lowercased()] == nil, let last = name.last, trailingPunctuation.contains(last) {
                name = name.dropLast()
            }
            index = tokenEnd

            guard !name.isEmpty, let id = catalog[name.lowercased()], seen.insert(id).inserted else { continue }
            let mentionText = String(text[at..<name.endIndex])
            let start = text.utf16.distance(from: text.startIndex, to: at)
            attachments.append(
                OCV2SkillAttachment(
                    id: id,
                    mention: .init(start: start, end: start + mentionText.utf16.count, text: mentionText)
                )
            )
        }

        return attachments
    }

    /// The partial skill name after a trailing `@` that is still being typed,
    /// or nil when the text does not end in a mention. An `@` on its own
    /// returns an empty query.
    static func activeQuery(in text: String) -> String? {
        guard let at = text.lastIndex(of: "@"),
              at == text.startIndex || text[text.index(before: at)].isWhitespace else { return nil }
        let query = text[text.index(after: at)...]
        guard !query.contains(where: \.isWhitespace) else { return nil }
        return String(query)
    }

    /// Replaces the trailing mention being typed with `@id ` so the user can
    /// keep typing. Without one, the mention is appended instead.
    static func completing(_ text: String, with id: String) -> String {
        guard let query = activeQuery(in: text) else {
            let separator = text.isEmpty || text.last?.isWhitespace == true ? "" : " "
            return text + separator + "@\(id) "
        }
        return String(text.dropLast(query.count + 1)) + "@\(id) "
    }
}
