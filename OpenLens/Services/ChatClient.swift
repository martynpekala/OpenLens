import SwiftUI
import UIKit
import os

enum ChatResponseState: Equatable {
    case idle
    case generating
    case stopping
    case stopped
    case failed
}

/// Thin coordinator for the chat interface.
/// Delegates all IO to domain services (MessagesService, ProvidersService,
/// QuestionService, SessionsService). Keeps UI state and orchestration only.
@MainActor @Observable
final class ChatClient: SSEEventHandlerDelegate {

    // MARK: - Published State

    /// The canonical message list. Because `ChatMessage` is now an `@Observable` class,
    /// mutations to individual message properties (content, isStreaming, parts) do NOT
    /// trigger array-level observation — only views reading that specific message re-render.
    ///
    /// Only structural changes (append, remove, reorder) trigger `didSet` / ForEach re-diff.
    var messages: [ChatMessage] = [] {
        didSet { rebuildDisplayedMessages() }
    }
    var inputText: String = ""
    var isLoading: Bool = false
    var responseState: ChatResponseState = .idle
    var errorMessage: String?

    /// Incremented when the chat should programmatically snap to the bottom.
    var scrollAnchor: UInt = 0

    /// Incremented when message content changes and the scroll view may need to
    /// update layout without forcing a scroll jump on every streaming flush.
    var contentVersion: UInt = 0

    /// Changes only when the flattened timeline has to be materialized again
    /// (messages/parts/visibility changed). Text-tail flushes intentionally do
    /// not touch it: their dedicated projection rows update in place.
    var timelineVersion: UInt = 0

    /// Current session being viewed.
    var currentSession: OCSession?

    /// Agent activity tracker for shimmer display.
    var currentActivity: AgentActivity?
    var lastCompletedActivity: AgentActivity?
    var showActivityCard: Bool = false

    /// Assistant message being built during streaming. Kept separate from
    /// `messages` so SSE handlers can mutate it freely. Included at the tail
    /// of `displayedMessages` so the UI shows the growing text bubble.
    /// Committed to `messages` on `finishLoading()`.
    var pendingAssistantMessage: ChatMessage? {
        didSet { rebuildDisplayedMessages() }
    }

    /// Session status from SSE.
    var sessionStatus: OCSessionStatus?

    /// Pending permission request from the server.
    var pendingPermission: OCPermissionRequest? {
        didSet { syncLiveActivityPendingUserResponse() }
    }
    var showPermissionAlert: Bool = false

    /// Pending question request from the server (interactive choices).
    var pendingQuestion: OCQuestionRequest? {
        didSet { syncLiveActivityPendingUserResponse() }
    }
    var showQuestionSheet: Bool = false
    var isRecordingStream: Bool = false

    /// Active todo list from the server (updated via `todo.updated` SSE event).
    var todos: [OCTodo] = []
    /// Number of server todos omitted from the bounded chat presentation.
    var hiddenTodoCount: Int = 0

    // MARK: - Model Selection

    var providers: [OCProvider] = [] {
        didSet { rebuildAvailableModels() }
    }
    var connectedProviderIDs: [String] = [] {
        didSet { rebuildAvailableModels() }
    }
    var selectedProviderID: String = "" {
        didSet { refreshSelectedModelState() }
    }
    var selectedModelID: String = "" {
        didSet { refreshSelectedModelState() }
    }
    var selectedVariant: String?
    var isLoadingProviders: Bool = false
    private var preferredDefaultProviderID: String = ""
    private var preferredDefaultModelID: String = ""
    private var serverReportedDefault: (providerID: String, modelID: String)?
    private var configReportedDefault: (providerID: String, modelID: String)?

    /// Provider filter lists from server config (enabled_providers / disabled_providers).
    private var enabledProviders: [String]? {
        didSet { rebuildAvailableModels() }
    }
    private var disabledProviders: [String]? {
        didSet { rebuildAvailableModels() }
    }
    private var availableSlashCommandMap: [String: String] = [:]
    private var availableSlashAgentMap: [String: String] = [:]

    struct ContextUsageSummary {
        let usedTokens: Int
        let limitTokens: Int?
        let usagePercent: Int?
        let modelLabel: String?
    }

    /// A flat list of selectable models from connected providers.
    struct SelectableModel: Identifiable, Hashable {
        struct SelectableVariant: Identifiable, Hashable {
            let id: String
            let value: OCProviderVariant

            var displayName: String {
                switch id.lowercased() {
                case "none": "Off"
                case "minimal": "Minimal"
                case "low": "Low"
                case "medium": "Medium"
                case "high": "High"
                case "xhigh": "X-High"
                case "max": "Max"
                default:
                    id
                        .replacingOccurrences(of: "-", with: " ")
                        .replacingOccurrences(of: "_", with: " ")
                        .capitalized
                }
            }
        }

        let providerID: String
        let providerName: String
        let modelID: String
        let modelName: String
        let reasoning: Bool
        let attachment: Bool
        let toolCall: Bool
        let cost: OCModelCost?
        let limit: OCModelLimit?
        let variants: [SelectableVariant]
        var id: String { "\(providerID)/\(modelID)" }

        // Hashable conformance ignoring cost/limit (non-Hashable)
        func hash(into hasher: inout Hasher) {
            hasher.combine(id)
        }

        static func == (lhs: SelectableModel, rhs: SelectableModel) -> Bool {
            lhs.id == rhs.id
        }
    }

    private(set) var availableModels: [SelectableModel] = [] {
        didSet { refreshSelectedModelState() }
    }

    private(set) var selectedModel: SelectableModel?

    private(set) var availableReasoningVariants: [SelectableModel.SelectableVariant] = []

    var showsThinkingEffortPicker: Bool {
        !availableReasoningVariants.isEmpty
    }

    var selectedVariantDisplayName: String {
        guard let selectedVariant,
              let variant = availableReasoningVariants.first(where: { $0.id == selectedVariant }) else {
            return AppText.thinkingDefault
        }
        return variant.displayName
    }

    private func persistCurrentSelection() {
        guard let connID = savedConnectionsStore?.activeConnectionID,
              !selectedProviderID.isEmpty,
              !selectedModelID.isEmpty else { return }

        savedConnectionsStore?.updateModelSelection(
            connectionID: connID,
            providerID: selectedProviderID,
            modelID: selectedModelID,
            variant: selectedVariant
        )
    }

    private func persistDefaultModelSelection(providerID: String, modelID: String) {
        guard let connID = savedConnectionsStore?.activeConnectionID else { return }
        savedConnectionsStore?.updateDefaultModelSelection(
            connectionID: connID,
            providerID: providerID,
            modelID: modelID
        )
    }

    private func clearDefaultModelSelection() {
        guard let connID = savedConnectionsStore?.activeConnectionID else { return }
        savedConnectionsStore?.clearDefaultModelSelection(connectionID: connID)
    }

    private func sortedVariants(from variants: [String: OCProviderVariant]?) -> [SelectableModel.SelectableVariant] {
        guard let variants else { return [] }

        return variants
            .map { SelectableModel.SelectableVariant(id: $0.key, value: $0.value) }
            .sorted { lhs, rhs in
                let lhsOrder = variantSortOrder(lhs.id)
                let rhsOrder = variantSortOrder(rhs.id)
                if lhsOrder == rhsOrder {
                    return lhs.id.localizedCaseInsensitiveCompare(rhs.id) == .orderedAscending
                }
                return lhsOrder < rhsOrder
            }
    }

    private func variantSortOrder(_ variantID: String) -> Int {
        switch variantID.lowercased() {
        case "none": 0
        case "minimal": 1
        case "low": 2
        case "medium": 3
        case "high": 4
        case "xhigh": 5
        case "max": 6
        default: 100
        }
    }

    private func rebuildAvailableModels() {
        var activeProviders = connectedProviderIDs.isEmpty
            ? providers
            : providers.filter { connectedProviderIDs.contains($0.id) }

        if let enabledProviders, !enabledProviders.isEmpty {
            activeProviders = activeProviders.filter { enabledProviders.contains($0.id) }
        }

        if let disabledProviders, !disabledProviders.isEmpty {
            activeProviders = activeProviders.filter { !disabledProviders.contains($0.id) }
        }

        availableModels = activeProviders.flatMap { provider in
            provider.modelList.map { model in
                SelectableModel(
                    providerID: provider.id,
                    providerName: provider.name,
                    modelID: model.id,
                    modelName: model.name.isEmpty ? model.id : model.name,
                    reasoning: model.reasoning ?? false,
                    attachment: model.attachment ?? false,
                    toolCall: model.toolCall ?? false,
                    cost: model.cost,
                    limit: model.limit,
                    variants: sortedVariants(from: model.variants)
                )
            }
        }
    }

    private func refreshSelectedModelState() {
        selectedModel = availableModels.first {
            $0.providerID == selectedProviderID && $0.modelID == selectedModelID
        }
        availableReasoningVariants = selectedModel?.variants.filter {
            $0.value.isThinkingEffortVariant
        } ?? []
    }

    var defaultModelSelection: (providerID: String, modelID: String)? {
        guard let activeConnectionID = savedConnectionsStore?.activeConnectionID else { return nil }
        return savedConnectionsStore?.defaultModelSelection(connectionID: activeConnectionID)
    }

    private func applyPreferredDefaultModelSelection() {
        guard !preferredDefaultProviderID.isEmpty, !preferredDefaultModelID.isEmpty else { return }
        selectedProviderID = preferredDefaultProviderID
        selectedModelID = preferredDefaultModelID
        selectedVariant = nil
    }

    private func refreshPreferredDefaultModelSelection() {
        let resolution = Self.resolveDefaultModelSelection(
            savedDefault: defaultModelSelection,
            serverDefault: serverReportedDefault,
            configDefault: configReportedDefault,
            availableModels: availableModels
        )

        preferredDefaultProviderID = resolution.providerID ?? ""
        preferredDefaultModelID = resolution.modelID ?? ""

        if let unavailableDefaultModelID = resolution.unavailableDefaultModelID {
            errorMessage = AppText.defaultModelUnavailable(unavailableDefaultModelID)
        }
    }

