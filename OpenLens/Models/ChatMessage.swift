import Foundation
import Observation

/// Produces a small display-ready value without traversing an unbounded server
/// string on the UI actor. The raw value remains in the server part for
/// fidelity; assistant segments retain only this preview.
private enum BoundedDisplayPreview {
    private static let maximumInspectedCharacters = 2_048

    /// Fast presence check for UI decisions made on MainActor. It never
    /// traverses an untrusted server string past the inspection budget.
    static func hasVisibleText(_ text: String?) -> Bool {
        guard let text else { return false }

        var inspectedCharacters = 0
        for character in text {
            guard inspectedCharacters < maximumInspectedCharacters else { return false }
            if !character.isWhitespace { return true }
            inspectedCharacters += 1
        }
        return false
    }

    static func make(from text: String?, limit: Int) -> String? {
        guard let text, limit > 0 else { return nil }

        var preview = ""
        preview.reserveCapacity(limit + 3)
        var inspectedCharacters = 0
        var visibleCharacters = 0
        var hasStarted = false
        var previousWasLineBreak = false
        var isTruncated = false

        for character in text {
            guard inspectedCharacters < maximumInspectedCharacters else {
                isTruncated = true
                break
            }
            inspectedCharacters += 1

            // Skip only leading whitespace. Once content begins, preserve its
            // shape while collapsing repeated blank lines without a full regex
            // pass over a potentially huge tool output.
            if !hasStarted {
                guard !character.isWhitespace else { continue }
                hasStarted = true
            }

            let isLineBreak = character == "\n" || character == "\r"
            if isLineBreak, previousWasLineBreak {
                continue
            }

            guard visibleCharacters < limit else {
                isTruncated = true
                break
            }

            if isLineBreak {
                preview.append(contentsOf: "\n")
            } else {
                preview.append(character)
            }
            visibleCharacters += 1
            previousWasLineBreak = isLineBreak
        }

        // `preview` is capped, so trimming its tail is bounded work as well.
        while let last = preview.last, last.isWhitespace {
            preview.removeLast()
        }

        guard !preview.isEmpty else { return nil }
        return isTruncated ? preview + "..." : preview
    }
}

/// Produces a short tool transcript. Tool output is intentionally tighter
/// than subagent task copy because it is rendered inline in the transcript.
private enum ToolOutputPreview {
    private static let maximumVisibleCharacters = 140

    static func make(from text: String?) -> String? {
        BoundedDisplayPreview.make(from: text, limit: maximumVisibleCharacters)
    }
}

private enum ChatDisplayLimit {
    static let toolName = 96
    static let subagentTitle = 96
    static let subagentDetail = 480
    static let subagentPrompt = 480
}

private enum ChatStreamLimit {
    /// A single agent turn can create hundreds of tool updates. Keep the live
    /// transcript useful without creating an unbounded number of SwiftUI rows
    /// or concurrent subagent animations.
    static let maximumActivityParts = 48

    /// Reasoning normally grows inside one part projection. A malformed or
    /// evolving server can nevertheless create a new reasoning part for every
    /// update; retain a useful recent window without letting that shape grow an
    /// unbounded transcript and index on MainActor.
    static let maximumReasoningParts = 24

    /// Retain just enough recently retracted text IDs to reject a delayed
    /// delta after an `ignored` or `removed` event. This is metadata only,
    /// deliberately bounded so malformed streams cannot grow it forever.
    static let maximumSuppressedTextPartIDs = 96
}

/// Represents a single chat message for display purposes.
/// This is a local model that combines OCMessage + OCPart data
/// into a flat structure suitable for the UI.
///
/// Using `@Observable` class instead of struct so that mutations to individual
/// message properties (content, isStreaming, parts) only invalidate the views
/// observing *that specific message* — NOT the entire ForEach list.
@Observable
final class ChatMessage: Identifiable {
    nonisolated struct StreamingMaterialization: Sendable {
        let contentChunks: [String]
        let textChunksByPartID: [String: [String]]
        let textPartOrder: [String]
        let staticTextByPartID: [String: String]
        let reasoningPartIDs: Set<String>
        let reasoningChunksByPartID: [String: [String]]
        let estimatedCharacterCount: Int
        let requiresBackgroundMaterialization: Bool
    }

    nonisolated struct MaterializedStreamingContent: Sendable {
        let content: String
        let hasVisibleContent: Bool
        let textByPartID: [String: String]
        let reasoningTextByPartID: [String: String]
        let hasVisibleReasoningByPartID: [String: Bool]
    }

    /// Keeps a growing stream split into stable, already-laid-out chunks and one
    /// small mutable tail. The full message is materialized into `content` only
    /// when streaming finishes, while SwiftUI only has to re-layout the tail
    /// during streaming.
    @Observable
    final class StreamingTextProjection {
        struct Chunk: Identifiable {
            let id: Int
            let text: String
        }

        struct LiveWindow {
            let sealedChunks: [Chunk]
            let omittedSealedChunkCount: Int
        }

        /// Shared with the enclosing message only for bounded-cost estimates;
        /// rendering still treats this as an implementation detail.
        static let targetChunkLength = 800
        /// A streaming row is one child of the outer chat LazyVStack. Keeping
        /// every sealed chunk in its inner eager stack makes each scroll/layout
        /// pass grow with the whole response. The live suffix stays constant;
        /// all chunks remain stored for Copy and final materialization.
        static let maximumLiveSealedChunkCount = 3

        let id: String
        private(set) var sealedChunks: [Chunk] = []
        private(set) var tail: String = ""
        /// A recovered history prefix is retained as one shared String rather
        /// than synchronously joining and re-chunking a large live response on
        /// MainActor. New deltas continue in `sealedChunks` / `tail`.
        private var historyBaseline: String?
        private var historyBaselineIsLiveVisible = false
        private var historyBaselineEstimatedCharacterCount = 0
        private var nextChunkID = 0

        var hasText: Bool {
            !(historyBaseline?.isEmpty ?? true) || !sealedChunks.isEmpty || !tail.isEmpty
        }

        var liveWindow: LiveWindow {
            let visibleCount = min(
                sealedChunks.count,
                Self.maximumLiveSealedChunkCount
            )
            var visibleChunks = Array(sealedChunks.suffix(visibleCount))
            var omittedChunkCount = sealedChunks.count - visibleCount
            if let historyBaseline, !historyBaseline.isEmpty {
                if historyBaselineIsLiveVisible,
                   visibleChunks.count < Self.maximumLiveSealedChunkCount {
                    visibleChunks.insert(Chunk(id: -1, text: historyBaseline), at: 0)
                } else {
                    // Keep rendering bounded after a large history recovery;
                    // the full text remains available for Copy/finalization.
                    omittedChunkCount += 1
                }
            }
            return LiveWindow(
                sealedChunks: visibleChunks,
                omittedSealedChunkCount: omittedChunkCount
            )
        }

        init(id: String) {
            self.id = id
        }

        func append(_ text: String) {
            guard !text.isEmpty else { return }
            tail += text
            sealCompletedChunks()
        }

        func append(chunks: [String]) {
            for chunk in chunks where !chunk.isEmpty {
                append(chunk)
            }
        }

        func replace(with text: String) {
            clearHistoryBaseline()
            sealedChunks = []
            tail = ""
            nextChunkID = 0
            append(text)
        }

        func replace(withChunks chunks: [String]) {
            clearHistoryBaseline()
            sealedChunks = []
            tail = ""
            nextChunkID = 0
            append(chunks: chunks)
        }

        func clear() {
            clearHistoryBaseline()
            sealedChunks = []
            tail = ""
            nextChunkID = 0
        }

        /// Incorporates a history snapshot without creating a whole joined
        /// String or re-running the chunker on the UI actor. A shorter server
        /// prefix is stale and leaves the newer local stream untouched.
        func synchronizeHistoryBaseline(with serverText: String) {
            guard !serverText.isEmpty else { return }

            switch historyRelation(to: serverText) {
            case .equal, .localExtendsServer:
                return
            case .serverExtendsLocal, .diverged:
                historyBaseline = serverText
                let metadata = Self.historyBaselineMetadata(for: serverText)
                historyBaselineIsLiveVisible = metadata.isLiveVisible
                historyBaselineEstimatedCharacterCount = metadata.estimatedCharacterCount
                sealedChunks = []
                tail = ""
                nextChunkID = 0
            }
        }

        /// This intentionally does work proportional to the full response only
        /// when a person explicitly invokes Copy, never during rendering.
        func copyText() -> String {
            (historyBaseline ?? "") + sealedChunks.map(\.text).joined() + tail
        }

        /// Copies only the small container and String storage references. The
        /// potentially expensive join is performed on the finalization worker.
        func materializationChunks() -> [String] {
            var chunks: [String] = []
            chunks.reserveCapacity(sealedChunks.count + (historyBaseline == nil ? 0 : 1) + (tail.isEmpty ? 0 : 1))
            if let historyBaseline, !historyBaseline.isEmpty {
                chunks.append(historyBaseline)
            }
            chunks.append(contentsOf: sealedChunks.map(\.text))
            if !tail.isEmpty {
                chunks.append(tail)
            }
            return chunks
        }

        var estimatedCharacterCount: Int {
            historyBaselineEstimatedCharacterCount
                + sealedChunks.count * Self.targetChunkLength
                + tail.utf8.count
        }

        private enum HistoryRelation {
            case equal
            case localExtendsServer
            case serverExtendsLocal
            case diverged
        }

