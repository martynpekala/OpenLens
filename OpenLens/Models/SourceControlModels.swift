import Foundation

struct ReviewFilePatchHunk: Hashable, Sendable {
    let oldStart: Int
    let oldLines: Int
    let newStart: Int
    let newLines: Int
    let lines: [String]

    init(patchHunk: OCFilePatchHunk) {
        self.oldStart = patchHunk.oldStart
        self.oldLines = patchHunk.oldLines
        self.newStart = patchHunk.newStart
        self.newLines = patchHunk.newLines
        self.lines = patchHunk.lines
    }
}

struct ReviewFileChange: Identifiable, Hashable, Sendable {
    let path: String
    let status: String
    let additions: Int
    let deletions: Int
    let beforeText: String?
    let afterText: String?
    let patchHunks: [ReviewFilePatchHunk]

    var id: String { path }

    init(
        path: String,
        status: String,
        additions: Int,
        deletions: Int,
        beforeText: String?,
        afterText: String?,
        patchHunks: [ReviewFilePatchHunk] = []
    ) {
        self.path = path
        self.status = status
        self.additions = additions
        self.deletions = deletions
        self.beforeText = beforeText
        self.afterText = afterText
        self.patchHunks = patchHunks
    }

    init(diff: OCFileDiff) {
        let normalizedPath = diff.resolvedPath?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        self.init(
            path: normalizedPath?.nilIfBlank ?? "Unknown file",
            status: diff.resolvedStatus,
            additions: diff.resolvedAdditions,
            deletions: diff.resolvedDeletions,
            beforeText: diff.before?.isEmpty == false ? diff.before : nil,
            afterText: diff.after?.isEmpty == false ? diff.after : nil,
            patchHunks: []
        )
    }

    init(fileStatus: OCWorkspaceFileStatus) {
        self.init(
            path: fileStatus.path,
            status: fileStatus.resolvedStatus,
            additions: fileStatus.added,
            deletions: fileStatus.removed,
            beforeText: nil,
            afterText: nil,
            patchHunks: []
        )
    }

    func applying(content: OCFileContent) -> ReviewFileChange {
        let resolvedAfterText: String?
        if status.uppercased() == "D" {
            resolvedAfterText = nil
        } else if let text = content.resolvedTextContent {
            resolvedAfterText = text
        } else {
            resolvedAfterText = afterText
        }

        return ReviewFileChange(
            path: path,
            status: status,
            additions: additions,
            deletions: deletions,
            beforeText: beforeText,
            afterText: resolvedAfterText,
            patchHunks: content.patch?.hunks.map(ReviewFilePatchHunk.init(patchHunk:)) ?? patchHunks
        )
    }

    var statusLabel: String {
        switch status.uppercased() {
        case "A": "ADDED"
        case "D": "DELETED"
        case "R": "RENAMED"
        default: "MODIFIED"
        }
    }

    var hasReadableDiff: Bool {
        !patchHunks.isEmpty || beforeText != nil || afterText != nil
    }
}

struct ReviewChangeSet: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let createdAt: Date?
    let messagePreview: String?
    let files: [ReviewFileChange]
}

struct SessionReviewSnapshot: Sendable {
    let sessionID: String
    let changeSets: [ReviewChangeSet]
    let workingTree: [ReviewFileChange]

    var latestChangeSet: ReviewChangeSet? {
        changeSets.first
    }
}