    func isDefaultModel(_ model: SelectableModel) -> Bool {
        guard let selection = defaultModelSelection else { return false }
        return selection.providerID == model.providerID && selection.modelID == model.modelID
    }

    var selectedModelRef: OCPromptInput.OCModelRef? {
        guard !selectedProviderID.isEmpty, !selectedModelID.isEmpty else { return nil }
        return OCPromptInput.OCModelRef(providerID: selectedProviderID, modelID: selectedModelID)
    }

    var selectedModelCommandValue: String? {
        guard !selectedProviderID.isEmpty, !selectedModelID.isEmpty else { return nil }
        return "\(selectedProviderID)/\(selectedModelID)"
    }

    var selectedModelDisplayName: String {
        if let model = selectedModel {
            return model.modelName
        }
        if !selectedModelID.isEmpty {
            return selectedModelID
        }
        return "Choose model"
    }

    struct DefaultModelResolution: Equatable {
        let providerID: String?
        let modelID: String?
        let unavailableDefaultModelID: String?
    }

    static func resolveDefaultModelSelection(
        savedDefault: (providerID: String, modelID: String)?,
        serverDefault: (providerID: String, modelID: String)?,
        configDefault: (providerID: String, modelID: String)?,
        availableModels: [SelectableModel]
    ) -> DefaultModelResolution {
        let availableIDs = Set(availableModels.map(\.id))

        func isAvailable(providerID: String, modelID: String) -> Bool {
            availableIDs.contains("\(providerID)/\(modelID)")
        }

        if let savedDefault {
            if isAvailable(providerID: savedDefault.providerID, modelID: savedDefault.modelID) {
                return DefaultModelResolution(
                    providerID: savedDefault.providerID,
                    modelID: savedDefault.modelID,
                    unavailableDefaultModelID: nil
                )
            }

            if let serverDefault,
               isAvailable(providerID: serverDefault.providerID, modelID: serverDefault.modelID) {
                return DefaultModelResolution(
                    providerID: serverDefault.providerID,
                    modelID: serverDefault.modelID,
                    unavailableDefaultModelID: savedDefault.modelID
                )
            }

            if let configDefault,
               isAvailable(providerID: configDefault.providerID, modelID: configDefault.modelID) {
                return DefaultModelResolution(
                    providerID: configDefault.providerID,
                    modelID: configDefault.modelID,
                    unavailableDefaultModelID: savedDefault.modelID
                )
            }

            return DefaultModelResolution(
                providerID: nil,
                modelID: nil,
                unavailableDefaultModelID: savedDefault.modelID
            )
        }

        if let serverDefault,
           isAvailable(providerID: serverDefault.providerID, modelID: serverDefault.modelID) {
            return DefaultModelResolution(
                providerID: serverDefault.providerID,
                modelID: serverDefault.modelID,
                unavailableDefaultModelID: nil
            )
        }

        if let configDefault,
           isAvailable(providerID: configDefault.providerID, modelID: configDefault.modelID) {
            return DefaultModelResolution(
                providerID: configDefault.providerID,
                modelID: configDefault.modelID,
                unavailableDefaultModelID: nil
            )
        }

        return DefaultModelResolution(
            providerID: nil,
            modelID: nil,
            unavailableDefaultModelID: nil
        )
    }

    // MARK: - Pagination

    var displayLimit: Int = 15 {
        didSet { rebuildDisplayedMessages() }
    }
    private let pageSize: Int = 15

    var displayedMessages: [ChatMessage] = []

    var hasEarlierMessages: Bool {
        messages.count > displayLimit
    }

    func loadEarlierMessages() {
        displayLimit += pageSize
    }

    private func rebuildDisplayedMessages() {
        var result: [ChatMessage]
        if messages.count <= displayLimit {
            result = messages
        } else {
            result = Array(messages.suffix(displayLimit))
        }
        // Append the in-flight streaming message so it's visible in the chat.
        if let pending = pendingAssistantMessage {
            result.append(pending)
        }
        displayedMessages = result
        timelineVersion &+= 1
    }

    // MARK: - Demo Mode

    /// When true, `send()` replays a demo script instead of hitting the network.
    @ObservationIgnored let isDemoMode: Bool

    @ObservationIgnored private let recordedReplay: RecordedChatReplay?
    @ObservationIgnored private let recordedReplayPlaybackMode: RecordedReplayPlayer.PlaybackMode?

    /// Script used by preview/demo chat modes.
    @ObservationIgnored private let demoScript: DemoScript

    /// Replays demo scripts when `isDemoMode` is true.
    @ObservationIgnored private var demoPlayer: DemoPlayer?
    @ObservationIgnored private var recordedReplayPlayer: RecordedReplayPlayer?

    // MARK: - Services (injected)

    @ObservationIgnored private let sessionsService: SessionsService?
    @ObservationIgnored private let messagesService: MessagesService?
    @ObservationIgnored private let providersService: ProvidersService?
    @ObservationIgnored private let questionService: QuestionService?
    @ObservationIgnored private let connection: ConnectionManager?
    @ObservationIgnored private let savedConnectionsStore: SavedConnectionsStore?
    @ObservationIgnored private let recordedReplayStore: RecordedReplayStore?

    var isRecordedReplayMode: Bool { recordedReplay != nil }
    var isOfflinePreviewMode: Bool { isDemoMode || isRecordedReplayMode }
    var isConnected: Bool { connection?.isConnected ?? isOfflinePreviewMode }
    var canCompose: Bool { !isRecordedReplayMode }
    var showsComposer: Bool { !isRecordedReplayMode }
    var isStoppingResponse: Bool { responseState == .stopping }
    var supportsStreamRecording: Bool {
    #if DEBUG
        FeatureFlags.debugFeaturesEnabled && !isOfflinePreviewMode && recordedReplayStore != nil
    #else
        false
    #endif
    }

    // MARK: - Collaborators

    @ObservationIgnored private let haptics: HapticController
    @ObservationIgnored private let liveActivityTracker: LiveActivityTracker?
    @ObservationIgnored private let sseHandler: SSEEventHandler?

    /// Active question timeout task (auto-rejects if user doesn't respond).
    @ObservationIgnored private var questionTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var responseStartDate: Date?
    @ObservationIgnored private var streamRecorder: ChatStreamRecorder?
    @ObservationIgnored private var abortTask: Task<Void, Never>?
    @ObservationIgnored private var stoppedStateClearTask: Task<Void, Never>?
    @ObservationIgnored private var ignoredAssistantMessageIDs: Set<String> = []
    @ObservationIgnored private var locallyStoppedSessionID: String?

    /// Duration before a pending question is auto-rejected (5 minutes).
    private static let questionTimeoutSeconds: UInt64 = 300
    static let stoppedResponseDisplayDuration: Duration = .milliseconds(1500)
    private static let statusRefreshIdleGraceInterval: TimeInterval = 1.5

    // MARK: - Streaming Text Buffer
    //
    // Text deltas from SSE accumulate in a lightweight projection on the
    // pending message. A flush timer coalesces rapid deltas into ~40ms UI updates, bumping

    var contextUsageSummary: ContextUsageSummary? {
        guard let sourceMessage = latestAssistantMessageWithUsage(),
              let tokens = sourceMessage.tokens else { return nil }

        let usedTokens = tokens.totalIncludingCache
        guard usedTokens > 0 else { return nil }

        let limitTokens = modelLimit(providerID: sourceMessage.providerID, modelID: sourceMessage.modelID)
        let usagePercent = contextUsagePercent(usedTokens: usedTokens, limitTokens: limitTokens)

        return ContextUsageSummary(
            usedTokens: usedTokens,
            limitTokens: limitTokens,
            usagePercent: usagePercent,
            modelLabel: sourceMessage.modelDisplayName
        )
    }
    // `contentVersion` on each flush so the view can decide whether to scroll.
    // The pending message is visible in `displayedMessages` during streaming
    // and committed to `messages` on `finishLoading()`.

    nonisolated private struct BufferedStreamUpdate: Sendable {
        let messageID: String
        let partID: String?
        /// A slice advances its start index in O(1). This is important for a
        /// large authoritative snapshot: `Array.removeFirst(8)` would shift
        /// every remaining chunk on each UI tick.
        var chunks: ArraySlice<String>
    }

    /// A bounded FIFO for one assistant message's unrendered stream chunks.
    /// Clearing each consumed ring slot is deliberate: keeping an Array cursor
    /// alone retains every already-rendered `ArraySlice` until the turn ends.
    /// The buffer is never shared across actors; its detached value is.
    private final class StreamingUpdateMailbox {
        private let capacity: Int
        private var storage: [BufferedStreamUpdate?] = []
        private var readIndex = 0
        private var writeIndex = 0
        private(set) var recordCount = 0
        private(set) var chunkCount = 0

        init(capacity: Int) {
            precondition(capacity > 0)
            self.capacity = capacity
        }

        var isEmpty: Bool { recordCount == 0 }

        var first: BufferedStreamUpdate? {
            guard recordCount > 0 else { return nil }
            return storage[readIndex]
        }

        @discardableResult
        func append(_ update: BufferedStreamUpdate) -> Bool {
            ensureStorage()
            guard recordCount < capacity else { return false }

            storage[writeIndex] = update
            writeIndex = (writeIndex + 1) % capacity
            recordCount += 1
            chunkCount += update.chunks.count
            return true
        }

        @discardableResult
        func removeFirst() -> BufferedStreamUpdate? {
            guard recordCount > 0, let update = storage[readIndex] else { return nil }

            storage[readIndex] = nil
            readIndex = (readIndex + 1) % capacity
            recordCount -= 1
            chunkCount -= update.chunks.count
            return update
        }

        func replaceFirst(with update: BufferedStreamUpdate) {
            precondition(recordCount > 0)
            guard let previous = storage[readIndex] else {
                preconditionFailure("Streaming mailbox lost its FIFO head")
            }

            chunkCount -= previous.chunks.count
            chunkCount += update.chunks.count
            storage[readIndex] = update
        }