        private func historyRelation(to serverText: String) -> HistoryRelation {
            var serverIndex = serverText.startIndex

            func compare(_ localText: String) -> HistoryRelation? {
                var localIndex = localText.startIndex
                while localIndex != localText.endIndex,
                      serverIndex != serverText.endIndex {
                    guard localText[localIndex] == serverText[serverIndex] else {
                        return .diverged
                    }
                    localIndex = localText.index(after: localIndex)
                    serverIndex = serverText.index(after: serverIndex)
                }
                return localIndex == localText.endIndex ? nil : .localExtendsServer
            }

            if let historyBaseline,
               let relation = compare(historyBaseline) {
                return relation
            }
            for chunk in sealedChunks {
                if let relation = compare(chunk.text) {
                    return relation
                }
            }
            if let relation = compare(tail) {
                return relation
            }
            return serverIndex == serverText.endIndex ? .equal : .serverExtendsLocal
        }

        private func clearHistoryBaseline() {
            historyBaseline = nil
            historyBaselineIsLiveVisible = false
            historyBaselineEstimatedCharacterCount = 0
        }

        private static func historyBaselineMetadata(for text: String) -> (
            isLiveVisible: Bool,
            estimatedCharacterCount: Int
        ) {
            var byteCount = 0
            for _ in text.utf8 {
                byteCount += 1
                if byteCount > targetChunkLength {
                    return (false, targetChunkLength)
                }
            }
            return (true, byteCount)
        }

        private func sealCompletedChunks() {
            while tail.count > Self.targetChunkLength {
                let hardEnd = tail.index(tail.startIndex, offsetBy: Self.targetChunkLength)
                let prefix = tail[..<hardEnd]
                // Prefer a natural paragraph boundary, then whitespace, before
                // falling back to the hard limit. Each sealed view is stable,
                // so only the small tail needs a new layout pass on a tick.
                let end = prefix.lastIndex(of: "\n")
                    .map { tail.index(after: $0) }
                    ?? prefix.lastIndex(where: { $0.isWhitespace })
                    .map { tail.index(after: $0) }
                    ?? hardEnd

                sealedChunks.append(Chunk(id: nextChunkID, text: String(tail[..<end])))
                nextChunkID += 1
                tail = String(tail[end...])
            }
        }
    }

    struct AssistantSegment: Identifiable {
        enum Kind {
            case text(String)
            case reasoning(String)
            case question(PersistedQuestionStep)
            case subagent(PersistedSubagentStep)
            case tool(PersistedToolStep)
        }

        let id: String
        let kind: Kind
        /// Present only while a reasoning part is actively growing. Holding the
        /// projection lets that row update without rebuilding the whole timeline.
        let streamingText: StreamingTextProjection?

        init(id: String, kind: Kind, streamingText: StreamingTextProjection? = nil) {
            self.id = id
            self.kind = kind
            self.streamingText = streamingText
        }
    }

    struct PersistedToolStep: Identifiable {
        let id: String
        let toolName: String
        let label: String
        /// A bounded, normalized summary prepared when the part changes. Views
        /// must not inspect the full server output while rendering.
        let outputPreview: String?
        let isError: Bool
        let toolCategory: ToolCategory
    }

    struct PersistedQuestionStep: Identifiable {
        let id: String
        let questions: [OCQuestionInfo]
        let answers: [[String]]
        let status: OCToolStatus
        let isError: Bool

        var hasAnswers: Bool {
            answers.contains { !$0.isEmpty }
        }

        var isAnswered: Bool {
            hasAnswers || status == .completed
        }
    }

    struct PersistedSubagentStep: Identifiable {
        let id: String
        let agentName: String?
        let title: String
        let detail: String
        let prompt: String?
        let isCompleted: Bool
        let isError: Bool
        let cost: Double?

        /// A task/subagent card should animate only while it is actively working.
        /// Completed and failed work stays visually stable in the timeline.
        var isActive: Bool {
            !isCompleted && !isError
        }
    }

    var id: String
    let role: OCMessageRole

    @ObservationIgnored private var appliesIncrementalPartUpdate = false
    @ObservationIgnored private var appliesStreamingContentUpdate = false
    @ObservationIgnored private var appliesPartRetentionLimits = false
    /// Each live text part owns a projection so its stable transcript row can
    /// grow in place without moving behind later tools or rebuilding the list.
    @ObservationIgnored private var textProjections: [String: StreamingTextProjection] = [:]
    @ObservationIgnored private var suppressedStreamingTextPartIDs: Set<String> = []
    @ObservationIgnored private var suppressedStreamingTextPartIDOrder: [String] = []
    /// Bumped for structural text retractions while a worker may be joining a
    /// final snapshot. The finalizer retries from current state if it changed.
    @ObservationIgnored private(set) var streamingMaterializationRevision: UInt = 0
    @ObservationIgnored private var reasoningProjections: [String: StreamingTextProjection] = [:]
    /// Streaming tool updates previously performed repeated linear lookups in
    /// both arrays. These indices are rebuilt only after a bounded structural
    /// change, making repeated status updates O(1) on MainActor.
    @ObservationIgnored private var partIndexByID: [String: Int] = [:]
    @ObservationIgnored private var assistantSegmentIndexByID: [String: Int] = [:]
    /// Number of activity parts intentionally summarized instead of retained
    /// as individual transcript rows.
    @ObservationIgnored private var omittedActivityPartCount = 0
    /// Reasoning parts have their own lower cap because every one becomes a
    /// transcript row. Counts are keyed by the next retained part, which lets
    /// summaries stay in order even when reasoning was interleaved with tools.
    @ObservationIgnored private var omittedReasoningPartCountsByAnchor: [String: Int] = [:]
    @ObservationIgnored private var omittedReasoningPartCountAtEnd = 0
    /// Question tool state is parsed on the SSE/replay worker. Preserve the
    /// resulting bounded DTO across the final `isStreaming = false` rebuild so
    /// a completed transcript never reparses raw dynamic tool JSON on MainActor.
    @ObservationIgnored private var preparedQuestionToolPayloads: [String: PreparedQuestionToolPayload] = [:]
    /// Exact whitespace information is calculated alongside large-string
    /// joining on the materialization worker, then reused by the final UI
    /// handoff instead of re-trimming the whole response on MainActor.
    @ObservationIgnored private var materializedContentHasVisibleText: Bool?
    @ObservationIgnored private var materializedReasoningHasVisibleText: [String: Bool] = [:]

    var content: String {
        didSet {
            if isStreaming {
                if !appliesStreamingContentUpdate {
                    materializedContentHasVisibleText = nil
                    streamingTextProjection.replace(with: content)
                }
            } else {
                materializedContentHasVisibleText = nil
                rebuildDerivedState()
            }
        }
    }
    var parts: [OCPart] {
        didSet {
            guard !appliesIncrementalPartUpdate else { return }

            if !appliesPartRetentionLimits {
                if let fallbackTextPartID,
                   !parts.contains(where: { $0.id == fallbackTextPartID }) {
                    discardStreamingTextProjection(partID: fallbackTextPartID)
                }
                materializedReasoningHasVisibleText.removeAll()
                preparedQuestionToolPayloads.removeAll()
                textProjections.removeAll()
                suppressedStreamingTextPartIDs.removeAll()
                suppressedStreamingTextPartIDOrder.removeAll()
                reasoningProjections.removeAll()
                omittedActivityPartCount = 0
                omittedReasoningPartCountsByAnchor.removeAll()
                omittedReasoningPartCountAtEnd = 0
                appliesPartRetentionLimits = true
                _ = discardPermanentlyNonRenderableStreamingPartsIfNeeded()
                _ = trimActivityPartsIfNeeded()
                _ = trimReasoningPartsIfNeeded()
                appliesPartRetentionLimits = false
            }

            rebuildPartIndex()
            rebuildDerivedState()
        }
    }
    var isStreaming: Bool {
        didSet {
            if isStreaming {
                appliesPartRetentionLimits = true
                _ = discardPermanentlyNonRenderableStreamingPartsIfNeeded()
                _ = trimActivityPartsIfNeeded()
                _ = trimReasoningPartsIfNeeded()
                appliesPartRetentionLimits = false
                materializedContentHasVisibleText = nil
                materializedReasoningHasVisibleText.removeAll()
                streamingTextProjection.replace(with: content)
            } else {
                streamingTextProjection.clear()
                textProjections.removeAll()
                suppressedStreamingTextPartIDs.removeAll()
                suppressedStreamingTextPartIDOrder.removeAll()
                reasoningProjections.removeAll()
            }
            rebuildDerivedState()
        }
    }
    let createdAt: Date
    var cost: Double?
    var tokens: OCTokenUsage?

    var modelID: String?
    var providerID: String?
    var finish: String?

    let streamingTextProjection: StreamingTextProjection
    /// Compatibility text without a server `partID` is represented as one
    /// terminal local text part. Keeping its ID separately lets it survive an
    /// optimistic message-ID remap without confusing it with server parts.
    @ObservationIgnored private var fallbackTextPartID: String?
    private(set) var hasRenderableTextPart = false
    private(set) var assistantSegments: [AssistantSegment] = [] {
        didSet { rebuildAssistantSegmentIndex() }
    }

    /// Resolves one stable transcript row without exposing the mutable segment
    /// collection to a view that only needs a single ID.
    func assistantSegment(withID id: String) -> AssistantSegment? {
        guard let index = assistantSegmentIndexByID[id],
              assistantSegments.indices.contains(index) else {
            return nil
        }
        return assistantSegments[index]
    }

