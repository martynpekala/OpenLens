import SwiftUI

struct FileChangeRow: View {
    let file: ReviewFileChange

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            FileChangeStatusBadge(status: file.status)

            VStack(alignment: .leading, spacing: 8) {
                Text(file.path)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.appPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 12) {
                    Text("+\(file.additions)")
                        .foregroundStyle(.green)
                    Text("-\(file.deletions)")
                        .foregroundStyle(.red)
                    if file.hasReadableDiff {
                        Text("Open diff")
                            .foregroundStyle(Color.appSecondary)
                    }
                }
                .font(.system(size: 12, weight: .medium, design: .rounded))
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.appSecondary)
                .padding(.top, 4)
        }
    }
}

struct FileChangeStatusBadge: View {
    let status: String

    var body: some View {
        Text(statusLabel(status))
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(statusForegroundColor(status))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(statusColor(status), in: Capsule())
    }

    private func statusForegroundColor(_ status: String) -> Color {
        switch status.uppercased() {
        case "A", "D", "R":
            .white
        default:
            Color.appOnAccent
        }
    }

    private func statusColor(_ status: String) -> Color {
        switch status.uppercased() {
        case "A": .green
        case "D": .red
        case "R": .orange
        default: Color.appAccent
        }
    }

    private func statusLabel(_ status: String) -> String {
        switch status.uppercased() {
        case "A": "ADDED"
        case "D": "DELETED"
        case "R": "RENAMED"
        default: "MODIFIED"
        }
    }
}

struct FileDiffDetailView: View {
    enum DisplayMode: String, CaseIterable, Identifiable {
        case changed = "Changed"
        case before = "Before"
        case after = "After"

        var id: String { rawValue }
    }

    let file: ReviewFileChange

    @Environment(\.dismiss) private var dismiss
    @State private var displayMode: DisplayMode

    init(file: ReviewFileChange) {
        self.file = file
        _displayMode = State(initialValue: Self.preferredDisplayMode(for: file))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headerCard

                    if hasModePicker {
                        Picker("View", selection: $displayMode) {
                            ForEach(availableModes) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    content
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 20)
            }
            .background(Color.appBackground)
            .navigationTitle(fileTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .onChange(of: file) { oldFile, newFile in
                let modes = Self.availableModes(for: newFile)
                if !modes.contains(displayMode) || (!oldFile.hasReadableDiff && newFile.hasReadableDiff) {
                    displayMode = Self.preferredDisplayMode(for: newFile)
                }
            }
        }
    }

    private var headerCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    Text(file.path)
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.appPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    FileChangeStatusBadge(status: file.status)
                }

                HStack(spacing: 10) {
                    metricPill(title: "Added", value: "\(file.additions)", tint: .green)
                    metricPill(title: "Removed", value: "\(file.deletions)", tint: .red)
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch displayMode {
        case .changed:
            UnifiedDiffView(file: file)
        case .before:
            codeCard(title: "Before", text: file.beforeText ?? "No previous content.", tint: Color.red.opacity(0.08))
        case .after:
            codeCard(title: "After", text: file.afterText ?? "No current content.", tint: Color.green.opacity(0.08))
        }
    }

    private var fileTitle: String {
        (file.path as NSString).lastPathComponent
    }

    private var availableModes: [DisplayMode] {
        Self.availableModes(for: file)
    }

    static func availableModes(for file: ReviewFileChange) -> [DisplayMode] {
        DisplayMode.allCases.filter { mode in
            switch mode {
            case .changed:
                return file.hasReadableDiff
            case .before:
                return file.beforeText != nil
            case .after:
                return file.afterText != nil
            }
        }
    }

    static func preferredDisplayMode(for file: ReviewFileChange) -> DisplayMode {
        if !file.patchHunks.isEmpty {
            return .changed
        } else if file.beforeText == nil, file.afterText != nil {
            return .after
        } else if file.afterText == nil, file.beforeText != nil {
            return .before
        } else if file.hasReadableDiff {
            return .changed
        } else {
            return .after
        }
    }

    private var hasModePicker: Bool {
        availableModes.count > 1
    }

    private func metricPill(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(Color.appSecondary)
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.appTertiary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func codeCard(title: String, text: String, tint: Color) -> some View {
        SurfaceCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.appPrimary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)

                SurfaceDivider()

                CodeListingView(text: text, tint: tint)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
            }
        }
    }
}

private struct CodeListingView: View {
    let text: String
    let tint: Color
    @State private var lines: [String]

    init(text: String, tint: Color) {
        self.text = text
        self.tint = tint
        _lines = State(initialValue: Self.makeLines(from: text))
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    HStack(alignment: .top, spacing: 12) {
                        Text("\(index + 1)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.appSecondary)
                            .frame(width: 36, alignment: .trailing)

                        Text(line.isEmpty ? " " : line)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Color.appPrimary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(tint)
                    )
                }
            }
        }
        .onChange(of: text) { _, newText in
            lines = Self.makeLines(from: newText)
        }
    }

    private static func makeLines(from text: String) -> [String] {
        let splitLines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return splitLines.isEmpty ? [text] : splitLines
    }
}

