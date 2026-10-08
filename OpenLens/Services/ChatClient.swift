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

struct QueuedPrompt: Identifiable, Equatable {
    enum State: Equatable {
        /// Sent by this client; the server has not confirmed admission yet.
        case submitting
        /// Accepted by the server and waiting in the session inbox.
        case queued
    }

    /// The supported v2 inbox entry types.
    enum Kind: Equatable {
        case user
        case synthetic(description: String?)
        case compaction
        case move(directory: String?)
    }

    let id: UUID
    let messageID: String
    let text: String
    let attachments: [PromptAttachment]
    var state: State
    var kind: Kind = .user
    var delivery: OCV2PromptInput.Delivery = .queue
    /// Files attached by another client, known only by name.
    var fileNames: [String] = []

    init(
        id: UUID = UUID(),
        messageID: String = UUID().uuidString,
        text: String,
        attachments: [PromptAttachment] = [],
        state: State,
        kind: Kind = .user,
        delivery: OCV2PromptInput.Delivery = .queue,
        fileNames: [String] = []
    ) {
        self.id = id
        self.messageID = messageID
        self.text = text
        self.attachments = attachments
        self.state = state
        self.kind = kind
        self.delivery = delivery
        self.fileNames = fileNames
    }

    /// One-based positions of accepted queue-mode entries; steers and
    /// unconfirmed submissions have no position in the queue.
    static func queuePositions(_ prompts: [QueuedPrompt]) -> [UUID: Int] {
        var positions: [UUID: Int] = [:]
        for prompt in prompts where prompt.state == .queued && prompt.delivery == .queue {
            positions[prompt.id] = positions.count + 1
        }
        return positions
    }
}

/// A v2 prompt admission attempt, keyed by its caller-provided message ID.
/// `uncertain` means the request may have reached the server but admission
/// could not be confirmed; resending the same text and attachments reuses the same
/// ID so the server's first-admission-wins reconciliation prevents duplicate work.
struct PromptSubmission: Identifiable, Equatable {
    enum State: Equatable {
        case sending
        case accepted(admissionID: String)
        case uncertain
        case failed
    }

    let id: String
    let sessionID: String
    /// Raw composer text, used to match retries and to restore the composer.
    let text: String
    /// The exact prepared attachments, so a retry resends identical bytes.
    let attachments: [PromptAttachment]
    var state: State
}

private enum PromptAdmissionOutcome: Equatable {
    case admitted(admissionID: String)
    case uncertain
    case failed
}