    init(
        id: String = UUID().uuidString,
        role: OCMessageRole,
        content: String,
        parts: [OCPart] = [],
        isStreaming: Bool = false,
        createdAt: Date = Date(),
        cost: Double? = nil,
        tokens: OCTokenUsage? = nil,
        modelID: String? = nil,
        providerID: String? = nil,
        finish: String? = nil
    ) {
        self.id = id
        self.role = role
        self.streamingTextProjection = StreamingTextProjection(id: "content-text-\(id)")
        self.content = content
        self.parts = parts
        self.isStreaming = isStreaming
        self.createdAt = createdAt
        self.cost = cost
        self.tokens = tokens
        self.modelID = modelID
        self.providerID = providerID
        self.finish = finish
        _ = discardPermanentlyNonRenderableStreamingPartsIfNeeded()
        trimActivityPartsIfNeeded()
        trimReasoningPartsIfNeeded()
        rebuildPartIndex()
        if isStreaming {
            streamingTextProjection.replace(with: content)
        }
        rebuildDerivedState()
    }

    /// Display-friendly model name for assistant messages.
    var modelDisplayName: String? {
        guard let modelID, !modelID.isEmpty else { return nil }
        return modelID
    }

    /// Extract all tool call parts from this message.
    var toolParts: [OCPart] {
        parts.filter { $0.type == .tool }
    }

    /// Whether the message has any active (running) tool calls.
    var hasRunningTools: Bool {
        toolParts.contains { $0.state?.status == .running }
    }

    var reasoningText: String {
        parts
            .filter { $0.type == .reasoning }
            .compactMap(\.text)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
    }

    var persistedToolSteps: [PersistedToolStep] {
        parts.compactMap(makePersistedToolStep)
    }

    func appendStreamingText(_ text: String, chunks: [String]? = nil) {
        guard isStreaming else { return }
        if let chunks, !chunks.isEmpty {
            streamingTextProjection.append(chunks: chunks)
        } else if !text.isEmpty {
            streamingTextProjection.append(text)
        } else {
            return
        }
    }

    /// The server can replace an optimistic temporary assistant ID after a
    /// stream has already begun. Keep the same projections and segments rather
    /// than rebuilding from the still-unmaterialized canonical content.
    func remapStreamingID(to newID: String) {
        guard isStreaming, id != newID else { return }
        id = newID
    }

    /// The active fallback slot is reusable only while it remains the terminal
    /// part. A later tool or text part starts a new no-partID text run, which
    /// must receive a fresh slot so it does not jump above that intervening row.
    var activeStreamingFallbackTextPartID: String? {
        guard let fallbackTextPartID,
              let index = partIndexByID[fallbackTextPartID],
              parts.indices.contains(index),
              parts[index].isRenderableText,
              index == parts.index(before: parts.endIndex),
              textProjections[fallbackTextPartID] != nil
        else {
            return nil
        }
        return fallbackTextPartID
    }

    /// Releases one streaming text projection. The first compatibility slot
    /// may own the legacy shared projection; if that slot is retracted, clear
    /// it as well so a worker retry cannot re-materialize stale fallback text.
    private func discardStreamingTextProjection(partID: String) {
        let projection = textProjections.removeValue(forKey: partID)
        if projection === streamingTextProjection {
            streamingTextProjection.clear()
        }
        if fallbackTextPartID == partID {
            fallbackTextPartID = nil
        }
    }

    /// Incorporates a foreground history refresh into the same live object.
    /// Server parts provide the best known order, while locally streamed parts
    /// and their projections win for matching IDs so a newer delta is never
    /// discarded by a slightly stale REST response.
    func absorbHistorySnapshot(_ snapshot: ChatMessage) {
        guard isStreaming,
              role == .assistant,
              snapshot.id == id else {
            return
        }

        var localPartsByID: [String: OCPart] = [:]
        for part in parts {
            localPartsByID[part.id] = part
        }

        var merged: [OCPart] = []
        var includedPartIDs = Set<String>()
        for serverPart in snapshot.parts {
            if serverPart.type == .text {
                // History can lag an SSE retraction. Only a later explicit
                // visible `part.updated` is allowed to restore this ID.
                if suppressedStreamingTextPartIDs.contains(serverPart.id) {
                    includedPartIDs.insert(serverPart.id)
                    continue
                }
                guard serverPart.isRenderableText else {
                    // A foreground refresh is authoritative for visibility.
                    // Do not let an older local projection keep a retracted
                    // row alive, or let a subsequent late delta recreate it.
                    invalidateStreamingMaterialization()
                    suppressStreamingTextPart(serverPart.id)
                    discardStreamingTextProjection(partID: serverPart.id)
                    includedPartIDs.insert(serverPart.id)
                    continue
                }
            }
            let selectedPart: OCPart
            if let localPart = localPartsByID[serverPart.id], localPart.type == serverPart.type {
                switch localPart.type {
                case .text:
                    // A server value extending the local projection is a
                    // recovered baseline, not an older overwrite. Adopt it
                    // before later deltas arrive so `A → history AB → C`
                    // continues as `ABC` in the live row as well as in the
                    // final transcript. A shorter server prefix leaves the
                    // newer local suffix intact.
                    if let projection = textProjections[localPart.id],
                       let serverText = serverPart.text,
                       !serverText.isEmpty {
                        synchronizeStreamingTextProjection(
                            projection,
                            withServerText: serverText
                        )
                    }
                    selectedPart = serverPart
                case .reasoning where reasoningProjections[localPart.id] != nil:
                    selectedPart = localPart
                default:
                    // Tool/subagent state and text without a local projection
                    // are recoverable server facts. A foreground refresh is
                    // specifically used to repair a missed SSE transition.
                    selectedPart = serverPart
                }
            } else {
                selectedPart = serverPart
            }
            merged.append(selectedPart)
            includedPartIDs.insert(serverPart.id)
        }

        // The refresh can lag behind SSE. Keep any local part it has not seen
        // yet rather than making a live tool or text slot disappear.
        merged.append(contentsOf: parts.filter { !includedPartIDs.contains($0.id) })

        mutatePartsWithoutRebuilding {
            parts = merged
        }
        // A finalization worker may have captured the pre-refresh parts and
        // projections. Even an ordinary visible history update must make it
        // re-snapshot before committing, or it could overwrite this recovered
        // server suffix with stale local text.
        invalidateStreamingMaterialization()
        rebuildDerivedState()

        cost = snapshot.cost ?? cost
        tokens = snapshot.tokens ?? tokens
        modelID = snapshot.modelID ?? modelID
        providerID = snapshot.providerID ?? providerID
        finish = snapshot.finish ?? finish
    }

    func replaceStreamingText(with text: String, chunks: [String]? = nil) {
        if let chunks {
            streamingTextProjection.replace(withChunks: chunks)
        } else {
            streamingTextProjection.replace(with: text)
        }
    }

    /// Registers the ordered placeholder for a streaming text part without
    /// copying its potentially large snapshot into the derived transcript.
    /// The text itself is kept in a per-part projection and materialized once
    /// when the response finishes.
    @discardableResult
    func registerStreamingTextPart(_ part: OCPart) -> Bool {
        guard isStreaming,
              role == .assistant,
              part.type == .text else {
            return false
        }

        let placeholder = part.replacingText(nil)
        if let index = partIndexByID[part.id] {
            guard parts[index].type == .text else { return false }
            guard part.isRenderableText else {
                // Hidden server text is not transcript state. Removing an
                // already-visible slot also releases its projection, so a
                // delayed delta cannot revive it on the next render tick.
                mutatePartsWithoutRebuilding {
                    parts.remove(at: index)
                }
                invalidateStreamingMaterialization()
                suppressStreamingTextPart(part.id)
                discardStreamingTextProjection(partID: part.id)
                rebuildDerivedState()
                return true
            }
            restoreStreamingTextPart(part.id)
            // Repeated snapshots normally differ only in their growing text,
            // which belongs to the projection rather than `parts`. Avoid an
            // O(parts) index rebuild for every such snapshot while still
            // honoring a visibility change from the server.
            if parts[index].synthetic != placeholder.synthetic
                || parts[index].ignored != placeholder.ignored {
                mutatePartsWithoutRebuilding {
                    parts[index] = placeholder
                }
            }
            return false
        }

        // Do not retain a potentially unbounded sequence of protocol text
        // parts the server has explicitly marked as synthetic or ignored.
        guard part.isRenderableText else {
            invalidateStreamingMaterialization()
            suppressStreamingTextPart(part.id)
            return false
        }
        restoreStreamingTextPart(part.id)
        mutatePartsWithoutRebuilding {
            parts.append(placeholder)
        }
        // The empty placeholder has no row yet. Its first projection flush
        // performs the one real timeline rebuild, batched with any siblings.
        return false
    }

    /// Supports a text delta that arrives before its accompanying part
    /// snapshot. The placeholder gains its canonical metadata later, while
    /// its projection and row identity remain stable.
    func registerStreamingTextPart(
        id partID: String,
        sessionID: String,
        messageID: String
    ) {
        guard partIndexByID[partID] == nil,
              !suppressedStreamingTextPartIDs.contains(partID) else {
            return
        }
        _ = registerStreamingTextPart(
            OCPart(
                id: partID,
                sessionID: sessionID,
                messageID: messageID,
                type: .text
            )
        )
    }

    /// Turns each contiguous legacy no-`partID` text run into an ordered
    /// terminal slot. A tool between two such deltas creates a new projection
    /// after the tool instead of appending the second delta to the old row.
    @discardableResult
    func registerStreamingFallbackTextPart() -> String? {
        guard isStreaming, role == .assistant else { return nil }

        if let fallbackTextPartID,
           let index = partIndexByID[fallbackTextPartID],
           parts.indices.contains(index),
           parts[index].type == .text,
           parts[index].isRenderableText,
           index == parts.index(before: parts.endIndex),
           textProjections[fallbackTextPartID] != nil {
            return fallbackTextPartID
        }

        // The previous fallback remains in the ordered transcript. It simply
        // stops being the active terminal target for subsequent no-partID
        // deltas once another visible part follows it.
        fallbackTextPartID = nil
        let partID = nextStreamingFallbackTextPartID()
        let projection: StreamingTextProjection
        if partID == "content-text-\(id)" {
            // Keep the original compatibility projection for the first slot,
            // preserving the cheap legacy path and any pre-existing content.
            projection = streamingTextProjection
        } else {
            projection = StreamingTextProjection(id: partID)
        }

        mutatePartsWithoutRebuilding {
            parts.append(
                OCPart(
                    id: partID,
                    sessionID: "",
                    messageID: id,
                    type: .text
                )
            )
        }
        fallbackTextPartID = partID
        textProjections[partID] = projection
        return partID
    }