struct UnifiedDiffView: View {
    let file: ReviewFileChange
    @State private var hunks: [UnifiedDiffHunk]

    init(file: ReviewFileChange) {
        self.file = file
        _hunks = State(initialValue: UnifiedDiffBuilder.makeHunks(file: file))
    }

    var body: some View {
        Group {
            if hunks.isEmpty {
                SurfaceCard {
                    Text("No line-level diff available for this file.")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.appSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(hunks) { hunk in
                        SurfaceCard(padding: 0) {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(hunk.header)
                                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(Color.appSecondary)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 12)

                                SurfaceDivider()

                                ScrollView(.horizontal, showsIndicators: false) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        ForEach(hunk.lines) { line in
                                            UnifiedDiffLineRow(line: line)
                                        }
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 10)
                                }
                            }
                        }
                    }
                }
            }
        }
        .onChange(of: file) { _, newFile in
            hunks = UnifiedDiffBuilder.makeHunks(file: newFile)
        }
    }
}

private struct UnifiedDiffLineRow: View {
    let line: UnifiedDiffLine

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(line.prefix)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(prefixColor)
                .frame(width: 12)

            Text(line.oldLineNumber.map(String.init) ?? "")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.appSecondary)
                .frame(width: 38, alignment: .trailing)

            Text(line.newLineNumber.map(String.init) ?? "")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.appSecondary)
                .frame(width: 38, alignment: .trailing)

            Text(line.text.isEmpty ? " " : line.text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color.appPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(backgroundColor)
        )
    }

    private var backgroundColor: Color {
        switch line.kind {
        case .context:
            Color.appTertiary.opacity(0.45)
        case .added:
            Color.green.opacity(0.14)
        case .removed:
            Color.red.opacity(0.14)
        }
    }

    private var prefixColor: Color {
        switch line.kind {
        case .context:
            Color.appSecondary
        case .added:
            .green
        case .removed:
            .red
        }
    }
}

private struct UnifiedDiffHunk: Identifiable {
    let id: String
    let header: String
    let lines: [UnifiedDiffLine]
}

private struct UnifiedDiffLine: Identifiable {
    enum Kind {
        case context
        case added
        case removed
    }

    let id: String
    let kind: Kind
    let oldLineNumber: Int?
    let newLineNumber: Int?
    let text: String

    var prefix: String {
        switch kind {
        case .context:
            " "
        case .added:
            "+"
        case .removed:
            "-"
        }
    }
}

private enum UnifiedDiffBuilder {
    private enum DiffOperation {
        case equal(String)
        case added(String)
        case removed(String)
    }

    static func makeHunks(file: ReviewFileChange, contextSize: Int = 3) -> [UnifiedDiffHunk] {
        if !file.patchHunks.isEmpty {
            return makePatchHunks(file.patchHunks)
        }

        return makeHunks(before: file.beforeText, after: file.afterText, contextSize: contextSize)
    }

    static func makeHunks(before: String?, after: String?, contextSize: Int = 3) -> [UnifiedDiffHunk] {
        let beforeLines = splitLines(before)
        let afterLines = splitLines(after)
        let operations = buildOperations(before: beforeLines, after: afterLines)
        let diffLines = annotateLines(operations)

        guard diffLines.contains(where: { $0.kind != .context }) else {
            return diffLines.isEmpty ? [] : [
                UnifiedDiffHunk(
                    id: "hunk-0",
                    header: makeHeader(diffLines),
                    lines: diffLines
                )
            ]
        }

        let changeIndexes = diffLines.indices.filter { diffLines[$0].kind != .context }
        var ranges: [ClosedRange<Int>] = []

        for index in changeIndexes {
            let start = max(diffLines.startIndex, index - contextSize)
            let end = min(diffLines.index(before: diffLines.endIndex), index + contextSize)

            if let lastRange = ranges.last, start <= lastRange.upperBound + 1 {
                ranges[ranges.count - 1] = lastRange.lowerBound...max(lastRange.upperBound, end)
            } else {
                ranges.append(start...end)
            }
        }

        return ranges.enumerated().map { offset, range in
            let lines = Array(diffLines[range])
            return UnifiedDiffHunk(
                id: "hunk-\(offset)",
                header: makeHeader(lines),
                lines: lines
            )
        }
    }

