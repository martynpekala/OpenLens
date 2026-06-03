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

    @Test func mapsSessionRawDiffPayloadIntoReviewFileChange() {
        let diff = OCFileDiff(
            path: "README.md",
            diff: """
            diff --git a/README.md b/README.md
            index 84e8c7f..07f62f8 100644
            --- a/README.md
            +++ b/README.md
            @@ -1,2 +1,2 @@
             Intro
            -# Title
            +# Updated title
            """
        )

        let change = ReviewFileChange(diff: diff)

        #expect(change.path == "README.md")
        #expect(change.status == "M")
        #expect(change.additions == 1)
        #expect(change.deletions == 1)
        #expect(change.beforeText == nil)
        #expect(change.afterText == nil)
        #expect(change.patchHunks.count == 1)
        #expect(change.patchHunks[0].lines == [" Intro", "-# Title", "+# Updated title"])
        #expect(change.hasReadableDiff)
        #expect(FileDiffDetailView.preferredDisplayMode(for: change) == .changed)
    }

    @Test func decodesTextPatchPayloadIntoReviewFileChange() throws {
        let data = #"""
        [{
          "file": ".bazelignore",
          "patch": "Index: .bazelignore\n===================================================================\n--- .bazelignore\t\n+++ .bazelignore\t\n@@ -1,2 +0,0 @@\n-.worktrees\n-Toolset/.build\n",
          "additions": 0,
          "deletions": 2,
          "status": "deleted"
        }]
        """#.data(using: .utf8)!

        let diffs = try JSONDecoder().decode([OCFileDiff].self, from: data)
        let diff = try #require(diffs.first)
        let change = ReviewFileChange(diff: diff)

        #expect(change.path == ".bazelignore")
        #expect(change.status == "D")
        #expect(change.statusLabel == "DELETED")
        #expect(change.additions == 0)
        #expect(change.deletions == 2)
        #expect(change.patchHunks.count == 1)
        #expect(change.patchHunks[0].oldStart == 1)
        #expect(change.patchHunks[0].newLines == 0)
        #expect(change.patchHunks[0].lines == ["-.worktrees", "-Toolset/.build"])
        #expect(change.hasReadableDiff)
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

    @Test func appliesWorkspaceRawDiffWhenPatchObjectIsMissing() {
        let summary = ReviewFileChange(
            fileStatus: OCWorkspaceFileStatus(
                path: "README.md",
                added: 4,
                removed: 1,
                status: "modified"
            )
        )

        let content = OCFileContent(
            type: nil,
            content: nil,
            diff: """
            diff --git a/README.md b/README.md
            index 84e8c7f..07f62f8 100644
            --- a/README.md
            +++ b/README.md
            @@ -1,2 +1,2 @@
             Intro
            -# Title
            +# Updated title
            """,
            patch: nil,
            encoding: nil,
            mimeType: "text/markdown"
        )

        let detail = summary.applying(content: content)

        #expect(detail.afterText == nil)
        #expect(detail.patchHunks.count == 1)
        #expect(detail.patchHunks[0].oldStart == 1)
        #expect(detail.patchHunks[0].oldLines == 2)
        #expect(detail.patchHunks[0].newStart == 1)
        #expect(detail.patchHunks[0].newLines == 2)
        #expect(detail.patchHunks[0].lines == [" Intro", "-# Title", "+# Updated title"])
        #expect(detail.hasReadableDiff)
    }

    @Test func appliesWorkspaceTextPatchWhenPatchObjectIsMissing() throws {
        let summary = ReviewFileChange(
            fileStatus: OCWorkspaceFileStatus(
                path: "README.md",
                added: 1,
                removed: 1,
                status: "modified"
            )
        )

        let data = #"""
        {
          "patch": "Index: README.md\n===================================================================\n--- README.md\t\n+++ README.md\t\n@@ -1,1 +1,1 @@\n-# Title\n+# Updated title\n",
          "mimeType": "text/markdown"
        }
        """#.data(using: .utf8)!

        let content = try JSONDecoder().decode(OCFileContent.self, from: data)
        let detail = summary.applying(content: content)

        #expect(detail.patchHunks.count == 1)
        #expect(detail.patchHunks[0].lines == ["-# Title", "+# Updated title"])
        #expect(detail.hasReadableDiff)
    }

    @Test func fileDiffDetailPrefersChangedModeAfterPatchLoads() {
        let summary = ReviewFileChange(
            fileStatus: OCWorkspaceFileStatus(
                path: "README.md",
                added: 1,
                removed: 1,
                status: "modified"
            )
        )

        let detail = summary.applying(
            content: OCFileContent(
                type: nil,
                content: nil,
                diff: "@@ -1,1 +1,1 @@\n-# Title\n+# Updated title\n",
                patch: nil,
                encoding: nil,
                mimeType: "text/markdown"
            )
        )

        #expect(FileDiffDetailView.preferredDisplayMode(for: summary) == .after)
        #expect(FileDiffDetailView.preferredDisplayMode(for: detail) == .changed)
        #expect(FileDiffDetailView.availableModes(for: detail) == [.changed])
    }
}
