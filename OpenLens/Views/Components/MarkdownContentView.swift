import SwiftUI

/// Renders markdown text as native SwiftUI views.
/// Supports: code blocks, headings, lists, and inline formatting via AttributedString.
///
/// Long messages are automatically truncated to `initialBlockLimit` blocks.
/// The user can tap "Show more" to reveal additional content incrementally.
struct MarkdownContentView: View {
    /// A parsed, immutable markdown document. It can only be made through
    /// `prepare`, which runs cache lookup and parsing on `parserQueue`.
    struct Prepared {
        fileprivate let cacheKey: Int
        let blocks: [Block]
    }

    let prepared: Prepared
    let foregroundColor: Color
    let usesRetroTypography: Bool

    /// Maximum blocks shown before truncation. Roughly 8-12 paragraphs worth.
    private static let initialBlockLimit = 12
    /// How many additional blocks to reveal per tap.
    private static let expandStep = 20
    /// Split very long plain paragraphs into smaller chunks to avoid expensive
    /// single Text layout passes when huge content is visible.
    private static let paragraphChunkSize = 1_600
    /// Code blocks need the same protection as prose: a single fenced block can
    /// otherwise contain an entire generated file or log transcript.
    private static let codeChunkSize = 1_600
    private static let codeLanguageLabelLimit = 80
    private static let parserQueue = DispatchQueue(
        label: "com.openlens.MarkdownContentView.parser",
        qos: .utility
    )

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

    init(
        prepared: Prepared,
        foregroundColor: Color = Color(.label),
        usesRetroTypography: Bool = false
    ) {
        self.prepared = prepared
        self.foregroundColor = foregroundColor
        self.usesRetroTypography = usesRetroTypography
    }

    /// The completion runs on the main queue, but all O(n) work (hashing,
    /// cache lookup and markdown parsing) has completed before that hop.
    static func prepare(_ text: String, completion: @escaping (Prepared) -> Void) {
        parserQueue.async {
            let key = cacheKey(for: text)
            let prepared: Prepared

            if let cached = blockCache.object(forKey: key) {
                prepared = Prepared(cacheKey: key.intValue, blocks: cached.blocks)
            } else {
                let signpostID = ChatStreamInstrumentation.beginMarkdownPrewarm(characterCount: text.count)
                let parsed = parseBlocks(from: text)
                blockCache.setObject(BlocksBox(parsed), forKey: key)
                ChatStreamInstrumentation.endMarkdownPrewarm(signpostID)
                prepared = Prepared(cacheKey: key.intValue, blocks: parsed)
            }

            DispatchQueue.main.async {
                completion(prepared)
            }
        }
    }

    private static func cacheKey(for text: String) -> NSNumber {
        // Use Swift Hasher for the cache key — O(n) like NSString hash but
        // avoids the NSString copy overhead for long messages (10K+ chars).
        var hasher = Hasher()
        hasher.combine(text)
        return NSNumber(value: hasher.finalize())
    }

    /// Whether the content exceeds the initial block limit.
    private var needsTruncation: Bool {
        prepared.blocks.count > Self.initialBlockLimit
    }

    /// Blocks currently shown (respects the visible limit).
    private var displayedBlocks: [Block] {
        if let limit = visibleBlockCount {
            return Array(prepared.blocks.prefix(limit))
        }
        // No explicit limit set yet — use initial limit if content is long
        if needsTruncation {
            return Array(prepared.blocks.prefix(Self.initialBlockLimit))
        }
        return prepared.blocks
    }

    /// True when not all blocks are shown.
    private var isTruncated: Bool {
        let shown = visibleBlockCount ?? (needsTruncation ? Self.initialBlockLimit : prepared.blocks.count)
        return shown < prepared.blocks.count
    }

    /// Number of blocks still hidden.
    private var remainingCount: Int {
        let shown = visibleBlockCount ?? (needsTruncation ? Self.initialBlockLimit : prepared.blocks.count)
        return max(0, prepared.blocks.count - shown)
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
                    if next >= prepared.blocks.count {
                        visibleBlockCount = prepared.blocks.count
                    } else {
                        visibleBlockCount = next
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .medium))
                        Text(AppText.markdownShowMore(remainingCount))
                            .font(usesRetroTypography ? RetroChatStyle.smallFont : .system(size: 14, weight: .medium))
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
    struct Block: Identifiable {
        /// Stable identity: sequential index assigned at parse time.
        let id: Int
        let kind: BlockKind
    }

