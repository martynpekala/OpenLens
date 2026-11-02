import SwiftUI
import Testing
@testable import OpenLens

struct DetectedLinksTests {

    @MainActor
    @Test func plainProseLinkBecomesTappable() async {
        let prepared = await prepareMarkdown("Docs are at https://opencode.ai/docs for details.")

        guard case let .paragraph(attributed?, _) = prepared.blocks.first?.kind else {
            Issue.record("Expected an attributed paragraph")
            return
        }

        #expect(links(in: attributed) == [URL(string: "https://opencode.ai/docs")!])
        #expect(attributed.runs.filter { $0.link != nil }.allSatisfy { $0.underlineStyle == .single })
    }

    @MainActor
    @Test func listAndBlockquoteLinksBecomeTappable() async {
        let prepared = await prepareMarkdown("- see www.example.com\n\n> from http://example.org/a")

        guard case let .unorderedList(items) = prepared.blocks.first?.kind,
              case let .blockquote(quote) = prepared.blocks.last?.kind else {
            Issue.record("Expected a list and a blockquote")
            return
        }

        #expect(items.first?.attributed.map(links(in:)) == [URL(string: "https://www.example.com")!])
        #expect(quote.first?.attributed.map(links(in:)) == [URL(string: "http://example.org/a")!])
    }

    @MainActor
    @Test func markdownLinksAndInlineCodeAreLeftAlone() async {
        let prepared = await prepareMarkdown("[OpenCode](https://opencode.ai) and `https://localhost:3000`")

        guard case let .paragraph(attributed?, _) = prepared.blocks.first?.kind else {
            Issue.record("Expected an attributed paragraph")
            return
        }

        #expect(links(in: attributed) == [URL(string: "https://opencode.ai")!])
    }

    @MainActor
    @Test func codeBlocksAreNotLinked() async {
        let prepared = await prepareMarkdown("```\ncurl https://example.com\n```")

        guard case .codeBlock = prepared.blocks.first?.kind else {
            Issue.record("Expected a code block")
            return
        }
        #expect(prepared.blocks.count == 1)
    }

    @Test func bareDomainsAndEmailsAreNotDetected() {
        #expect(DetectedLinks.urls(in: "Email me@example.com or visit example.com").isEmpty)
    }

    @Test func menuLinksSkipCodeFencesAndDuplicates() {
        let text = """
        Open https://a.com/one and https://a.com/one again.
        ```
        https://inside.com/code
        ```
        Then www.b.com.
        """

        #expect(DetectedLinks.urls(in: text) == [
            URL(string: "https://a.com/one")!,
            URL(string: "https://www.b.com")!,
        ])
    }

    @Test func displayStringDropsSchemeAndTruncates() {
        #expect(DetectedLinks.displayString(for: URL(string: "https://example.com/")!) == "example.com")

        let long = URL(string: "https://example.com/" + String(repeating: "a", count: 60))!
        let display = DetectedLinks.displayString(for: long)
        #expect(display.count == 40)
        #expect(display.hasSuffix("…"))
    }

    private func links(in attributed: AttributedString) -> [URL] {
        attributed.runs.compactMap(\.link)
    }

    private func prepareMarkdown(_ text: String) async -> MarkdownContentView.Prepared {
        await withCheckedContinuation { continuation in
            MarkdownContentView.prepare(text) { prepared in
                continuation.resume(returning: prepared)
            }
        }
    }
}
