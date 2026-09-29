import Testing
@testable import OpenLens

struct UnifiedDiffBuilderTests {

    private let originalLines = (0..<2000).map { "line \($0)" }

    private func file(
        before: [String]? = nil,
        after: [String]? = nil,
        patchHunks: [ReviewFilePatchHunk] = []
    ) -> ReviewFileChange {
        ReviewFileChange(
            path: "Sources/App.swift",
            status: "M",
            additions: 0,
            deletions: 0,
            beforeText: before?.joined(separator: "\n"),
            afterText: after?.joined(separator: "\n"),
            patchHunks: patchHunks
        )
    }

    private func shape(of hunk: UnifiedDiffHunk) -> String {
        hunk.lines.map(\.prefix).joined()
    }

    @Test func rendersOnlyChangedLinesWithContext() {
        var edited = originalLines
        edited[1000] = "CHANGED"

        let hunks = UnifiedDiffBuilder.makeHunks(file: file(before: originalLines, after: edited))

        #expect(hunks.count == 1)
        #expect(shape(of: hunks[0]) == "   -+   ")
        #expect(hunks[0].lines.first?.oldLineNumber == 998)
        #expect(hunks[0].lines.first?.newLineNumber == 998)
    }

    @Test func splitsDistantChangesIntoSeparateHunks() {
        var edited = originalLines
        edited[100] = "A"
        edited[1500] = "B"

        let hunks = UnifiedDiffBuilder.makeHunks(file: file(before: originalLines, after: edited))

        #expect(hunks.count == 2)
        #expect(Set(hunks.map(\.id)).count == 2)
    }

    @Test func mergesChangesCloserThanTwiceTheContext() {
        var edited = originalLines
        edited[100] = "A"
        edited[106] = "B"

        let hunks = UnifiedDiffBuilder.makeHunks(file: file(before: originalLines, after: edited))

        #expect(hunks.count == 1)
    }

    @Test func unchangedFileProducesNoHunks() {
        let hunks = UnifiedDiffBuilder.makeHunks(file: file(before: originalLines, after: originalLines))

        #expect(hunks.isEmpty)
    }

    @Test func addedAndDeletedFilesShowEveryLineAsChanged() {
        let added = UnifiedDiffBuilder.makeHunks(file: file(after: ["a", "b", "c"]))
        let deleted = UnifiedDiffBuilder.makeHunks(file: file(before: ["a", "b"]))

        #expect(added.map(shape(of:)) == ["+++"])
        #expect(deleted.map(shape(of:)) == ["--"])
    }

    @Test func trimsServerPatchThatCarriesWholeFileAsContext() {
        var patchLines = originalLines.map { " \($0)" }
        patchLines[1000] = "-line 1000"
        patchLines.insert("+CHANGED", at: 1001)
        let patch = ReviewFilePatchHunk(
            oldStart: 1,
            oldLines: 2000,
            newStart: 1,
            newLines: 2000,
            lines: patchLines
        )

        let hunks = UnifiedDiffBuilder.makeHunks(file: file(patchHunks: [patch]))

        #expect(hunks.count == 1)
        #expect(shape(of: hunks[0]) == "   -+   ")
        #expect(hunks[0].lines.first?.oldLineNumber == 998)
        #expect(hunks[0].header == "@@ -998,7 +998,7 @@")
    }

    @Test func reportsLongestLineSoRowsCanReserveWidthWithoutWrapping() {
        let long = String(repeating: "x", count: 300)
        let hunks = UnifiedDiffBuilder.makeHunks(file: file(before: ["short"], after: ["short", long]))

        #expect(hunks.count == 1)
        #expect(hunks[0].maxLineLength == 300)
    }

    @Test func keepsServerPatchThatIsAlreadyTight() {
        let patch = ReviewFilePatchHunk(
            oldStart: 1,
            oldLines: 2,
            newStart: 1,
            newLines: 2,
            lines: [" Intro", "-# Title", "+# Updated title"]
        )

        let hunks = UnifiedDiffBuilder.makeHunks(file: file(patchHunks: [patch, patch]))

        #expect(hunks.count == 2)
        #expect(hunks[0].header == "@@ -1,2 +1,2 @@")
        #expect(shape(of: hunks[0]) == " -+")
        #expect(Set(hunks.map(\.id)).count == 2)
        #expect(Set(hunks.flatMap { $0.lines.map(\.id) }).count == 6)
    }
}
