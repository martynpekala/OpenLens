import Foundation
import Testing
@testable import OpenLens

struct MarkdownContentViewTests {

    @MainActor
    @Test func longBlockquoteIsPreparedAsBoundedFragments() async {
        let quotedText = String(repeating: "quoted response fragment ", count: 500)
        let prepared = await prepareMarkdown("> \(quotedText)")

        guard case let .blockquote(fragments) = prepared.blocks.first?.kind else {
            Issue.record("Expected a blockquote")
            return
        }

        #expect(fragments.count > 1)
        #expect(fragments.allSatisfy { $0.raw.count <= 1_600 })
    }

    @MainActor
    @Test func longListItemUsesBoundedContinuationFragments() async {
        let longItem = String(repeating: "long list item fragment ", count: 500)
        let prepared = await prepareMarkdown("- \(longItem)\n- final item")

        guard case let .unorderedList(fragments) = prepared.blocks.first?.kind else {
            Issue.record("Expected an unordered list")
            return
        }

        #expect(fragments.count > 2)
        #expect(fragments.allSatisfy { $0.raw.count <= 1_600 })
        #expect(fragments.first?.marker == "•")
        #expect(fragments.dropFirst().contains { $0.marker == nil })
        #expect(fragments.last?.marker == "•")
    }

    @MainActor
    @Test func longHeadingIsPreparedAsBoundedBlocks() async {
        let heading = "# " + String(repeating: "heading fragment ", count: 500)
        let prepared = await prepareMarkdown(heading)
        let headingTexts = prepared.blocks.compactMap { block -> String? in
            guard case let .heading(_, text) = block.kind else { return nil }
            return text
        }

        #expect(headingTexts.count > 1)
        #expect(headingTexts.allSatisfy { $0.count <= 1_600 })
    }

    @MainActor
    @Test func fencedCodeLanguageLabelIsBounded() async {
        let language = String(repeating: "swift", count: 100)
        let prepared = await prepareMarkdown("```\(language)\nlet answer = 42\n```")

        guard case let .codeBlock(label, _) = prepared.blocks.first?.kind else {
            Issue.record("Expected a code block")
            return
        }

        #expect(label?.count == 83)
        #expect(label?.hasSuffix("...") == true)
    }

    @MainActor
    @Test func preparedDocumentIsAvailableSynchronouslyFromTheCache() async {
        let text = "Cached reply \(UUID().uuidString) with **bold** text"
        #expect(MarkdownContentView.cachedPrepared(for: text) == nil)

        let prepared = await prepareMarkdown(text)
        let cached = MarkdownContentView.cachedPrepared(for: text)

        #expect(cached?.blocks.count == prepared.blocks.count)
    }

    // MARK: - Tables