    private func nextStreamingFallbackTextPartID() -> String {
        let baseID = "content-text-\(id)"
        guard partIndexByID[baseID] != nil else { return baseID }

        var suffix = 1
        while partIndexByID["\(baseID)-\(suffix)"] != nil {
            suffix += 1
        }
        return "\(baseID)-\(suffix)"
    }

    /// Replaces only one text-part projection before its authoritative
    /// snapshot is replayed through ChatClient's bounded mailbox.
    func resetStreamingTextProjection(partID: String) {
        guard isStreaming,
              let part = part(withID: partID),
              part.type == .text else {
            return
        }
        _ = textProjection(
            for: partID,
            text: "",
            chunks: [],
            synchronizing: true
        )
    }

    /// Appends one bounded batch to the projection associated with a text
    /// part. Returns true only when the row becomes visible for the first
    /// time and the flattened timeline needs one structural rebuild.
    @discardableResult
    func appendStreamingText(
        partID: String,
        text: String,
        chunks: [String]? = nil,
        rebuildDerivedStateImmediately: Bool = true
    ) -> Bool {
        guard isStreaming,
              let part = part(withID: partID),
              part.type == .text,
              part.isRenderableText else {
            return false
        }

        let hasChunks = chunks?.isEmpty == false
        guard hasChunks || !text.isEmpty else { return false }

        let existingText = part.text ?? ""
        let projection = textProjection(for: partID, text: existingText)
        if let chunks {
            projection.append(chunks: chunks)
        } else {
            projection.append(text)
        }

        if let existingSegment = assistantSegment(withID: partID) {
            // A foreground history refresh may have supplied a static text
            // row before the next live delta arrives. Swap its payload in
            // place once so the same row starts observing this projection.
            if existingSegment.streamingText !== projection {
                _ = replaceAssistantSegment(for: part)
            }
            return false
        }

        guard rebuildDerivedStateImmediately else { return true }
        rebuildDerivedState()
        return assistantSegmentIndexByID[partID] != nil
    }

    func hasLiveStreamingPart(id partID: String, type: OCPartType) -> Bool {
        guard isStreaming,
              let index = partIndexByID[partID],
              parts.indices.contains(index),
              parts[index].type == type else {
            return false
        }
        return type != .text || parts[index].isRenderableText
    }

    func partType(withID partID: String) -> OCPartType? {
        guard let index = partIndexByID[partID], parts.indices.contains(index) else {
            return nil
        }
        return parts[index].type
    }

    func streamingTextProjection(forPartID partID: String) -> StreamingTextProjection? {
        textProjections[partID]
    }

    /// Clears only the small projection containers before an authoritative
    /// reasoning snapshot is replayed through ChatClient's bounded buffer.
    /// The server part remains canonical and is materialized off-main at the
    /// end of the stream.
    func resetStreamingReasoningProjection(partID: String) {
        guard isStreaming,
              let part = part(withID: partID),
              part.type == .reasoning else { return }
        _ = reasoningProjection(
            for: partID,
            text: "",
            chunks: [],
            synchronizing: true
        )
    }

    /// Applies one server snapshot without rebuilding every segment in the
    /// message. Streaming tool updates touch only their own stable timeline row.
    /// Returns whether the flattened timeline must be rebuilt. A growing
    /// reasoning row can update its own projection without changing timeline
    /// identity or structure.
    @discardableResult
    func applyPartUpdate(
        _ part: OCPart,
        textChunks: [String]? = nil,
        questionPayload: PreparedQuestionToolPayload? = nil
    ) -> Bool {
        // File/snapshot/step protocol records never produce a timeline row.
        // Keeping every one in an in-flight assistant message only makes the
        // part index grow and turns a long stream into progressively slower
        // MainActor work.
        guard !shouldDiscardStreamingPart(part) else { return false }

        if isStreaming, role == .assistant, part.type == .text {
            // Keep only the ordered slot here. Its authoritative snapshot is
            // replayed through a bounded per-part projection by ChatClient.
            return registerStreamingTextPart(part)
        }

        if let questionPayload {
            preparedQuestionToolPayloads[part.id] = questionPayload
        } else {
            preparedQuestionToolPayloads.removeValue(forKey: part.id)
        }
        var trimmedActivityParts = false
        var trimmedReasoningParts = false
        var replacedTextPartWithAnotherType = false
        mutatePartsWithoutRebuilding {
            if let index = partIndexByID[part.id] {
                let previousPart = parts[index]
                let typeChanged = parts[index].type != part.type
                replacedTextPartWithAnotherType = previousPart.type == .text && part.type != .text
                parts[index] = part
                if typeChanged {
                    trimmedActivityParts = trimActivityPartsIfNeeded()
                    trimmedReasoningParts = trimReasoningPartsIfNeeded()
                }
            } else {
                parts.append(part)
                trimmedActivityParts = trimActivityPartsIfNeeded()
                trimmedReasoningParts = trimReasoningPartsIfNeeded()
            }
        }

        if replacedTextPartWithAnotherType {
            invalidateStreamingMaterialization()
            suppressStreamingTextPart(part.id)
            discardStreamingTextProjection(partID: part.id)
        }

        if !isStreaming,
           (part.type == .text || replacedTextPartWithAnotherType) {
            refreshCompletedContentFromRenderableTextParts()
        }

        guard isStreaming, role == .assistant else {
            rebuildDerivedState()
            return true
        }

        // The bounded activity window changed its visible identities. Rebuild
        // once now; subsequent status changes only update their own stable row.
        if trimmedActivityParts || trimmedReasoningParts {
            rebuildDerivedState()
            return true
        }

        if part.type == .reasoning,
           let text = part.text,
           BoundedDisplayPreview.hasVisibleText(text) {
            _ = reasoningProjection(
                for: part.id,
                text: text,
                chunks: textChunks,
                synchronizing: true
            )
            if assistantSegmentIndexByID[part.id] != nil {
                return false
            }
            // A part can be absent from the visible transcript while pending
            // or empty, then become visible after later parts already arrived.
            // Rebuilding this rare structural transition derives its position
            // from `parts`, rather than incorrectly appending it at the end.
            rebuildDerivedState()
            return true
        }

        let replacedStructure = replaceAssistantSegment(for: part)
        return normalizeStreamingPlaceholder() || replacedStructure
    }

    /// Appends a buffered reasoning delta to its individual projection. The
    /// canonical `parts` snapshot is materialized once when streaming ends;
    /// rebuilding its growing String on every tick would defeat the projection.
    @discardableResult
    func appendStreamingReasoning(
        partID: String,
        text: String,
        chunks: [String]? = nil,
        rebuildDerivedStateImmediately: Bool = true
    ) -> Bool {
        guard isStreaming,
              let index = partIndexByID[partID],
              parts[index].type == .reasoning else {
            return false
        }

        let hasChunks = chunks?.isEmpty == false
        guard hasChunks || !text.isEmpty else { return false }

        let existing = parts[index]
        let projection = reasoningProjection(for: partID, text: existing.text ?? "")
        if let chunks {
            projection.append(chunks: chunks)
        } else {
            projection.append(text)
        }

        if assistantSegmentIndexByID[partID] == nil {
            // The first delta can make a previously empty reasoning part
            // visible. The model rebuild is structural but happens only once
            // for that part; it keeps interleaved tools/reasoning in server
            // order.
            if rebuildDerivedStateImmediately {
                rebuildDerivedState()
            }
            return true
        }

        return false
    }

    /// Persists the append-only reasoning projections once, immediately before
    /// a streaming message becomes a completed immutable transcript.
    func materializeStreamingProjections() {
        guard isStreaming else { return }

        applyStreamingMaterialization(
            Self.materialize(streamingMaterializationSnapshot())
        )
    }

