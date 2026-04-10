import Foundation
import Testing
@testable import OpenLens

struct SourceControlModelsTests {

    @Test func mapsDiffPayloadIntoReviewFileChange() {
        let diff = OCFileDiff(
            path: "Sources/App.swift",
            status: "m",
            additions: 12,
            deletions: 3,
            before: "let oldValue = 1\n",
            after: "let newValue = 2\n"
        )

        let change = ReviewFileChange(diff: diff)

        #expect(change.path == "Sources/App.swift")
        #expect(change.status == "M")
        #expect(change.statusLabel == "MODIFIED")
        #expect(change.additions == 12)
        #expect(change.deletions == 3)
        #expect(change.beforeText == "let oldValue = 1\n")
        #expect(change.afterText == "let newValue = 2\n")
    }

    @Test func derivesFallbackValuesWhenDiffPayloadIsSparse() {
        let added = ReviewFileChange(
            diff: OCFileDiff(
                file: "README.md",
                before: nil,
                after: "# Title\n"
            )
        )

        let unknown = ReviewFileChange(diff: OCFileDiff())

        #expect(added.path == "README.md")
        #expect(added.status == "A")
        #expect(added.statusLabel == "ADDED")
        #expect(added.additions == 1)
        #expect(added.deletions == 0)

        #expect(unknown.path == "Unknown file")
        #expect(unknown.status == "M")
        #expect(unknown.additions == 0)
        #expect(unknown.deletions == 0)
        #expect(unknown.beforeText == nil)
        #expect(unknown.afterText == nil)
    }

    @Test func mapsWorkspaceFileStatusIntoReviewFileChange() {
        let status = OCWorkspaceFileStatus(
            path: "OpenLens/App.swift",
            added: 7,
            removed: 2,
            status: "modified"
        )

        let change = ReviewFileChange(fileStatus: status)

        #expect(change.path == "OpenLens/App.swift")
        #expect(change.status == "M")
        #expect(change.additions == 7)
        #expect(change.deletions == 2)
        #expect(change.beforeText == nil)
        #expect(change.afterText == nil)
        #expect(change.patchHunks.isEmpty)
    }

    @Test func appliesWorkspaceFileContentPatchToReviewFileChange() {
        let summary = ReviewFileChange(
            fileStatus: OCWorkspaceFileStatus(
                path: "README.md",
                added: 4,
                removed: 1,
                status: "modified"
            )
        )

        let content = OCFileContent(
            type: "text",
            content: "# Updated title\n",
            diff: "@@ -1,1 +1,1 @@\n-# Title\n+# Updated title\n",
            patch: OCFilePatch(
                oldFileName: "README.md",
                newFileName: "README.md",
                oldHeader: nil,
                newHeader: nil,
                hunks: [
                    OCFilePatchHunk(
                        oldStart: 1,
                        oldLines: 1,
                        newStart: 1,
                        newLines: 1,
                        lines: [
                            "-# Title",
                            "+# Updated title"
                        ]
                    )
                ],
                index: nil
            ),
            encoding: nil,
            mimeType: "text/markdown"
        )

        let detail = summary.applying(content: content)

        #expect(detail.afterText == "# Updated title\n")
        #expect(detail.patchHunks.count == 1)
        #expect(detail.patchHunks[0].lines == ["-# Title", "+# Updated title"])
        #expect(detail.hasReadableDiff)
    }
}