        /// Removing invalidated authoritative snapshots is bounded by the ring
        /// capacity, rather than by the total response size.
        func discard(where predicate: (BufferedStreamUpdate) -> Bool) -> (records: Int, chunks: Int) {
            guard !isEmpty else { return (0, 0) }

            var retained: [BufferedStreamUpdate] = []
            retained.reserveCapacity(recordCount)
            var removedRecords = 0
            var removedChunks = 0

            while let update = removeFirst() {
                if predicate(update) {
                    removedRecords += 1
                    removedChunks += update.chunks.count
                } else {
                    retained.append(update)
                }
            }

            for update in retained {
                precondition(append(update), "Streaming mailbox capacity changed while compacting")
            }

            return (removedRecords, removedChunks)
        }

        /// Swaps out the ring storage without copying every pending chunk on
        /// MainActor. The worker owns iteration and final materialization.
        func detach() -> DetachedStreamingUpdates {
            let detached = DetachedStreamingUpdates(
                storage: storage,
                readIndex: readIndex,
                recordCount: recordCount,
                chunkCount: chunkCount,
                capacity: capacity
            )
            storage = []
            readIndex = 0
            writeIndex = 0
            recordCount = 0
            chunkCount = 0
            return detached
        }

        private func ensureStorage() {
            guard storage.isEmpty else { return }
            storage = [BufferedStreamUpdate?](repeating: nil, count: capacity)
        }
    }

    nonisolated private struct DetachedStreamingUpdates: Sendable {
        let storage: [BufferedStreamUpdate?]
        let readIndex: Int
        let recordCount: Int
        let chunkCount: Int
        let capacity: Int

        static let empty = DetachedStreamingUpdates(
            storage: [],
            readIndex: 0,
            recordCount: 0,
            chunkCount: 0,
            capacity: 0
        )

        var isEmpty: Bool { recordCount == 0 }

        func forEachInFIFO(_ body: (BufferedStreamUpdate) -> Void) {
            guard recordCount > 0, capacity > 0 else { return }

            var index = readIndex
            for _ in 0..<recordCount {
                if let update = storage[index] {
                    body(update)
                }
                index = (index + 1) % capacity
            }
        }
    }

    /// Coalesces rapid answer and reasoning deltas into ordered batched UI
    /// updates (~40ms). Adjacent updates for the same source retain small chunks
    /// rather than constructing a repeatedly growing `String` on MainActor.
    /// One small ring per live assistant message. A completion detaches its
    /// ring in O(1) for worker-side materialization, so idle never scans a
    /// response-sized `Array` on MainActor.
    @ObservationIgnored private var streamingUpdateMailboxes: [String: StreamingUpdateMailbox] = [:]
    @ObservationIgnored private var bufferedStreamingRecordCount = 0
    @ObservationIgnored private var bufferedStreamingChunkCount = 0
    @ObservationIgnored private var isStreamingConsumerBackpressured = false
    /// Server confirmation can replace an optimistic message id while chunks
    /// are still queued. Resolve the id lazily rather than rewriting every
    /// queued record synchronously.
    @ObservationIgnored private var streamingMessageIDRemaps: [String: String] = [:]
    @ObservationIgnored private var flushTimer: Timer?
    /// Structural tool bursts are coalesced separately from text flushes. A
    /// single row still observes its status immediately, while the expensive
    /// flattened timeline is rebuilt at most once per short window.
    @ObservationIgnored private var timelineInvalidationTimer: Timer?
    /// Large completed messages can be materialized concurrently with the next
    /// user turn, so tokens are scoped by message rather than globally.
    @ObservationIgnored private var streamingFinalizationTokens: [String: UUID] = [:]

    /// Interval between streaming buffer flushes (seconds).
    private static let flushInterval: TimeInterval = 0.04
    private static let timelineInvalidationInterval: TimeInterval = 0.04
    /// At most this many already-bounded text chunks enter a projection in one
    /// MainActor turn. A server can send a 100 KB snapshot in one SSE event;
    /// chunking it alone is not enough if every chunk is still appended in the
    /// same UI update.
    private static let maximumStreamingChunksPerFlush = 8
    /// Bounds bookkeeping too: a burst of superseded records must not make a
    /// later timer callback walk an arbitrarily long stale FIFO on MainActor.
    private static let maximumStreamingRecordsPerFlush = 16
    /// This bounded ring is intentionally smaller than the SSE mailbox. Once
    /// it reaches the high watermark, the consumer gate pauses the transport
    /// before another main-delivery batch can grow the render backlog.
    private static let streamingMailboxCapacity = 96
    private static let streamingRecordHighWatermark = 48
    private static let streamingRecordLowWatermark = 16
    private static let streamingChunkHighWatermark = 192
    private static let streamingChunkLowWatermark = 64
    /// Small responses remain synchronous for the usual fast path. Larger
    /// transcripts are joined off the UI executor before Markdown handoff.
    private static let asynchronousMaterializationThreshold = 24_000
    private static let streamingMaterializationQueue = DispatchQueue(
        label: "com.openlens.ChatClient.streaming-materialization",
        qos: .userInitiated
    )

    private func syncLiveActivityPendingUserResponse() {
        guard let liveActivityTracker else { return }

        if let pendingPermission {
            liveActivityTracker.setPendingPermission(pendingPermission)
        } else if let pendingQuestion {
            liveActivityTracker.setPendingQuestion(pendingQuestion)
        } else {
            liveActivityTracker.clearPendingUserResponse()
        }
    }

    // MARK: - SSEEventHandlerDelegate

    var currentSessionID: String? { currentSession?.id }

    func questionDidPresent() {
        startQuestionTimeout()
    }

    func messageLayoutDidChange() {
        contentVersion &+= 1
        scheduleTimelineInvalidation()
    }