    /// Captures lightweight references to the append-only projections. It is
    /// intentionally called on MainActor, while `materialize(_:)` joins those
    /// chunks on a worker queue.
    func streamingMaterializationSnapshot(
        appendingContentChunks: [String] = [],
        appendingTextChunksByPartID: [String: [String]] = [:],
        appendingReasoningChunksByPartID: [String: [String]] = [:]
    ) -> StreamingMaterialization {
        let renderableTextParts = parts.filter { part in
            part.type == .text && part.isRenderableText
        }
        let textPartOrder = renderableTextParts.map(\.id)
        let reasoningPartIDs = Set(parts.compactMap { part in
            part.type == .reasoning ? part.id : nil
        })
        var staticTextByPartID: [String: String] = [:]
        for part in renderableTextParts {
            if let text = part.text {
                staticTextByPartID[part.id] = text
            }
        }
        // A foreground refresh can contribute an already-complete server text
        // part. Its size has not passed through the worker chunker, so avoid a
        // synchronous join on MainActor regardless of its apparent estimate.
        let requiresBackgroundMaterialization = staticTextByPartID.values.contains {
            !$0.isEmpty
        }

        var textChunksByPartID: [String: [String]] = [:]
        var reasoningChunksByPartID: [String: [String]] = [:]
        let fallbackTextPartID = activeStreamingFallbackTextPartID
        let globalProjectionBelongsToTextPart = textProjections.values.contains {
            $0 === streamingTextProjection
        }
        var estimatedCharacterCount = globalProjectionBelongsToTextPart
            ? 0
            : streamingTextProjection.estimatedCharacterCount

        for (partID, projection) in textProjections {
            var chunks = projection.materializationChunks()
            if let additionalChunks = appendingTextChunksByPartID[partID] {
                chunks.append(contentsOf: additionalChunks)
            }
            textChunksByPartID[partID] = chunks
            estimatedCharacterCount += projection.estimatedCharacterCount
        }

        // A final idle event can race the next UI flush. Retain the server
        // placeholder's pending text chunks even if its projection has not
        // yet been instantiated on MainActor.
        for (partID, additionalChunks) in appendingTextChunksByPartID
        where textChunksByPartID[partID] == nil {
            var chunks: [String] = []
            if let existingText = staticTextByPartID[partID], !existingText.isEmpty {
                chunks.append(existingText)
            }
            chunks.append(contentsOf: additionalChunks)
            textChunksByPartID[partID] = chunks
        }

        for (partID, projection) in reasoningProjections {
            var chunks = projection.materializationChunks()
            if let additionalChunks = appendingReasoningChunksByPartID[partID] {
                chunks.append(contentsOf: additionalChunks)
            }
            reasoningChunksByPartID[partID] = chunks
            estimatedCharacterCount += projection.estimatedCharacterCount
        }

        // A final `idle` can arrive before the next UI flush creates a
        // projection for an otherwise valid reasoning part. Retain its server
        // snapshot plus pending suffixes for worker materialization rather
        // than dropping that last buffered update.
        for (partID, additionalChunks) in appendingReasoningChunksByPartID
        where reasoningChunksByPartID[partID] == nil {
            var chunks: [String] = []
            if let existingText = part(withID: partID)?.text, !existingText.isEmpty {
                chunks.append(existingText)
            }
            chunks.append(contentsOf: additionalChunks)
            reasoningChunksByPartID[partID] = chunks
        }

        // Buffered updates are already split on the SSE worker. Estimate from
        // their chunk count instead of traversing the full payload on
        // MainActor. The caller forces a worker finalization whenever it adds
        // buffered chunks, so this is diagnostic rather than a cutoff.
        let extraChunkCount = appendingContentChunks.count
            + appendingTextChunksByPartID.values.reduce(into: 0) { $0 += $1.count }
            + appendingReasoningChunksByPartID.values.reduce(into: 0) { $0 += $1.count }
        estimatedCharacterCount += extraChunkCount * StreamingTextProjection.targetChunkLength

        if let fallbackTextPartID {
            // The compatibility projection is already present in
            // `textChunksByPartID` under its terminal local part. Keeping it
            // out of `contentChunks` avoids both duplicate final content and
            // an invisible suffix after a preceding named text part.
            if !appendingContentChunks.isEmpty {
                textChunksByPartID[fallbackTextPartID, default: []]
                    .append(contentsOf: appendingContentChunks)
            }
        }

        return StreamingMaterialization(
            contentChunks: globalProjectionBelongsToTextPart
                ? []
                : streamingTextProjection.materializationChunks()
                    + (fallbackTextPartID == nil ? appendingContentChunks : []),
            textChunksByPartID: textChunksByPartID,
            textPartOrder: textPartOrder,
            staticTextByPartID: staticTextByPartID,
            reasoningPartIDs: reasoningPartIDs,
            reasoningChunksByPartID: reasoningChunksByPartID,
            estimatedCharacterCount: estimatedCharacterCount,
            requiresBackgroundMaterialization: requiresBackgroundMaterialization
        )
    }

    nonisolated static func materialize(
        _ snapshot: StreamingMaterialization
    ) -> MaterializedStreamingContent {
        var textByPartID = snapshot.staticTextByPartID
        for (partID, chunks) in snapshot.textChunksByPartID {
            let streamedText = chunks.joined()
            if let serverText = snapshot.staticTextByPartID[partID] {
                textByPartID[partID] = resolveStreamingText(
                    serverText: serverText,
                    streamedText: streamedText
                )
            } else {
                textByPartID[partID] = streamedText
            }
        }

        let orderedText = snapshot.textPartOrder
            .compactMap { textByPartID[$0] }
            .joined()
        let fallbackContent = snapshot.contentChunks.joined()
        let content = orderedText.isEmpty ? fallbackContent : orderedText + fallbackContent
        var reasoningTextByPartID: [String: String] = [:]
        var hasVisibleReasoningByPartID: [String: Bool] = [:]

        for (partID, chunks) in snapshot.reasoningChunksByPartID {
            let text = chunks.joined()
            reasoningTextByPartID[partID] = text
            hasVisibleReasoningByPartID[partID] = containsNonWhitespace(text)
        }

        return MaterializedStreamingContent(
            content: content,
            hasVisibleContent: containsNonWhitespace(content),
            textByPartID: textByPartID,
            reasoningTextByPartID: reasoningTextByPartID,
            hasVisibleReasoningByPartID: hasVisibleReasoningByPartID
        )
    }

    func applyStreamingMaterialization(_ materialized: MaterializedStreamingContent) {
        guard isStreaming else { return }

        // The canonical string deliberately lags behind the projection while a
        // response is streaming. The complete value arrives here once, after a
        // worker has joined the chunks, rather than growing on every tick.
        materializedContentHasVisibleText = materialized.hasVisibleContent
        materializedReasoningHasVisibleText = materialized.hasVisibleReasoningByPartID
        appliesStreamingContentUpdate = true
        content = materialized.content
        appliesStreamingContentUpdate = false

        mutatePartsWithoutRebuilding {
            for index in parts.indices where parts[index].type == .text {
                guard let text = materialized.textByPartID[parts[index].id] else { continue }
                parts[index] = parts[index].replacingText(text)
            }
            for index in parts.indices where parts[index].type == .reasoning {
                guard let text = materialized.reasoningTextByPartID[parts[index].id] else { continue }
                parts[index] = parts[index].replacingText(text)
            }
        }
    }

    /// A completed assistant message keeps `content` as a convenient canonical
    /// fallback, but its visible text rows are still governed by `parts`.
    /// When the server retracts a text part after completion, rebuild that
    /// canonical value from the remaining renderable text parts so the old
    /// content cannot reappear as a generic fallback row.
    private func refreshCompletedContentFromRenderableTextParts() {
        guard !isStreaming, role == .assistant else { return }

        let refreshedContent = parts
            .filter { $0.type == .text && $0.isRenderableText }
            .compactMap(\.text)
            .joined()
        guard content != refreshedContent else { return }

        materializedContentHasVisibleText = nil
        content = refreshedContent
    }

    @discardableResult
    func removePart(id partID: String) -> Bool {
        let cachedIndex = partIndexByID[partID]
        let index: Int?
        if let cachedIndex,
           parts.indices.contains(cachedIndex),
           parts[cachedIndex].id == partID {
            index = cachedIndex
        } else {
            // A removal is rare, and it must not fail merely because a
            // foreground reconciliation changed `parts` between incremental
            // updates. The hot append path still uses the O(1) cache.
            index = parts.firstIndex(where: { $0.id == partID })
        }
        guard let index else {
            return false
        }
        let removedPart = parts[index]

        mutatePartsWithoutRebuilding {
            parts.remove(at: index)
        }
        let movedReasoningSummaryAnchor = moveReasoningSummaryAnchor(
            partID,
            to: parts.indices.contains(index) ? parts[index].id : nil
        )
        discardStreamingTextProjection(partID: partID)
        reasoningProjections[partID] = nil
        if removedPart.type == .text {
            invalidateStreamingMaterialization()
            suppressStreamingTextPart(partID)
        }
        if !isStreaming, removedPart.type == .text {
            refreshCompletedContentFromRenderableTextParts()
        }
        materializedReasoningHasVisibleText.removeValue(forKey: partID)
        preparedQuestionToolPayloads.removeValue(forKey: partID)

        guard isStreaming, role == .assistant else {
            rebuildDerivedState()
            return true
        }

        if movedReasoningSummaryAnchor {
            rebuildDerivedState()
            return true
        }

        let removedSegment = removeAssistantSegment(withID: partID)
        return normalizeStreamingPlaceholder() || removedSegment
    }

    func rebuildDerivedState() {
        hasRenderableTextPart = parts.contains { part in
            guard part.type == .text, part.isRenderableText else { return false }
            if isStreaming, let projection = textProjections[part.id] {
                return projection.hasText
            }
            return BoundedDisplayPreview.hasVisibleText(part.text)
        }
        assistantSegments = buildAssistantSegments(hasTextPart: hasRenderableTextPart)
    }

    private func buildAssistantSegments(hasTextPart: Bool) -> [AssistantSegment] {
        guard role == .assistant else { return [] }

        var segments: [AssistantSegment] = []
        let activityVisibility = activityPartVisibility()

        if activityVisibility.hiddenCount > 0 {
            segments.append(activitySummarySegment(hiddenCount: activityVisibility.hiddenCount))
        }

        for part in parts {
            if let hiddenCount = omittedReasoningPartCountsByAnchor[part.id] {
                segments.append(
                    reasoningSummarySegment(anchorPartID: part.id, hiddenCount: hiddenCount)
                )
            }
            if isActivityPart(part),
               let visibleIDs = activityVisibility.visibleIDs,
               !visibleIDs.contains(part.id) {
                continue
            }
            if let segment = assistantSegment(for: part) {
                segments.append(segment)
            }
        }

        if omittedReasoningPartCountAtEnd > 0 {
            // No retained part followed the earliest omitted reasoning update,
            // so its ordered position is the end of the transcript.
            segments.append(
                reasoningSummarySegment(
                    anchorPartID: nil,
                    hiddenCount: omittedReasoningPartCountAtEnd
                )
            )
        }

        if !isStreaming,
           !hasTextPart,
           hasVisibleContent {
            segments.append(AssistantSegment(id: "content-text-\(id)", kind: .text(content)))
        }

        if isStreaming, segments.isEmpty {
            return [
                AssistantSegment(
                    id: "streaming-thinking-\(id)",
                    kind: .reasoning("Thinking...")
                )
            ]
        }

        if segments.isEmpty,
           hasVisibleContent {
            return [AssistantSegment(id: "fallback-text-\(id)", kind: .text(content))]
        }

        return segments
    }

