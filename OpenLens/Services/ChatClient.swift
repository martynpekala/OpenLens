import SwiftUI
import UIKit
import os

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
    var errorMessage: String?

    /// Incremented when the chat should programmatically snap to the bottom.
    var scrollAnchor: UInt = 0

    /// Incremented when message content changes and the scroll view may need to
    /// update layout without forcing a scroll jump on every streaming flush.
    var contentVersion: UInt = 0

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

    /// Duration before a pending question is auto-rejected (5 minutes).
    private static let questionTimeoutSeconds: UInt64 = 300

    // MARK: - Streaming Text Buffer
    //
    // Text deltas from SSE accumulate on `pendingAssistantMessage.content`.
    // A flush timer coalesces rapid deltas into ~40ms UI updates, bumping

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

    /// Coalesces rapid SSE text deltas into batched UI updates (~40ms).
    @ObservationIgnored private var streamingBuffer: String = ""
    @ObservationIgnored private var flushTimer: Timer?

    /// Interval between streaming buffer flushes (seconds).
    private static let flushInterval: TimeInterval = 0.04

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
            self.messages = loaded
            syncSessionModelSelection(from: loaded)
            Logger.debug.info("messages count: \(loaded.count)")
            self.contentVersion &+= 1
            self.scrollAnchor &+= 1
        } catch {
            self.errorMessage = "Failed to load messages: \(error.localizedDescription)"
        }

        await loadTodos()
    }

    func loadTodos() async {
        guard let session = currentSession,
              let client = connection?.client else {
            Logger.debug.info("[TODO] loadTodos skipped: no session or client")
            return
        }
        do {
            let loaded = try await client.listTodos(sessionID: session.id)
            self.todos = loaded
            Logger.debug.info("[TODO] loaded \(loaded.count) todos from API")
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

        do {
            let result = try await providersService!.loadProviders()
            self.providers = result.providers
            self.connectedProviderIDs = result.connectedProviderIDs

            // Always sync model from server on connect — override any local selection
            if let providerID = result.defaultProviderID, let modelID = result.defaultModelID {
                self.selectedProviderID = providerID
                self.selectedModelID = modelID
                self.selectedVariant = nil
                // Clear persisted override so next launch also syncs from server
                if let connID = savedConnectionsStore?.activeConnectionID {
                    savedConnectionsStore?.clearModelSelection(connectionID: connID)
                }
            }
        } catch {
            Logger.chat.error("loadProviders failed: \(error, privacy: .public)")
        }

        // Fallback: try config for default model (matches server session config)
        if selectedProviderID.isEmpty,
           let providerID = configResult.defaultProviderID,
           let modelID = configResult.defaultModelID {
            self.selectedProviderID = providerID
            self.selectedModelID = modelID
            self.selectedVariant = nil
            if let connID = savedConnectionsStore?.activeConnectionID {
                savedConnectionsStore?.clearModelSelection(connectionID: connID)
            }
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

    func updateSlashCatalog(commands: [String], agents: [String]) {
        availableSlashCommandMap = Dictionary(uniqueKeysWithValues: commands.map { ($0.lowercased(), $0) })
        availableSlashAgentMap = Dictionary(uniqueKeysWithValues: agents.map { ($0.lowercased(), $0) })
    }

    // MARK: - Send Message

    func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isLoading, currentSession != nil else { return }

        haptics.prepareForResponse()

        if isDemoMode {
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

        let userMessage = ChatMessage(role: .user, content: text)
        messages.append(userMessage)
        inputText = ""
        isLoading = true

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
        let userMessage = ChatMessage(role: .user, content: text)
        messages.append(userMessage)
        inputText = ""
        isLoading = true

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
        let userMessage = ChatMessage(role: .user, content: text)
        messages.append(userMessage)
        inputText = ""
        isLoading = true

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
            isLoading = false
            errorMessage = "Not connected."
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
            isLoading = false
            if let agent, !agent.isEmpty {
                errorMessage = "Failed to run /\(agent): \(error.localizedDescription)"
            } else {
                errorMessage = "Failed to send: \(error.localizedDescription)"
            }
            currentActivity = nil
            responseStartDate = nil
            liveActivityTracker?.end()
        }
    }

    private func sendCommandAsync(command: String, arguments: String) async {
        guard let session = currentSession else {
            isLoading = false
            errorMessage = "Not connected."
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
            isLoading = false
            errorMessage = "Failed to run /\(command): \(error.localizedDescription)"
            currentActivity = nil
            responseStartDate = nil
            liveActivityTracker?.end()
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
        if isDemoMode {
            demoPlayer?.stop()
            finishLoading()
            return
        }

        if isRecordedReplayMode {
            recordedReplayPlayer?.stop()
            if isLoading || pendingAssistantMessage != nil {
                finishLoading()
            }
            return
        }

        guard let session = currentSession else { return }

        Task {
            try? await messagesService?.abort(sessionID: session.id)
        }
    }

    // MARK: - SSE Setup

    func setupSSEHandlers() {
        guard let connection, let sseClient = connection.sseClient else { return }

        // Keep SSE handler's refs in sync
        sseHandler?.connectionClient = connection.client
        sseHandler?.connectionManager = connection

        sseClient.onEvent = { [weak self] event in
            self?.recordIncomingEvent(event)
            self?.sseHandler?.handleEvent(event)
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
    }

    func stopStreamRecording() {
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

    func respondToPermission(requestID: String, approve: Bool) async {
        guard let questionService else {
            errorMessage = "Failed to respond to permission: Not connected."
            return
        }

        do {
            try await questionService.respondToPermission(
                requestID: requestID,
                approve: approve
            )

            if pendingPermission?.id == requestID {
                pendingPermission = nil
                showPermissionAlert = false
            }

            await recoverPendingPermission()
        } catch {
            errorMessage = "Failed to respond to permission: \(error.localizedDescription)"
        }
    }

    /// Recover any pending permission from the server for the current session.
    func recoverPendingPermission() async {
        guard !isOfflinePreviewMode, let sessionID = currentSession?.id else { return }

        do {
            let permission = try await questionService?.recoverPendingPermission(sessionID: sessionID)

            if let permission {
                pendingPermission = permission
                showPermissionAlert = true
            } else if pendingPermission?.sessionID == sessionID {
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
        guard let pending = pendingAssistantMessage, pending.id == messageID else { return }
        streamingBuffer += text
        ensureFlushTimer()
    }

    func clearStreamingBuffer(messageID: String) {
        guard let pending = pendingAssistantMessage, pending.id == messageID else { return }
        stopFlushTimer()
        streamingBuffer = ""
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

        let bufferedText = streamingBuffer
        guard !bufferedText.isEmpty,
              let pending = pendingAssistantMessage else {
            streamingBuffer = ""
            return
        }

        let signpostID = ChatStreamInstrumentation.beginStreamingFlush(characterCount: bufferedText.count)
        defer {
            ChatStreamInstrumentation.endStreamingFlush(signpostID)
        }

        pending.content += bufferedText
        streamingBuffer = ""
        contentVersion &+= 1
    }

    private func stopFlushTimer() {
        flushTimer?.invalidate()
        flushTimer = nil
    }

    private func resetSessionState() {
        demoPlayer?.stop()
        recordedReplayPlayer?.stop()
        streamRecorder = nil
        isRecordingStream = false
        stopFlushTimer()
        streamingBuffer = ""
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
        cancelQuestionTimeout()
        responseStartDate = nil
    }

    // MARK: - Finish Loading

    func finishLoading() {
        isLoading = false

        // Drain any remaining buffered text before committing.
        stopFlushTimer()
        if !streamingBuffer.isEmpty, let pending = pendingAssistantMessage {
            pending.content += streamingBuffer
            streamingBuffer = ""
        }

        // Publish the completed assistant message to the chat.
        if let pending = pendingAssistantMessage {
            pending.isStreaming = false
            // Clear pending FIRST to avoid a transient duplicate in
            // rebuildDisplayedMessages (messages.append triggers didSet
            // which would still see the pending message).
            pendingAssistantMessage = nil
            messages.append(pending)
        }

        responseStartDate = nil

        liveActivityTracker?.end()

        if let activity = currentActivity {
            lastCompletedActivity = activity
        }
        currentActivity = nil
        sessionStatus = nil

        contentVersion &+= 1
    }
}

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
