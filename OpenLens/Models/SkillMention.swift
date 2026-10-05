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
        var seen = Set<String>()
        return matches(in: text, skillIDs: skillIDs).compactMap { match in
            guard seen.insert(match.id).inserted else { return nil }
            let mentionText = String(text[match.range])
            let start = text.utf16.distance(from: text.startIndex, to: match.range.lowerBound)
            return OCV2SkillAttachment(
                id: match.id,
                mention: .init(start: start, end: start + mentionText.utf16.count, text: mentionText)
            )
        }
    }

    /// Every mention in `text`, repeats included, as the range of the `@` and
    /// the name, so a sent message can draw each one as a chip.
    static func mentionRanges(in text: String, skillIDs: some Sequence<String>) -> [Range<String.Index>] {
        matches(in: text, skillIDs: skillIDs).map(\.range)
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

    /// Drops the trailing mention being typed, once the composer has turned
    /// the picked skill into a chip.
    static func removingActiveQuery(from text: String) -> String {
        guard let query = activeQuery(in: text) else { return text }
        return String(text.dropLast(query.count + 1))
    }

    /// Pulls finished `@skill` tokens out of `text` so the composer can show
    /// them as chips. A token is finished once whitespace follows it, and it
    /// must name a listed skill exactly (ignoring case); one following space
    /// or tab goes with it. Anything else, including the token still being
    /// typed, stays in the text.
    static func extractingCompletedMentions(
        from text: String,
        skillIDs: some Sequence<String>
    ) -> (text: String, skillIDs: [String]) {
        let catalog = catalog(of: skillIDs)
        guard !catalog.isEmpty, text.contains("@") else { return (text, []) }

        var remaining = ""
        var ids: [String] = []
        var copyStart = text.startIndex
        var index = text.startIndex

        while let at = text[index...].firstIndex(of: "@") {
            index = text.index(after: at)
            guard at == text.startIndex || text[text.index(before: at)].isWhitespace,
                  let tokenEnd = text[index...].firstIndex(where: \.isWhitespace) else { continue }
            index = tokenEnd
            guard let id = catalog[text[text.index(after: at)..<tokenEnd].lowercased()] else { continue }

            remaining += text[copyStart..<at]
            if !ids.contains(id) {
                ids.append(id)
            }
            copyStart = text[tokenEnd] == " " || text[tokenEnd] == "\t" ? text.index(after: tokenEnd) : tokenEnd
            index = copyStart
        }

        guard !ids.isEmpty else { return (text, []) }
        remaining += text[copyStart...]
        return (remaining, ids)
    }

    /// Writes chip skills back into the text as `@skill` mentions, which is
    /// how the server receives them. They lead the prompt, or follow the
    /// command name so a `/command` still parses.
    static func composing(_ text: String, mentioning ids: [String]) -> String {
        guard !ids.isEmpty else { return text }
        let mentions = ids.map { "@\($0)" }.joined(separator: " ")

        guard text.hasPrefix("/") else {
            return text.isEmpty ? mentions : "\(mentions) \(text)"
        }

        let commandEnd = text.firstIndex(where: \.isWhitespace) ?? text.endIndex
        let arguments = text[commandEnd...].drop(while: \.isWhitespace)
        let command = text[..<commandEnd]
        return arguments.isEmpty ? "\(command) \(mentions)" : "\(command) \(mentions) \(arguments)"
    }

    private static func matches(
        in text: String,
        skillIDs: some Sequence<String>
    ) -> [(id: String, range: Range<String.Index>)] {
        let catalog = catalog(of: skillIDs)
        guard !catalog.isEmpty, text.contains("@") else { return [] }

        var matches: [(id: String, range: Range<String.Index>)] = []
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

            guard !name.isEmpty, let id = catalog[name.lowercased()] else { continue }
            matches.append((id, at..<name.endIndex))
        }

        return matches
    }

    /// Lowercased name to listed id; the first id wins when two differ only by case.
    private static func catalog(of skillIDs: some Sequence<String>) -> [String: String] {
        var catalog: [String: String] = [:]
        for id in skillIDs where catalog[id.lowercased()] == nil {
            catalog[id.lowercased()] = id
        }
        return catalog
    }
}