    private func assistantSegment(for part: OCPart) -> AssistantSegment? {
        switch part.type {
        case .text:
            guard part.isRenderableText else { return nil }
            if isStreaming, let projection = textProjections[part.id] {
                guard projection.hasText else { return nil }
                return AssistantSegment(
                    id: part.id,
                    kind: .text(part.text ?? ""),
                    streamingText: projection
                )
            }
            guard let text = part.text,
                  BoundedDisplayPreview.hasVisibleText(text) else { return nil }
            return AssistantSegment(id: part.id, kind: .text(text))

        case .reasoning:
            let text = part.text ?? ""
            let existingProjection = isStreaming ? reasoningProjections[part.id] : nil
            guard hasVisibleReasoningText(partID: part.id, text: text)
                    || existingProjection?.hasText == true
            else { return nil }
            let projection: StreamingTextProjection?
            if isStreaming {
                projection = existingProjection
                    ?? reasoningProjection(for: part.id, text: text, synchronizing: true)
            } else {
                projection = nil
            }
            return AssistantSegment(id: part.id, kind: .reasoning(text), streamingText: projection)

        case .tool:
            if let questionStep = makePersistedQuestionStep(
                from: part,
                payload: preparedQuestionToolPayloads[part.id]
            ) {
                return AssistantSegment(id: part.id, kind: .question(questionStep))
            }

            if let subagentStep = makePersistedSubagentStep(from: part) {
                return AssistantSegment(id: part.id, kind: .subagent(subagentStep))
            }

            guard let step = makePersistedToolStep(from: part) else { return nil }
            return AssistantSegment(id: part.id, kind: .tool(step))

        case .agent,
             .subtask:
            guard let step = makePersistedSubagentStep(from: part) else { return nil }
            return AssistantSegment(id: part.id, kind: .subagent(step))

        case .file,
             .stepStart,
             .stepFinish,
             .snapshot,
             .patch,
             .retry,
             .compaction,
             .unknown:
            return nil
        }
    }

    private func mutatePartsWithoutRebuilding(_ mutation: () -> Void) {
        appliesIncrementalPartUpdate = true
        defer {
            appliesIncrementalPartUpdate = false
            rebuildPartIndex()
        }
        mutation()
    }

    private func part(withID id: String) -> OCPart? {
        guard let index = partIndexByID[id], parts.indices.contains(index) else {
            return nil
        }
        return parts[index]
    }

    private func suppressStreamingTextPart(_ partID: String) {
        guard suppressedStreamingTextPartIDs.insert(partID).inserted else { return }

        suppressedStreamingTextPartIDOrder.append(partID)
        if suppressedStreamingTextPartIDOrder.count > ChatStreamLimit.maximumSuppressedTextPartIDs {
            let oldestPartID = suppressedStreamingTextPartIDOrder.removeFirst()
            suppressedStreamingTextPartIDs.remove(oldestPartID)
        }
    }

    private func invalidateStreamingMaterialization() {
        guard isStreaming else { return }
        streamingMaterializationRevision &+= 1
    }

    private func restoreStreamingTextPart(_ partID: String) {
        guard suppressedStreamingTextPartIDs.remove(partID) != nil else { return }
        suppressedStreamingTextPartIDOrder.removeAll { $0 == partID }
    }

    private func rebuildPartIndex() {
        var indices: [String: Int] = [:]
        indices.reserveCapacity(parts.count)
        for (index, part) in parts.enumerated() {
            // A malformed duplicate must not trap the UI actor. The latest
            // server snapshot is the one an incremental update should replace.
            indices[part.id] = index
        }
        partIndexByID = indices
    }

    private func rebuildAssistantSegmentIndex() {
        var indices: [String: Int] = [:]
        indices.reserveCapacity(assistantSegments.count)
        for (index, segment) in assistantSegments.enumerated() {
            indices[segment.id] = index
        }
        assistantSegmentIndexByID = indices
    }

    private func isActivityPart(_ part: OCPart) -> Bool {
        switch part.type {
        case .tool, .agent, .subtask:
            true
        case .text,
             .reasoning,
             .file,
             .stepStart,
             .stepFinish,
             .snapshot,
             .patch,
             .retry,
             .compaction,
             .unknown:
            false
        }
    }

    /// These protocol records update transient activity state elsewhere, but
    /// `assistantSegment(for:)` can never render them in the transcript. Do
    /// not let a long streaming run retain them just to rebuild an index.
    private func shouldDiscardStreamingPart(_ part: OCPart) -> Bool {
        guard isStreaming, role == .assistant else { return false }

        switch part.type {
        case .file,
             .stepStart,
             .stepFinish,
             .snapshot,
             .patch,
             .retry,
             .compaction,
             .unknown:
            return true
        case .text,
             .reasoning,
             .tool,
             .agent,
             .subtask:
            return false
        }
    }

    @discardableResult
    private func discardPermanentlyNonRenderableStreamingPartsIfNeeded() -> Bool {
        guard isStreaming, role == .assistant else { return false }

        let removedIndices = Set(parts.indices.filter { shouldDiscardStreamingPart(parts[$0]) })
        guard !removedIndices.isEmpty else { return false }

        let removedPartIDs = removedIndices.map { parts[$0].id }
        moveReasoningSummaryAnchorsPastRemovedParts(removedIndices)
        parts = parts.enumerated().compactMap { index, part in
            removedIndices.contains(index) ? nil : part
        }
        discardCachedPartState(for: removedPartIDs)
        return true
    }

    /// Retain only the most recent activity parts. They are display state, not
    /// the canonical server log; a compact row reports how many earlier updates
    /// were summarized. This caps both retained tool payloads and concurrent
    /// subagent shimmer animations.
    @discardableResult
    private func trimActivityPartsIfNeeded() -> Bool {
        let activityIndices = parts.indices.filter { isActivityPart(parts[$0]) }
        let excess = activityIndices.count - ChatStreamLimit.maximumActivityParts
        guard excess > 0 else { return false }

        let removedIndices = Set(activityIndices.prefix(excess))
        let removedPartIDs = removedIndices.map { parts[$0].id }
        moveReasoningSummaryAnchorsPastRemovedParts(removedIndices)
        parts = parts.enumerated().compactMap { index, part in
            removedIndices.contains(index) ? nil : part
        }
        discardCachedPartState(for: removedPartIDs)
        omittedActivityPartCount += removedPartIDs.count
        return true
    }

    /// Keep a bounded number of individual reasoning rows. Small summaries
    /// replace omitted updates at their original transcript positions, so
    /// interleaved tools and visible reasoning do not move.
    @discardableResult
    private func trimReasoningPartsIfNeeded() -> Bool {
        let reasoningIndices = parts.indices.filter { parts[$0].type == .reasoning }
        let excess = reasoningIndices.count - ChatStreamLimit.maximumReasoningParts
        guard excess > 0 else { return false }

        let removedIndices = Set(reasoningIndices.prefix(excess))
        let removedPartIDs = removedIndices.map { parts[$0].id }

        var nextRetainedPartID: String?
        var addedCountsByAnchor: [String: Int] = [:]
        var addedCountAtEnd = 0
        for index in parts.indices.reversed() {
            if removedIndices.contains(index) {
                if let nextRetainedPartID {
                    addedCountsByAnchor[nextRetainedPartID, default: 0] += 1
                } else {
                    addedCountAtEnd += 1
                }
            } else {
                nextRetainedPartID = parts[index].id
            }
        }

        moveReasoningSummaryAnchorsPastRemovedParts(removedIndices)
        parts = parts.enumerated().compactMap { index, part in
            removedIndices.contains(index) ? nil : part
        }
        discardCachedPartState(for: removedPartIDs)
        for (anchor, count) in addedCountsByAnchor {
            omittedReasoningPartCountsByAnchor[anchor, default: 0] += count
        }
        omittedReasoningPartCountAtEnd += addedCountAtEnd
        return true
    }

    private func moveReasoningSummaryAnchorsPastRemovedParts(_ removedIndices: Set<Int>) {
        let anchors = Array(omittedReasoningPartCountsByAnchor.keys)
        for anchor in anchors {
            guard let anchorIndex = parts.firstIndex(where: { $0.id == anchor }),
                  removedIndices.contains(anchorIndex),
                  let count = omittedReasoningPartCountsByAnchor.removeValue(forKey: anchor) else {
                continue
            }

            let nextAnchor = nextRetainedPartID(after: anchorIndex, excluding: removedIndices)
            if let nextAnchor {
                omittedReasoningPartCountsByAnchor[nextAnchor, default: 0] += count
            } else {
                omittedReasoningPartCountAtEnd += count
            }
        }
    }

    @discardableResult
    private func moveReasoningSummaryAnchor(_ anchor: String, to nextAnchor: String?) -> Bool {
        guard let count = omittedReasoningPartCountsByAnchor.removeValue(forKey: anchor) else {
            return false
        }

        if let nextAnchor {
            omittedReasoningPartCountsByAnchor[nextAnchor, default: 0] += count
        } else {
            omittedReasoningPartCountAtEnd += count
        }
        return true
    }

