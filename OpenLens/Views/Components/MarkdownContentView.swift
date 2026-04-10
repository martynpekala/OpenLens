import SwiftUI

/// Renders markdown text as native SwiftUI views.
/// Supports: code blocks, headings, lists, and inline formatting via AttributedString.
///
/// Long messages are automatically truncated to `initialBlockLimit` blocks.
/// The user can tap "Show more" to reveal additional content incrementally.
struct MarkdownContentView: View {
    let text: String
    let foregroundColor: Color

    private let cachedBlocks: [Block]

    /// Maximum blocks shown before truncation. Roughly 8-12 paragraphs worth.
    private static let initialBlockLimit = 12
    /// How many additional blocks to reveal per tap.
    private static let expandStep = 20
    /// Split very long plain paragraphs into smaller chunks to avoid expensive
    /// single Text layout passes when huge content is visible.
    private static let paragraphChunkSize = 1_600

    /// Number of blocks currently visible (nil = show all).
    @State private var visibleBlockCount: Int?

    // Global parse cache — avoids re-parsing the same (finished) message text on every
    // SwiftUI re-render of the parent. NSCache evicts under memory pressure automatically.
    // Keyed by a stable hash of the text to avoid expensive NSString copies for long messages.
    private static let blockCache: NSCache<NSNumber, BlocksBox> = {
        let c = NSCache<NSNumber, BlocksBox>()
        c.countLimit = 200
        return c
    }()

    // Wrapper so we can store [Block] in NSCache (which requires AnyObject values).
    private final class BlocksBox {
        let blocks: [Block]
        init(_ blocks: [Block]) { self.blocks = blocks }
    }

    init(_ text: String, foregroundColor: Color = Color(.label)) {
        self.text = text
        self.foregroundColor = foregroundColor

        // Use Swift Hasher for the cache key — O(n) like NSString hash but
        // avoids the NSString copy overhead for long messages (10K+ chars).
        var hasher = Hasher()
        hasher.combine(text)
        let key = NSNumber(value: hasher.finalize())

        if let cached = Self.blockCache.object(forKey: key) {
            self.cachedBlocks = cached.blocks
        } else {
            let parsed = Self.parseBlocks(from: text)
            Self.blockCache.setObject(BlocksBox(parsed), forKey: key)
            self.cachedBlocks = parsed
        }
    }

    /// Whether the content exceeds the initial block limit.
    private var needsTruncation: Bool {
        cachedBlocks.count > Self.initialBlockLimit
    }

    /// Blocks currently shown (respects the visible limit).
    private var displayedBlocks: [Block] {
        if let limit = visibleBlockCount {
            return Array(cachedBlocks.prefix(limit))
        }
        // No explicit limit set yet — use initial limit if content is long
        if needsTruncation {
            return Array(cachedBlocks.prefix(Self.initialBlockLimit))
        }
        return cachedBlocks
    }

    /// True when not all blocks are shown.
    private var isTruncated: Bool {
        let shown = visibleBlockCount ?? (needsTruncation ? Self.initialBlockLimit : cachedBlocks.count)
        return shown < cachedBlocks.count
    }

    /// Number of blocks still hidden.
    private var remainingCount: Int {
        let shown = visibleBlockCount ?? (needsTruncation ? Self.initialBlockLimit : cachedBlocks.count)
        return max(0, cachedBlocks.count - shown)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(displayedBlocks) { block in
                renderBlock(block)
            }

            if isTruncated {
                Button {
                    let current = visibleBlockCount ?? Self.initialBlockLimit
                    let next = current + Self.expandStep
                    if next >= cachedBlocks.count {
                        visibleBlockCount = cachedBlocks.count
                    } else {
                        visibleBlockCount = next
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .medium))
                        Text(AppText.markdownShowMore(remainingCount))
                            .font(.system(size: 14, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
                }
            }
        }
    }

    // MARK: - Block Types