    private static func makePatchHunks(_ patchHunks: [ReviewFilePatchHunk]) -> [UnifiedDiffHunk] {
        patchHunks.enumerated().map { offset, hunk in
            var oldLineNumber = hunk.oldStart
            var newLineNumber = hunk.newStart

            let lines = hunk.lines.enumerated().map { index, rawLine in
                let prefix = rawLine.first
                let text = prefix.map { _ in String(rawLine.dropFirst()) } ?? rawLine

                switch prefix {
                case "-":
                    defer { oldLineNumber += 1 }
                    return UnifiedDiffLine(
                        id: "patch-del-\(offset)-\(index)-\(oldLineNumber)",
                        kind: .removed,
                        oldLineNumber: lineNumberOrNil(oldLineNumber),
                        newLineNumber: nil,
                        text: text
                    )
                case "+":
                    defer { newLineNumber += 1 }
                    return UnifiedDiffLine(
                        id: "patch-add-\(offset)-\(index)-\(newLineNumber)",
                        kind: .added,
                        oldLineNumber: nil,
                        newLineNumber: lineNumberOrNil(newLineNumber),
                        text: text
                    )
                default:
                    let currentOldLine = lineNumberOrNil(oldLineNumber)
                    let currentNewLine = lineNumberOrNil(newLineNumber)
                    if prefix != "\\" {
                        oldLineNumber += 1
                        newLineNumber += 1
                    }
                    return UnifiedDiffLine(
                        id: "patch-ctx-\(offset)-\(index)-\(currentOldLine ?? 0)-\(currentNewLine ?? 0)",
                        kind: .context,
                        oldLineNumber: currentOldLine,
                        newLineNumber: currentNewLine,
                        text: prefix == "\\" ? rawLine : text
                    )
                }
            }

            return UnifiedDiffHunk(
                id: "patch-hunk-\(offset)",
                header: "@@ -\(hunk.oldStart),\(hunk.oldLines) +\(hunk.newStart),\(hunk.newLines) @@",
                lines: lines
            )
        }
    }

    private static func lineNumberOrNil(_ value: Int) -> Int? {
        value > 0 ? value : nil
    }

    private static func splitLines(_ text: String?) -> [String] {
        guard let text else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private static func buildOperations(before: [String], after: [String]) -> [DiffOperation] {
        let beforeCount = before.count
        let afterCount = after.count

        var table = Array(
            repeating: Array(repeating: 0, count: afterCount + 1),
            count: beforeCount + 1
        )

        if beforeCount > 0 && afterCount > 0 {
            for beforeIndex in stride(from: beforeCount - 1, through: 0, by: -1) {
                for afterIndex in stride(from: afterCount - 1, through: 0, by: -1) {
                    if before[beforeIndex] == after[afterIndex] {
                        table[beforeIndex][afterIndex] = table[beforeIndex + 1][afterIndex + 1] + 1
                    } else {
                        table[beforeIndex][afterIndex] = max(
                            table[beforeIndex + 1][afterIndex],
                            table[beforeIndex][afterIndex + 1]
                        )
                    }
                }
            }
        }

        var operations: [DiffOperation] = []
        var beforeIndex = 0
        var afterIndex = 0

        while beforeIndex < beforeCount, afterIndex < afterCount {
            if before[beforeIndex] == after[afterIndex] {
                operations.append(.equal(before[beforeIndex]))
                beforeIndex += 1
                afterIndex += 1
            } else if table[beforeIndex + 1][afterIndex] >= table[beforeIndex][afterIndex + 1] {
                operations.append(.removed(before[beforeIndex]))
                beforeIndex += 1
            } else {
                operations.append(.added(after[afterIndex]))
                afterIndex += 1
            }
        }

        while beforeIndex < beforeCount {
            operations.append(.removed(before[beforeIndex]))
            beforeIndex += 1
        }

        while afterIndex < afterCount {
            operations.append(.added(after[afterIndex]))
            afterIndex += 1
        }

        return operations
    }

    private static func annotateLines(_ operations: [DiffOperation]) -> [UnifiedDiffLine] {
        var oldLineNumber = 1
        var newLineNumber = 1

        return operations.enumerated().map { index, operation in
            switch operation {
            case .equal(let text):
                defer {
                    oldLineNumber += 1
                    newLineNumber += 1
                }
                return UnifiedDiffLine(
                    id: "ctx-\(index)-\(oldLineNumber)-\(newLineNumber)",
                    kind: .context,
                    oldLineNumber: oldLineNumber,
                    newLineNumber: newLineNumber,
                    text: text
                )
            case .removed(let text):
                defer { oldLineNumber += 1 }
                return UnifiedDiffLine(
                    id: "del-\(index)-\(oldLineNumber)",
                    kind: .removed,
                    oldLineNumber: oldLineNumber,
                    newLineNumber: nil,
                    text: text
                )
            case .added(let text):
                defer { newLineNumber += 1 }
                return UnifiedDiffLine(
                    id: "add-\(index)-\(newLineNumber)",
                    kind: .added,
                    oldLineNumber: nil,
                    newLineNumber: newLineNumber,
                    text: text
                )
            }
        }
    }

    private static func makeHeader(_ lines: [UnifiedDiffLine]) -> String {
        let oldNumbers = lines.compactMap(\.oldLineNumber)
        let newNumbers = lines.compactMap(\.newLineNumber)

        let oldStart = oldNumbers.first ?? max((newNumbers.first ?? 1) - 1, 0)
        let newStart = newNumbers.first ?? max((oldNumbers.first ?? 1) - 1, 0)
        let oldCount = max(oldNumbers.count, 1)
        let newCount = max(newNumbers.count, 1)

        return "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@"
    }
}