    private func nextRetainedPartID(after index: Int, excluding removedIndices: Set<Int>) -> String? {
        parts.indices.first(where: {
            $0 > index && !removedIndices.contains($0)
        }).map { parts[$0].id }
    }

    private func discardCachedPartState(for partIDs: [String]) {
        for partID in partIDs {
            preparedQuestionToolPayloads.removeValue(forKey: partID)
            discardStreamingTextProjection(partID: partID)
            reasoningProjections.removeValue(forKey: partID)
            materializedReasoningHasVisibleText.removeValue(forKey: partID)
        }
    }

    private func activityPartVisibility() -> (visibleIDs: Set<String>?, hiddenCount: Int) {
        // The normal streaming path physically trims parts before reaching this
        // function, so it avoids a full scan for every tool status update.
        if omittedActivityPartCount > 0 {
            return (nil, omittedActivityPartCount)
        }

        var newestIDs: [String] = []
        newestIDs.reserveCapacity(ChatStreamLimit.maximumActivityParts)
        var totalCount = 0

        for part in parts.reversed() where isActivityPart(part) {
            totalCount += 1
            if newestIDs.count < ChatStreamLimit.maximumActivityParts {
                newestIDs.append(part.id)
            }
        }

        let hiddenCount = max(0, totalCount - ChatStreamLimit.maximumActivityParts)
        guard hiddenCount > 0 else { return (nil, 0) }
        return (Set(newestIDs), hiddenCount)
    }

    private func activitySummarySegment(hiddenCount: Int) -> AssistantSegment {
        let summaryID = "activity-summary-\(id)"
        return AssistantSegment(
            id: summaryID,
            kind: .tool(
                PersistedToolStep(
                    id: summaryID,
                    toolName: "Tools",
                    label: "\(hiddenCount) earlier tool updates summarized",
                    outputPreview: nil,
                    isError: false,
                    toolCategory: .unknown
                )
            )
        )
    }

    private func reasoningSummarySegment(anchorPartID: String?, hiddenCount: Int) -> AssistantSegment {
        let anchorSuffix = anchorPartID.map { "before-\($0)" } ?? "end"
        return AssistantSegment(
            id: "reasoning-summary-\(id)-\(anchorSuffix)",
            kind: .reasoning("\(hiddenCount) earlier reasoning updates summarized")
        )
    }

    private var hasVisibleContent: Bool {
        materializedContentHasVisibleText
            ?? BoundedDisplayPreview.hasVisibleText(content)
    }

    private func hasVisibleReasoningText(partID: String, text: String) -> Bool {
        materializedReasoningHasVisibleText[partID]
            ?? BoundedDisplayPreview.hasVisibleText(text)
    }

    nonisolated private static func containsNonWhitespace(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar)
        }
    }

    /// Resolves a foreground history snapshot and a local append-only stream
    /// off the UI actor. Prefix-compatible values retain the longer source;
    /// a true divergence is an authoritative server replacement.
    nonisolated private static func resolveStreamingText(
        serverText: String,
        streamedText: String
    ) -> String {
        if serverText.hasPrefix(streamedText) {
            return serverText
        }
        if streamedText.hasPrefix(serverText) {
            return streamedText
        }
        return serverText
    }

    private func textProjection(
        for partID: String,
        text: String,
        chunks: [String]? = nil,
        synchronizing: Bool = false
    ) -> StreamingTextProjection {
        if let projection = textProjections[partID] {
            if synchronizing {
                if let chunks {
                    projection.replace(withChunks: chunks)
                } else {
                    projection.replace(with: text)
                }
            }
            return projection
        }

        let projection = StreamingTextProjection(id: partID)
        if let chunks {
            projection.replace(withChunks: chunks)
        } else {
            projection.replace(with: text)
        }
        textProjections[partID] = projection
        return projection
    }

    /// Aligns a live projection with an authoritative history value only when
    /// that value is not an older prefix of the local stream. The projection
    /// retains a shared baseline, avoiding a full join and re-chunk on the UI
    /// actor during this rare recovery path.
    private func synchronizeStreamingTextProjection(
        _ projection: StreamingTextProjection,
        withServerText serverText: String
    ) {
        projection.synchronizeHistoryBaseline(with: serverText)
    }

    private func reasoningProjection(
        for partID: String,
        text: String,
        chunks: [String]? = nil,
        synchronizing: Bool = false
    ) -> StreamingTextProjection {
        if let projection = reasoningProjections[partID] {
            if synchronizing {
                if let chunks {
                    projection.replace(withChunks: chunks)
                } else {
                    projection.replace(with: text)
                }
            }
            return projection
        }

        let projection = StreamingTextProjection(id: partID)
        if let chunks {
            projection.replace(withChunks: chunks)
        } else {
            projection.replace(with: text)
        }
        reasoningProjections[partID] = projection
        return projection
    }

    /// Returns true only when a timeline identity was added or removed. A
    /// replacement at an existing index is observed directly by that row.
    private func replaceAssistantSegment(for part: OCPart) -> Bool {
        let replacement = assistantSegment(for: part)
        if let index = assistantSegmentIndexByID[part.id] {
            if let replacement {
                assistantSegments[index] = replacement
                return false
            } else {
                assistantSegments.remove(at: index)
                return true
            }
        } else if replacement != nil {
            // The part existed but was not visible (for example a pending tool
            // becoming running). Its correct position is derived from the
            // canonical `parts` sequence, never from arrival time.
            rebuildDerivedState()
            return true
        }
        return false
    }

    @discardableResult
    private func removeAssistantSegment(withID id: String) -> Bool {
        guard let index = assistantSegmentIndexByID[id] else { return false }
        assistantSegments.remove(at: index)
        return true
    }

    @discardableResult
    private func normalizeStreamingPlaceholder() -> Bool {
        let thinkingID = "streaming-thinking-\(id)"
        let hasRealSegment = assistantSegments.contains { $0.id != thinkingID }

        if hasRealSegment {
            return removeAssistantSegment(withID: thinkingID)
        } else if assistantSegments.isEmpty {
            assistantSegments = [
                AssistantSegment(id: thinkingID, kind: .reasoning("Thinking..."))
            ]
            return true
        }
        return false
    }

    private func makePersistedToolStep(from part: OCPart) -> PersistedToolStep? {
        guard part.type == .tool,
              let rawToolName = part.tool,
              let state = part.state else { return nil }

        // Server-provided tool identifiers are normally tiny. Retain only a
        // bounded display value before it reaches an assistant segment so a
        // malformed name cannot become a rendering or categorization cost.
        let toolName = BoundedDisplayPreview.make(
            from: rawToolName,
            limit: ChatDisplayLimit.toolName
        ) ?? "Tool"
        let normalizedName = toolName.lowercased()
        guard normalizedName != "question" else { return nil }

        switch state.status {
        case .pending, .unknown:
            return nil
        case .running, .completed, .error:
            let isTodoTool = normalizedName.contains("todo")
            let usesInlineDetail = ["read", "write", "edit"].contains(normalizedName)
            let inlineDetailPreview = usesInlineDetail
                ? toolPathPreview(from: state)
                : nil
            let outputPreview = isTodoTool
                ? nil
                : inlineDetailPreview
                    ?? ToolOutputPreview.make(from: state.output)
                    ?? ToolOutputPreview.make(from: state.error)

            return PersistedToolStep(
                id: part.id,
                toolName: toolName,
                label: ToolLabelFormatter.label(toolName: toolName, state: state),
                outputPreview: outputPreview,
                isError: state.status == .error,
                toolCategory: ToolCategory.from(toolName: toolName)
            )
        }
    }

    private func toolPathPreview(from state: OCToolState) -> String? {
        guard let input = state.input?.value as? [String: Any] else { return nil }
        return ToolOutputPreview.make(from: input["filePath"] as? String)
            ?? ToolOutputPreview.make(from: input["path"] as? String)
    }

    private func makePersistedQuestionStep(
        from part: OCPart,
        payload: PreparedQuestionToolPayload? = nil
    ) -> PersistedQuestionStep? {
        guard part.type == .tool,
              normalizedToolName(part.tool) == "question",
              let state = part.state else { return nil }

        guard state.status != .unknown else { return nil }

        return PersistedQuestionStep(
            id: part.id,
            questions: payload?.questions ?? questionInfos(from: state.input),
            answers: payload?.answers ?? questionAnswers(from: state.metadata),
            status: state.status,
            isError: state.status == .error
        )
    }

    private func makePersistedSubagentStep(from part: OCPart) -> PersistedSubagentStep? {
        let taskState = subagentToolState(from: part)
        guard part.type == .agent || part.type == .subtask || taskState != nil else { return nil }

        let taskInput = taskState?.input?.value as? [String: Any]
        let agentName = subagentName(from: part)
            ?? taskInputDisplayValue(
                in: taskInput,
                keys: ["subagent_type", "agent", "agentID", "name"],
                limit: ChatDisplayLimit.subagentTitle
            )
        let description = boundedDisplayValue(
            part.partDescription,
            limit: ChatDisplayLimit.subagentDetail
        ) ?? taskInputDisplayValue(
            in: taskInput,
            keys: ["description", "task"],
            limit: ChatDisplayLimit.subagentDetail
        )
        let prompt = boundedDisplayValue(
            part.prompt,
            limit: ChatDisplayLimit.subagentPrompt
        ) ?? taskInputDisplayValue(
            in: taskInput,
            keys: ["prompt", "message"],
            limit: ChatDisplayLimit.subagentPrompt
        )
        let source = boundedStringValue(from: part.source, limit: ChatDisplayLimit.subagentDetail)
        let stateTitle = boundedDisplayValue(taskState?.title, limit: ChatDisplayLimit.subagentDetail)
        let stateError = boundedDisplayValue(taskState?.error, limit: ChatDisplayLimit.subagentDetail)
        let fallbackName = boundedDisplayValue(part.name, limit: ChatDisplayLimit.subagentTitle)

        let title = agentName ?? fallbackName ?? "Subagent"
        let detail = description ?? prompt ?? stateTitle ?? source ?? stateError ?? ""

        guard title != "Subagent" || !detail.isEmpty else { return nil }

        return PersistedSubagentStep(
            id: part.id,
            agentName: agentName,
            title: title,
            detail: detail,
            prompt: prompt,
            isCompleted: isSubagentPartCompleted(part, taskState: taskState),
            isError: taskState?.status == .error,
            cost: part.cost
        )
    }

    private func subagentToolState(from part: OCPart) -> OCToolState? {
        guard part.type == .tool,
              normalizedToolName(part.tool) == "task",
              let state = part.state else { return nil }
        return state
    }

    private func isSubagentPartCompleted(_ part: OCPart, taskState: OCToolState?) -> Bool {
        if let taskState {
            return taskState.status == .completed || taskState.status == .error
        }

        return !isStreaming || part.cost != nil || part.tokens != nil || hasEndTime(part.time)
    }

    private func hasEndTime(_ time: AnyCodable?) -> Bool {
        guard let dictionary = time?.value as? [String: Any] else { return false }
        return dictionary["end"] != nil || dictionary["completed"] != nil
    }

    private func subagentName(from part: OCPart) -> String? {
        boundedDisplayValue(part.name, limit: ChatDisplayLimit.subagentTitle)
            ?? boundedStringValue(from: part.agent, limit: ChatDisplayLimit.subagentTitle)
            ?? dictionaryDisplayValue(for: "name", in: part.agent, limit: ChatDisplayLimit.subagentTitle)
            ?? dictionaryDisplayValue(for: "id", in: part.agent, limit: ChatDisplayLimit.subagentTitle)
            ?? dictionaryDisplayValue(for: "title", in: part.agent, limit: ChatDisplayLimit.subagentTitle)
    }

    private func normalizedToolName(_ toolName: String?) -> String? {
        boundedDisplayValue(toolName, limit: ChatDisplayLimit.toolName)?.lowercased()
    }

    private func boundedDisplayValue(_ text: String?, limit: Int) -> String? {
        BoundedDisplayPreview.make(from: text, limit: limit)
    }

    private func boundedStringValue(from value: AnyCodable?, limit: Int) -> String? {
        boundedDisplayValue(value?.value as? String, limit: limit)
    }

    private func taskInputDisplayValue(
        in input: [String: Any]?,
        keys: [String],
        limit: Int
    ) -> String? {
        guard let input else { return nil }

        for key in keys {
            if let value = boundedDisplayValue(input[key] as? String, limit: limit) {
                return value
            }
        }

        return nil
    }

    private func dictionaryDisplayValue(for key: String, in value: AnyCodable?, limit: Int) -> String? {
        guard let dictionary = value?.value as? [String: Any] else { return nil }
        return boundedDisplayValue(dictionary[key] as? String, limit: limit)
    }

    private func questionInfos(from input: AnyCodable?) -> [OCQuestionInfo] {
        guard let rawInput = input?.value else { return [] }

        let compatibleInput = jsonCompatibleValue(rawInput)
        let rawQuestions: Any?
        if let input = compatibleInput as? [String: Any] {
            rawQuestions = input["questions"]
        } else {
            rawQuestions = compatibleInput
        }

        guard let rawQuestions else { return [] }
        let compatibleQuestions = jsonCompatibleValue(rawQuestions)
        guard JSONSerialization.isValidJSONObject(compatibleQuestions),
              let data = try? JSONSerialization.data(withJSONObject: compatibleQuestions),
              let questions = try? JSONDecoder().decode([OCQuestionInfo].self, from: data) else {
            return []
        }

        return questions
    }

    private func questionAnswers(from metadata: [String: AnyCodable]?) -> [[String]] {
        guard let rawAnswers = metadata?["answers"]?.value else { return [] }
        return answerRows(from: rawAnswers)
    }

    private func answerRows(from value: Any) -> [[String]] {
        let compatibleValue = jsonCompatibleValue(value)

        if let rows = compatibleValue as? [[String]] {
            return rows
                .map(normalizedAnswerStrings)
                .filter { !$0.isEmpty }
        }

        if let rows = compatibleValue as? [[Any]] {
            return rows
                .map(answerStrings)
                .filter { !$0.isEmpty }
        }

        if let row = compatibleValue as? [String] {
            let answers = normalizedAnswerStrings(row)
            return answers.isEmpty ? [] : [answers]
        }

        if let values = compatibleValue as? [Any] {
            let containsNestedRows = values.contains { $0 is [Any] || $0 is [String] }
            if containsNestedRows {
                return values
                    .map(answerStrings)
                    .filter { !$0.isEmpty }
            }

            let answers = answerStrings(values)
            return answers.isEmpty ? [] : [answers]
        }

        if let answer = answerString(compatibleValue) {
            return [[answer]]
        }

        return []
    }

    private func answerStrings(_ value: Any) -> [String] {
        if let values = value as? [String] {
            return normalizedAnswerStrings(values)
        }

        if let values = value as? [Any] {
            return values.compactMap(answerString)
        }

        return answerString(value).map { [$0] } ?? []
    }

    private func normalizedAnswerStrings(_ values: [String]) -> [String] {
        values.compactMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank }
    }

    private func answerString(_ value: Any) -> String? {
        (value as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfBlank
    }

    private func jsonCompatibleValue(_ value: Any) -> Any {
        switch value {
        case let wrapped as AnyCodable:
            return jsonCompatibleValue(wrapped.value)
        case let array as [AnyCodable]:
            return array.map { jsonCompatibleValue($0.value) }
        case let dictionary as [String: AnyCodable]:
            return dictionary.mapValues { jsonCompatibleValue($0.value) }
        case let array as [Any]:
            return array.map(jsonCompatibleValue)
        case let dictionary as [String: Any]:
            return dictionary.mapValues(jsonCompatibleValue)
        default:
            return value
        }
    }
}