    enum BlockKind {
        case paragraph(AttributedString?, String)
        case codeBlock(language: String?, chunks: [String])
        case heading(level: Int, text: String)
        case unorderedList([ListFragment])
        case orderedList([ListFragment])
        case blockquote([TextFragment])
    }

    /// A bounded piece of prose that can be laid out independently. Quotes use
    /// these instead of one unbounded `Text` for their entire source block.
    struct TextFragment: Identifiable {
        let id: Int
        let attributed: AttributedString?
        let raw: String
    }

    /// A bounded visual row in a Markdown list. Continuations intentionally
    /// omit the marker so one very long list item retains a single bullet or
    /// ordinal while still avoiding an unbounded text layout pass.
    struct ListFragment: Identifiable {
        let id: Int
        let marker: String?
        let attributed: AttributedString?
        let raw: String
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
                    language: lang.isEmpty ? nil : boundedLanguageLabel(lang),
                    chunks: splitCodeBlock(codeLines.joined(separator: "\n"))
                )))
                nextID += 1
                i += 1
                continue
            }

            if line.hasPrefix("#") {
                let level = line.prefix(while: { $0 == "#" }).count
                let headingText = String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                if !headingText.isEmpty && level <= 6 {
                    // A generated heading can be arbitrarily large. Turn it
                    // into ordinary bounded blocks while parsing off-main, so
                    // the first render never asks one Text view to lay out a
                    // 100 KB line.
                    for chunk in splitLongParagraph(headingText, maxLength: Self.paragraphChunkSize) {
                        blocks.append(Block(id: nextID, kind: .heading(level: level, text: chunk)))
                        nextID += 1
                    }
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
                let fragments = textFragments(from: raw)
                blocks.append(Block(id: nextID, kind: .blockquote(fragments)))
                nextID += 1
                continue
            }

            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                var fragments: [ListFragment] = []
                while i < lines.count && (lines[i].hasPrefix("- ") || lines[i].hasPrefix("* ")) {
                    let raw = String(lines[i].dropFirst(2))
                    appendListFragments(raw: raw, marker: "•", to: &fragments)
                    i += 1
                }
                blocks.append(Block(id: nextID, kind: .unorderedList(fragments)))
                nextID += 1
                continue
            }

            if let firstDot = line.firstIndex(of: "."),
               line.distance(from: line.startIndex, to: firstDot) <= 3,
               let _ = Int(line[line.startIndex..<firstDot]) {
                var fragments: [ListFragment] = []
                while i < lines.count {
                    let currentLine = lines[i]
                    if let dot = currentLine.firstIndex(of: "."),
                       currentLine.distance(from: currentLine.startIndex, to: dot) <= 3,
                       let ordinal = Int(currentLine[currentLine.startIndex..<dot]) {
                        let afterDot = currentLine[currentLine.index(after: dot)...]
                        let raw = afterDot.trimmingCharacters(in: .whitespaces)
                        appendListFragments(raw: raw, marker: "\(ordinal).", to: &fragments)
                        i += 1
                    } else {
                        break
                    }
                }
                blocks.append(Block(id: nextID, kind: .orderedList(fragments)))
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

    private static func textFragments(from text: String) -> [TextFragment] {
        splitLongParagraph(text, maxLength: Self.paragraphChunkSize)
            .enumerated()
            .map { offset, chunk in
                TextFragment(
                    id: offset,
                    attributed: makeAttributed(chunk),
                    raw: chunk
                )
            }
    }

    private static func appendListFragments(
        raw: String,
        marker: String,
        to fragments: inout [ListFragment]
    ) {
        for (offset, chunk) in splitLongParagraph(raw, maxLength: Self.paragraphChunkSize).enumerated() {
            fragments.append(
                ListFragment(
                    id: fragments.count,
                    marker: offset == 0 ? marker : nil,
                    attributed: makeAttributed(chunk),
                    raw: chunk
                )
            )
        }
    }

    private static func boundedLanguageLabel(_ language: String) -> String {
        guard language.count > Self.codeLanguageLabelLimit else { return language }
        let end = language.index(language.startIndex, offsetBy: Self.codeLanguageLabelLimit)
        return String(language[..<end]) + "..."
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

    /// Splits source while preserving every character (including newline
    /// boundaries), so Copy can reconstruct the original code on demand.
    private static func splitCodeBlock(_ code: String) -> [String] {
        guard code.count > Self.codeChunkSize else { return [code] }

        var chunks: [String] = []
        var start = code.startIndex

        while start < code.endIndex {
            let hardEnd = code.index(
                start,
                offsetBy: Self.codeChunkSize,
                limitedBy: code.endIndex
            ) ?? code.endIndex
            if hardEnd == code.endIndex {
                chunks.append(String(code[start..<code.endIndex]))
                break
            }

            let segment = code[start..<hardEnd]
            let end = segment.lastIndex(of: "\n")
                .map { code.index(after: $0) }
                ?? hardEnd
            chunks.append(String(code[start..<end]))
            start = end
        }

        return chunks.isEmpty ? [code] : chunks
    }

    // MARK: - Render

    @ViewBuilder
    private func renderBlock(_ block: Block) -> some View {
        switch block.kind {
        case .paragraph(let attributed, let raw):
            MarkdownInlineText(
                attributed: attributed,
                fallback: raw,
                foregroundColor: foregroundColor,
                usesRetroTypography: usesRetroTypography
            )

        case .codeBlock(let language, let chunks):
            MarkdownCodeBlockView(
                language: language,
                chunks: chunks,
                foregroundColor: foregroundColor,
                usesRetroTypography: usesRetroTypography
            )

        case .heading(let level, let text):
            Text(text)
                .font(usesRetroTypography ? RetroChatStyle.headerFont : .system(size: headingSize(level), weight: .bold))
                .foregroundStyle(foregroundColor)

        case .unorderedList(let fragments),
             .orderedList(let fragments):
            MarkdownListBlockView(
                fragments: fragments,
                foregroundColor: foregroundColor,
                usesRetroTypography: usesRetroTypography
            )

        case .blockquote(let fragments):
            MarkdownBlockquoteView(
                fragments: fragments,
                usesRetroTypography: usesRetroTypography
            )
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

/// Renders an already-prepared inline Markdown fragment. Parsing remains on
/// `MarkdownContentView.parserQueue`; this view only selects the prepared text.
private struct MarkdownInlineText: View {
    let attributed: AttributedString?
    let fallback: String
    let foregroundColor: Color
    let usesRetroTypography: Bool

    var body: some View {
        Group {
            if let attributed {
                Text(attributed)
            } else {
                Text(fallback)
            }
        }
        .font(usesRetroTypography ? RetroChatStyle.bodyFont : .system(size: 17))
        .foregroundStyle(foregroundColor)
    }
}

/// A list can contain thousands of short rows or one enormous row. Render only
/// a bounded prefix, and add fragments with stable identities when the person
/// explicitly asks to see more.
private struct MarkdownListBlockView: View {
    private static let initialFragmentLimit = 12
    private static let expandStep = 20

    let fragments: [MarkdownContentView.ListFragment]
    let foregroundColor: Color
    let usesRetroTypography: Bool

    @State private var visibleFragmentCount: Int?

    private var shownFragmentCount: Int {
        min(visibleFragmentCount ?? Self.initialFragmentLimit, fragments.count)
    }

    private var isTruncated: Bool {
        shownFragmentCount < fragments.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(fragments.prefix(shownFragmentCount)) { fragment in
                HStack(alignment: .top, spacing: 6) {
                    Text(fragment.marker ?? "")
                        .font(usesRetroTypography ? RetroChatStyle.bodyFont : .system(size: 17))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, alignment: .trailing)

                    MarkdownInlineText(
                        attributed: fragment.attributed,
                        fallback: fragment.raw,
                        foregroundColor: foregroundColor,
                        usesRetroTypography: usesRetroTypography
                    )
                }
            }

            if isTruncated {
                Button {
                    visibleFragmentCount = min(
                        shownFragmentCount + Self.expandStep,
                        fragments.count
                    )
                } label: {
                    Text(AppText.markdownShowMore(fragments.count - shownFragmentCount))
                        .font(usesRetroTypography ? RetroChatStyle.smallFont : .system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 26)
                .padding(.top, 4)
            }
        }
    }
}

/// Quotes are divided before rendering so a quoted log or transcript cannot
/// turn into one giant text layout on the main executor.
private struct MarkdownBlockquoteView: View {
    private static let initialFragmentLimit = 8
    private static let expandStep = 12

    let fragments: [MarkdownContentView.TextFragment]
    let usesRetroTypography: Bool

    @State private var visibleFragmentCount: Int?

    private var shownFragmentCount: Int {
        min(visibleFragmentCount ?? Self.initialFragmentLimit, fragments.count)
    }

    private var isTruncated: Bool {
        shownFragmentCount < fragments.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 0) {
                Rectangle()
                    .fill(Color(.systemGray3))
                    .frame(width: 3)

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(fragments.prefix(shownFragmentCount)) { fragment in
                        MarkdownInlineText(
                            attributed: fragment.attributed,
                            fallback: fragment.raw,
                            foregroundColor: .secondary,
                            usesRetroTypography: usesRetroTypography
                        )
                    }
                }
                .padding(.leading, 10)
            }

            if isTruncated {
                Button {
                    visibleFragmentCount = min(
                        shownFragmentCount + Self.expandStep,
                        fragments.count
                    )
                } label: {
                    Text(AppText.markdownShowMore(fragments.count - shownFragmentCount))
                        .font(usesRetroTypography ? RetroChatStyle.smallFont : .system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 13)
            }
        }
    }
}

/// Keeps a single giant fenced block from forcing one unbounded `Text` layout.
/// It reveals the code in stable, newline-preserving chunks and only joins them
/// if the person explicitly chooses Copy Code.
private struct MarkdownCodeBlockView: View {
    private static let initialChunkLimit = 8
    private static let expandStep = 12

    let language: String?
    let chunks: [String]
    let foregroundColor: Color
    let usesRetroTypography: Bool

    @State private var visibleChunkCount: Int?

    private var shownChunkCount: Int {
        min(visibleChunkCount ?? Self.initialChunkLimit, chunks.count)
    }

    private var isTruncated: Bool {
        shownChunkCount < chunks.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let language {
                Text(language)
                    .font(usesRetroTypography ? RetroChatStyle.smallFont : .system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(chunks.prefix(shownChunkCount).enumerated()), id: \.offset) { _, chunk in
                        Text(chunk)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(foregroundColor)
                            .fixedSize(horizontal: true, vertical: true)
                    }
                }
                .padding(12)
            }

            if isTruncated {
                Button {
                    visibleChunkCount = min(
                        shownChunkCount + Self.expandStep,
                        chunks.count
                    )
                } label: {
                    Text(AppText.markdownShowMore(chunks.count - shownChunkCount))
                        .font(usesRetroTypography ? RetroChatStyle.smallFont : .system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contextMenu {
            Button(AppText.copyCode) {
                UIPasteboard.general.string = chunks.joined()
            }
        }
    }
}

/// Keeps final assistant text responsive while its Markdown representation is
/// prepared off the main thread. The plain `Text` fallback remains visible until
/// a fully parsed immutable document is available.
struct DeferredMarkdownTextView: View {
    private static let fallbackPreviewLimit = 800

    let text: String
    let foregroundColor: Color
    let usesRetroTypography: Bool
    private let fallbackPreview: String
    private let fallbackIsTruncated: Bool

    @State private var prepared: MarkdownContentView.Prepared?
    @State private var requestID = UUID()

    init(text: String, foregroundColor: Color, usesRetroTypography: Bool) {
        self.text = text
        self.foregroundColor = foregroundColor
        self.usesRetroTypography = usesRetroTypography

        let end = text.index(
            text.startIndex,
            offsetBy: Self.fallbackPreviewLimit,
            limitedBy: text.endIndex
        ) ?? text.endIndex
        self.fallbackPreview = String(text[..<end])
        self.fallbackIsTruncated = end != text.endIndex
    }

    var body: some View {
        Group {
            if let prepared {
                MarkdownContentView(
                    prepared: prepared,
                    foregroundColor: foregroundColor,
                    usesRetroTypography: usesRetroTypography
                )
                .id(prepared.cacheKey)
            } else {
                plainText
            }
        }
        .onAppear {
            requestPreparation(for: text)
        }
        .onChange(of: text) { _, newText in
            requestPreparation(for: newText)
        }
    }

    private var plainText: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(fallbackPreview)
                .font(usesRetroTypography ? RetroChatStyle.bodyFont : .system(size: 16))
                .foregroundStyle(foregroundColor)

            if fallbackIsTruncated {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Preparing full response")
            }
        }
    }

    private func requestPreparation(for text: String) {
        let nextRequestID = UUID()
        requestID = nextRequestID
        prepared = nil

        MarkdownContentView.prepare(text) { candidate in
            guard requestID == nextRequestID else { return }
            prepared = candidate
        }
    }
}