    private func scheduleTimelineInvalidation() {
        guard timelineInvalidationTimer == nil else { return }

        let timer = Timer(timeInterval: Self.timelineInvalidationInterval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.timelineInvalidationTimer = nil
                self.timelineVersion &+= 1
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        timelineInvalidationTimer = timer
    }

    private func cancelTimelineInvalidation() {
        timelineInvalidationTimer?.invalidate()
        timelineInvalidationTimer = nil
    }

    func beginExternalResponse() {
        abortTask?.cancel()
        abortTask = nil
        cancelStoppedStateClear()
        ignoredAssistantMessageIDs.removeAll()
        locallyStoppedSessionID = nil
        responseState = .generating
        errorMessage = nil
        isLoading = true
        currentActivity = AgentActivity()
        currentActivity?.currentLabel = "Thinking..."
        responseStartDate = Date()
        haptics.prepareForResponse()
    }

    func shouldIgnoreAssistantEvent(sessionID: String, messageID: String) -> Bool {
        if ignoredAssistantMessageIDs.contains(messageID) {
            return true
        }

        guard locallyStoppedSessionID == sessionID else { return false }

        switch responseState {
        case .stopping, .stopped:
            ignoredAssistantMessageIDs.insert(messageID)
            return true
        case .idle, .generating, .failed:
            return false
        }
    }

    func shouldIgnoreBusyStatus(sessionID: String) -> Bool {
        guard locallyStoppedSessionID == sessionID else { return false }

        switch responseState {
        case .stopping, .stopped:
            return true
        case .idle, .generating, .failed:
            return false
        }
    }

    // MARK: - Init

    init(
        connection: ConnectionManager,
        liveActivity: LiveActivityManager,
        sessionsService: SessionsService,
        messagesService: MessagesService,
        providersService: ProvidersService,
        questionService: QuestionService,
        savedConnectionsStore: SavedConnectionsStore,
        recordedReplayStore: RecordedReplayStore
    ) {
        self.isDemoMode = false
        self.recordedReplay = nil
        self.recordedReplayPlaybackMode = nil
        self.demoScript = .showcase
        self.connection = connection
        self.sessionsService = sessionsService
        self.messagesService = messagesService
        self.providersService = providersService
        self.questionService = questionService
        self.savedConnectionsStore = savedConnectionsStore
        self.recordedReplayStore = recordedReplayStore

        let haptics = HapticController()
        let tracker = LiveActivityTracker(
            liveActivity: liveActivity
        )

        self.haptics = haptics
        self.liveActivityTracker = tracker
        self.sseHandler = SSEEventHandler(haptics: haptics, liveActivityTracker: tracker)
        self.recordedReplayPlayer = nil

        // Wire delegate after all properties are initialized
        self.sseHandler?.delegate = self

        // Restore persisted model selection from the most recent saved connection
        if let activeID = savedConnectionsStore.activeConnectionID,
           let saved = savedConnectionsStore.savedModelSelection(connectionID: activeID) {
            self.selectedProviderID = saved.providerID
            self.selectedModelID = saved.modelID
            self.selectedVariant = saved.variant
        } else if let mostRecent = savedConnectionsStore.mostRecent,
                  let saved = savedConnectionsStore.savedModelSelection(connectionID: mostRecent.id) {
            self.selectedProviderID = saved.providerID
            self.selectedModelID = saved.modelID
            self.selectedVariant = saved.variant
        }
    }

    private func latestAssistantMessageWithUsage() -> ChatMessage? {
        if let pendingAssistantMessage,
           pendingAssistantMessage.role == .assistant,
           (pendingAssistantMessage.tokens?.totalIncludingCache ?? 0) > 0 {
            return pendingAssistantMessage
        }

        return messages.reversed().first(where: { message in
            message.role == .assistant && (message.tokens?.totalIncludingCache ?? 0) > 0
        })
    }

    private func modelLimit(providerID: String?, modelID: String?) -> Int? {
        guard let providerID, !providerID.isEmpty,
              let modelID, !modelID.isEmpty,
              let provider = providers.first(where: { $0.id == providerID }) else { return nil }

        return provider.models[modelID]?.limit?.context
    }

    private func contextUsagePercent(usedTokens: Int, limitTokens: Int?) -> Int? {
        guard let limitTokens, limitTokens > 0 else { return nil }
        return Int((Double(usedTokens) / Double(limitTokens) * 100).rounded())
    }

    /// Creates a ChatClient in demo mode — no server connection required.
    /// The DemoPlayer drives the same streaming/activity paths as real SSE events.
    init(demoMode: Bool, script: DemoScript = .showcase) {
        precondition(demoMode, "Use the full init for non-demo mode")
        self.isDemoMode = true
        self.recordedReplay = nil
        self.recordedReplayPlaybackMode = nil
        self.demoScript = script
        self.connection = nil
        self.sessionsService = nil
        self.messagesService = nil
        self.providersService = nil
        self.questionService = nil
        self.savedConnectionsStore = nil
        self.recordedReplayStore = nil
        self.liveActivityTracker = nil
        self.sseHandler = nil
        self.recordedReplayPlayer = nil

        self.haptics = HapticController()
        self.selectedProviderID = "anthropic"
        self.selectedModelID = "claude-sonnet-4-20250514"

        self.demoPlayer = DemoPlayer(chatClient: self)
    }

    init(recordedReplay: RecordedChatReplay, playbackMode: RecordedReplayPlayer.PlaybackMode = .realtime) {
        self.isDemoMode = false
        self.recordedReplay = recordedReplay
        self.recordedReplayPlaybackMode = playbackMode
        self.demoScript = .showcase
        self.connection = nil
        self.sessionsService = nil
        self.messagesService = nil
        self.providersService = nil
        self.questionService = nil
        self.savedConnectionsStore = nil
        self.recordedReplayStore = nil

        let haptics = HapticController()
        let tracker = LiveActivityTracker(liveActivity: NoopLiveActivityProvider())
        let handler = SSEEventHandler(haptics: haptics, liveActivityTracker: tracker)

        self.haptics = haptics
        self.liveActivityTracker = tracker
        self.sseHandler = handler
        self.recordedReplayPlayer = RecordedReplayPlayer(eventHandler: handler)
        self.selectedProviderID = ""
        self.selectedModelID = ""
        self.demoPlayer = nil

        self.sseHandler?.delegate = self
    }

    // MARK: - Session Management

    /// Ensures a session is loaded. Loads the most recent existing session,
    /// or creates a new one if none exist. No-op if a session is already loaded.
    /// In demo mode, creates a fake local session.
    func ensureSession() async {
        guard currentSession == nil else { return }

        if isDemoMode {
            let session = ScreenshotFixtures.isEnabled
                ? ScreenshotFixtures.defaultSession
                : OCSession(
                    id: UUID().uuidString,
                    title: demoScript.sessionTitle,
                    time: OCSessionTime(created: Date.now.timeIntervalSince1970, updated: Date.now.timeIntervalSince1970)
                )
            currentSession = session
            messages = []
            displayLimit = pageSize
            currentActivity = nil
            lastCompletedActivity = nil
            errorMessage = nil
            // Auto-start demo playback after session is ready
            demoPlayer?.play(demoScript)
            return
        }

        if let recordedReplay {
            resetSessionState()

            let createdAt = recordedReplay.createdAt.timeIntervalSince1970 * 1000
            let updatedAt = recordedReplay.createdAt
                .addingTimeInterval(recordedReplay.duration)
                .timeIntervalSince1970 * 1000

            currentSession = OCSession(
                id: recordedReplay.sessionID,
                title: recordedReplay.sessionTitle ?? "",
                time: OCSessionTime(created: createdAt, updated: updatedAt)
            )
            errorMessage = nil
            recordedReplayPlayer?.play(
                recordedReplay,
                mode: recordedReplayPlaybackMode ?? .realtime
            )
            return
        }

        do {
            let session = try await sessionsService!.ensureSession()
            await loadSession(session)
        } catch {
            Logger.chat.error("ensureSession failed: \(error, privacy: .public)")
            errorMessage = "Failed to load session: \(error.localizedDescription)"
        }
    }

    func loadSession(_ session: OCSession) async {
        if isDemoMode {
            resetSessionState()
            currentSession = session
            messages = []
            displayLimit = pageSize
            currentActivity = nil
            lastCompletedActivity = nil
            errorMessage = nil
            demoPlayer?.play(demoScript)
            return
        }

        if isRecordedReplayMode {
            resetSessionState()
            currentSession = session
            return
        }

        // Drain any in-flight state from the previous session
        resetSessionState()

        currentSession = session

        setupSSEHandlers()
        if providers.isEmpty {
            await loadProviders()
        }
        await loadMessages()
        await recoverPendingPermission()
        await recoverPendingQuestions()
    }

    func loadMessages() async {
        guard !isOfflinePreviewMode, let session = currentSession else { return }

        do {
            let loaded = try await messagesService!.loadMessages(sessionID: session.id)
            let visibleMessages = mergeLoadedMessagesWithLocallyStoppedMessages(loaded)
            self.messages = visibleMessages
            if Self.recentSessionModelSelection(from: visibleMessages) != nil {
                syncSessionModelSelection(from: visibleMessages)
            } else {
                applyPreferredDefaultModelSelection()
            }
            Logger.debug.info("messages count: \(visibleMessages.count)")
            self.contentVersion &+= 1
            self.scrollAnchor &+= 1
        } catch {
            self.errorMessage = "Failed to load messages: \(error.localizedDescription)"
        }

        await refreshCurrentSessionStatus()
        await loadTodos()
    }

    func refreshCurrentSessionStatus() async {
        guard !isOfflinePreviewMode,
              let sessionsService,
              let sessionID = currentSession?.id else { return }

        do {
            let statuses = try await sessionsService.getSessionStatuses()
            guard currentSession?.id == sessionID else { return }
            reconcileCurrentSessionStatus(statuses[sessionID])
        } catch {
            Logger.chat.warning("refreshCurrentSessionStatus failed: \(error, privacy: .public)")
        }
    }

    private func reconcileCurrentSessionStatus(_ status: OCSessionStatus?) {
        guard let status else {
            reconcileMissingCurrentSessionStatus()
            return
        }

        applyCurrentSessionStatus(status)
    }

    private func reconcileMissingCurrentSessionStatus(now: Date = Date()) {
        sessionStatus = nil

        guard isLoading || pendingAssistantMessage != nil || responseState == .generating || responseState == .stopping else {
            return
        }

        if shouldDeferIdleStatusRefresh(now: now) {
            return
        }

        finishLoading()
    }

    func applyCurrentSessionStatus(_ status: OCSessionStatus?) {
        guard let status else { return }

        switch status.type {
        case .idle:
            sessionStatus = status

            if shouldDeferIdleStatusRefresh() {
                return
            }

            guard isLoading || pendingAssistantMessage != nil || responseState == .generating || responseState == .stopping else {
                sessionStatus = nil
                return
            }

            finishLoading()

        case .busy, .retry:
            guard let sessionID = currentSession?.id,
                  !shouldIgnoreBusyStatus(sessionID: sessionID) else { return }

            sessionStatus = status

            if !isLoading || responseState == .idle || responseState == .failed {
                beginExternalResponse()
            }
        }
    }

    private func shouldDeferIdleStatusRefresh(now: Date = Date()) -> Bool {
        guard let responseStartDate else { return false }
        return now.timeIntervalSince(responseStartDate) < Self.statusRefreshIdleGraceInterval
    }

    private func mergeLoadedMessagesWithLocallyStoppedMessages(_ loaded: [ChatMessage]) -> [ChatMessage] {
        guard !ignoredAssistantMessageIDs.isEmpty else { return loaded }

        let localStoppedMessages = messages.filter { ignoredAssistantMessageIDs.contains($0.id) }
        guard !localStoppedMessages.isEmpty else {
            return loaded.filter { !ignoredAssistantMessageIDs.contains($0.id) }
        }

        var result = loaded.filter { !ignoredAssistantMessageIDs.contains($0.id) }
        let existingIDs = Set(result.map(\.id))
        result.append(contentsOf: localStoppedMessages.filter { !existingIDs.contains($0.id) })
        return result
    }

    func loadTodos() async {
        guard let session = currentSession,
              let client = connection?.client else {
            Logger.debug.info("[TODO] loadTodos skipped: no session or client")
            return
        }
        do {
            let loaded = try await client.listTodos(sessionID: session.id)
            self.todos = loaded.todos
            self.hiddenTodoCount = loaded.hiddenCount
            Logger.debug.info("[TODO] loaded \(loaded.todos.count) visible todos")
        } catch {
            Logger.debug.warning("[TODO] loadTodos failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func reloadForProjectContextChange() async {
        guard !isOfflinePreviewMode else { return }

        resetSessionState()
        currentSession = nil
        inputText = ""

        await loadProviders()
        await ensureSession()
    }

    @discardableResult
    func submitWorkspaceRequest(_ text: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        guard !isLoading else {
            errorMessage = "Wait for the active session to finish before starting another workspace action."
            return false
        }

        guard pendingQuestion == nil else {
            errorMessage = "Answer the current question before starting another workspace action."
            return false
        }

        if currentSession == nil {
            await ensureSession()
        }

        guard currentSession != nil else {
            errorMessage = "Failed to start a session for this workspace action."
            return false
        }

        inputText = trimmed
        send()
        return true
    }

    // MARK: - Provider / Model Loading

    func loadProviders() async {
        guard !isOfflinePreviewMode else { return }
        isLoadingProviders = true
        defer { isLoadingProviders = false }

        // Load config first — we need filter lists before selecting a model
        let configResult = await providersService!.loadConfig()
        self.enabledProviders = configResult.enabledProviders
        self.disabledProviders = configResult.disabledProviders

        let savedDefault = savedConnectionsStore?.activeConnectionID.flatMap {
            savedConnectionsStore?.defaultModelSelection(connectionID: $0)
        }
        var serverDefault: (providerID: String, modelID: String)?
        let configDefault = configResult.defaultProviderID.flatMap { providerID in
            configResult.defaultModelID.map { (providerID: providerID, modelID: $0) }
        }
        configReportedDefault = configDefault

        do {
            let result = try await providersService!.loadProviders()
            self.providers = result.providers
            self.connectedProviderIDs = result.connectedProviderIDs
            serverDefault = result.defaultProviderID.flatMap { providerID in
                result.defaultModelID.map { (providerID: providerID, modelID: $0) }
            }
            serverReportedDefault = serverDefault
        } catch {
            Logger.chat.error("loadProviders failed: \(error, privacy: .public)")
        }

        let resolution = Self.resolveDefaultModelSelection(
            savedDefault: savedDefault,
            serverDefault: serverDefault,
            configDefault: configDefault,
            availableModels: availableModels
        )

        if let providerID = resolution.providerID,
           let modelID = resolution.modelID {
            preferredDefaultProviderID = providerID
            preferredDefaultModelID = modelID
            self.selectedProviderID = providerID
            self.selectedModelID = modelID
            self.selectedVariant = nil
        } else {
            preferredDefaultProviderID = ""
            preferredDefaultModelID = ""
            self.selectedProviderID = ""
            self.selectedModelID = ""
            self.selectedVariant = nil
        }

        if let unavailableDefaultModelID = resolution.unavailableDefaultModelID {
            errorMessage = AppText.defaultModelUnavailable(unavailableDefaultModelID)
        }

        // Guard: if selected model's provider is filtered out, clear selection
        // so the UI doesn't show a model the user can't actually use
        if !selectedProviderID.isEmpty,
           !availableModels.contains(where: { $0.providerID == selectedProviderID && $0.modelID == selectedModelID }) {
            Logger.chat.warning("Selected model \(self.selectedProviderID)/\(self.selectedModelID) is filtered out by config — clearing")
            self.selectedProviderID = ""
            self.selectedModelID = ""
            self.selectedVariant = nil
            if let connID = savedConnectionsStore?.activeConnectionID {
                savedConnectionsStore?.clearModelSelection(connectionID: connID)
            }
        } else if let selectedVariant,
                  !availableReasoningVariants.contains(where: { $0.id == selectedVariant }) {
            self.selectedVariant = nil
            persistCurrentSelection()
        }
    }

    static func recentSessionModelSelection(from messages: [ChatMessage]) -> (providerID: String, modelID: String)? {
        for message in messages.reversed() {
            guard let providerID = message.providerID?.nilIfBlank,
                  let modelID = message.modelID?.nilIfBlank else {
                continue
            }

            return (providerID, modelID)
        }

        return nil
    }

    private func syncSessionModelSelection(from messages: [ChatMessage]) {
        guard let selection = Self.recentSessionModelSelection(from: messages) else { return }

        if !availableModels.isEmpty,
           !availableModels.contains(where: {
               $0.providerID == selection.providerID && $0.modelID == selection.modelID
           }) {
            return
        }

        selectedProviderID = selection.providerID
        selectedModelID = selection.modelID
        selectedVariant = nil
    }

    func selectModel(_ model: SelectableModel) {
        let isSameModel = selectedProviderID == model.providerID && selectedModelID == model.modelID
        selectedProviderID = model.providerID
        selectedModelID = model.modelID
        if !isSameModel || !model.variants.contains(where: { $0.id == selectedVariant }) {
            selectedVariant = nil
        }
        persistCurrentSelection()
    }

    func selectVariant(_ variantID: String?) {
        selectedVariant = variantID
        persistCurrentSelection()
    }

    func toggleDefaultModel(_ model: SelectableModel) {
        if isDefaultModel(model) {
            clearDefaultModelSelection()
        } else {
            persistDefaultModelSelection(providerID: model.providerID, modelID: model.modelID)
        }

        refreshPreferredDefaultModelSelection()
    }

    func updateSlashCatalog(commands: [String], agents: [String]) {
        availableSlashCommandMap = Dictionary(uniqueKeysWithValues: commands.map { ($0.lowercased(), $0) })
        availableSlashAgentMap = Dictionary(uniqueKeysWithValues: agents.map { ($0.lowercased(), $0) })
    }

    private func beginResponse() {
        abortTask?.cancel()
        abortTask = nil
        cancelStoppedStateClear()
        ignoredAssistantMessageIDs.removeAll()
        locallyStoppedSessionID = nil
        responseState = .generating
        errorMessage = nil
        isLoading = true
        haptics.prepareForResponse()
    }

    private func markResponseFailed(_ message: String) {
        cancelStoppedStateClear()
        isLoading = false
        responseState = .failed
        errorMessage = message
        currentActivity = nil
        responseStartDate = nil
        sessionStatus = nil
        liveActivityTracker?.end()
    }

    func dismissError() {
        errorMessage = nil
        if responseState == .failed {
            responseState = .idle
        }
    }

    private func markResponseIdleAfterFinish() {
        switch responseState {
        case .stopping:
            locallyStoppedSessionID = nil
            showStoppedResponseState()
        case .generating, .idle:
            cancelStoppedStateClear()
            responseState = .idle
            locallyStoppedSessionID = nil
        case .stopped, .failed:
            locallyStoppedSessionID = nil
        }
    }

    private func showStoppedResponseState() {
        cancelStoppedStateClear()
        responseState = .stopped
        stoppedStateClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.stoppedResponseDisplayDuration)
            guard !Task.isCancelled else { return }
            guard let self, self.responseState == .stopped else { return }

            self.responseState = .idle
            self.locallyStoppedSessionID = nil
            self.stoppedStateClearTask = nil
        }
    }

    private func cancelStoppedStateClear() {
        stoppedStateClearTask?.cancel()
        stoppedStateClearTask = nil
    }

    // MARK: - Send Message

    func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isLoading, currentSession != nil else { return }

        if isDemoMode {
            beginResponse()
            inputText = ""
            demoPlayer?.play(demoScript)
            return
        }

        if isRecordedReplayMode {
            errorMessage = AppText.recordedReplayReadOnly
            return
        }

        if let slashAction = parseSlashAction(text) {
            switch slashAction {
            case .command(let command, let arguments):
                sendCommand(text: text, command: command, arguments: arguments)
            case .agent(let agent, let prompt):
                sendAgentPrompt(text: text, agent: agent, prompt: prompt)
            }
            return
        }

        beginResponse()

        let userMessage = ChatMessage(role: .user, content: text)
        messages.append(userMessage)
        inputText = ""

        currentActivity = AgentActivity()
        currentActivity?.currentLabel = "Thinking..."
        responseStartDate = Date()

        liveActivityTracker?.start(
            agentName: currentSession?.title ?? "OpenCode",
            userTask: String(text.prefix(80))
        )

        contentVersion &+= 1

        Task {
            await sendPromptAsync(text: text)
        }
    }