    // AttributedString is computed once at parse time and stored in the block,
    // so renderBlock / body never calls AttributedString(markdown:) during rendering.
    fileprivate struct Block: Identifiable {
        /// Stable identity: sequential index assigned at parse time.
        let id: Int
        let kind: BlockKind
    }

    fileprivate enum BlockKind {
        case paragraph(AttributedString?, String)
        case codeBlock(language: String?, code: String)
        case heading(level: Int, text: String)
        case unorderedList([(AttributedString?, String)])
        case orderedList([(AttributedString?, String)])
        case blockquote(AttributedString?, String)
    }

    // MARK: - Inline AttributedString helper (called once at parse time only)

    private static func makeAttributed(_ text: String) -> AttributedString? {
        // Fast path: most assistant text is plain prose with no markdown markers.
        // Skipping the markdown parser here removes a significant CPU spike for
        // long messages while preserving markdown rendering when syntax is present.
        guard needsInlineMarkdownParsing(text) else {
            return nil
        }

        return try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )
    }

    private static func needsInlineMarkdownParsing(_ text: String) -> Bool {
        if text.isEmpty { return false }

        // Common inline markdown patterns.
        if text.contains("**") || text.contains("__") || text.contains("~~") {
            return true
        }
        if text.contains("`") || text.contains("[") || text.contains("](") {
            return true
        }

        // Single-marker emphasis can still be valid markdown.
        if text.contains("*") || text.contains("_") {
            return true
        }

        return false
    }

    // MARK: - Parser

    private static func parseBlocks(from text: String) -> [Block] {
        var blocks: [Block] = []
        var nextID = 0
        let lines = text.components(separatedBy: "\n")
        var i = 0

        while i < lines.count {
            let line = lines[i]

            if line.hasPrefix("```") {
                let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                i += 1
                while i < lines.count && !lines[i].hasPrefix("```") {
                    codeLines.append(lines[i])
                    i += 1
                }
                blocks.append(Block(id: nextID, kind: .codeBlock(
                    language: lang.isEmpty ? nil : lang,
                    code: codeLines.joined(separator: "\n")
                )))
                nextID += 1
                i += 1
                continue
            }

            if line.hasPrefix("#") {
                let level = line.prefix(while: { $0 == "#" }).count
                let headingText = String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                if !headingText.isEmpty && level <= 6 {
                    blocks.append(Block(id: nextID, kind: .heading(level: level, text: headingText)))
                    nextID += 1
                    i += 1
                    continue
                }
            }

            if line.hasPrefix("> ") {
                var quoteLines: [String] = []
                while i < lines.count && lines[i].hasPrefix("> ") {
                    quoteLines.append(String(lines[i].dropFirst(2)))
                    i += 1
                }
                let raw = quoteLines.joined(separator: "\n")
                blocks.append(Block(id: nextID, kind: .blockquote(makeAttributed(raw), raw)))
                nextID += 1
                continue
            }

            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                var items: [(AttributedString?, String)] = []
                while i < lines.count && (lines[i].hasPrefix("- ") || lines[i].hasPrefix("* ")) {
                    let raw = String(lines[i].dropFirst(2))
                    items.append((makeAttributed(raw), raw))
                    i += 1
                }
                blocks.append(Block(id: nextID, kind: .unorderedList(items)))
                nextID += 1
                continue
            }

            if let firstDot = line.firstIndex(of: "."),
               line.distance(from: line.startIndex, to: firstDot) <= 3,
               let _ = Int(line[line.startIndex..<firstDot]) {
                var items: [(AttributedString?, String)] = []
                while i < lines.count {
                    let currentLine = lines[i]
                    if let dot = currentLine.firstIndex(of: "."),
                       currentLine.distance(from: currentLine.startIndex, to: dot) <= 3,
                       let _ = Int(currentLine[currentLine.startIndex..<dot]) {
                        let afterDot = currentLine[currentLine.index(after: dot)...]
                        let raw = afterDot.trimmingCharacters(in: .whitespaces)
                        items.append((makeAttributed(raw), raw))
                        i += 1
                    } else {
                        break
                    }
                }
                blocks.append(Block(id: nextID, kind: .orderedList(items)))
                nextID += 1
                continue
            }

            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                i += 1
                continue
            }

            // Paragraph: collect consecutive non-special lines
            var paraLines: [String] = []
            while i < lines.count {
                let current = lines[i]
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || current.hasPrefix("```") || current.hasPrefix("#") ||
                   current.hasPrefix("> ") || current.hasPrefix("- ") || current.hasPrefix("* ") {
                    break
                }
                paraLines.append(current)
                i += 1
            }
            if !paraLines.isEmpty {
                let raw = paraLines.joined(separator: "\n")
                let chunks = splitLongParagraph(raw, maxLength: Self.paragraphChunkSize)
                for chunk in chunks {
                    blocks.append(Block(id: nextID, kind: .paragraph(makeAttributed(chunk), chunk)))
                    nextID += 1
                }
            }
        }

        return blocks
    }

    /// Splits a long paragraph into smaller chunks on whitespace boundaries
    /// to reduce per-view text layout cost for extremely long responses.
    private static func splitLongParagraph(_ text: String, maxLength: Int) -> [String] {
        guard text.count > maxLength, maxLength > 0 else { return [text] }

        var chunks: [String] = []
        var currentStart = text.startIndex

        while currentStart < text.endIndex {
            let hardEnd = text.index(currentStart, offsetBy: maxLength, limitedBy: text.endIndex) ?? text.endIndex
            if hardEnd == text.endIndex {
                chunks.append(String(text[currentStart..<text.endIndex]))
                break
            }

            let segment = text[currentStart..<hardEnd]
            if let breakPoint = segment.lastIndex(where: { $0.isWhitespace }) {
                let chunk = String(text[currentStart..<breakPoint])
                if !chunk.isEmpty { chunks.append(chunk) }
                currentStart = text.index(after: breakPoint)
            } else {
                chunks.append(String(segment))
                currentStart = hardEnd
            }
        }

        return chunks.isEmpty ? [text] : chunks
    }

    // MARK: - Render

    @ViewBuilder
    private func renderBlock(_ block: Block) -> some View {
        switch block.kind {
        case .paragraph(let attributed, let raw):
            inlineText(attributed, fallback: raw)

        case .codeBlock(let language, let code):
            VStack(alignment: .leading, spacing: 4) {
                if let language {
                    Text(language)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(code)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(foregroundColor)
                        .padding(12)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contextMenu {
                Button(AppText.copyCode) {
                    UIPasteboard.general.string = code
                }
            }

        case .heading(let level, let text):
            Text(text)
                .font(.system(size: headingSize(level), weight: .bold))
                .foregroundStyle(foregroundColor)

        case .unorderedList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 6) {
                        Text("\u{2022}")
                            .foregroundStyle(.secondary)
                        inlineText(item.0, fallback: item.1)
                    }
                }
            }

        case .orderedList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top, spacing: 6) {
                        Text("\(index + 1).")
                            .foregroundStyle(.secondary)
                            .frame(width: 20, alignment: .trailing)
                        inlineText(item.0, fallback: item.1)
                    }
                }
            }

        case .blockquote(let attributed, let raw):
            HStack(spacing: 0) {
                Rectangle()
                    .fill(Color(.systemGray3))
                    .frame(width: 3)
                inlineText(attributed, fallback: raw)
                    .padding(.leading, 10)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Renders a pre-computed AttributedString or falls back to plain Text.
    /// No markdown parsing happens here — everything was computed in parseBlocks.
    private func inlineText(_ attributed: AttributedString?, fallback: String) -> some View {
        Group {
            if let attributed {
                Text(attributed)
                    .font(.system(size: 17))
                    .foregroundStyle(foregroundColor)
            } else {
                Text(fallback)
                    .font(.system(size: 17))
                    .foregroundStyle(foregroundColor)
            }
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 24
        case 2: return 20
        case 3: return 18
        default: return 16
        }
    }
}
