import SwiftUI

/// Finds bare `http(s)://` and `www.` URLs in message prose so they can be
/// tapped and copied. Markdown `[text](url)` links keep their own URL.
enum DetectedLinks {
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Cheap pre-check so plain prose skips the detector entirely.
    static func mayContainLink(_ text: String) -> Bool {
        text.range(of: "http", options: .caseInsensitive) != nil
            || text.range(of: "www.", options: .caseInsensitive) != nil
    }

    /// Returns `attributed` with a `.link` run on each detected link that is not
    /// already a link or inline code. Every link is underlined, because chat
    /// links share the text color.
    static func addingLinks(to attributed: AttributedString) -> AttributedString {
        let plain = String(attributed.characters)
        var result = attributed
        if mayContainLink(plain) {
            for (nsRange, url) in matches(in: plain) {
                guard let range = Range(nsRange, in: result),
                      result[range].runs.allSatisfy({
                          $0.link == nil && !($0.inlinePresentationIntent?.contains(.code) ?? false)
                      }) else { continue }
                result[range].link = url
            }
        }
        for run in result.runs where run.link != nil {
            result[run.range].underlineStyle = .single
        }
        return result
    }

    /// Detected links in `text`, in order and without duplicates. Fenced code
    /// blocks are skipped, matching what the chat renders as tappable.
    static func urls(in text: String) -> [URL] {
        guard mayContainLink(text) else { return [] }

        var seen = Set<URL>()
        return matches(in: proseOutsideCodeFences(text))
            .map(\.url)
            .filter { seen.insert($0).inserted }
    }

    /// A short form for menus: host and path, without the scheme.
    static func displayString(for url: URL, limit: Int = 40) -> String {
        var display = url.absoluteString
        for prefix in ["https://", "http://"] where display.lowercased().hasPrefix(prefix) {
            display.removeFirst(prefix.count)
        }
        if display.hasSuffix("/") { display.removeLast() }
        guard display.count > limit else { return display }
        return String(display.prefix(limit - 1)) + "…"
    }

    private static func matches(in text: String) -> [(range: NSRange, url: URL)] {
        guard let detector else { return [] }
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)

        return detector.matches(in: text, range: fullRange).compactMap { match in
            let matched = nsText.substring(with: match.range).lowercased()
            if matched.hasPrefix("http://") || matched.hasPrefix("https://") {
                guard let url = match.url else { return nil }
                return (match.range, url)
            }
            // Accept `www.` without a scheme, but not bare domains or emails.
            guard matched.hasPrefix("www."),
                  let url = URL(string: "https://" + nsText.substring(with: match.range)) else { return nil }
            return (match.range, url)
        }
    }

    private static func proseOutsideCodeFences(_ text: String) -> String {
        guard text.contains("```") else { return text }

        var isInFence = false
        var lines: [Substring] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                isInFence.toggle()
            } else if !isInFence {
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n")
    }
}