    private func sendCommand(text: String, command: String, arguments: String) {
        beginResponse()

        let userMessage = ChatMessage(role: .user, content: text)
        messages.append(userMessage)
        inputText = ""

        currentActivity = AgentActivity()
        currentActivity?.currentLabel = "Running /\(command)..."
        responseStartDate = Date()

        liveActivityTracker?.start(
            agentName: currentSession?.title ?? "OpenCode",
            userTask: "/\(command)"
        )

        contentVersion &+= 1
        scrollAnchor &+= 1

        Task {
            await sendCommandAsync(command: command, arguments: arguments)
        }
    }

    private func sendAgentPrompt(text: String, agent: String, prompt: String) {
        beginResponse()

        let userMessage = ChatMessage(role: .user, content: text)
        messages.append(userMessage)
        inputText = ""

        currentActivity = AgentActivity()
        currentActivity?.currentLabel = "Running /\(agent)..."
        responseStartDate = Date()

        liveActivityTracker?.start(
            agentName: agent,
            userTask: prompt.isEmpty ? "/\(agent)" : prompt
        )

        contentVersion &+= 1
        scrollAnchor &+= 1

        Task {
            await sendPromptAsync(text: prompt, agent: agent)
        }
    }

    private func sendPromptAsync(text: String, agent: String? = nil) async {
        guard let session = currentSession else {
            markResponseFailed("Not connected.")
            return
        }

        do {
            try await messagesService!.sendPromptAsync(
                sessionID: session.id,
                text: text,
                model: selectedModelRef,
                agent: agent,
                variant: selectedVariant
            )
        } catch {
            guard responseState == .generating else { return }
            if let agent, !agent.isEmpty {
                markResponseFailed("Failed to run /\(agent): \(error.localizedDescription)")
            } else {
                markResponseFailed("Failed to send: \(error.localizedDescription)")
            }
        }
    }

    private func sendCommandAsync(command: String, arguments: String) async {
        guard let session = currentSession else {
            markResponseFailed("Not connected.")
            return
        }

        do {
            try await messagesService!.sendCommand(
                sessionID: session.id,
                command: command,
                arguments: arguments,
                model: selectedModelCommandValue,
                variant: selectedVariant
            )
        } catch {
            guard responseState == .generating else { return }
            markResponseFailed("Failed to run /\(command): \(error.localizedDescription)")
        }
    }

    private enum SlashAction {
        case command(command: String, arguments: String)
        case agent(agent: String, prompt: String)
    }

    private func parseSlashAction(_ text: String) -> SlashAction? {
        guard text.hasPrefix("/") else { return nil }

        let raw = String(text.dropFirst())
        let parts = raw.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
        guard let commandPart = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines),
              !commandPart.isEmpty else { return nil }

        let arguments = parts.count > 1
            ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            : ""

        let normalizedToken = commandPart.lowercased()

        if let command = availableSlashCommandMap[normalizedToken] {
            return .command(command: command, arguments: arguments)
        }

        if let agent = availableSlashAgentMap[normalizedToken] {
            return .agent(agent: agent, prompt: arguments)
        }