private struct OptimisticV2CommandMessage {
    let text: String
    let knownTranscriptMessageIDs: Set<String>
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
        didSet {
            if !reconcileLiveAssistantMessagesWithLoadedHistory() {
                rebuildDisplayedMessages()
            }
        }
    }
    var inputText: String = ""
    private(set) var composerAttachments: [PromptAttachment] = []
    private(set) var isPreparingComposerImage = false
    var isLoading: Bool = false
    /// True while a follow-up is being admitted to the server-side turn queue.
    var isQueueingPrompt: Bool = false
    /// Follow-ups that were admitted behind the active turn but have not been
    /// promoted into the visible transcript yet.
    var queuedPrompts: [QueuedPrompt] = []
    private(set) var queuedPromptMutationID: UUID?
    private(set) var promptSubmissions: [PromptSubmission] = []
    /// True while OpenCode is reverting a selected user message.
    var isUndoingMessage: Bool = false
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
    var currentSession: OCSession? {
        didSet {
            guard currentSession?.id != oldValue?.id
                    || currentSession?.model != oldValue?.model
                    || currentSession?.agent != oldValue?.agent else { return }
            applyCanonicalSessionSettings()
        }
    }

    /// Agent activity tracker for shimmer display.
    var currentActivity: AgentActivity?
    var lastCompletedActivity: AgentActivity?
    var showActivityCard: Bool = false

    /// Assistant message being built during streaming. Kept separate from
    /// `messages` so SSE handlers can mutate it freely. Included at the tail
    /// of `displayedMessages` so the UI shows the growing text bubble.
    /// Committed to `messages` on `finishLoading()`.
    var pendingAssistantMessage: ChatMessage? {
        didSet {
            if !reconcileLiveAssistantMessagesWithLoadedHistory() {
                rebuildDisplayedMessages()
            }
        }
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
    /// Pending v2 form. Forms are distinct from legacy questions because their
    /// field values and cancellation operation are session-scoped.
    var pendingForm: OCFormRequest? {
        didSet { syncLiveActivityPendingUserResponse() }
    }
    var showFormSheet: Bool = false
    var isResolvingForm: Bool = false
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
    private var inMemoryRecentModelIDs: [String] = []
    private var globalQuickModelAssignments: [ModelQuickAction: QuickModelAssignment] = AppPreferences.quickModelAssignments()
    var quickModelAssignmentsVersion: UInt = 0

    /// Provider filter lists from server config (enabled_providers / disabled_providers).
    private var enabledProviders: [String]? {
        didSet { rebuildAvailableModels() }
    }
    private var disabledProviders: [String]? {
        didSet { rebuildAvailableModels() }
    }
    private var availableSlashCommandMap: [String: String] = [:]
    private var availableSlashAgentMap: [String: String] = [:]
    private var availableSkillIDs: [String] = []

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
        /// Non-text input media explicitly listed by the v2 runtime catalog.
        /// `nil` preserves the v1 attachment-only presentation.
        let inputMedia: [String]?
        /// A runtime catalog can report multiple price tiers. v1 models retain
        /// their single `cost` value instead.
        let costTiers: [OCModelCost]
        var id: String { "\(providerID)/\(modelID)" }

        // Hashable conformance ignoring cost/limit (non-Hashable)
        func hash(into hasher: inout Hasher) {
            hasher.combine(id)
        }

        static func == (lhs: SelectableModel, rhs: SelectableModel) -> Bool {
            lhs.id == rhs.id
        }

        init(
            providerID: String,
            providerName: String,
            modelID: String,
            modelName: String,
            reasoning: Bool,
            attachment: Bool,
            toolCall: Bool,
            cost: OCModelCost?,
            limit: OCModelLimit?,
            variants: [SelectableVariant],
            inputMedia: [String]? = nil,
            costTiers: [OCModelCost] = []
        ) {
            self.providerID = providerID
            self.providerName = providerName
            self.modelID = modelID
            self.modelName = modelName
            self.reasoning = reasoning
            self.attachment = attachment
            self.toolCall = toolCall
            self.cost = cost
            self.limit = limit
            self.variants = variants
            self.inputMedia = inputMedia
            self.costTiers = costTiers
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
        guard !selectedProviderID.isEmpty, !selectedModelID.isEmpty else { return }

        let selectionID = "\(selectedProviderID)/\(selectedModelID)"
        guard let connID = savedConnectionsStore?.activeConnectionID else {
            guard isDemoMode else { return }
            inMemoryRecentModelIDs.removeAll { $0 == selectionID }
            inMemoryRecentModelIDs.insert(selectionID, at: 0)
            inMemoryRecentModelIDs = Array(inMemoryRecentModelIDs.prefix(5))
            return
        }

        // A v2 session owns its settings; switching one must not change the
        // preference that seeds new sessions.
        if usesV2SessionAPI, currentSession != nil {
            savedConnectionsStore?.recordRecentModelSelection(
                connectionID: connID,
                providerID: selectedProviderID,
                modelID: selectedModelID
            )
            return
        }

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
                    variants: sortedVariants(from: model.variants),
                    inputMedia: model.inputMedia,
                    costTiers: model.costTiers ?? []
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
        guard let saved = savedConnectionsStore?.defaultModelSelection(connectionID: activeConnectionID) else { return nil }
        return Self.resolveSavedModelSelection(
            providerID: saved.providerID,
            modelID: saved.modelID,
            availableModels: availableModels,
            legacyModelIDs: legacyModelIDs
        ).map { (providerID: $0.providerID, modelID: $0.modelID) }
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
        return AppText.chooseModel
    }

    var recentModelIDs: [String] {
        guard let savedConnectionsStore, let connectionID = quickModelConnectionID else {
            return inMemoryRecentModelIDs
        }
        return savedConnectionsStore.recentModelSelections(connectionID: connectionID).map { saved in
            Self.resolveSavedModelSelection(
                providerID: saved.providerID,
                modelID: saved.modelID,
                availableModels: availableModels,
                legacyModelIDs: legacyModelIDs
            )?.id ?? saved.id
        }
    }

    private var legacyModelIDs: [String: String] {
        Self.legacyModelIDMap(providers: providers)
    }

    /// Maps `provider/legacyModelID` to a v2 catalog model ID. Several catalog
    /// aliases can share one upstream model, so collisions resolve to the
    /// lexicographically smallest catalog ID to stay deterministic.
    static func legacyModelIDMap(providers: [OCProvider]) -> [String: String] {
        Dictionary(
            providers.flatMap { provider in
                provider.models.values.compactMap { model in
                    model.legacyModelID.map { ("\(provider.id)/\($0)", model.id) }
                }
            },
            uniquingKeysWith: { min($0, $1) }
        )
    }

    /// Models assigned to the global Code and Review quick actions.
    /// A revision counter keeps views that read the persisted preferences up
    /// to date after an assignment changes.
    var quickModelAssignments: [ModelQuickAction: QuickModelAssignment] {
        _ = quickModelAssignmentsVersion
        return globalQuickModelAssignments
    }

    func quickModelAssignment(for action: ModelQuickAction) -> QuickModelAssignment? {
        quickModelAssignments[action]
    }

    private var quickModelConnectionID: String? {
        guard let savedConnectionsStore else { return nil }
        return savedConnectionsStore.activeConnectionID ?? savedConnectionsStore.mostRecent?.id
    }

    /// Saves a model and optional reasoning variant for a quick action without
    /// changing the active session model.
    func assignQuickModel(
        _ model: SelectableModel,
        variant: String?,
        for action: ModelQuickAction
    ) {
        let validVariant = variant.flatMap { variantID in
            model.variants.contains(where: {
                $0.id == variantID && $0.value.isThinkingEffortVariant
            }) ? variantID : nil
        }
        globalQuickModelAssignments[action] = QuickModelAssignment(
            providerID: model.providerID,
            modelID: model.modelID,
            variant: validVariant
        )
        AppPreferences.saveQuickModelAssignments(globalQuickModelAssignments)
        quickModelAssignmentsVersion &+= 1
    }

    /// Removes the model assigned to a quick action.
    func clearQuickModelAssignment(for action: ModelQuickAction) {
        globalQuickModelAssignments.removeValue(forKey: action)
        AppPreferences.saveQuickModelAssignments(globalQuickModelAssignments)
        quickModelAssignmentsVersion &+= 1
    }

    /// Updates only the reasoning variant for an existing quick action.
    func updateQuickModelVariant(for action: ModelQuickAction, variantID: String?) {
        guard var assignment = globalQuickModelAssignments[action] else { return }

        if let variantID,
           let model = availableModels.first(where: { $0.id == assignment.id }),
           !model.variants.contains(where: { $0.id == variantID && $0.value.isThinkingEffortVariant }) {
            assignment.variant = nil
        } else {
            assignment.variant = variantID
        }

        globalQuickModelAssignments[action] = assignment
        AppPreferences.saveQuickModelAssignments(globalQuickModelAssignments)
        quickModelAssignmentsVersion &+= 1
    }

    /// Activates the model assigned to a quick action, if it is available.
    @discardableResult
    func selectQuickModelAction(_ action: ModelQuickAction) -> Bool {
        guard let assignment = quickModelAssignment(for: action),
              let model = availableModels.first(where: { $0.id == assignment.id }) else {
            return false
        }

        setSelectedModel(model)
        selectedVariant = assignment.variant
        persistCurrentSelection()
        switchCurrentSessionModelToSelection()
        return true
    }

    struct DefaultModelResolution: Equatable {
        let providerID: String?
        let modelID: String?
        let unavailableDefaultModelID: String?
    }

    static func resolveSavedModelSelection(
        providerID: String,
        modelID: String,
        availableModels: [SelectableModel],
        legacyModelIDs: [String: String]
    ) -> SelectableModel? {
        if let exactMatch = availableModels.first(where: {
            $0.providerID == providerID && $0.modelID == modelID
        }) {
            return exactMatch
        }

        guard let catalogModelID = legacyModelIDs["\(providerID)/\(modelID)"] else { return nil }
        return availableModels.first {
            $0.providerID == providerID && $0.modelID == catalogModelID
        }
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
            if let existingIndex = result.lastIndex(where: { $0.id == pending.id }) {
                result[existingIndex] = pending
            } else {
                result.append(pending)
            }
        }
        displayedMessages = result
        timelineVersion &+= 1
        scheduleTurnDiffLoads(for: result)
    }

    /// A foreground refresh can return an assistant message while the same
    /// local object is still receiving SSE deltas or waiting for worker-side
    /// finalization. Keep that object identity so a stale history response
    /// cannot discard locally buffered suffixes.
    @discardableResult
    private func reconcileLiveAssistantMessagesWithLoadedHistory() -> Bool {
        guard !isReconcilingLiveAssistantMessages else { return false }

        if let pending = pendingAssistantMessage,
           let loaded = messages.last(where: { $0.id == pending.id }),
           loaded !== pending {
            pending.absorbHistorySnapshot(loaded)
        }

        var reconciledMessages = messages
        var replacedFinalizingMessage = false
        for (messageID, finalizing) in finalizingAssistantMessages where finalizing.isStreaming {
            if let loadedIndex = reconciledMessages.lastIndex(where: { $0.id == messageID }) {
                let loaded = reconciledMessages[loadedIndex]
                guard loaded !== finalizing else { continue }
                finalizing.absorbHistorySnapshot(loaded)
                reconciledMessages[loadedIndex] = finalizing
                replacedFinalizingMessage = true
            } else {
                // The REST snapshot can briefly lag behind a just-finished
                // stream. Keep the local transcript until its worker result
                // has been committed instead of making it disappear.
                reconciledMessages.append(finalizing)
                replacedFinalizingMessage = true
            }
        }

        guard replacedFinalizingMessage else { return false }
        isReconcilingLiveAssistantMessages = true
        messages = reconciledMessages
        isReconcilingLiveAssistantMessages = false
        return true
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
    @ObservationIgnored private var interactiveRequestTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var responseStartDate: Date?
    @ObservationIgnored private var streamRecorder: ChatStreamRecorder?
    @ObservationIgnored private var abortTask: Task<Void, Never>?
    @ObservationIgnored private var stoppedStateClearTask: Task<Void, Never>?
    @ObservationIgnored private var ignoredAssistantMessageIDs: Set<String> = []
    /// User rows accepted optimistically by v2. The prompt endpoint accepts a
    /// caller-provided ID, allowing the authoritative transcript to replace
    /// the same row when its projector catches up.
    @ObservationIgnored private var optimisticV2UserMessageIDs: Set<String> = []
    /// The command endpoint does not accept a caller-provided message ID.
    /// Preserve a local command row until a newly projected matching user
    /// message confirms that the server transcript has caught up.
    @ObservationIgnored private var optimisticV2CommandMessages: [String: OptimisticV2CommandMessage] = [:]
    /// Last applied snapshot of the v2 session inbox, the source of
    /// `queuedPrompts`. A read applies only if no newer read has applied and
    /// the session state was not reset while it was in flight.
    @ObservationIgnored private var sessionInbox: [OCV2InboxEntry] = []
    @ObservationIgnored private var inboxReadSequence: UInt = 0
    @ObservationIgnored private var appliedInboxReadSequence: UInt = 0
    @ObservationIgnored private var inboxEpoch: UInt = 0
    /// Entries this client admitted, in admission order, with the last read sequence
    /// started before admission. Reads started earlier cannot include them, so
    /// they stay projected until a later read is applied.
    @ObservationIgnored private var locallyAdmittedInbox: [(entry: OCV2InboxEntry, readSequence: UInt)] = []
    @ObservationIgnored private var locallyStoppedSessionID: String?
    /// A v2 stream has no resume cursor, so a transport or decoding gap must be
    /// reconciled against the session and transcript endpoints. Coalesce gap
    /// notifications while that authoritative refresh is in flight.
    @ObservationIgnored private var streamSynchronizationTask: Task<Void, Never>?
    @ObservationIgnored private var streamSynchronizationGeneration: UInt = 0
    @ObservationIgnored private var streamSynchronizationToken: UUID?
    private(set) var isStreamSynchronized = true

    /// Duration before a pending question is auto-rejected (5 minutes).
    private static let interactiveRequestTimeoutSeconds: UInt64 = 300
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

    nonisolated private enum BufferedStreamTarget: Sendable, Equatable {
        case fallbackText
        case textPart(String)
        case reasoningPart(String)
    }

    nonisolated private struct BufferedStreamUpdate: Sendable {
        let messageID: String
        let target: BufferedStreamTarget
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
    /// Retains the live object while a worker joins it. A history refresh may
    /// replace the array entry with a stale snapshot, so its identity must be
    /// restored before the worker callback validates membership.
    @ObservationIgnored private var finalizingAssistantMessages: [String: ChatMessage] = [:]
    @ObservationIgnored private var isReconcilingLiveAssistantMessages = false
    @ObservationIgnored private var turnDiffTasksByAssistantID: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var resolvedTurnDiffAssistantIDs = Set<String>()
    @ObservationIgnored private var turnFileDetailCache: [TurnFileDetailCacheKey: ReviewFileChange] = [:]
    @ObservationIgnored private var turnFileDetailCacheOrder: [TurnFileDetailCacheKey] = []

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
    private static let maximumTurnFileDetailCacheCount = 12

    private struct TurnFileDetailCacheKey: Hashable {
        let userMessageID: String
        let path: String
    }

    private func syncLiveActivityPendingUserResponse() {
        guard let liveActivityTracker else { return }

        if let pendingPermission {
            liveActivityTracker.setPendingPermission(pendingPermission)
        } else if let pendingQuestion {
            liveActivityTracker.setPendingQuestion(pendingQuestion)
        } else if let pendingForm {
            liveActivityTracker.setPendingForm(pendingForm)
        } else {
            liveActivityTracker.clearPendingUserResponse()
        }
    }

    // MARK: - SSEEventHandlerDelegate

    var currentSessionID: String? { currentSession?.id }

    func questionDidPresent() {
        startInteractiveRequestTimeout()
    }

    @discardableResult
    func presentForm(_ form: OCFormRequest) -> Bool {
        guard pendingQuestion == nil else { return false }

        if pendingForm?.id == form.id {
            if !showFormSheet, !isResolvingForm {
                showFormSheet = true
            }
            return true
        }

        guard pendingForm == nil else { return false }
        pendingForm = form
        showFormSheet = true
        startInteractiveRequestTimeout()
        return true
    }

    func formDidResolve(id: String) {
        guard pendingForm?.id == id else { return }
        cancelInteractiveRequestTimeout()
        pendingForm = nil
        showFormSheet = false
        isResolvingForm = false
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
        case .stopping, .stopped, .idle:
            ignoredAssistantMessageIDs.insert(messageID)
            return true
        case .generating, .failed:
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
        liveActivity: any LiveActivityProviding,
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
            let session = try await sessionsService!.ensureSession(
                model: await newSessionModelPreference()
            )
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

        // A listed session can be stale: another client may have switched its
        // model or agent since the list loaded. v2 sessions own that selection,
        // so open them from a fresh snapshot and fall back to the list entry.
        var session = session
        if usesV2SessionAPI, let sessionsService,
           let freshSession = try? await sessionsService.getSession(id: session.id) {
            guard !Task.isCancelled else { return }
            session = freshSession
        }

        // Session-scoped API calls can be read without a location, but the chat
        // toolbar and workspace-dependent controls use the connection's active
        // project context. Switch it before loading the transcript so a session
        // opened from another directory does not inherit the previously viewed
        // project's name, branch, commands, or files.
        await restoreProjectContext(for: session)
        guard !Task.isCancelled else { return }

        // Attachments picked for one session must never be sent to another.
        if currentSession?.id != session.id {
            composerAttachments = []
        }

        // Drain any in-flight state from the previous session
        resetSessionState()

        currentSession = session

        setupSSEHandlers()
        if providers.isEmpty {
            await loadProviders()
        }
        guard !Task.isCancelled, currentSession?.id == session.id else { return }
        let didLoadMessages = await loadMessages()
        guard !Task.isCancelled, currentSession?.id == session.id else { return }
        let permissionRecovered = await recoverPendingPermission()
        let questionRecovered = await recoverPendingQuestions()
        let formRecovered = await recoverPendingForms()
        guard !Task.isCancelled, currentSession?.id == session.id else { return }
        isStreamSynchronized = didLoadMessages && permissionRecovered && questionRecovered && formRecovered
    }

    func restoreProjectContext(for session: OCSession) async {
        guard let directory = session.directory?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank,
              connection?.selectedProjectDirectory != directory else { return }
        await connection?.setProjectContext(directory: directory)
    }

    @discardableResult
    func loadMessages(syncModelSelection: Bool = true) async -> Bool {
        guard !isOfflinePreviewMode, let session = currentSession else { return false }

        // Read the inbox before the transcript: an entry delivered in between
        // then appears in both and is shown once, rather than in neither.
        var inboxRecovered = false
        do {
            inboxRecovered = await recoverSessionInbox() == .current
            guard !Task.isCancelled, currentSession?.id == session.id else { return false }
            let loaded = try await messagesService!.loadMessages(sessionID: session.id)
            guard !Task.isCancelled, currentSession?.id == session.id else { return false }
            let loadedIDs = Set(loaded.map(\.id))
            queuedPrompts.removeAll { prompt in
                prompt.state == .queued && loadedIDs.contains(prompt.messageID)
            }
            let mergedMessages = mergeLoadedMessagesWithLocalMessages(loaded)
            let revert = currentSession?.id == session.id
                ? currentSession?.revert
                : session.revert
            let visibleMessages = Self.messagesBeforeRevert(mergedMessages, revert: revert)
            prepareTurnDiffRefresh(for: visibleMessages)
            preserveTurnFileChanges(in: visibleMessages)
            self.messages = visibleMessages
            projectSessionInbox()
            // v2 sessions carry their canonical selection; transcript history
            // and saved defaults must not override it.
            if syncModelSelection, !usesV2SessionAPI {
                if Self.recentSessionModelSelection(from: visibleMessages) != nil {
                    syncSessionModelSelection(from: visibleMessages)
                } else {
                    applyPreferredDefaultModelSelection()
                }
            }
            Logger.debug.info("messages count: \(visibleMessages.count)")
            self.contentVersion &+= 1
            self.scrollAnchor &+= 1
        } catch is CancellationError {
            return false
        } catch {
            guard currentSession?.id == session.id else { return false }
            self.errorMessage = "Failed to load messages: \(error.localizedDescription)"
            return false
        }

        let statusRecovered = await refreshCurrentSessionStatus()
        await loadTodos()
        return inboxRecovered && statusRecovered && !Task.isCancelled && currentSession?.id == session.id
    }

    func unloadSession(ifMatching sessionID: String) {
        guard currentSession?.id == sessionID else { return }
        resetSessionState()
        currentSession = nil
        inputText = ""
        composerAttachments = []
    }

    nonisolated static func messagesBeforeRevert(
        _ messages: [ChatMessage],
        revert: OCSessionRevert?
    ) -> [ChatMessage] {
        guard let revert else { return messages }
        if let revertedIndex = messages.firstIndex(where: { $0.id == revert.messageID }) {
            return Array(messages[..<revertedIndex])
        }
        return messages.filter { $0.id < revert.messageID }
    }

    /// Whether the current transcript can safely undo a persisted user turn.
    /// OpenCode performs the actual revert, so this is intentionally unavailable
    /// for locally simulated and read-only chat modes.
    func canUndo(_ message: ChatMessage) -> Bool {
        message.role == .user
            && !isLoading
            && !isQueueingPrompt
            && !isUndoingMessage
            && !isDemoMode
            && !isRecordedReplayMode
            && !isOfflinePreviewMode
            && currentSession != nil
            && messagesService != nil
    }

    /// Mirrors the TUI's Undo Message command by asking OpenCode to restore the
    /// session state from immediately before the selected user message.
    func undo(_ message: ChatMessage) async {
        guard canUndo(message), let session = currentSession, let messagesService else { return }

        isUndoingMessage = true
        defer { isUndoingMessage = false }

        do {
            let revertedSession = try await messagesService.revertMessage(
                sessionID: session.id,
                messageID: message.id
            )
            guard currentSession?.id == session.id else { return }
            currentSession = revertedSession ?? OCSession(
                id: session.id,
                projectID: session.projectID,
                directory: session.directory,
                parentID: session.parentID,
                title: session.title,
                version: session.version,
                time: session.time,
                share: session.share,
                revert: OCSessionRevert(messageID: message.id),
                agent: session.agent,
                model: session.model
            )
            await loadMessages()
        } catch {
            guard currentSession?.id == session.id else { return }

            let didRefresh: Bool
            if let revertError = error as? OpenCodeError,
               case .incompleteRevert(let recoveredSession, _) = revertError {
                currentSession = recoveredSession
                didRefresh = await loadMessages()
            } else {
                didRefresh = await refreshCurrentSessionFromServer()
            }

            guard currentSession?.id == session.id else { return }
            if !didRefresh {
                discardStaleTranscriptAndDiffState()
            }
            errorMessage = "Failed to undo message: \(error.localizedDescription)"
        }
    }

    /// Invoked by `/undo` in the composer. OpenCode's TUI undo command targets
    /// the most recent user turn, so the mobile command follows the same rule.
    func undoLatestMessage() async {
        guard let message = messages.reversed().first(where: { $0.role == .user }) else {
            errorMessage = "There is no message to undo."
            return
        }

        guard canUndo(message) else {
            errorMessage = isRecordedReplayMode
                ? AppText.recordedReplayReadOnly
                : "Undo is not available right now."
            return
        }

        await undo(message)
    }

    /// Reloads the active session projection and transcript after a user-driven
    /// mutation whose server result may be incomplete or conflict with ongoing
    /// work. The REST snapshot keeps the chat and turn-diff state recoverable.
    @discardableResult
    func refreshCurrentSessionFromServer() async -> Bool {
        guard !isOfflinePreviewMode,
              !isDemoMode,
              !isRecordedReplayMode,
              let sessionID = currentSession?.id,
              let sessionsService
        else { return false }

        do {
            let session = try await sessionsService.getSession(id: sessionID)
            guard currentSession?.id == sessionID else { return false }
            currentSession = session
            let didRefresh = await loadMessages()
            guard currentSession?.id == sessionID else { return false }
            if !didRefresh {
                discardStaleTranscriptAndDiffState()
            }
            return didRefresh
        } catch is CancellationError {
            return false
        } catch {
            guard currentSession?.id == sessionID else { return false }
            discardStaleTranscriptAndDiffState()
            errorMessage = "Failed to refresh the session: \(error.localizedDescription)"
            return false
        }
    }

    private func discardStaleTranscriptAndDiffState() {
        turnDiffTasksByAssistantID.values.forEach { $0.cancel() }
        turnDiffTasksByAssistantID.removeAll()
        resolvedTurnDiffAssistantIDs.removeAll()
        turnFileDetailCache.removeAll()
        turnFileDetailCacheOrder.removeAll()
        pendingAssistantMessage = nil
        messages = []
        contentVersion &+= 1
        timelineVersion &+= 1
        scrollAnchor &+= 1
        isStreamSynchronized = false
    }

    @discardableResult
    func refreshCurrentSessionStatus() async -> Bool {
        guard !isOfflinePreviewMode,
              let sessionsService,
              let sessionID = currentSession?.id else { return false }

        do {
            let statuses = try await sessionsService.getSessionStatuses()
            guard !Task.isCancelled, currentSession?.id == sessionID else { return false }
            reconcileCurrentSessionStatus(statuses[sessionID])
            return true
        } catch {
            if currentSession?.id == sessionID { errorMessage = "Failed to refresh session status: \(error.localizedDescription)" }
            return false
        }
    }

    /// Replaces any potentially incomplete incremental stream state with the
    /// authoritative session and transcript. Calls arriving while a refresh is
    /// in flight collapse into one follow-up pass, preserving the newest state
    /// without concurrent requests racing to overwrite the chat.
    func synchronizeCurrentSessionFromServer() {
        guard !isOfflinePreviewMode,
              !isDemoMode,
              !isRecordedReplayMode,
              currentSession != nil,
              sessionsService != nil,
              messagesService != nil
        else { return }

        streamSynchronizationGeneration &+= 1
        isStreamSynchronized = false
        guard streamSynchronizationTask == nil else { return }
        let token = UUID()
        streamSynchronizationToken = token

        streamSynchronizationTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                guard self.streamSynchronizationToken == token else { break }
                let generation = self.streamSynchronizationGeneration
                let stream = self.connection?.sseClient
                let gapGeneration = await stream?.synchronizationGeneration()
                guard let sessionID = self.currentSession?.id,
                      let sessionsService = self.sessionsService
                else { break }

                do {
                    let session = try await sessionsService.getSession(id: sessionID)
                    guard !Task.isCancelled,
                          self.streamSynchronizationToken == token,
                          self.currentSession?.id == sessionID
                    else { break }
                    self.currentSession = session

                    guard await self.loadMessages(), self.currentSession?.id == sessionID else {
                        break
                    }
                    guard await self.recoverPendingPermission(sessionID: sessionID),
                          !Task.isCancelled, self.currentSession?.id == sessionID,
                          self.streamSynchronizationToken == token else { break }
                    guard await self.recoverPendingQuestions(),
                          !Task.isCancelled, self.currentSession?.id == sessionID,
                          self.streamSynchronizationToken == token else { break }
                    guard await self.recoverPendingForms(),
                          !Task.isCancelled, self.currentSession?.id == sessionID,
                          self.streamSynchronizationToken == token else { break }
                } catch is CancellationError {
                    break
                } catch {
                    guard self.currentSession?.id == sessionID else { break }
                    self.errorMessage = "Failed to synchronize chat: \(error.localizedDescription)"
                    break
                }

                guard generation == self.streamSynchronizationGeneration else { continue }
                if let stream, let gapGeneration {
                    guard await stream.acknowledgeSynchronization(since: gapGeneration) else { continue }
                }
                guard !Task.isCancelled, self.currentSession?.id == sessionID,
                      self.streamSynchronizationToken == token else { break }
                guard generation == self.streamSynchronizationGeneration else { continue }
                self.isStreamSynchronized = true
                if let error = self.errorMessage, [
                    "Failed to refresh session status:", "Failed to recover pending interactions:",
                    "Failed to synchronize chat:", "Failed to load messages:",
                    AppText.sessionInboxLoadFailedPrefix
                ].contains(where: { error.hasPrefix($0) }) {
                    self.errorMessage = nil
                }
                break
            }

            guard self.streamSynchronizationToken == token else { return }
            self.streamSynchronizationTask = nil
            self.streamSynchronizationToken = nil
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

    private func mergeLoadedMessagesWithLocalMessages(_ loaded: [ChatMessage]) -> [ChatMessage] {
        let loadedIDs = Set(loaded.map(\.id))
        optimisticV2UserMessageIDs.subtract(loadedIDs)
        confirmUncertainSubmissions(admittedIDs: loadedIDs)
        let projectedCommandIDs = optimisticV2CommandMessages.compactMap { localID, command in
            let commandWasProjected = loaded.contains { message in
                message.role == .user &&
                    message.content == command.text &&
                    !command.knownTranscriptMessageIDs.contains(message.id)
            }
            return commandWasProjected ? localID : nil
        }
        for localID in projectedCommandIDs {
            optimisticV2CommandMessages.removeValue(forKey: localID)
        }

        let localMessageIDs = ignoredAssistantMessageIDs
            .union(optimisticV2UserMessageIDs)
            .union(optimisticV2CommandMessages.keys)
        guard !localMessageIDs.isEmpty else { return loaded }

        var result = loaded.filter { !ignoredAssistantMessageIDs.contains($0.id) }
        let existingIDs = Set(result.map(\.id))
        let preservedLocalMessages = messages.filter { localMessageIDs.contains($0.id) }
        result.append(contentsOf: preservedLocalMessages.filter { !existingIDs.contains($0.id) })
        return result
    }

    private func preserveTurnFileChanges(in loaded: [ChatMessage]) {
        let existingByID = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        for message in loaded {
            guard let existing = existingByID[message.id], !existing.turnFileChanges.isEmpty else {
                continue
            }
            message.setTurnFileChanges(existing.turnFileChanges)
            resolvedTurnDiffAssistantIDs.insert(message.id)
        }
    }

    private func prepareTurnDiffRefresh(for loaded: [ChatMessage]) {
        for message in loaded where message.role == .assistant {
            turnDiffTasksByAssistantID.removeValue(forKey: message.id)?.cancel()
            resolvedTurnDiffAssistantIDs.remove(message.id)
        }
    }

    private func scheduleTurnDiffLoads(for candidateMessages: [ChatMessage]) {
        guard !isOfflinePreviewMode,
              let sessionID = currentSession?.id,
              messagesService != nil else {
            return
        }

        for message in candidateMessages where message.role == .assistant && !message.isStreaming {
            guard message.parentUserMessageID != nil,
                  !resolvedTurnDiffAssistantIDs.contains(message.id),
                  turnDiffTasksByAssistantID[message.id] == nil else {
                continue
            }

            let assistantMessageID = message.id
            turnDiffTasksByAssistantID[assistantMessageID] = Task { @MainActor [weak self, weak message] in
                guard let self, let message else { return }
                await self.loadTurnDiffSummary(for: message, sessionID: sessionID)
            }
        }
    }

    private func loadTurnDiffSummary(for message: ChatMessage, sessionID: String) async {
        defer { turnDiffTasksByAssistantID.removeValue(forKey: message.id) }

        guard let userMessageID = message.parentUserMessageID,
              let messagesService else {
            return
        }

        for attempt in 0..<2 {
            do {
                let files = try await messagesService.loadTurnFileChanges(
                    sessionID: sessionID,
                    userMessageID: userMessageID
                )
                guard !Task.isCancelled,
                      currentSession?.id == sessionID,
                      messages.contains(where: { $0 === message }) else {
                    return
                }

                message.setTurnFileChanges(files.map(TurnFileChangeSummary.init(file:)))
                resolvedTurnDiffAssistantIDs.insert(message.id)
                if !files.isEmpty {
                    timelineVersion &+= 1
                    contentVersion &+= 1
                }
                return
            } catch is CancellationError {
                return
            } catch {
                if attempt == 0 {
                    try? await Task.sleep(for: .milliseconds(350))
                    guard !Task.isCancelled else { return }
                    continue
                }

                resolvedTurnDiffAssistantIDs.insert(message.id)
                Logger.chat.warning(
                    "Failed to load turn diff for assistant message \(message.id, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    func loadTurnFileDetail(userMessageID: String, path: String) async throws -> ReviewFileChange {
        let key = TurnFileDetailCacheKey(userMessageID: userMessageID, path: path)
        if let cached = turnFileDetailCache[key] {
            touchTurnFileDetailCacheKey(key)
            return cached
        }

        guard let sessionID = currentSession?.id, let messagesService else {
            throw OpenCodeError.notConnected
        }

        let files = try await messagesService.loadTurnFileChanges(
            sessionID: sessionID,
            userMessageID: userMessageID
        )
        guard currentSession?.id == sessionID,
              let file = files.first(where: { $0.path == path }) else {
            throw OpenCodeError.invalidPayload("This historical file diff is no longer available.")
        }

        cacheTurnFileDetail(file, for: key)
        return file
    }

    /// Seeds the same lightweight summary and lazy detail cache used by live
    /// turns so offline previews exercise the production presentation path.
    func registerDemoTurnFileChanges(_ files: [ReviewFileChange], userMessageID: String) {
        guard isDemoMode, let pendingAssistantMessage else { return }

        pendingAssistantMessage.setParentUserMessageID(userMessageID)
        pendingAssistantMessage.setTurnFileChanges(files.map(TurnFileChangeSummary.init(file:)))
        for file in files {
            cacheTurnFileDetail(
                file,
                for: TurnFileDetailCacheKey(userMessageID: userMessageID, path: file.path)
            )
        }
    }

    private func cacheTurnFileDetail(_ file: ReviewFileChange, for key: TurnFileDetailCacheKey) {
        turnFileDetailCache[key] = file
        touchTurnFileDetailCacheKey(key)

        while turnFileDetailCacheOrder.count > Self.maximumTurnFileDetailCacheCount {
            let oldest = turnFileDetailCacheOrder.removeFirst()
            turnFileDetailCache.removeValue(forKey: oldest)
        }
    }

    private func touchTurnFileDetailCacheKey(_ key: TurnFileDetailCacheKey) {
        turnFileDetailCacheOrder.removeAll { $0 == key }
        turnFileDetailCacheOrder.append(key)
    }

    func loadTodos() async {
        guard let session = currentSession,
              let client = connection?.client else {
            Logger.debug.info("[TODO] loadTodos skipped: no session or client")
            return
        }
        guard connection?.serverCapabilities?.supports(.todos) != false else {
            todos = []
            hiddenTodoCount = 0
            Logger.debug.info("[TODO] loadTodos skipped: unsupported by the active protocol")
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
        isStreamSynchronized = false
        currentSession = nil
        inputText = ""
        composerAttachments = []

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

        guard pendingQuestion == nil, pendingForm == nil else {
            errorMessage = "Complete the current question or form before starting another workspace action."
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
        defer {
            isLoadingProviders = false
            quickModelAssignmentsVersion &+= 1
        }

        // Load config first — we need filter lists before selecting a model
        let configResult = await providersService!.loadConfig()
        self.enabledProviders = configResult.enabledProviders
        self.disabledProviders = configResult.disabledProviders

        let savedDefault = savedConnectionsStore?.activeConnectionID.flatMap {
            savedConnectionsStore?.defaultModelSelection(connectionID: $0)
        }
        let savedSelection = savedConnectionsStore?.activeConnectionID.flatMap {
            savedConnectionsStore?.savedModelSelection(connectionID: $0)
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

        let resolvedSavedDefault = savedDefault.flatMap { selection in
            Self.resolveSavedModelSelection(
                providerID: selection.providerID,
                modelID: selection.modelID,
                availableModels: availableModels,
                legacyModelIDs: legacyModelIDs
            ).map { (providerID: $0.providerID, modelID: $0.modelID) }
        }
        let resolvedSavedSelection = savedSelection.flatMap { selection in
            Self.resolveSavedModelSelection(
                providerID: selection.providerID,
                modelID: selection.modelID,
                availableModels: availableModels,
                legacyModelIDs: legacyModelIDs
            )
        }
        let resolution = Self.resolveDefaultModelSelection(
            savedDefault: resolvedSavedDefault,
            serverDefault: serverDefault,
            configDefault: configDefault,
            availableModels: availableModels
        )

        if let resolvedSavedSelection {
            preferredDefaultProviderID = resolution.providerID ?? ""
            preferredDefaultModelID = resolution.modelID ?? ""
            self.selectedProviderID = resolvedSavedSelection.providerID
            self.selectedModelID = resolvedSavedSelection.modelID
            self.selectedVariant = savedSelection?.variant
        } else if let providerID = resolution.providerID,
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

        // An unavailable saved selection is retained in the connection store so
        // it can be restored when the server exposes it again. The current
        // session instead falls back to a supported default where possible.
        if !selectedProviderID.isEmpty,
           !availableModels.contains(where: { $0.providerID == selectedProviderID && $0.modelID == selectedModelID }) {
            Logger.chat.warning("Selected model \(self.selectedProviderID)/\(self.selectedModelID) is unavailable — clearing current session selection")
            self.selectedProviderID = ""
            self.selectedModelID = ""
            self.selectedVariant = nil
        } else if let selectedVariant,
                  !availableReasoningVariants.contains(where: { $0.id == selectedVariant }) {
            self.selectedVariant = nil
        }

        // The selection above models new-session preferences. An open v2
        // session keeps showing its canonical selection, even when that model
        // is not in this client's catalog.
        applyCanonicalSessionSettings()
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
        setSelectedModel(model)
        persistCurrentSelection()
        switchCurrentSessionModelToSelection()
    }

    func selectVariant(_ variantID: String?) {
        selectedVariant = variantID
        persistCurrentSelection()
        switchCurrentSessionModelToSelection()
    }

    private func setSelectedModel(_ model: SelectableModel) {
        let isSameModel = selectedProviderID == model.providerID && selectedModelID == model.modelID
        selectedProviderID = model.providerID
        selectedModelID = model.modelID
        if !isSameModel || !model.variants.contains(where: { $0.id == selectedVariant }) {
            selectedVariant = nil
        }
    }

    func toggleDefaultModel(_ model: SelectableModel) {
        if isDefaultModel(model) {
            clearDefaultModelSelection()
        } else {
            persistDefaultModelSelection(providerID: model.providerID, modelID: model.modelID)
        }

        refreshPreferredDefaultModelSelection()
    }

    // MARK: - V2 Session Settings

    private enum SessionSettingsChange {
        case model(OCV2ModelRef)
        case agent(String)
    }

    enum SessionSettingsError: LocalizedError {
        case notApplied

        var errorDescription: String? {
            "The session settings change was not applied."
        }
    }

    /// Explicit setting changes for one v2 session, applied in order. The task
    /// yields whether every change since the chain started succeeded, so a
    /// prompt that depends on them is only admitted after they all apply.
    private struct SessionSettingsChain {
        let id: UUID
        let sessionID: String
        let task: Task<Bool, Never>
    }

    private var sessionSettingsChain: SessionSettingsChain?

    /// Model to seed a new v2 session with: the saved new-session selection,
    /// else the saved default, whichever this server still offers; otherwise
    /// nil so the server default applies. Existing sessions never read this.
    func newSessionModelPreference() async -> OCV2ModelRef? {
        guard usesV2SessionAPI, !isDemoMode, !isRecordedReplayMode else { return nil }
        if providers.isEmpty {
            await loadProviders()
        }
        if let saved = savedConnectionsStore?.activeConnectionID.flatMap({
               savedConnectionsStore?.savedModelSelection(connectionID: $0)
           }),
           let model = Self.resolveSavedModelSelection(
               providerID: saved.providerID,
               modelID: saved.modelID,
               availableModels: availableModels,
               legacyModelIDs: legacyModelIDs
           ) {
            let variant = saved.variant.flatMap { variant in
                model.variants.contains { $0.id == variant } ? variant : nil
            }
            return OCV2ModelRef(id: model.modelID, providerID: model.providerID, variant: variant)
        }
        guard let selection = defaultModelSelection else { return nil }
        return OCV2ModelRef(id: selection.modelID, providerID: selection.providerID, variant: nil)
    }

    /// Shows the open v2 session's canonical model and variant. While explicit
    /// local changes are in flight the optimistic selection stays visible.
    private func applyCanonicalSessionSettings() {
        guard usesV2SessionAPI,
              !isDemoMode,
              !isRecordedReplayMode,
              let session = currentSession,
              sessionSettingsChain?.sessionID != session.id else { return }

        if let model = session.model {
            setDisplayedSelection(
                providerID: model.providerID,
                modelID: model.id,
                variant: model.variant?.nilIfBlank
            )
        } else if let serverDefault = serverReportedDefault {
            setDisplayedSelection(
                providerID: serverDefault.providerID,
                modelID: serverDefault.modelID,
                variant: nil
            )
        }
    }

    private func setDisplayedSelection(providerID: String, modelID: String, variant: String?) {
        if selectedProviderID != providerID { selectedProviderID = providerID }
        if selectedModelID != modelID { selectedModelID = modelID }
        if selectedVariant != variant { selectedVariant = variant }
    }

    private func switchCurrentSessionModelToSelection() {
        guard let sessionID = currentSession?.id,
              !selectedProviderID.isEmpty,
              !selectedModelID.isEmpty else { return }
        enqueueSessionSettingsChange(
            .model(OCV2ModelRef(id: selectedModelID, providerID: selectedProviderID, variant: selectedVariant)),
            for: sessionID
        )
    }

    private func enqueueSessionSettingsChange(_ change: SessionSettingsChange, for sessionID: String) {
        guard usesV2SessionAPI,
              !isDemoMode,
              !isRecordedReplayMode,
              currentSession?.id == sessionID,
              let sessionsService else { return }

        let previous = sessionSettingsChain?.sessionID == sessionID ? sessionSettingsChain?.task : nil
        let chainID = UUID()
        let task = Task { [weak self] () -> Bool in
            let previousSucceeded = await previous?.value ?? true
            guard let self, self.currentSession?.id == sessionID else { return false }
            do {
                switch change {
                case .model(let model):
                    try await sessionsService.switchModel(sessionID: sessionID, model: model)
                case .agent(let agent):
                    try await sessionsService.switchAgent(sessionID: sessionID, agent: agent)
                }
            } catch {
                guard self.currentSession?.id == sessionID else { return false }
                switch change {
                case .model:
                    self.errorMessage = "Failed to change model: \(error.localizedDescription)"
                case .agent(let agent):
                    self.errorMessage = "Failed to switch to \(agent): \(error.localizedDescription)"
                }
                return false
            }

            // A result for a session that is no longer open must not touch
            // the current chat or admit its prompts.
            guard let session = self.currentSession, session.id == sessionID else { return false }
            switch change {
            case .model(let model):
                self.currentSession = session.withSelection(agent: session.agent, model: model)
            case .agent(let agent):
                self.currentSession = session.withSelection(agent: agent, model: session.model)
            }
            return previousSucceeded
        }
        sessionSettingsChain = SessionSettingsChain(id: chainID, sessionID: sessionID, task: task)

        Task { [weak self] in
            _ = await task.value
            guard let self, self.sessionSettingsChain?.id == chainID else { return }
            self.sessionSettingsChain = nil
            // Settles the display on the canonical selection, which restores
            // it after a failed change.
            self.applyCanonicalSessionSettings()
        }
    }

    /// Waits for explicit setting changes queued before a prompt. Throws when
    /// any of them failed or the session changed, so the prompt is not admitted.
    private func awaitSessionSettingsChanges(for sessionID: String) async throws {
        guard let chain = sessionSettingsChain, chain.sessionID == sessionID else { return }
        guard await chain.task.value, currentSession?.id == sessionID else {
            throw SessionSettingsError.notApplied
        }
    }

    func updateSlashCatalog(commands: [String], agents: [String]) {
        availableSlashCommandMap = Dictionary(uniqueKeysWithValues: commands.map { ($0.lowercased(), $0) })
        availableSlashAgentMap = Dictionary(uniqueKeysWithValues: agents.map { ($0.lowercased(), $0) })
    }

    func updateSkillCatalog(_ skills: [String]) {
        availableSkillIDs = skills
    }

    /// v2 servers only load a skill the prompt attaches, so `@skill` mentions
    /// in the text are sent alongside it the way the TUI sends them.
    private func skillAttachments(in text: String) -> [OCV2SkillAttachment] {
        guard usesV2SessionAPI else { return [] }
        return SkillMention.attachments(in: text, skillIDs: availableSkillIDs)
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
        liveActivityTracker?.end(phase: .failed)
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
        guard !text.isEmpty, !isLoading, !isQueueingPrompt, currentSession != nil else { return }

        if Self.isUndoCommand(text) {
            inputText = ""
            Task {
                await undoLatestMessage()
            }
            return
        }

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
            case .command:
                submitCommandIfPresent(text, delivery: .steer)
            case .agent(let agent, let prompt):
                sendAgentPrompt(text: text, agent: agent, prompt: prompt)
            }
            return
        }

        let attachments = composerAttachments
        guard validateComposerAttachments(attachments, text: text, delivery: .steer) else { return }

        beginResponse()

        let userMessage = makeOptimisticUserMessage(text: text, attachments: attachments)
        messages.append(userMessage)
        inputText = ""
        composerAttachments = []

        currentActivity = AgentActivity()
        currentActivity?.currentLabel = "Thinking..."
        responseStartDate = Date()

        liveActivityTracker?.start(session: currentSession)

        contentVersion &+= 1

        Task {
            await sendPromptAsync(text: text, messageID: userMessage.id, attachments: attachments)
        }
    }

    /// Queues the current composer text after the running session turn. This
    /// deliberately does not change response state or live activity: the
    /// current turn remains in control until the server promotes the input.
    func queuePrompt() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.isUndoCommand(text) {
            errorMessage = "Wait for the active session to finish before undoing."
            return
        }
        guard !text.isEmpty,
              isLoading,
              !isStoppingResponse,
              !isQueueingPrompt,
              pendingQuestion == nil,
              pendingForm == nil,
              canCompose,
              currentSession != nil else {
            return
        }

        if usesV2SessionAPI, submitCommandIfPresent(text, delivery: .queue) {
            return
        }

        let attachments = composerAttachments
        guard validateComposerAttachments(attachments, text: text, delivery: .queue) else { return }

        let tracksAdmission = usesV2SessionAPI && !isDemoMode && !isRecordedReplayMode
        let queuedPrompt = QueuedPrompt(
            messageID: tracksAdmission ? beginPromptSubmission(text: text, attachments: attachments) : UUID().uuidString,
            text: text,
            attachments: attachments,
            state: isDemoMode ? .queued : .submitting
        )
        inputText = ""
        composerAttachments = []
        queuedPrompts.append(queuedPrompt)
        contentVersion &+= 1
        scrollAnchor &+= 1

        if isDemoMode {
            return
        }

        if isRecordedReplayMode {
            queuedPrompts.removeAll { $0.id == queuedPrompt.id }
            errorMessage = AppText.recordedReplayReadOnly
            return
        }

        guard let session = currentSession,
              let messagesService else {
            queuedPrompts.removeAll { $0.id == queuedPrompt.id }
            errorMessage = "Not connected."
            return
        }

        isQueueingPrompt = true

        Task {
            defer {
                if currentSession?.id == session.id {
                    isQueueingPrompt = false
                }
            }

            var requestStarted = false
            do {
                try await awaitSessionSettingsChanges(for: session.id)
                if tracksAdmission {
                    await reconcileUncertainSubmissions(in: session.id, before: queuedPrompt.messageID)
                }
                requestStarted = true
                let admission = try await messagesService.queuePrompt(
                    sessionID: session.id,
                    text: text,
                    model: selectedModelRef,
                    variant: selectedVariant,
                    messageID: tracksAdmission ? queuedPrompt.messageID : nil,
                    skills: skillAttachments(in: text),
                    attachments: attachments
                )
                if tracksAdmission {
                    settlePromptSubmission(
                        queuedPrompt.messageID,
                        as: .accepted(admissionID: admission?.id ?? queuedPrompt.messageID)
                    )
                }
                guard currentSession?.id == session.id else { return }
                acceptQueuedPrompt(id: queuedPrompt.id)
                if usesV2SessionAPI {
                    await loadMessages(syncModelSelection: false)
                }
            } catch {
                let outcome: PromptAdmissionOutcome = tracksAdmission
                    ? await reconcilePromptAdmission(
                        after: error,
                        requestStarted: requestStarted,
                        sessionID: session.id,
                        messageID: queuedPrompt.messageID
                    )
                    : .failed
                guard currentSession?.id == session.id else { return }
                if case .admitted = outcome {
                    acceptQueuedPrompt(id: queuedPrompt.id)
                    await loadMessages(syncModelSelection: false)
                    return
                }
                queuedPrompts.removeAll { $0.id == queuedPrompt.id }
                restoreComposer(text, attachments: attachments)
                errorMessage = outcome == .uncertain
                    ? AppText.promptAdmissionUncertain
                    : "Failed to queue: \(error.localizedDescription)"
                contentVersion &+= 1
            }
        }
    }

    private func acceptQueuedPrompt(id: UUID) {
        guard let index = queuedPrompts.firstIndex(where: { $0.id == id }) else { return }
        if usesV2SessionAPI {
            // The server owns delivery. Keep the admitted entry until an
            // inbox read started after admission is applied.
            let prompt = queuedPrompts[index]
            let entry = OCV2InboxEntry(
                id: prompt.messageID,
                sessionID: currentSession?.id ?? "",
                type: "user",
                delivery: .queue,
                text: prompt.text
            )
            locallyAdmittedInbox.removeAll { $0.entry.id == entry.id }
            locallyAdmittedInbox.append((entry, inboxReadSequence))
            projectSessionInbox()
            return
        }
        queuedPrompts[index].state = .queued

        // The active turn can finish while the admission request is in flight.
        // Promote immediately in that race; otherwise finishLoading() performs
        // the transition at the next real turn boundary.
        if !isLoading {
            promoteNextQueuedPrompt()
        }
    }

    /// Moves the next local follow-up into the transcript. Only for v1: a v2
    /// server delivers its inbox itself, so the client never promotes there.
    private func promoteNextQueuedPrompt() {
        guard !usesV2SessionAPI, queuedPrompts.first?.state == .queued else { return }
        let prompt = queuedPrompts.removeFirst()
        messages.append(
            ChatMessage(
                id: prompt.messageID,
                role: .user,
                content: prompt.text,
                parts: attachmentParts(for: prompt.attachments, messageID: prompt.messageID),
                createdAt: Date()
            )
        )
        contentVersion &+= 1
        scrollAnchor &+= 1
    }

    private func sendCommand(
        text: String,
        command: String,
        arguments: String,
        delivery: OCV2PromptInput.Delivery
    ) {
        let startsNewResponse = !isLoading
        if startsNewResponse {
            beginResponse()
        }

        let userMessage = makeOptimisticCommandUserMessage(text: text)
        messages.append(userMessage)
        inputText = ""

        if startsNewResponse {
            currentActivity = AgentActivity()
            currentActivity?.currentLabel = "Running /\(command)..."
            responseStartDate = Date()

            liveActivityTracker?.start(session: currentSession)
        }

        contentVersion &+= 1
        scrollAnchor &+= 1

        Task {
            await sendCommandAsync(
                command: command,
                arguments: arguments,
                delivery: delivery,
                messageID: userMessage.id
            )
        }
    }

    private func sendAgentPrompt(text: String, agent: String, prompt: String) {
        let attachments = composerAttachments
        guard validateComposerAttachments(attachments, text: prompt, delivery: .steer) else { return }

        beginResponse()

        let userMessage = makeOptimisticUserMessage(text: text, attachments: attachments)
        messages.append(userMessage)
        inputText = ""
        composerAttachments = []

        currentActivity = AgentActivity()
        currentActivity?.currentLabel = "Running /\(agent)..."
        responseStartDate = Date()

        liveActivityTracker?.start(session: currentSession)

        contentVersion &+= 1
        scrollAnchor &+= 1

        Task {
            await sendPromptAsync(text: prompt, agent: agent, messageID: userMessage.id, attachments: attachments)
        }
    }

    private func makeOptimisticUserMessage(text: String, attachments: [PromptAttachment] = []) -> ChatMessage {
        let id = usesV2SessionAPI ? beginPromptSubmission(text: text, attachments: attachments) : UUID().uuidString
        if usesV2SessionAPI {
            optimisticV2UserMessageIDs.insert(id)
        }
        return ChatMessage(id: id, role: .user, content: text, parts: attachmentParts(for: attachments, messageID: id))
    }

    private func attachmentParts(for attachments: [PromptAttachment], messageID: String) -> [OCPart] {
        attachments.enumerated().map { index, attachment in
            attachment.part(id: "\(messageID)-file-\(index)", sessionID: currentSession?.id ?? "", messageID: messageID)
        }
    }

    // MARK: - Composer Attachments

    var canAttachFiles: Bool {
        usesV2SessionAPI && !isDemoMode && !isRecordedReplayMode && canCompose && currentSession != nil
    }

    var composerImages: [PromptImageAttachment] {
        composerAttachments.compactMap(\.image)
    }

    /// The folder the current session runs in on the server; repository
    /// references must stay inside it.
    var sessionDirectory: String? {
        let directory = currentSession?.directory
        guard let directory, !directory.isEmpty else { return nil }
        return directory
    }

    /// Whether the selected model reads images. v2 catalogs list input media;
    /// otherwise the v1 attachment flag applies. Unknown models are allowed
    /// and left for the server to judge.
    var selectedModelAcceptsImages: Bool {
        guard let selectedModel else { return true }
        if let inputMedia = selectedModel.inputMedia {
            return inputMedia.contains { $0.trimmingCharacters(in: .whitespaces).lowercased() == "image" }
        }
        return selectedModel.attachment
    }

    func addComposerAttachment(_ attachment: PromptAttachment) {
        composerAttachments.append(attachment)
    }

    func removeComposerAttachment(id: String) {
        composerAttachments.removeAll { $0.id == id }
    }

    /// Prepares picked image data off the main actor and attaches it,
    /// within the space the composer's text and attachments leave in the request.
    /// `nil` means the photo library could not provide the image's bytes.
    func attachComposerImage(data: Data?) async {
        guard canAttachFiles else { return }
        guard let data else {
            errorMessage = PromptAttachmentError.unsupportedImage.errorDescription
            return
        }
        if let error = imageCapabilityError() {
            errorMessage = error.errorDescription
            return
        }

        isPreparingComposerImage = true
        defer { isPreparingComposerImage = false }

        let sessionID = currentSession?.id
        let remaining = OpenCodeClient.maximumPromptBodyBytes - currentComposerBodySize()
        // Base64 grows bytes by 4/3 and JSON escapes its slashes; keep headroom.
        let budget = min(PromptImagePreparer.defaultMaximumBytes, Int(Double(remaining - 4_096) * 0.72))
        guard budget >= 16_384 else {
            errorMessage = PromptAttachmentError.promptTooLarge.errorDescription
            return
        }

        do {
            let image = try await Task.detached(priority: .userInitiated) {
                try PromptImagePreparer.prepare(data, maximumBytes: budget)
            }.value
            guard currentSession?.id == sessionID else { return }
            composerAttachments.append(.image(image))
        } catch {
            errorMessage = (error as? PromptAttachmentError)?.errorDescription
                ?? PromptAttachmentError.unsupportedImage.errorDescription
        }
    }

    /// Attaches a text file picked from Files on the phone. Its content is
    /// sent inline; files that aren't UTF-8 text or don't fit are refused.
    func attachComposerTextFile(at url: URL) {
        attachComposerTextFile(name: url.lastPathComponent) { try PromptTextFileAttachment.read(from: url) }
    }

    func attachComposerTextFile(data: Data, name: String) {
        attachComposerTextFile(name: name) { try PromptTextFileAttachment(data: data, name: name) }
    }

    private func attachComposerTextFile(name: String, _ makeFile: () throws -> PromptTextFileAttachment) {
        guard canAttachFiles else { return }
        do {
            let file = try makeFile()
            do {
                try appendIfItFits(.textFile(file))
            } catch PromptAttachmentError.promptTooLarge where composerAttachments.isEmpty {
                throw PromptAttachmentError.textFileTooLarge(name: name)
            }
        } catch {
            errorMessage = (error as? PromptAttachmentError)?.errorDescription
                ?? PromptAttachmentError.unreadableFile(name: name).errorDescription
        }
    }

    /// Attaches a reference to a file in the session's folder on the server,
    /// optionally limited to a line range. `relativePath` is relative to the
    /// session folder; the server reads the file when the prompt is admitted.
    func attachComposerServerFile(relativePath: String, lines: ServerFileReference.LineRange? = nil) {
        guard canAttachFiles else { return }
        do {
            guard let directory = sessionDirectory, !relativePath.hasPrefix("/") else {
                throw PromptAttachmentError.fileOutsideSession
            }
            let reference = try ServerFileReference(
                path: ServerFileReference.path(relativePath, in: directory),
                sessionDirectory: directory,
                lines: lines
            )
            try appendIfItFits(.serverFile(reference))
        } catch {
            errorMessage = (error as? PromptAttachmentError)?.errorDescription
                ?? PromptAttachmentError.fileOutsideSession.errorDescription
        }
    }

    private func appendIfItFits(_ attachment: PromptAttachment) throws {
        let input = OpenCodeClient.makePromptInput(
            messageID: "msg_\(UUID().uuidString)",
            text: inputText,
            skills: skillAttachments(in: inputText),
            attachments: composerAttachments + [attachment],
            delivery: .queue
        )
        do {
            try OpenCodeClient.validatePromptBodySize(input)
        } catch {
            throw PromptAttachmentError.promptTooLarge
        }
        composerAttachments.append(attachment)
    }

    private func currentComposerBodySize() -> Int {
        let input = OpenCodeClient.makePromptInput(
            messageID: "msg_\(UUID().uuidString)",
            text: inputText,
            skills: skillAttachments(in: inputText),
            attachments: composerAttachments,
            delivery: .queue
        )
        return (try? OpenCodeClient.encodedPromptBodySize(input)) ?? 0
    }

    private func imageCapabilityError() -> PromptAttachmentError? {
        guard usesV2SessionAPI else { return .attachmentsRequireV2 }
        guard selectedModelAcceptsImages else {
            return .modelDoesNotAcceptImages(modelName: selectedModelDisplayName)
        }
        return nil
    }

    /// Checks attachments against the protocol, the selected model, and the
    /// complete request size before any row or request is created. Shows the
    /// error and keeps the composer intact when the prompt cannot be sent.
    private func validateComposerAttachments(
        _ attachments: [PromptAttachment],
        text: String,
        delivery: OCV2PromptInput.Delivery
    ) -> Bool {
        guard !attachments.isEmpty else { return true }
        var failure: PromptAttachmentError?
        if !usesV2SessionAPI {
            failure = .attachmentsRequireV2
        } else if attachments.contains(where: { $0.image != nil }) {
            failure = imageCapabilityError()
        }
        if failure == nil {
            let input = OpenCodeClient.makePromptInput(
                messageID: "msg_\(UUID().uuidString)",
                text: text,
                skills: skillAttachments(in: text),
                attachments: attachments,
                delivery: delivery
            )
            do {
                try OpenCodeClient.validatePromptBodySize(input)
            } catch {
                failure = .promptTooLarge
            }
        }
        if let failure {
            errorMessage = failure.errorDescription
            return false
        }
        return true
    }

    // MARK: - V2 Prompt Admission

    /// Admission state of the local user row with `messageID`, if tracked.
    func promptSubmissionState(forMessageID messageID: String) -> PromptSubmission.State? {
        promptSubmissions.first { $0.id == messageID }?.state
    }

    /// Starts tracking a v2 prompt and returns its caller-provided message ID.
    /// Resending the exact text and attachments of an uncertain submission reuses
    /// its ID; a rejected one is new work. Either way the stale local row is
    /// replaced.
    private func beginPromptSubmission(text: String, attachments: [PromptAttachment]) -> String {
        let sessionID = currentSession?.id ?? ""
        let id: String
        if let index = promptSubmissions.lastIndex(where: {
            $0.sessionID == sessionID && $0.text == text && $0.attachments == attachments
                && ($0.state == .uncertain || $0.state == .failed)
        }) {
            let previous = promptSubmissions.remove(at: index)
            messages.removeAll { $0.id == previous.id }
            queuedPrompts.removeAll { $0.messageID == previous.id }
            id = previous.state == .uncertain ? previous.id : "msg_\(UUID().uuidString)"
        } else {
            id = "msg_\(UUID().uuidString)"
        }
        promptSubmissions.append(
            PromptSubmission(id: id, sessionID: sessionID, text: text, attachments: attachments, state: .sending)
        )
        return id
    }

    private func settlePromptSubmission(_ id: String, as state: PromptSubmission.State) {
        guard let index = promptSubmissions.firstIndex(where: { $0.id == id }) else { return }
        promptSubmissions[index].state = state
    }

    /// Decides what a failed admission request means. Failures before the
    /// request left, and explicit rejections, are definitive. Otherwise the
    /// server is asked whether it admitted the ID, and the submission stays
    /// uncertain unless the server positively answers.
    private func reconcilePromptAdmission(
        after error: Error,
        requestStarted: Bool,
        sessionID: String,
        messageID: String
    ) async -> PromptAdmissionOutcome {
        let outcome: PromptAdmissionOutcome
        if requestStarted, OpenCodeClient.requestMayHaveReachedServer(error), let messagesService {
            do {
                if let admission = try await messagesService.findPromptAdmission(
                    sessionID: sessionID,
                    messageID: messageID
                ) {
                    outcome = .admitted(admissionID: admission.id)
                } else {
                    outcome = .uncertain
                }
            } catch {
                Logger.chat.warning("Prompt admission reconciliation failed: \(error, privacy: .public)")
                outcome = .uncertain
            }
        } else {
            outcome = .failed
        }

        switch outcome {
        case let .admitted(admissionID):
            settlePromptSubmission(messageID, as: .accepted(admissionID: admissionID))
        case .uncertain:
            settlePromptSubmission(messageID, as: .uncertain)
        case .failed:
            settlePromptSubmission(messageID, as: .failed)
        }
        return outcome
    }

    /// Asks the server about earlier uncertain prompts before new content is
    /// admitted, so an edited retry is not sent while the original may be pending.
    private func reconcileUncertainSubmissions(in sessionID: String, before messageID: String) async {
        guard let messagesService else { return }
        let uncertainIDs = promptSubmissions
            .filter { $0.sessionID == sessionID && $0.id != messageID && $0.state == .uncertain }
            .map(\.id)
        for id in uncertainIDs {
            do {
                if try await messagesService.findPromptAdmission(sessionID: sessionID, messageID: id) != nil {
                    settlePromptSubmission(id, as: .accepted(admissionID: id))
                }
            } catch {
                Logger.chat.warning("Uncertain prompt reconciliation failed: \(error, privacy: .public)")
            }
        }
    }

    /// Marks uncertain submissions the server has shown it admitted. The
    /// restored composer text invited a retry; resending would now create new
    /// work, so it is withdrawn.
    private func confirmUncertainSubmissions(admittedIDs: Set<String>) {
        for index in promptSubmissions.indices
        where promptSubmissions[index].state == .uncertain && admittedIDs.contains(promptSubmissions[index].id) {
            promptSubmissions[index].state = .accepted(admissionID: promptSubmissions[index].id)
            if inputText == promptSubmissions[index].text,
               composerAttachments == promptSubmissions[index].attachments {
                inputText = ""
                composerAttachments = []
            }
            if errorMessage == AppText.promptAdmissionUncertain {
                dismissError()
            }
        }
    }

    // MARK: - V2 Session Inbox

    func canSteerQueuedPrompt(_ prompt: QueuedPrompt) -> Bool {
        canCancelQueuedPrompt(prompt)
            && queuedPrompts.first(where: { $0.id == prompt.id })?.delivery == .queue
    }

    func steerQueuedPrompt(_ prompt: QueuedPrompt) async {
        await mutateQueuedPrompt(prompt, action: .steer)
    }

    func canCancelQueuedPrompt(_ prompt: QueuedPrompt) -> Bool {
        supportsQueuedPromptActions(prompt) && queuedPromptMutationID == nil
    }

    func supportsQueuedPromptActions(_ prompt: QueuedPrompt) -> Bool {
        usesV2SessionAPI && !isDemoMode && !isRecordedReplayMode && !isOfflinePreviewMode
            && currentSession != nil && connection?.client != nil
            && queuedPrompts.contains { $0.id == prompt.id && $0.messageID == prompt.messageID && $0.state == .queued && $0.kind == .user }
    }

    func cancelQueuedPrompt(_ prompt: QueuedPrompt) async {
        await mutateQueuedPrompt(prompt, action: .cancel)
    }

    private enum QueuedPromptMutation {
        case cancel, steer

        var failurePrefix: String {
            switch self {
            case .cancel: AppText.cancelQueuedPromptFailedPrefix
            case .steer: AppText.steerQueuedPromptFailedPrefix
            }
        }
    }

    private func mutateQueuedPrompt(_ prompt: QueuedPrompt, action: QueuedPromptMutation) async {
        let canMutate = switch action {
        case .cancel: canCancelQueuedPrompt(prompt)
        case .steer: canSteerQueuedPrompt(prompt)
        }
        guard canMutate, let sessionID = currentSession?.id,
              let messagesService, let client = connection?.client else { return }
        let epoch = inboxEpoch
        let isStale = {
            Task.isCancelled || self.inboxEpoch != epoch
                || self.currentSession?.id != sessionID || self.connection?.client !== client
        }
        queuedPromptMutationID = prompt.id
        defer {
            if queuedPromptMutationID == prompt.id { queuedPromptMutationID = nil }
        }

        var mutationError: Error?
        do {
            switch action {
            case .cancel:
                try await messagesService.cancelSessionInboxEntry(sessionID: sessionID, inboxID: prompt.messageID)
            case .steer:
                try await messagesService.changeSessionInboxDelivery(sessionID: sessionID, inboxID: prompt.messageID, delivery: .steer)
            }
        } catch {
            mutationError = error
        }
        guard !isStale() else { return }
        // A mutation can race with delivery or lose its response. Recover the
        // shared inbox and transcript even when the request reports a failure.
        synchronizeCurrentSessionFromServer()
        await streamSynchronizationTask?.value
        guard !isStale() else { return }
        let reflectsMutation = switch action {
        case .cancel: !sessionInbox.contains(where: { $0.id == prompt.messageID })
        case .steer: sessionInbox.first(where: { $0.id == prompt.messageID })?.delivery == .steer
        }
        let confirmed = isStreamSynchronized && reflectsMutation
            && mutationError.map(OpenCodeClient.requestMayHaveReachedServer) == true
        if let mutationError, !confirmed, isStreamSynchronized || errorMessage == nil {
            errorMessage = "\(action.failurePrefix) \(mutationError.localizedDescription)"
        } else if mutationError == nil || confirmed, hasQueuedPromptMutationError {
            errorMessage = nil
        }
    }

    private var hasQueuedPromptMutationError: Bool {
        guard let errorMessage else { return false }
        return errorMessage.hasPrefix(AppText.cancelQueuedPromptFailedPrefix)
            || errorMessage.hasPrefix(AppText.steerQueuedPromptFailedPrefix)
    }

    private enum InboxRecovery {
        /// The queue reflects a server snapshot at least as new as this read.
        case current
        /// The session changed or was reset while the read was in flight.
        case discarded
        case failed
    }

    /// Reads the v2 session inbox and projects it into `queuedPrompts`.
    private func recoverSessionInbox() async -> InboxRecovery {
        guard usesV2SessionAPI, !isDemoMode, !isRecordedReplayMode, !isOfflinePreviewMode else { return .current }
        guard let sessionID = currentSession?.id, let messagesService else { return .discarded }

        inboxReadSequence &+= 1
        let sequence = inboxReadSequence
        let epoch = inboxEpoch
        let isStale = { Task.isCancelled || self.inboxEpoch != epoch || self.currentSession?.id != sessionID }
        do {
            let entries = try await messagesService.listSessionInbox(sessionID: sessionID)
            if isStale() { return .discarded }
            guard sequence > appliedInboxReadSequence else { return .current }
            appliedInboxReadSequence = sequence
            sessionInbox = entries
            locallyAdmittedInbox.removeAll { $0.readSequence < sequence }
            confirmUncertainSubmissions(admittedIDs: Set(entries.map(\.id)))
            projectSessionInbox()
            return .current
        } catch {
            if isStale() { return .discarded }
            isStreamSynchronized = false
            errorMessage = "\(AppText.sessionInboxLoadFailedPrefix) \(error.localizedDescription)"
            return .failed
        }
    }

    /// Reacts to an inbox change from any client. If the read fails, the
    /// queue may be stale, so the session falls back to full recovery.
    private func refreshInboxAfterChange() {
        Task { [weak self] in
            guard let self else { return }
            if await self.recoverSessionInbox() == .failed {
                self.synchronizeCurrentSessionFromServer()
            }
        }
    }

    /// Projects the server inbox, in delivery order, followed by prompts this
    /// client is still submitting. Entries already visible in the transcript,
    /// such as an optimistic steer, are not repeated.
    private func projectSessionInbox() {
        guard usesV2SessionAPI else { return }
        let transcriptIDs = Set(messages.map(\.id))
        let serverIDs = Set(sessionInbox.map(\.id))
        let localEntries = locallyAdmittedInbox.map(\.entry).filter { !serverIDs.contains($0.id) }
        // A command's optimistic row has no server admission ID. Matching its
        // text must not hide authoritative entries with distinct identities.
        let pending = (sessionInbox + localEntries).filter { !transcriptIDs.contains($0.id) }
        // The server delivers every steer before the next queued entry.
        var steers = pending.filter { $0.delivery == .steer }
        // Mirror SessionInbox.pendingSteers: compact before earlier steers so
        // their text follows the checkpoint, without crossing a steered move.
        if let controlIndex = steers.firstIndex(where: { $0.type == "compaction" || $0.type == "move" }),
           controlIndex > 0, steers[controlIndex].type == "compaction" {
            let compaction = steers.remove(at: controlIndex)
            steers.insert(compaction, at: 0)
        }
        let ordered = steers + pending.filter { $0.delivery != .steer }
        let accepted = ordered.compactMap(queuedPrompt(for:))
        let acceptedIDs = Set(accepted.map(\.messageID))
        let submitting = queuedPrompts.filter { $0.state == .submitting && !acceptedIDs.contains($0.messageID) }
        let projected = accepted + submitting
        guard projected != queuedPrompts else { return }
        queuedPrompts = projected
        contentVersion &+= 1
    }

    private func queuedPrompt(for entry: OCV2InboxEntry) -> QueuedPrompt? {
        let kind: QueuedPrompt.Kind
        switch entry.type {
        case "user": kind = .user
        case "synthetic": kind = .synthetic(description: entry.description)
        case "compaction": kind = .compaction
        case "move": kind = .move(directory: entry.moveDirectory)
        default: return nil
        }
        // Prompts sent from this phone keep their prepared attachments.
        let submission = promptSubmissions.first { $0.id == entry.id }
        return QueuedPrompt(
            id: queuedPrompts.first { $0.messageID == entry.id }?.id ?? UUID(),
            messageID: entry.id,
            text: entry.text ?? "",
            attachments: submission?.attachments ?? [],
            state: .queued,
            kind: kind,
            delivery: entry.delivery ?? .queue,
            fileNames: submission == nil ? entry.fileNames : []
        )
    }

    private func restoreComposer(_ text: String, attachments: [PromptAttachment]) {
        if inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, composerAttachments.isEmpty {
            inputText = text
            composerAttachments = attachments
        }
    }

    private func makeOptimisticCommandUserMessage(text: String) -> ChatMessage {
        let id = usesV2SessionAPI ? "cmd_\(UUID().uuidString)" : UUID().uuidString
        if usesV2SessionAPI {
            optimisticV2CommandMessages[id] = .init(
                text: text,
                knownTranscriptMessageIDs: Set(messages.map(\.id))
            )
        }
        return ChatMessage(id: id, role: .user, content: text)
    }

    @discardableResult
    private func submitCommandIfPresent(
        _ text: String,
        delivery: OCV2PromptInput.Delivery
    ) -> Bool {
        guard let slashAction = parseSlashAction(text),
              case let .command(command, arguments) = slashAction
        else {
            return false
        }

        sendCommand(
            text: text,
            command: command,
            arguments: arguments,
            delivery: delivery
        )
        return true
    }

    private var usesV2SessionAPI: Bool {
        connection?.serverCapabilities?.protocolVersion == .v2
    }

    var canSteerPrompt: Bool {
        usesV2SessionAPI
            && isLoading
            && !isStoppingResponse
            && !isQueueingPrompt
            && pendingQuestion == nil
            && pendingForm == nil
            && canCompose
            && currentSession != nil
    }

    /// Sends a busy-session prompt as a v2 steering instruction rather than
    /// appending it behind the active turn.
    func steerPrompt() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, canSteerPrompt else { return }

        if submitCommandIfPresent(text, delivery: .steer) {
            return
        }

        let attachments = composerAttachments
        guard validateComposerAttachments(attachments, text: text, delivery: .steer) else { return }

        let userMessage = makeOptimisticUserMessage(text: text, attachments: attachments)
        messages.append(userMessage)
        inputText = ""
        composerAttachments = []
        contentVersion &+= 1
        scrollAnchor &+= 1

        Task {
            await sendPromptAsync(text: text, messageID: userMessage.id, attachments: attachments)
        }
    }

    private func sendPromptAsync(
        text: String,
        agent: String? = nil,
        messageID: String? = nil,
        attachments: [PromptAttachment] = []
    ) async {
        guard let session = currentSession else {
            markResponseFailed("Not connected.")
            return
        }

        let tracksAdmission = usesV2SessionAPI && messageID != nil
        var requestStarted = false
        do {
            if let agent {
                enqueueSessionSettingsChange(.agent(agent), for: session.id)
            }
            try await awaitSessionSettingsChanges(for: session.id)
            if tracksAdmission, let messageID {
                await reconcileUncertainSubmissions(in: session.id, before: messageID)
            }
            requestStarted = true
            let admission = try await messagesService!.sendPromptAsync(
                sessionID: session.id,
                text: text,
                model: selectedModelRef,
                agent: agent,
                variant: selectedVariant,
                messageID: messageID,
                skills: skillAttachments(in: text),
                attachments: attachments
            )
            if tracksAdmission, let messageID {
                settlePromptSubmission(messageID, as: .accepted(admissionID: admission?.id ?? messageID))
            }
            guard currentSession?.id == session.id else { return }
            if usesV2SessionAPI {
                // Prompt admission is durable but projection is asynchronous.
                // Reload now; the merge above keeps the local row visible until
                // the transcript returns the same caller-provided message ID.
                await loadMessages(syncModelSelection: false)
            }
        } catch {
            guard tracksAdmission, let messageID else {
                guard responseState == .generating else { return }
                markPromptFailed(error, agent: agent)
                return
            }

            let outcome = await reconcilePromptAdmission(
                after: error,
                requestStarted: requestStarted,
                sessionID: session.id,
                messageID: messageID
            )
            guard currentSession?.id == session.id else { return }
            if case .admitted = outcome {
                await loadMessages(syncModelSelection: false)
                return
            }

            // Keep the row visible for immediate feedback, but do not preserve
            // it over a later authoritative transcript load.
            optimisticV2UserMessageIDs.remove(messageID)
            if let submission = promptSubmissions.first(where: { $0.id == messageID }) {
                restoreComposer(submission.text, attachments: submission.attachments)
            }
            guard responseState == .generating else { return }
            if outcome == .uncertain {
                markResponseFailed(AppText.promptAdmissionUncertain)
            } else {
                markPromptFailed(error, agent: agent)
            }
        }
    }

    private func markPromptFailed(_ error: Error, agent: String?) {
        if let agent, !agent.isEmpty {
            markResponseFailed("Failed to run /\(agent): \(error.localizedDescription)")
        } else {
            markResponseFailed("Failed to send: \(error.localizedDescription)")
        }
    }

    private func sendCommandAsync(
        command: String,
        arguments: String,
        delivery: OCV2PromptInput.Delivery,
        messageID: String
    ) async {
        guard let session = currentSession else {
            markResponseFailed("Not connected.")
            return
        }

        do {
            try await awaitSessionSettingsChanges(for: session.id)
            try await messagesService!.sendCommand(
                sessionID: session.id,
                command: command,
                arguments: arguments,
                model: selectedModelRef,
                variant: selectedVariant,
                skills: skillAttachments(in: arguments),
                delivery: delivery
            )
            guard currentSession?.id == session.id else { return }
            if usesV2SessionAPI {
                // Commands are admitted asynchronously just like prompts, but
                // their v2 endpoint does not accept a caller-provided message
                // ID. Refresh the authoritative transcript after admission.
                await loadMessages(syncModelSelection: false)
            }
        } catch {
            if usesV2SessionAPI {
                optimisticV2CommandMessages.removeValue(forKey: messageID)
            }
            if delivery == .queue {
                errorMessage = "Failed to queue /\(command): \(error.localizedDescription)"
                return
            }
            guard responseState == .generating else { return }
            markResponseFailed("Failed to run /\(command): \(error.localizedDescription)")
        }
    }

    private enum SlashAction {
        case command(command: String, arguments: String)
        case agent(agent: String, prompt: String)
    }

    static func isUndoCommand(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "/undo"
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

        abortTask = Task { [weak self] in
            do {
                let interrupted = try await self?.messagesService?.abort(sessionID: session.id)
                if interrupted == true {
                    self?.completeStoppedResponse()
                } else {
                    self?.completeUninterruptedStop()
                }
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
                appendsWhenEmpty: true,
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
        pendingForm = nil
        showFormSheet = false
        isResolvingForm = false
        cancelInteractiveRequestTimeout()
        liveActivityTracker?.end(phase: .stopped)
        contentVersion &+= 1
    }

    private func completeStoppedResponse() {
        guard responseState == .stopping else { return }

        abortTask = nil
        finalizeLocalStoppedTurn()
        isLoading = false
        showStoppedResponseState()
    }

    private func completeUninterruptedStop() {
        guard responseState == .stopping else { return }

        abortTask = nil
        isLoading = false
        locallyStoppedSessionID = nil
        responseState = .idle
        synchronizeCurrentSessionFromServer()
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
            self?.receiveStreamEvent(inboundEvent)
        }
        sseClient.onSynchronizationGap = { [weak self] _ in
            self?.synchronizeCurrentSessionFromServer()
        }
    }

    /// Routes one event from the session stream. Reconcile and inbox-change
    /// events trigger authoritative reads for the open session only.
    func receiveStreamEvent(_ inboundEvent: SSEInboundEvent) {
        if case .raw(let event) = inboundEvent,
           event.type == "session.reconcile" || event.type == V2EventAdapter.inboxChangedEventType {
            let sessionID = (event.properties?.value as? [String: Any])?["sessionID"] as? String
            guard sessionID == nil || sessionID == currentSession?.id else { return }
            if event.type == "session.reconcile" {
                synchronizeCurrentSessionFromServer()
            } else {
                refreshInboxAfterChange()
            }
            return
        }
        if let rawEvent = inboundEvent.rawEvent {
            recordIncomingEvent(rawEvent)
        }
        sseHandler?.handleInboundEvent(inboundEvent)
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

        guard let permission = pendingPermission, permission.id == requestID else {
            errorMessage = "Failed to respond to permission: The request is no longer pending."
            return false
        }
        let recoverySessionID = permission.sessionID ?? currentSession?.id

        do {
            try await questionService.respondToPermission(permission, reply: reply)

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

    /// Superseded recovery requests surface as task or URLSession cancellation; they are not user-facing failures.
    private static func isCancellation(_ error: Error) -> Bool {
        Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    /// Recover any pending permission from the server for the current session.
    @discardableResult
    func recoverPendingPermission(sessionID preferredSessionID: String? = nil) async -> Bool {
        guard !isOfflinePreviewMode else { return true }

        let sessionID = preferredSessionID ?? currentSession?.id

        do {
            guard let questionService else { return false }
            let permission = try await questionService.recoverPendingPermission(sessionID: sessionID)
            guard !Task.isCancelled, currentSession?.id == sessionID else { return false }

            if let permission {
                pendingPermission = permission
                showPermissionAlert = true
            } else if sessionID == nil || pendingPermission?.sessionID == sessionID {
                pendingPermission = nil
                showPermissionAlert = false
            }
            return true
        } catch {
            guard !Self.isCancellation(error) else { return false }
            Logger.chat.warning("recoverPendingPermission failed: \(error, privacy: .public)")
            if currentSession?.id == sessionID { errorMessage = "Failed to recover pending interactions: \(error.localizedDescription)" }
            return false
        }
    }

    // MARK: - Question Response

    /// Recover any pending questions from the server after reconnection.
    @discardableResult
    func recoverPendingQuestions() async -> Bool {
        guard !isOfflinePreviewMode, let sessionID = currentSession?.id else { return false }

        do {
            guard let questionService else { return false }
            let question = try await questionService.recoverPendingQuestion(sessionID: sessionID)
            guard !Task.isCancelled, currentSession?.id == sessionID else { return false }
            if let question {
                if self.pendingQuestion == nil {
                    self.pendingQuestion = question
                    self.showQuestionSheet = true
                    self.startInteractiveRequestTimeout()
                }
            }
            return true
        } catch {
            guard !Self.isCancellation(error) else { return false }
            Logger.chat.warning("recoverPendingQuestions failed: \(error, privacy: .public)")
            if currentSession?.id == sessionID { errorMessage = "Failed to recover pending interactions: \(error.localizedDescription)" }
            return false
        }
    }

    /// Recover pending v2 forms after a stream gap or foreground return.
    @discardableResult
    func recoverPendingForms() async -> Bool {
        guard !isOfflinePreviewMode, let sessionID = currentSession?.id else { return false }

        do {
            guard let questionService else { return false }
            let form = try await questionService.recoverPendingForm(sessionID: sessionID)
            guard !Task.isCancelled, currentSession?.id == sessionID else { return false }
            if let form {
                guard pendingQuestion == nil else { return true }
                if pendingForm?.id == form.id {
                    if !showFormSheet, !isResolvingForm {
                        showFormSheet = true
                    }
                    return true
                }
                guard pendingForm == nil else { return true }
                _ = presentForm(form)
            } else if pendingForm?.sessionID == sessionID {
                cancelInteractiveRequestTimeout()
                pendingForm = nil
                showFormSheet = false
            }
            return true
        } catch {
            guard !Self.isCancellation(error) else { return false }
            Logger.chat.warning("recoverPendingForms failed: \(error, privacy: .public)")
            if currentSession?.id == sessionID { errorMessage = "Failed to recover pending interactions: \(error.localizedDescription)" }
            return false
        }
    }

    /// Send selected answers back to the server.
    func respondToQuestion(answers: [[String]]) {
        cancelInteractiveRequestTimeout()

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
        cancelInteractiveRequestTimeout()

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

    /// Sends a v2 form reply. Unsupported fields never call this method
    /// because `FormView` disables submission until OpenCode can handle them.
    func respondToForm(answer: [String: OCFormValue]) {
        resolvePendingForm(failureMessage: "Failed to submit form") { service, form in
            try await service.respondToForm(form, answer: answer)
        }
    }

    func cancelForm() {
        resolvePendingForm(failureMessage: "Failed to cancel form") { service, form in
            try await service.cancelForm(form)
        }
    }

    private func resolvePendingForm(
        failureMessage: String,
        operation: @escaping (QuestionService, OCFormRequest) async throws -> Void
    ) {
        guard !isResolvingForm else { return }
        cancelInteractiveRequestTimeout()

        guard let form = pendingForm else {
            pendingForm = nil
            showFormSheet = false
            return
        }
        guard let questionService else {
            errorMessage = "\(failureMessage): OpenLens is not connected."
            showFormSheet = true
            startInteractiveRequestTimeout()
            return
        }

        isResolvingForm = true
        Task {
            defer { isResolvingForm = false }
            do {
                try await operation(questionService, form)
                guard pendingForm?.id == form.id else { return }
                pendingForm = nil
                showFormSheet = false
            } catch {
                errorMessage = "\(failureMessage): \(error.localizedDescription)"
                showFormSheet = true
                startInteractiveRequestTimeout()
            }
        }
    }

    // MARK: - Interactive Request Timeout

    private func startInteractiveRequestTimeout() {
        cancelInteractiveRequestTimeout()
        interactiveRequestTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(Self.interactiveRequestTimeoutSeconds))
            } catch {
                return // cancelled
            }
            guard let self, self.pendingQuestion != nil || self.pendingForm != nil else { return }
            await MainActor.run {
                Logger.chat.info("Interactive request timed out after \(Self.interactiveRequestTimeoutSeconds)s, auto-cancelling")
                if self.pendingForm != nil {
                    self.cancelForm()
                } else {
                    self.rejectQuestion()
                }
            }
        }
    }

    private func cancelInteractiveRequestTimeout() {
        interactiveRequestTimeoutTask?.cancel()
        interactiveRequestTimeoutTask = nil
    }

    // MARK: - Streaming Text Buffer API

    /// Append text for a streaming message. Accumulated in a buffer that
    /// flushes to the pending message every ~40ms, keeping UI updates smooth.
    func appendStreamingText(messageID: String, text: String) {
        appendStreamingText(messageID: messageID, text: text, chunks: [text])
    }

    func appendStreamingText(messageID: String, text: String, chunks: [String]) {
        appendStreamingText(
            messageID: messageID,
            partID: nil,
            text: text,
            chunks: chunks
        )
    }

    func appendStreamingText(
        messageID: String,
        partID: String?,
        text: String,
        chunks: [String]
    ) {
        guard !ignoredAssistantMessageIDs.contains(messageID) else { return }
        let resolvedMessageID = resolvedStreamingMessageID(messageID)
        let target: BufferedStreamTarget
        if let partID {
            guard let message = assistantMessage(withID: resolvedMessageID),
                  message.isStreaming,
                  !isStreamingFinalizing(messageID: resolvedMessageID),
                  message.hasLiveStreamingPart(id: partID, type: .text) else {
                return
            }
            target = .textPart(partID)
        } else {
            guard let pending = pendingAssistantMessage,
                  pending.id == resolvedMessageID,
                  pending.isStreaming,
                  !isStreamingFinalizing(messageID: resolvedMessageID),
                  let fallbackTextPartID = pending.registerStreamingFallbackTextPart() else {
                return
            }
            target = .textPart(fallbackTextPartID)
        }
        enqueueStreamingUpdate(messageID: resolvedMessageID, target: target, text: text, chunks: chunks)
        ensureFlushTimer()
    }

    func replaceStreamingText(messageID: String, text: String, chunks: [String]) {
        replaceStreamingText(
            messageID: messageID,
            partID: nil,
            text: text,
            chunks: chunks
        )
    }

    func replaceStreamingText(
        messageID: String,
        partID: String?,
        text: String,
        chunks: [String]
    ) {
        guard !ignoredAssistantMessageIDs.contains(messageID) else { return }
        let resolvedMessageID = resolvedStreamingMessageID(messageID)

        // An authoritative snapshot supersedes only unrendered text. Clearing
        // the projection and invalidating the old FIFO generation are both
        // O(1); its worker-prepared chunks are then appended through the
        // normal per-tick budget below.
        let target: BufferedStreamTarget
        if let partID {
            guard let message = assistantMessage(withID: resolvedMessageID),
                  message.isStreaming,
                  !isStreamingFinalizing(messageID: resolvedMessageID),
                  message.hasLiveStreamingPart(id: partID, type: .text) else {
                return
            }
            target = .textPart(partID)
            invalidateStreamingUpdates(messageID: resolvedMessageID, target: target)
            message.resetStreamingTextProjection(partID: partID)
        } else {
            guard let pending = pendingAssistantMessage,
                  pending.id == resolvedMessageID,
                  pending.isStreaming,
                  !isStreamingFinalizing(messageID: resolvedMessageID),
                  let fallbackTextPartID = pending.registerStreamingFallbackTextPart() else {
                return
            }
            target = .textPart(fallbackTextPartID)
            invalidateStreamingUpdates(messageID: resolvedMessageID, target: target)
            pending.resetStreamingTextProjection(partID: fallbackTextPartID)
        }
        enqueueStreamingUpdate(messageID: resolvedMessageID, target: target, text: text, chunks: chunks)
        ensureFlushTimer()
    }

    func appendStreamingReasoning(messageID: String, partID: String, text: String, chunks: [String]) {
        guard !ignoredAssistantMessageIDs.contains(messageID) else { return }
        let resolvedMessageID = resolvedStreamingMessageID(messageID)
        guard let message = assistantMessage(withID: resolvedMessageID),
              message.isStreaming,
              !isStreamingFinalizing(messageID: resolvedMessageID),
              message.hasLiveStreamingPart(id: partID, type: .reasoning) else {
            return
        }
        enqueueStreamingUpdate(
            messageID: resolvedMessageID,
            target: .reasoningPart(partID),
            text: text,
            chunks: chunks
        )
        ensureFlushTimer()
    }

    func replaceStreamingReasoning(messageID: String, partID: String, text: String, chunks: [String]) {
        guard !ignoredAssistantMessageIDs.contains(messageID) else { return }
        let resolvedMessageID = resolvedStreamingMessageID(messageID)
        guard let message = assistantMessage(withID: resolvedMessageID),
              message.isStreaming,
              !isStreamingFinalizing(messageID: resolvedMessageID),
              message.hasLiveStreamingPart(id: partID, type: .reasoning) else {
            return
        }

        invalidateStreamingUpdates(messageID: resolvedMessageID, target: .reasoningPart(partID))
        message.resetStreamingReasoningProjection(partID: partID)
        enqueueStreamingUpdate(
            messageID: resolvedMessageID,
            target: .reasoningPart(partID),
            text: text,
            chunks: chunks
        )
        ensureFlushTimer()
    }

    func clearStreamingBuffer(messageID: String) {
        guard !ignoredAssistantMessageIDs.contains(messageID) else { return }
        let resolvedMessageID = resolvedStreamingMessageID(messageID)
        guard let pending = pendingAssistantMessage, pending.id == resolvedMessageID else { return }
        let target = pending.activeStreamingFallbackTextPartID
            .map(BufferedStreamTarget.textPart)
            ?? .fallbackText
        invalidateStreamingUpdates(messageID: resolvedMessageID, target: target)
        stopFlushTimerIfIdle()
    }

    func clearStreamingReasoningBuffer(messageID: String, partID: String) {
        invalidateStreamingUpdates(
            messageID: resolvedStreamingMessageID(messageID),
            target: .reasoningPart(partID)
        )
        stopFlushTimerIfIdle()
    }

    /// An explicit `message.removed` is stronger than a potentially stale
    /// foreground history response. Cancel any deferred worker commit before
    /// removing the row, otherwise reconciliation could restore it.
    func removeAssistantMessage(messageID: String) {
        let resolvedMessageID = resolvedStreamingMessageID(messageID)
        clearStreamingFinalization(messageID: resolvedMessageID)
        _ = detachBufferedStreamUpdates(for: resolvedMessageID)
        if pendingAssistantMessage?.id == resolvedMessageID {
            pendingAssistantMessage = nil
        }
        messages.removeAll { $0.id == resolvedMessageID }
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
        target: BufferedStreamTarget,
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
            target: target,
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

    /// Once `idle` has detached a stream for worker-side materialization, the
    /// result is immutable. Rejecting late SSE deltas here prevents a brief
    /// visible append that the already-captured worker snapshot would later
    /// overwrite.
    private func isStreamingFinalizing(messageID: String) -> Bool {
        streamingFinalizationTokens[messageID] != nil
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

    private func invalidateStreamingUpdates(messageID: String, target: BufferedStreamTarget) {
        let resolvedMessageID = resolvedStreamingMessageID(messageID)
        guard let mailbox = streamingUpdateMailboxes[resolvedMessageID] else { return }

        let removed = mailbox.discard { $0.target == target }
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
        var messagesNeedingDerivedStateRebuild: [ObjectIdentifier: ChatMessage] = [:]
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
            switch update.target {
            case .textPart, .reasoningPart:
                targetMessage = assistantMessage(withID: resolvedMessageID)
            case .fallbackText:
                targetMessage = pendingAssistantMessage?.id == resolvedMessageID
                    ? pendingAssistantMessage
                    : nil
            }
            guard let message = targetMessage else {
                if let discarded = mailbox.removeFirst() {
                    bufferedStreamingRecordCount -= 1
                    bufferedStreamingChunkCount -= discarded.chunks.count
                }
                if mailbox.isEmpty {
                    streamingUpdateMailboxes.removeValue(forKey: mailboxMessageID)
                }
                continue
            }

            let acceptsTarget: Bool
            switch update.target {
            case .textPart(let partID):
                acceptsTarget = message.hasLiveStreamingPart(id: partID, type: .text)
            case .reasoningPart(let partID):
                acceptsTarget = message.hasLiveStreamingPart(id: partID, type: .reasoning)
            case .fallbackText:
                acceptsTarget = true
            }
            guard message.isStreaming,
                  !isStreamingFinalizing(messageID: resolvedMessageID),
                  acceptsTarget else {
                // The server can remove a part or finish a message between
                // enqueue and the next 40 ms render tick. Drop the complete
                // FIFO record so no invisible work bumps contentVersion or
                // influences auto-follow.
                if let discarded = mailbox.removeFirst() {
                    bufferedStreamingRecordCount -= 1
                    bufferedStreamingChunkCount -= discarded.chunks.count
                }
                if mailbox.isEmpty {
                    streamingUpdateMailboxes.removeValue(forKey: mailboxMessageID)
                }
                continue
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

            switch update.target {
            case .textPart(let partID):
                let insertedTextSegment = message.appendStreamingText(
                    partID: partID,
                    text: "",
                    chunks: chunks,
                    rebuildDerivedStateImmediately: false
                )
                if insertedTextSegment {
                    messagesNeedingDerivedStateRebuild[ObjectIdentifier(message)] = message
                }
                changedContent = true
            case .reasoningPart(let partID):
                let insertedReasoningSegment = message.appendStreamingReasoning(
                    partID: partID,
                    text: "",
                    chunks: chunks,
                    rebuildDerivedStateImmediately: false
                )
                if insertedReasoningSegment {
                    messagesNeedingDerivedStateRebuild[ObjectIdentifier(message)] = message
                }
                changedContent = true
            case .fallbackText:
                let pending = message
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

        if !messagesNeedingDerivedStateRebuild.isEmpty {
            for message in messagesNeedingDerivedStateRebuild.values {
                message.rebuildDerivedState()
            }
            requiresTimelineRebuild = true
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
        var textChunksByPartID = baseSnapshot.textChunksByPartID
        var reasoningChunksByPartID = baseSnapshot.reasoningChunksByPartID
        var additionalChunkCount = 0
        let validTextPartIDs = Set(baseSnapshot.textPartOrder)
        let validReasoningPartIDs = baseSnapshot.reasoningPartIDs

        bufferedUpdates.forEachInFIFO { update in
            switch update.target {
            case .textPart(let partID):
                guard validTextPartIDs.contains(partID) else { return }
                additionalChunkCount += update.chunks.count
                textChunksByPartID[partID, default: []].append(contentsOf: update.chunks)
            case .reasoningPart(let partID):
                guard validReasoningPartIDs.contains(partID) else { return }
                additionalChunkCount += update.chunks.count
                reasoningChunksByPartID[partID, default: []].append(contentsOf: update.chunks)
            case .fallbackText:
                additionalChunkCount += update.chunks.count
                contentChunks.append(contentsOf: update.chunks)
            }
        }

        return ChatMessage.materialize(
            ChatMessage.StreamingMaterialization(
                contentChunks: contentChunks,
                textChunksByPartID: textChunksByPartID,
                textPartOrder: baseSnapshot.textPartOrder,
                staticTextByPartID: baseSnapshot.staticTextByPartID,
                reasoningPartIDs: baseSnapshot.reasoningPartIDs,
                reasoningChunksByPartID: reasoningChunksByPartID,
                estimatedCharacterCount: baseSnapshot.estimatedCharacterCount
                    + additionalChunkCount * 2_400,
                requiresBackgroundMaterialization: baseSnapshot.requiresBackgroundMaterialization
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
        sessionSettingsChain = nil
        streamSynchronizationTask?.cancel()
        streamSynchronizationTask = nil
        streamSynchronizationToken = nil
        streamSynchronizationGeneration &+= 1
        isStreamSynchronized = true
        abortTask?.cancel()
        abortTask = nil
        streamingFinalizationTokens.removeAll()
        finalizingAssistantMessages.removeAll()
        turnDiffTasksByAssistantID.values.forEach { $0.cancel() }
        turnDiffTasksByAssistantID.removeAll()
        resolvedTurnDiffAssistantIDs.removeAll()
        turnFileDetailCache.removeAll()
        turnFileDetailCacheOrder.removeAll()
        cancelStoppedStateClear()
        ignoredAssistantMessageIDs.removeAll()
        optimisticV2UserMessageIDs.removeAll()
        optimisticV2CommandMessages.removeAll()
        sessionInbox = []
        locallyAdmittedInbox.removeAll()
        inboxEpoch &+= 1
        promptSubmissions.removeAll { $0.state != .uncertain }
        locallyStoppedSessionID = nil
        demoPlayer?.stop()
        recordedReplayPlayer?.stop()
        streamRecorder = nil
        isRecordingStream = false
        connection?.sseClient?.setRawEventRetentionEnabled(false)
        isLoading = false
        isQueueingPrompt = false
        queuedPrompts = []
        queuedPromptMutationID = nil
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
        pendingForm = nil
        showFormSheet = false
        isResolvingForm = false
        sessionStatus = nil
        todos = []
        hiddenTodoCount = 0
        cancelInteractiveRequestTimeout()
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
           !snapshot.requiresBackgroundMaterialization,
           snapshot.estimatedCharacterCount <= Self.asynchronousMaterializationThreshold {
            pending.applyStreamingMaterialization(ChatMessage.materialize(snapshot))
            pending.isStreaming = false
            // Clear pending FIRST to avoid a transient duplicate in
            // rebuildDisplayedMessages (messages.append triggers didSet which
            // would still see the pending message).
            pendingAssistantMessage = nil
            upsertAssistantMessage(pending)
            return
        }

        // Move the same object into the canonical list immediately. It remains
        // chunked/streaming until the worker returns, so another user turn can
        // start without losing this finished response.
        pendingAssistantMessage = nil
        upsertAssistantMessage(pending)
        scheduleStreamingMaterialization(
            for: pending,
            snapshot: snapshot,
            bufferedUpdates: bufferedUpdates
        )
    }

    private func scheduleStreamingMaterialization(
        for message: ChatMessage,
        snapshot: ChatMessage.StreamingMaterialization,
        bufferedUpdates: DetachedStreamingUpdates = .empty
    ) {
        let messageID = message.id
        let materializationRevision = message.streamingMaterializationRevision
        let token = UUID()
        streamingFinalizationTokens[messageID] = token
        finalizingAssistantMessages[messageID] = message
        Self.streamingMaterializationQueue.async { [weak self, weak message] in
            let materialized = Self.materialize(snapshot, appending: bufferedUpdates)
            DispatchQueue.main.async {
                guard let self, self.streamingFinalizationTokens[messageID] == token else {
                    return
                }

                guard let message,
                      self.messages.contains(where: { $0 === message }) else {
                    self.clearStreamingFinalization(messageID: messageID)
                    return
                }

                guard message.isStreaming else {
                    self.clearStreamingFinalization(messageID: messageID)
                    return
                }

                guard message.streamingMaterializationRevision == materializationRevision else {
                    // A retraction arrived after this worker snapshot was
                    // captured. Re-snapshot the surviving live state instead
                    // of restoring text that the server has removed.
                    self.scheduleStreamingMaterialization(
                        for: message,
                        snapshot: message.streamingMaterializationSnapshot(),
                        bufferedUpdates: bufferedUpdates
                    )
                    return
                }

                message.applyStreamingMaterialization(materialized)
                message.isStreaming = false
                self.clearStreamingFinalization(messageID: messageID)
                self.scheduleTurnDiffLoads(for: [message])
                self.contentVersion &+= 1
                // The cached timeline switches its row kind from the live
                // streaming projection to the finalized Markdown message.
                self.timelineVersion &+= 1
            }
        }
    }

    private func clearStreamingFinalization(messageID: String) {
        streamingFinalizationTokens.removeValue(forKey: messageID)
        finalizingAssistantMessages.removeValue(forKey: messageID)
    }

    private func upsertAssistantMessage(_ message: ChatMessage) {
        if let existingIndex = messages.lastIndex(where: { $0.id == message.id }) {
            messages[existingIndex] = message
        } else {
            messages.append(message)
        }
    }

    // MARK: - Finish Loading

    /// A native v2 step ends one assistant message without ending the session turn.
    func finishAssistantStep(messageID: String) {
        guard let pending = pendingAssistantMessage, pending.id == messageID else { return }
        let updates = detachBufferedStreamUpdates(for: messageID)
        finalizePendingAssistantMessage(pending, appendsWhenEmpty: true, bufferedUpdates: updates)
        continueStreamingFlushIfNeeded()
        contentVersion &+= 1
    }

    func finishLoading() {
        let completedActiveTurn = isLoading
            || pendingAssistantMessage != nil
            || responseState == .generating
            || responseState == .stopping
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

        if completedActiveTurn {
            promoteNextQueuedPrompt()
        }

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

    func startActivity(sessionID: String?, directory: String?) {}

    func update(pendingUserResponse: OpenLensActivityAttributes.PendingUserResponse?) {}

    func endActivity(phase: OpenLensActivityAttributes.Phase) {}

    func dismissImmediately() {}

    func previewLiveActivity() {}
}
