import Foundation

struct ReviewFilePatchHunk: Hashable, Sendable {
    let oldStart: Int
    let oldLines: Int
    let newStart: Int
    let newLines: Int
    let lines: [String]

    nonisolated init(patchHunk: OCFilePatchHunk) {
        self.oldStart = patchHunk.oldStart
        self.oldLines = patchHunk.oldLines
        self.newStart = patchHunk.newStart
        self.newLines = patchHunk.newLines
        self.lines = patchHunk.lines
    }

    nonisolated init(oldStart: Int, oldLines: Int, newStart: Int, newLines: Int, lines: [String]) {
        self.oldStart = oldStart
        self.oldLines = oldLines
        self.newStart = newStart
        self.newLines = newLines
        self.lines = lines
    }

    nonisolated static func parseUnifiedDiff(_ diff: String?) -> [ReviewFilePatchHunk] {
        guard let diff, !diff.isEmpty else { return [] }

        var hunks: [ReviewFilePatchHunk] = []
        var currentHeader: (oldStart: Int, oldLines: Int, newStart: Int, newLines: Int)?
        var currentLines: [String] = []

        func finishCurrentHunk() {
            guard let header = currentHeader else { return }
            while currentLines.last == "" {
                currentLines.removeLast()
            }
            hunks.append(
                ReviewFilePatchHunk(
                    oldStart: header.oldStart,
                    oldLines: header.oldLines,
                    newStart: header.newStart,
                    newLines: header.newLines,
                    lines: currentLines
                )
            )
            currentHeader = nil
            currentLines = []
        }

        for line in diff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if let header = parseUnifiedDiffHeader(line) {
                finishCurrentHunk()
                currentHeader = header
            } else if currentHeader != nil {
                currentLines.append(line)
            }
        }

        finishCurrentHunk()
        return hunks.filter { !$0.lines.isEmpty }
    }

    private nonisolated static func parseUnifiedDiffHeader(_ line: String) -> (oldStart: Int, oldLines: Int, newStart: Int, newLines: Int)? {
        guard line.hasPrefix("@@") else { return nil }

        let tokens = line.split(separator: " ")
        guard let oldToken = tokens.first(where: { $0.hasPrefix("-") }),
              let newToken = tokens.first(where: { $0.hasPrefix("+") }),
              let oldRange = parseUnifiedDiffRange(String(oldToken), prefix: "-"),
              let newRange = parseUnifiedDiffRange(String(newToken), prefix: "+")
        else {
            return nil
        }

        return (
            oldStart: oldRange.start,
            oldLines: oldRange.lines,
            newStart: newRange.start,
            newLines: newRange.lines
        )
    }

    private nonisolated static func parseUnifiedDiffRange(_ token: String, prefix: Character) -> (start: Int, lines: Int)? {
        guard token.first == prefix else { return nil }

        let body = token.dropFirst()
        let parts = body.split(separator: ",", maxSplits: 1)
        guard let startPart = parts.first,
              let start = Int(startPart)
        else {
            return nil
        }

        let lineCount = parts.dropFirst().first.flatMap { Int($0) } ?? 1
        return (start: start, lines: lineCount)
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
        let patchHunks: [ReviewFilePatchHunk]
        if let patch = diff.patch {
            patchHunks = patch.hunks.map(ReviewFilePatchHunk.init(patchHunk:))
        } else {
            patchHunks = ReviewFilePatchHunk.parseUnifiedDiff(diff.unifiedPatchText)
        }

        self.init(
            path: normalizedPath?.nilIfBlank ?? "Unknown file",
            status: diff.resolvedStatus,
            additions: diff.resolvedAdditions,
            deletions: diff.resolvedDeletions,
            beforeText: diff.before?.isEmpty == false ? diff.before : nil,
            afterText: diff.after?.isEmpty == false ? diff.after : nil,
            patchHunks: patchHunks
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

        let resolvedPatchHunks: [ReviewFilePatchHunk]
        if let patch = content.patch {
            resolvedPatchHunks = patch.hunks.map(ReviewFilePatchHunk.init(patchHunk:))
        } else {
            let parsedHunks = ReviewFilePatchHunk.parseUnifiedDiff(content.unifiedPatchText)
            resolvedPatchHunks = parsedHunks.isEmpty ? patchHunks : parsedHunks
        }

        return ReviewFileChange(
            path: path,
            status: status,
            additions: additions,
            deletions: deletions,
            beforeText: beforeText,
            afterText: resolvedAfterText,
            patchHunks: resolvedPatchHunks
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