        return .command(command: commandPart, arguments: arguments)
    }

    /// Auto-starts demo playback. Call after `ensureSession()` in demo mode.
    func startDemoPlayback() {
        guard isDemoMode else { return }
        demoPlayer?.play(demoScript)
    }

    func stopPreviewPlayback() {
        demoPlayer?.stop()
        recordedReplayPlayer?.stop()
    }

    // MARK: - Abort

    func abort() {
        guard responseState != .stopping else { return }

        if isDemoMode {
            demoPlayer?.stop()
            beginStoppingResponse(sessionID: currentSession?.id)
            completeStoppedResponse()
            return
        }

        if isRecordedReplayMode {
            recordedReplayPlayer?.stop()
            if isLoading || pendingAssistantMessage != nil {
                beginStoppingResponse(sessionID: currentSession?.id)
                completeStoppedResponse()
            }
            return
        }

        guard let session = currentSession else { return }

        beginStoppingResponse(sessionID: session.id)
        finalizeLocalStoppedTurn()

        abortTask = Task { [weak self] in
            do {
                try await self?.messagesService?.abort(sessionID: session.id)
                self?.completeStoppedResponse()
            } catch {
                self?.failStoppedResponse(error)
            }
        }
    }

    private func beginStoppingResponse(sessionID: String?) {
        responseState = .stopping
        locallyStoppedSessionID = sessionID

        if let pendingAssistantMessage {
            ignoredAssistantMessageIDs.insert(pendingAssistantMessage.id)
        }
    }

    private func finalizeLocalStoppedTurn() {
        stopFlushTimer()
        // Keep the common small-stop path immediate, but never drain an
        // unbounded snapshot in one UI turn.
        flushStreamingBuffer()

        if let pending = pendingAssistantMessage {
            let bufferedUpdates = detachBufferedStreamUpdates(for: pending.id)
            finalizePendingAssistantMessage(
                pending,
                appendsWhenEmpty: false,
                bufferedUpdates: bufferedUpdates
            )
        }
        continueStreamingFlushIfNeeded()

        currentActivity = nil
        sessionStatus = nil
        responseStartDate = nil
        pendingPermission = nil
        showPermissionAlert = false
        pendingQuestion = nil
        showQuestionSheet = false
        cancelQuestionTimeout()
        liveActivityTracker?.end()
        contentVersion &+= 1
    }

    private func completeStoppedResponse() {
        guard responseState == .stopping else { return }

        abortTask = nil
        finalizeLocalStoppedTurn()
        isLoading = false
        showStoppedResponseState()
    }

    private func failStoppedResponse(_ error: Error) {
        guard responseState == .stopping else { return }

        abortTask = nil
        cancelStoppedStateClear()
        finalizeLocalStoppedTurn()
        isLoading = false
        responseState = .failed
        errorMessage = "Failed to stop: \(error.localizedDescription)"
    }

    // MARK: - SSE Setup

    func setupSSEHandlers() {
        guard let connection, let sseClient = connection.sseClient else { return }

        // Keep SSE handler's refs in sync
        sseHandler?.connectionClient = connection.client
        sseHandler?.connectionManager = connection

        sseClient.onEvent = nil
        sseClient.setRawEventRetentionEnabled(isRecordingStream)
        sseClient.onInboundEvent = { [weak self] inboundEvent in
            if let rawEvent = inboundEvent.rawEvent {
                self?.recordIncomingEvent(rawEvent)
            }
            self?.sseHandler?.handleInboundEvent(inboundEvent)
        }
    }

    // MARK: - Stream Recording

    func startStreamRecording() {
        guard supportsStreamRecording else {
            errorMessage = FeatureFlags.debugFeaturesEnabled
                ? AppText.recordingStorageUnavailable
                : AppText.recordingDebugFeaturesDisabled
            return
        }

        guard !isRecordingStream else {
            errorMessage = AppText.recordingAlreadyInProgress
            return
        }

        guard let session = currentSession else {
            errorMessage = AppText.recordingNeedsSession
            return
        }

        guard !isLoading else {
            errorMessage = AppText.recordingWaitForIdle
            return
        }

        errorMessage = nil
        isRecordingStream = true
        streamRecorder = ChatStreamRecorder(
            sessionID: session.id,
            sessionTitle: session.title,
            projectName: connection?.projectName,
            branch: connection?.branch
        )
        connection?.sseClient?.setRawEventRetentionEnabled(true)
    }

    func stopStreamRecording() {
        connection?.sseClient?.setRawEventRetentionEnabled(false)
        guard let recorder = streamRecorder else { return }

        streamRecorder = nil
        isRecordingStream = false
        handleStreamRecorderCompletion(recorder.stop(), surfaceEmptyCapture: true)
    }

    private func recordIncomingEvent(_ event: OCEvent) {
        guard var recorder = streamRecorder else { return }

        if let completion = recorder.record(event) {
            streamRecorder = nil
            isRecordingStream = false
            connection?.sseClient?.setRawEventRetentionEnabled(false)
            handleStreamRecorderCompletion(completion, surfaceEmptyCapture: false)
        } else {
            streamRecorder = recorder
        }
    }

    private func handleStreamRecorderCompletion(
        _ completion: ChatStreamRecorder.Completion,
        surfaceEmptyCapture: Bool
    ) {
        switch completion {
        case .saved(let replay):
            guard let recordedReplayStore else {
                errorMessage = AppText.recordingStorageUnavailable
                return
            }

            do {
                _ = try recordedReplayStore.saveReplay(replay)
            } catch {
                errorMessage = AppText.recordedCaptureSaveFailed(error.localizedDescription)
            }

        case .discardedEmpty:
            if surfaceEmptyCapture {
                errorMessage = AppText.recordingEmptyCapture
            }
        }
    }

    // MARK: - Permission Response

    @discardableResult
    func respondToPermission(requestID: String, reply: OCPermissionReply) async -> Bool {
        guard let questionService else {
            errorMessage = "Failed to respond to permission: Not connected."
            return false
        }

        let recoverySessionID = pendingPermission?.sessionID ?? currentSession?.id

        do {
            try await questionService.respondToPermission(
                requestID: requestID,
                reply: reply
            )

            if pendingPermission?.id == requestID {
                pendingPermission = nil
                showPermissionAlert = false
            }

            await recoverPendingPermission(sessionID: recoverySessionID)
            return pendingPermission?.id != requestID
        } catch {
            errorMessage = "Failed to respond to permission: \(error.localizedDescription)"
            return false
        }
    }

    /// Recover any pending permission from the server for the current session.
    func recoverPendingPermission(sessionID preferredSessionID: String? = nil) async {
        guard !isOfflinePreviewMode else { return }

        let sessionID = preferredSessionID ?? currentSession?.id

        do {
            let permission = try await questionService?.recoverPendingPermission(sessionID: sessionID)

            if let permission {
                pendingPermission = permission
                showPermissionAlert = true
            } else if sessionID == nil || pendingPermission?.sessionID == sessionID {
                pendingPermission = nil
                showPermissionAlert = false
            }
        } catch {
            Logger.chat.warning("recoverPendingPermission failed: \(error, privacy: .public)")
        }
    }

    // MARK: - Question Response

    /// Recover any pending questions from the server after reconnection.
    func recoverPendingQuestions() async {
        guard !isOfflinePreviewMode, let sessionID = currentSession?.id else { return }

        do {
            if let question = try await questionService?.recoverPendingQuestion(sessionID: sessionID) {
                if self.pendingQuestion == nil {
                    self.pendingQuestion = question
                    self.showQuestionSheet = true
                    self.startQuestionTimeout()
                }
            }
        } catch {
            Logger.chat.warning("recoverPendingQuestions failed: \(error, privacy: .public)")
        }
    }

    /// Send selected answers back to the server.
    func respondToQuestion(answers: [[String]]) {
        cancelQuestionTimeout()

        guard let question = pendingQuestion else {
            pendingQuestion = nil
            showQuestionSheet = false
            return
        }

        Task {
            try? await questionService?.respondToQuestion(
                requestID: question.id,
                answers: answers
            )
        }

        pendingQuestion = nil
        showQuestionSheet = false
    }

    /// Dismiss/reject the question without answering.
    func rejectQuestion() {
        cancelQuestionTimeout()

        guard let question = pendingQuestion else {
            pendingQuestion = nil
            showQuestionSheet = false
            return
        }

        Task {
            try? await questionService?.rejectQuestion(requestID: question.id)
        }

        pendingQuestion = nil
        showQuestionSheet = false
    }

    // MARK: - Question Timeout

    private func startQuestionTimeout() {
        cancelQuestionTimeout()
        questionTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(Self.questionTimeoutSeconds))
            } catch {
                return // cancelled
            }
            guard let self, self.pendingQuestion != nil else { return }
            await MainActor.run {
                Logger.chat.info("Question timed out after \(Self.questionTimeoutSeconds)s, auto-rejecting")
                self.rejectQuestion()
            }
        }
    }

    private func cancelQuestionTimeout() {
        questionTimeoutTask?.cancel()
        questionTimeoutTask = nil
    }

    // MARK: - Streaming Text Buffer API

    /// Append text for a streaming message. Accumulated in a buffer that
    /// flushes to the pending message every ~40ms, keeping UI updates smooth.
    func appendStreamingText(messageID: String, text: String) {
        appendStreamingText(messageID: messageID, text: text, chunks: [text])
    }

    func appendStreamingText(messageID: String, text: String, chunks: [String]) {
        guard !ignoredAssistantMessageIDs.contains(messageID) else { return }
        guard let pending = pendingAssistantMessage, pending.id == messageID else { return }
        enqueueStreamingUpdate(messageID: messageID, partID: nil, text: text, chunks: chunks)
        ensureFlushTimer()
    }

    func replaceStreamingText(messageID: String, text: String, chunks: [String]) {
        guard !ignoredAssistantMessageIDs.contains(messageID) else { return }
        guard let pending = pendingAssistantMessage, pending.id == messageID else { return }

        // An authoritative snapshot supersedes only unrendered text. Clearing
        // the projection and invalidating the old FIFO generation are both
        // O(1); its worker-prepared chunks are then appended through the
        // normal per-tick budget below.
        invalidateStreamingUpdates(messageID: messageID, partID: nil)
        pending.streamingTextProjection.clear()
        enqueueStreamingUpdate(messageID: messageID, partID: nil, text: text, chunks: chunks)
        ensureFlushTimer()
    }

    func appendStreamingReasoning(messageID: String, partID: String, text: String, chunks: [String]) {
        guard !ignoredAssistantMessageIDs.contains(messageID) else { return }
        guard assistantMessage(withID: messageID) != nil else { return }
        enqueueStreamingUpdate(messageID: messageID, partID: partID, text: text, chunks: chunks)
        ensureFlushTimer()
    }

    func replaceStreamingReasoning(messageID: String, partID: String, text: String, chunks: [String]) {
        guard !ignoredAssistantMessageIDs.contains(messageID) else { return }
        guard let message = assistantMessage(withID: messageID) else { return }

        invalidateStreamingUpdates(messageID: messageID, partID: partID)
        message.resetStreamingReasoningProjection(partID: partID)
        enqueueStreamingUpdate(messageID: messageID, partID: partID, text: text, chunks: chunks)
        ensureFlushTimer()
    }

    func clearStreamingBuffer(messageID: String) {
        guard !ignoredAssistantMessageIDs.contains(messageID) else { return }
        guard let pending = pendingAssistantMessage, pending.id == messageID else { return }
        invalidateStreamingUpdates(messageID: messageID, partID: nil)
        stopFlushTimerIfIdle()
    }

    func clearStreamingReasoningBuffer(messageID: String, partID: String) {
        invalidateStreamingUpdates(messageID: messageID, partID: partID)
        stopFlushTimerIfIdle()
    }

    /// Preserves the pending stream when the server replaces an optimistic
    /// assistant ID. Both the visible projection and not-yet-flushed chunks
    /// continue under the authoritative ID.
    @discardableResult
    func remapStreamingMessageID(from oldID: String, to newID: String) -> Bool {
        guard oldID != newID,
              let pending = pendingAssistantMessage,
              pending.id == oldID
        else {
            return false
        }

        pending.remapStreamingID(to: newID)
        streamingMessageIDRemaps[oldID] = newID

        // Moving a ring is O(1): no queued string/chunk has to be rewritten on
        // MainActor when the server replaces an optimistic message identifier.
        if let mailbox = streamingUpdateMailboxes.removeValue(forKey: oldID) {
            precondition(
                streamingUpdateMailboxes[newID] == nil,
                "An assistant stream cannot own two buffered mailboxes"
            )
            streamingUpdateMailboxes[newID] = mailbox
        }

        if ignoredAssistantMessageIDs.remove(oldID) != nil {
            ignoredAssistantMessageIDs.insert(newID)
        }

        return true
    }

    func streamingContentDidChange() {
        contentVersion &+= 1
    }

    /// Network streams are paused by `SSEClient` once this mailbox reaches its
    /// high watermark. Demo and recorded-replay producers have no transport to
    /// suspend, so they cooperatively wait for the normal 40 ms flushes to
    /// cross the low watermark before producing more events.
    func waitForStreamingRenderCapacity() async -> Bool {
        while isStreamingConsumerBackpressured {
            guard !Task.isCancelled else { return false }

            do {
                try await Task.sleep(for: .milliseconds(8))
            } catch {
                return false
            }
        }

        return !Task.isCancelled
    }

    private func enqueueStreamingUpdate(
        messageID: String,
        partID: String?,
        text: String,
        chunks: [String]
    ) {
        // SSE payloads have already been split on the worker. Keep their
        // array storage as a slice instead of filtering/copying every chunk
        // on MainActor. Each delivery is a separate FIFO record, which also
        // avoids a copy-on-write append of a large snapshot when a later delta
        // arrives before it has rendered.
        guard !chunks.isEmpty || !text.isEmpty else { return }
        let retainedChunks = chunks.isEmpty ? [text] : chunks
        let resolvedMessageID = resolvedStreamingMessageID(messageID)
        let mailbox = streamingMailbox(for: resolvedMessageID)
        let update = BufferedStreamUpdate(
            messageID: resolvedMessageID,
            partID: partID,
            chunks: retainedChunks[...]
        )

        // The consumer gate leaves room for the currently-delivering SSE batch,
        // so a fixed ring is a correctness assertion rather than a drop policy.
        precondition(
            mailbox.append(update),
            "SSE consumer backpressure must keep the streaming mailbox below capacity"
        )
        bufferedStreamingRecordCount += 1
        bufferedStreamingChunkCount += update.chunks.count
        updateStreamingConsumerPressure()
    }

    private func assistantMessage(withID messageID: String) -> ChatMessage? {
        if let pending = pendingAssistantMessage, pending.id == messageID {
            return pending
        }
        return messages.last(where: { $0.id == messageID && $0.role == .assistant })
    }

    private var hasBufferedStreamingUpdates: Bool {
        bufferedStreamingRecordCount > 0
    }

    private func resolvedStreamingMessageID(_ messageID: String) -> String {
        var resolved = messageID
        var remainingHops = streamingMessageIDRemaps.count + 1

        while remainingHops > 0,
              let next = streamingMessageIDRemaps[resolved],
              next != resolved {
            resolved = next
            remainingHops -= 1
        }

        return resolved
    }

    private func invalidateStreamingUpdates(messageID: String, partID: String?) {
        let resolvedMessageID = resolvedStreamingMessageID(messageID)
        guard let mailbox = streamingUpdateMailboxes[resolvedMessageID] else { return }

        let removed = mailbox.discard { $0.partID == partID }
        bufferedStreamingRecordCount -= removed.records
        bufferedStreamingChunkCount -= removed.chunks
        if mailbox.isEmpty {
            streamingUpdateMailboxes.removeValue(forKey: resolvedMessageID)
        }
        updateStreamingConsumerPressure()
    }

    private func streamingMailbox(for messageID: String) -> StreamingUpdateMailbox {
        if let mailbox = streamingUpdateMailboxes[messageID] {
            return mailbox
        }

        let mailbox = StreamingUpdateMailbox(capacity: Self.streamingMailboxCapacity)
        streamingUpdateMailboxes[messageID] = mailbox
        return mailbox
    }

    private func nextStreamingMailbox() -> (messageID: String, mailbox: StreamingUpdateMailbox)? {
        if let pending = pendingAssistantMessage,
           let mailbox = streamingUpdateMailboxes[pending.id],
           !mailbox.isEmpty {
            return (pending.id, mailbox)
        }

        return streamingUpdateMailboxes.first(where: { !$0.value.isEmpty })
            .map { (messageID: $0.key, mailbox: $0.value) }
    }

    private func detachBufferedStreamUpdates(for messageID: String) -> DetachedStreamingUpdates {
        let resolvedMessageID = resolvedStreamingMessageID(messageID)
        guard let mailbox = streamingUpdateMailboxes.removeValue(forKey: resolvedMessageID) else {
            return .empty
        }

        let detached = mailbox.detach()
        bufferedStreamingRecordCount -= detached.recordCount
        bufferedStreamingChunkCount -= detached.chunkCount
        updateStreamingConsumerPressure()
        return detached
    }

    private func discardAllBufferedStreamingUpdates() {
        streamingUpdateMailboxes.removeAll()
        bufferedStreamingRecordCount = 0
        bufferedStreamingChunkCount = 0
        updateStreamingConsumerPressure()
    }

    private func updateStreamingConsumerPressure() {
        let needsBackpressure: Bool
        if isStreamingConsumerBackpressured {
            needsBackpressure = bufferedStreamingRecordCount > Self.streamingRecordLowWatermark
                || bufferedStreamingChunkCount > Self.streamingChunkLowWatermark
        } else {
            needsBackpressure = bufferedStreamingRecordCount >= Self.streamingRecordHighWatermark
                || bufferedStreamingChunkCount >= Self.streamingChunkHighWatermark
        }

        guard needsBackpressure != isStreamingConsumerBackpressured else { return }
        isStreamingConsumerBackpressured = needsBackpressure
        connection?.sseClient?.setConsumerBackpressured(needsBackpressure)
    }

    private func ensureFlushTimer() {
        guard flushTimer == nil else { return }
        let timer = Timer(timeInterval: Self.flushInterval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.flushStreamingBuffer()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        flushTimer = timer
    }

    private func flushStreamingBuffer() {
        flushTimer?.invalidate()
        flushTimer = nil

        guard hasBufferedStreamingUpdates else { return }

        // Reporting the fixed cap avoids scanning a potentially long FIFO only
        // to construct instrumentation metadata on the UI actor.
        let signpostID = ChatStreamInstrumentation.beginStreamingFlush(
            chunkCount: Self.maximumStreamingChunksPerFlush
        )
        defer {
            ChatStreamInstrumentation.endStreamingFlush(signpostID)
        }

        var changedContent = false
        var requiresTimelineRebuild = false
        var remainingChunkBudget = Self.maximumStreamingChunksPerFlush
        var remainingRecordBudget = Self.maximumStreamingRecordsPerFlush

        while remainingChunkBudget > 0,
              remainingRecordBudget > 0,
              let (mailboxMessageID, mailbox) = nextStreamingMailbox(),
              var update = mailbox.first {
            remainingRecordBudget -= 1

            let chunkCount = min(remainingChunkBudget, update.chunks.count)
            guard chunkCount > 0 else {
                if let discarded = mailbox.removeFirst() {
                    bufferedStreamingRecordCount -= 1
                    bufferedStreamingChunkCount -= discarded.chunks.count
                }
                if mailbox.isEmpty {
                    streamingUpdateMailboxes.removeValue(forKey: mailboxMessageID)
                }
                continue
            }

            let resolvedMessageID = resolvedStreamingMessageID(update.messageID)
            let targetMessage: ChatMessage?
            if update.partID != nil {
                targetMessage = assistantMessage(withID: resolvedMessageID)
                guard targetMessage != nil else {
                    if let discarded = mailbox.removeFirst() {
                        bufferedStreamingRecordCount -= 1
                        bufferedStreamingChunkCount -= discarded.chunks.count
                    }
                    if mailbox.isEmpty {
                        streamingUpdateMailboxes.removeValue(forKey: mailboxMessageID)
                    }
                    continue
                }
            } else {
                targetMessage = pendingAssistantMessage?.id == resolvedMessageID
                    ? pendingAssistantMessage
                    : nil
                guard targetMessage != nil else {
                    if let discarded = mailbox.removeFirst() {
                        bufferedStreamingRecordCount -= 1
                        bufferedStreamingChunkCount -= discarded.chunks.count
                    }
                    if mailbox.isEmpty {
                        streamingUpdateMailboxes.removeValue(forKey: mailboxMessageID)
                    }
                    continue
                }
            }

            let end = update.chunks.index(
                update.chunks.startIndex,
                offsetBy: chunkCount
            )
            // At most `maximumStreamingChunksPerFlush` elements are copied for
            // the view handoff. Advancing ArraySlice itself is O(1).
            let chunks = Array(update.chunks[..<end])
            update.chunks = update.chunks[end...]
            remainingChunkBudget -= chunkCount

            if let partID = update.partID, let message = targetMessage {
                let insertedReasoningSegment = message.appendStreamingReasoning(
                    partID: partID,
                    text: "",
                    chunks: chunks
                )
                requiresTimelineRebuild = requiresTimelineRebuild || insertedReasoningSegment
                changedContent = true
            } else if let pending = targetMessage {
                let wasEmpty = pending.streamingTextProjection.hasText
                pending.appendStreamingText("", chunks: chunks)
                requiresTimelineRebuild = requiresTimelineRebuild
                    || (!wasEmpty && pending.streamingTextProjection.hasText)
                changedContent = true
            }

            if !update.chunks.isEmpty {
                // FIFO ordering is deliberate: a large text snapshot must not
                // let a later stream update leapfrog it.
                mailbox.replaceFirst(with: update)
                bufferedStreamingChunkCount -= chunkCount
                break
            }

            if let completed = mailbox.removeFirst() {
                bufferedStreamingRecordCount -= 1
                bufferedStreamingChunkCount -= completed.chunks.count
            }
            if mailbox.isEmpty {
                streamingUpdateMailboxes.removeValue(forKey: mailboxMessageID)
            }
        }

        updateStreamingConsumerPressure()

        if changedContent {
            contentVersion &+= 1
            if requiresTimelineRebuild {
                timelineVersion &+= 1
            }
        }

        if hasBufferedStreamingUpdates {
            ensureFlushTimer()
        }
    }

    nonisolated private static func materialize(
        _ baseSnapshot: ChatMessage.StreamingMaterialization,
        appending bufferedUpdates: DetachedStreamingUpdates
    ) -> ChatMessage.MaterializedStreamingContent {
        guard !bufferedUpdates.isEmpty else {
            return ChatMessage.materialize(baseSnapshot)
        }

        var contentChunks = baseSnapshot.contentChunks
        var reasoningChunksByPartID = baseSnapshot.reasoningChunksByPartID
        var additionalChunkCount = 0

        bufferedUpdates.forEachInFIFO { update in
            additionalChunkCount += update.chunks.count
            if let partID = update.partID {
                reasoningChunksByPartID[partID, default: []].append(contentsOf: update.chunks)
            } else {
                contentChunks.append(contentsOf: update.chunks)
            }
        }

        return ChatMessage.materialize(
            ChatMessage.StreamingMaterialization(
                contentChunks: contentChunks,
                reasoningChunksByPartID: reasoningChunksByPartID,
                estimatedCharacterCount: baseSnapshot.estimatedCharacterCount
                    + additionalChunkCount * 2_400
            )
        )
    }

    private func stopFlushTimer() {
        flushTimer?.invalidate()
        flushTimer = nil
    }

    private func stopFlushTimerIfIdle() {
        if !hasBufferedStreamingUpdates {
            stopFlushTimer()
        }
    }

    /// A final/stop event detaches the active assistant mailbox for worker-side
    /// materialization. A late reasoning update for an older message can still
    /// own a secondary mailbox, though; leaving its timer cancelled would hold
    /// consumer backpressure forever. Keep draining those FIFO entries until
    /// the global low watermark can release the transport.
    private func continueStreamingFlushIfNeeded() {
        guard hasBufferedStreamingUpdates else {
            stopFlushTimer()
            return
        }

        ensureFlushTimer()
    }

    private func resetSessionState() {
        abortTask?.cancel()
        abortTask = nil
        streamingFinalizationTokens.removeAll()
        cancelStoppedStateClear()
        ignoredAssistantMessageIDs.removeAll()
        locallyStoppedSessionID = nil
        demoPlayer?.stop()
        recordedReplayPlayer?.stop()
        streamRecorder = nil
        isRecordingStream = false
        connection?.sseClient?.setRawEventRetentionEnabled(false)
        isLoading = false
        responseState = .idle
        stopFlushTimer()
        cancelTimelineInvalidation()
        discardAllBufferedStreamingUpdates()
        streamingMessageIDRemaps.removeAll()
        pendingAssistantMessage = nil
        messages = []
        displayLimit = pageSize
        currentActivity = nil
        lastCompletedActivity = nil
        errorMessage = nil
        pendingPermission = nil
        showPermissionAlert = false
        pendingQuestion = nil
        showQuestionSheet = false
        sessionStatus = nil
        todos = []
        hiddenTodoCount = 0
        cancelQuestionTimeout()
        responseStartDate = nil
    }

    /// Finalizes the visible projection into the immutable transcript. The
    /// projection snapshot is cheap to take on MainActor; joining a large text
    /// and several reasoning streams happens on a dedicated worker instead.
    private func finalizePendingAssistantMessage(
        _ pending: ChatMessage,
        appendsWhenEmpty: Bool,
        bufferedUpdates: DetachedStreamingUpdates = .empty
    ) {
        // This only captures the existing projection containers. Any not-yet-
        // rendered ring entries stay detached and are merged on the worker.
        let snapshot = pending.streamingMaterializationSnapshot()
        let shouldAppend = appendsWhenEmpty
            || pending.streamingTextProjection.hasText
            || !pending.parts.isEmpty
            || !bufferedUpdates.isEmpty

        guard shouldAppend else {
            pending.isStreaming = false
            pendingAssistantMessage = nil
            return
        }

        if bufferedUpdates.isEmpty,
           snapshot.estimatedCharacterCount <= Self.asynchronousMaterializationThreshold {
            pending.applyStreamingMaterialization(ChatMessage.materialize(snapshot))
            pending.isStreaming = false
            // Clear pending FIRST to avoid a transient duplicate in
            // rebuildDisplayedMessages (messages.append triggers didSet which
            // would still see the pending message).
            pendingAssistantMessage = nil
            if !messages.contains(where: { $0.id == pending.id }) {
                messages.append(pending)
            }
            return
        }

        // Move the same object into the canonical list immediately. It remains
        // chunked/streaming until the worker returns, so another user turn can
        // start without losing this finished response.
        let messageID = pending.id
        pendingAssistantMessage = nil
        if !messages.contains(where: { $0.id == messageID }) {
            messages.append(pending)
        }

        let token = UUID()
        streamingFinalizationTokens[messageID] = token
        Self.streamingMaterializationQueue.async { [weak self] in
            let materialized = Self.materialize(snapshot, appending: bufferedUpdates)
            DispatchQueue.main.async {
                guard let self,
                      self.streamingFinalizationTokens[messageID] == token,
                      let message = self.messages.first(where: { $0.id == messageID })
                else {
                    return
                }

                message.applyStreamingMaterialization(materialized)
                message.isStreaming = false
                self.streamingFinalizationTokens.removeValue(forKey: messageID)
                self.contentVersion &+= 1
                // The cached timeline switches its row kind from the live
                // streaming projection to the finalized Markdown message.
                self.timelineVersion &+= 1
            }
        }
    }

    // MARK: - Finish Loading

    func finishLoading() {
        isLoading = false
        abortTask = nil

        // Do not synchronously drain a giant final SSE snapshot here. The
        // already-rendered projection stays visible while the worker joins the
        // remaining chunk references into the immutable transcript.
        stopFlushTimer()
        flushStreamingBuffer()

        // Publish the completed assistant message to the chat. Large streams
        // stay in their chunked form until their canonical transcript has been
        // assembled on a worker queue.
        if let pending = pendingAssistantMessage {
            let bufferedUpdates = detachBufferedStreamUpdates(for: pending.id)
            finalizePendingAssistantMessage(
                pending,
                appendsWhenEmpty: true,
                bufferedUpdates: bufferedUpdates
            )
        }
        continueStreamingFlushIfNeeded()

        responseStartDate = nil

        liveActivityTracker?.end()

        if let activity = currentActivity {
            lastCompletedActivity = activity
        }
        currentActivity = nil
        sessionStatus = nil
        markResponseIdleAfterFinish()

        contentVersion &+= 1
    }
}

#if DEBUG
extension ChatClient {
    /// Narrow test seam for the bounded render mailbox. It deliberately exposes
    /// counts rather than storage, so tests can prove consumed chunks are
    /// released without inspecting or copying transcript text.
    var bufferedStreamingMetricsForTesting: (records: Int, chunks: Int, isBackpressured: Bool) {
        (
            records: bufferedStreamingRecordCount,
            chunks: bufferedStreamingChunkCount,
            isBackpressured: isStreamingConsumerBackpressured
        )
    }
}
#endif

private final class NoopLiveActivityProvider: LiveActivityProviding {
    var isActive: Bool { false }

    func startActivity(agentName: String, userTask: String, subject: String?) {}

    func update(
        subject: String?,
        currentIntent: String,
        currentIntentIcon: String?,
        previousIntent: String?,
        secondPreviousIntent: String?,
        stepNumber: Int,
        costTotal: String?,
        pendingUserResponse: OpenLensActivityAttributes.PendingUserResponse?
    ) {}

    func endActivity(completionSummary: String?) {}

    func previewLiveActivity() {}
}