/// A display-only projection of server-backed chat messages.
///
/// Assistant segments deliberately preserve `ChatMessage.assistantSegments` order,
/// which is built from the REST/SSE `parts` array. These are not persisted or
/// independently reordered client-side; they merely let SwiftUI render each server
/// part as its own stable chat row.
struct ChatTimelineItem: Identifiable {
    enum Content {
        case message(ChatMessage)
        case assistantSegment(message: ChatMessage, segment: ChatMessage.AssistantSegment)
        case streamingAssistantText(
            message: ChatMessage,
            projection: ChatMessage.StreamingTextProjection
        )
    }

    let id: String
    let content: Content
    /// At most one visible subagent gets a repeating shimmer. Other active
    /// rows still communicate their state statically, avoiding a render loop
    /// per tool when an agent fan-outs many tasks.
    let animatesSubagentStatus: Bool

    init(
        id: String,
        content: Content,
        animatesSubagentStatus: Bool = false
    ) {
        self.id = id
        self.content = content
        self.animatesSubagentStatus = animatesSubagentStatus
    }
}

enum ChatTimeline {
    static func items(
        from messages: [ChatMessage],
        showsThinking: Bool
    ) -> [ChatTimelineItem] {
        let animatedSubagent = messages.reversed().lazy.compactMap { message -> (messageID: String, segmentID: String)? in
            guard let segment = message.assistantSegments.reversed().first(where: { segment in
                guard case .subagent(let step) = segment.kind else { return false }
                return step.isActive
            }) else {
                return nil
            }
            return (message.id, segment.id)
        }.first

        return messages.flatMap { message -> [ChatTimelineItem] in
            guard message.role == .assistant else {
                return [
                    ChatTimelineItem(
                        id: "message-\(message.id)",
                        content: .message(message)
                    )
                ]
            }

            var items = message.assistantSegments
                .filter { segment in
                    if case .reasoning = segment.kind {
                        return showsThinking
                    }
                    return true
                }
                .map { segment in
                    ChatTimelineItem(
                        id: "message-\(message.id)-part-\(segment.id)",
                        content: .assistantSegment(message: message, segment: segment),
                        animatesSubagentStatus: animatedSubagent?.messageID == message.id
                            && animatedSubagent?.segmentID == segment.id
                    )
                }

            if message.isStreaming,
               !message.hasRenderableTextPart,
               message.streamingTextProjection.hasText {
                items.append(
                    ChatTimelineItem(
                        // Matches the completed fallback segment ID so the streaming
                        // text row keeps its SwiftUI identity through markdown handoff.
                        id: "message-\(message.id)-part-content-text-\(message.id)",
                        content: .streamingAssistantText(
                            message: message,
                            projection: message.streamingTextProjection
                        )
                    )
                )
            }

            return items
        }
    }
}

extension OCPart {
    func replacingText(_ text: String?) -> OCPart {
        OCPart(
            id: id,
            sessionID: sessionID,
            messageID: messageID,
            type: type,
            text: text,
            synthetic: synthetic,
            ignored: ignored,
            metadata: metadata,
            time: time,
            callID: callID,
            tool: tool,
            state: state,
            mime: mime,
            filename: filename,
            url: url,
            source: source,
            snapshot: snapshot,
            hash: hash,
            files: files,
            name: name,
            reason: reason,
            cost: cost,
            tokens: tokens,
            prompt: prompt,
            partDescription: partDescription,
            agent: agent,
            attempt: attempt,
            retryError: retryError,
            auto: auto
        )
    }
}