    @MainActor
    @Test func tableParsesHeaderDelimiterAndRows() async {
        let prepared = await prepareMarkdown(
            """
            ## Updated app-codebase report (non-e2e)

            Two app changes plus the prod grants:

            | what | where | commit |
            |---|---|---|
            | `preselections_controller.php` `index()` | **pollini** | `c4722ce41` |
            | `exam_report.php` fallback | **sipao** | `848d60d2d` |
            """
        )

        #expect(prepared.blocks.count == 3)

        guard case let .table(table) = prepared.blocks[2].kind else {
            Issue.record("Expected a table block after the heading and paragraph")
            return
        }

        #expect(table.header.cells.map(\.raw) == ["what", "where", "commit"])
        #expect(table.rows.count == 2)
        #expect(table.rows.first?.cells.map(\.raw) == [
            "`preselections_controller.php` `index()`",
            "**pollini**",
            "`c4722ce41`",
        ])
        #expect(table.alignments == [.leading, .leading, .leading])
        #expect(table.columnWidths.count == 3)
    }

    @MainActor
    @Test func tableWithoutOuterPipesParses() async {
        let prepared = await prepareMarkdown("a | b\n--- | ---\n1 | 2")

        guard case let .table(table) = prepared.blocks.first?.kind else {
            Issue.record("Expected a table without optional outer pipes")
            return
        }

        #expect(table.header.cells.map(\.raw) == ["a", "b"])
        #expect(table.rows.first?.cells.map(\.raw) == ["1", "2"])
    }

    @MainActor
    @Test func tableDelimiterColonsSelectAlignment() async {
        let prepared = await prepareMarkdown("| a | b | c |\n|:--|:-:|--:|\n| 1 | 2 | 3 |")

        guard case let .table(table) = prepared.blocks.first?.kind else {
            Issue.record("Expected a table")
            return
        }

        #expect(table.alignments == [.leading, .center, .trailing])
    }

    @MainActor
    @Test func tableInterruptsParagraphAndEndsAtNonRowLine() async {
        let prepared = await prepareMarkdown(
            "intro\n| a | b |\n|---|---|\n| 1 | 2 |\nafter"
        )

        #expect(prepared.blocks.count == 3)
        guard case .paragraph = prepared.blocks[0].kind else {
            Issue.record("Expected the intro paragraph before the table")
            return
        }
        guard case .table = prepared.blocks[1].kind else {
            Issue.record("Expected the table to interrupt the paragraph")
            return
        }
        guard case .paragraph = prepared.blocks[2].kind else {
            Issue.record("Expected the trailing line to stay a paragraph")
            return
        }
    }

    @MainActor
    @Test func tableRowsPadMissingCellsAndDropExtras() async {
        let prepared = await prepareMarkdown("| a | b |\n|---|---|\n| 1 |\n| 1 | 2 | 3 |")

        guard case let .table(table) = prepared.blocks.first?.kind else {
            Issue.record("Expected a table")
            return
        }

        #expect(table.rows.count == 2)
        #expect(table.rows[0].cells.map(\.raw) == ["1", ""])
        #expect(table.rows[1].cells.map(\.raw) == ["1", "2"])
    }

    @MainActor
    @Test func escapedPipeStaysInsideItsCell() async {
        let prepared = await prepareMarkdown("| a \\| b | c |\n|---|---|\n| 1 | 2 |")

        guard case let .table(table) = prepared.blocks.first?.kind else {
            Issue.record("Expected a table")
            return
        }

        #expect(table.header.cells.map(\.raw) == ["a | b", "c"])
    }

    @MainActor
    @Test func pipeLinesWithoutDelimiterRowStayParagraphs() async {
        let prepared = await prepareMarkdown("just some | pipes\nsecond line")

        guard case .paragraph = prepared.blocks.first?.kind else {
            Issue.record("Expected pipes without a delimiter row to stay a paragraph")
            return
        }
    }

    @MainActor
    @Test func mismatchedDelimiterCellCountIsNotATable() async {
        let prepared = await prepareMarkdown("| a | b |\n|---|\n| 1 | 2 |")

        guard case .paragraph = prepared.blocks.first?.kind else {
            Issue.record("Expected a mismatched delimiter row to stay a paragraph")
            return
        }
    }

    @MainActor
    @Test func longTableParsesEveryRow() async {
        var text = "| a | b |\n|---|---|\n"
        for index in 0..<30 {
            text += "| \(index) | row |\n"
        }

        let prepared = await prepareMarkdown(text)

        guard case let .table(table) = prepared.blocks.first?.kind else {
            Issue.record("Expected a table")
            return
        }

        #expect(table.rows.count == 30)
        #expect(table.rows.last?.cells.map(\.raw) == ["29", "row"])
    }

    @MainActor
    private func prepareMarkdown(_ text: String) async -> MarkdownContentView.Prepared {
        await withCheckedContinuation { continuation in
            MarkdownContentView.prepare(text) { prepared in
                continuation.resume(returning: prepared)
            }
        }
    }
}
