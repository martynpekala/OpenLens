import SwiftUI
import UniformTypeIdentifiers

private enum MicroLayout {
    static let screenInset: CGFloat = 18
    static let screenVerticalPadding: CGFloat = 18
    static let sectionGap: CGFloat = 16
    static let cardRadius: CGFloat = 26
    static let keyRadius: CGFloat = 15
}

private enum MicroPalette {
    static let canvasTop = Color(red: 0.92, green: 0.95, blue: 1.00)
    static let canvasBottom = Color(red: 0.84, green: 0.90, blue: 0.98)
    static let deviceTop = Color(red: 0.96, green: 0.98, blue: 1.00)
    static let deviceBottom = Color(red: 0.69, green: 0.75, blue: 0.82)
    static let deviceInner = Color(red: 0.62, green: 0.68, blue: 0.75)
    static let ink = Color(red: 0.10, green: 0.12, blue: 0.16)
    static let mutedInk = Color(red: 0.30, green: 0.37, blue: 0.47)
    static let keycap = Color.white.opacity(0.82)
    static let keycapHighlight = Color.white.opacity(0.96)
    static let idle = Color.white
    static let thinking = Color(red: 0.45, green: 0.61, blue: 0.97)
    static let complete = Color(red: 0.55, green: 0.84, blue: 0.63)
    static let needsInput = Color(red: 0.98, green: 0.76, blue: 0.45)
    static let error = Color(red: 0.94, green: 0.47, blue: 0.67)
    static let lemon = Color(red: 0.93, green: 0.99, blue: 0.22)
}

enum MicroAgentState: String, CaseIterable, Identifiable {
    case idle
    case thinking
    case approval
    case question
    case error

    var id: String { rawValue }

    var title: String {
        switch self {
        case .idle: "Idle"
        case .thinking: "Thinking"
        case .approval: "Needs approval"
        case .question: "Needs answer"
        case .error: "Error"
        }
    }

    var symbol: String {
        switch self {
        case .idle: "circle"
        case .thinking: "sparkles"
        case .approval: "checkmark.shield"
        case .question: "questionmark.bubble"
        case .error: "exclamationmark.triangle"
        }
    }

    var tint: Color {
        switch self {
        case .idle: MicroPalette.idle
        case .thinking: MicroPalette.thinking
        case .approval, .question: MicroPalette.needsInput
        case .error: MicroPalette.error
        }
    }
}

private enum MicroSignal: String, CaseIterable, Identifiable {
    case idle
    case thinking
    case complete
    case needsInput
    case error

    var id: String { rawValue }

    var title: String {
        switch self {
        case .idle: "Idle"
        case .thinking: "Thinking"
        case .complete: "Complete"
        case .needsInput: "Needs input"
        case .error: "Error"
        }
    }

    var tint: Color {
        switch self {
        case .idle: MicroPalette.idle
        case .thinking: MicroPalette.thinking
        case .complete: MicroPalette.complete
        case .needsInput: MicroPalette.needsInput
        case .error: MicroPalette.error
        }
    }
}

struct MicroRootView: View {
    enum ViewState: Equatable {
        case idle
        case loading
        case loaded
        case error(String)
    }

    private enum ControllerGridItem: Hashable {
        case agent(Int)
        case approve
        case deny
        case newChat
        case openChat
        case dial
        case primaryChat
        case skills

        var dragID: String {
            switch self {
            case let .agent(index): "agent-\(index)"
            case .approve: "approve"
            case .deny: "deny"
            case .newChat: "new-chat"
            case .openChat: "open-chat"
            case .dial: "dial"
            case .primaryChat: "primary-chat"
            case .skills: "skills"
            }
        }
    }

    private struct ControllerGridSlot: Identifiable {
        let index: Int
        let item: ControllerGridItem?

        var id: String {
            item?.dragID ?? "empty-slot-\(index)"
        }
    }

    private struct ControllerGridDropDelegate: DropDelegate {
        let onEntered: () -> Void
        let onExited: () -> Void
        let onPerform: () -> Bool

        func dropEntered(info: DropInfo) {
            onEntered()
        }

        func dropUpdated(info: DropInfo) -> DropProposal? {
            DropProposal(operation: .move)
        }

        func dropExited(info: DropInfo) {
            onExited()
        }

        func performDrop(info: DropInfo) -> Bool {
            onPerform()
        }
    }

    private static let defaultControllerGridItems: [ControllerGridItem?] = [
        .agent(0), .agent(1), .agent(2), .agent(3),
        .approve, .deny, .newChat, .openChat,
        .dial, .primaryChat, .skills, nil,
        nil, nil, nil, nil
    ]

    struct PreviewState {
        let sessions: [OCSession]
        let sessionStatuses: [String: OCSessionStatus]
        let inbox: InboxSnapshot
        let focusedSessionID: String?

        init(
            sessions: [OCSession],
            sessionStatuses: [String: OCSessionStatus],
            inbox: InboxSnapshot,
            focusedSessionID: String? = nil
        ) {
            self.sessions = sessions
            self.sessionStatuses = sessionStatuses
            self.inbox = inbox
            self.focusedSessionID = focusedSessionID
        }
    }

    @Bindable var chatClient: ChatClient
    private let previewState: PreviewState?

    @Environment(AppRouter.self) private var router
    @Environment(\.connection) private var connection
    @Environment(\.sessionsService) private var sessionsService
    @Environment(\.inboxService) private var inboxService

    @State private var viewState: ViewState = .idle
    @State private var sessions: [OCSession] = []
    @State private var sessionStatuses: [String: OCSessionStatus] = [:]
    @State private var inbox = InboxSnapshot(permissions: [], questions: [])
    @State private var focusedSessionID: String?
    @State private var activeQuestion: OCQuestionRequest?
    @State private var isCreatingSession = false
    @State private var actionError: String?
    @AppStorage("microControllerGridItems") private var controllerGridStorage = ""
    @State private var controllerGridItems: [ControllerGridItem?]
    @State private var activeControllerDragID: String?
    @State private var targetedControllerSlot: Int?
    @State private var controllerDragHaptics: HapticController

    init(chatClient: ChatClient, previewState: PreviewState? = nil) {
        self.chatClient = chatClient
        self.previewState = previewState
        _viewState = State(initialValue: previewState == nil ? .idle : .loaded)
        _sessions = State(initialValue: previewState?.sessions ?? [])
        _sessionStatuses = State(initialValue: previewState?.sessionStatuses ?? [:])
        _inbox = State(initialValue: previewState?.inbox ?? InboxSnapshot(permissions: [], questions: []))
        _focusedSessionID = State(initialValue: previewState?.focusedSessionID)
        _controllerGridItems = State(initialValue: Self.defaultControllerGridItems)
        _activeControllerDragID = State(initialValue: nil)
        _targetedControllerSlot = State(initialValue: nil)
        _controllerDragHaptics = State(initialValue: HapticController())
    }

    var body: some View {
        Group {
            if isInitialLoading {
                ProgressView()
                    .tint(MicroPalette.mutedInk)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(microCanvas)
            } else {
                content
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(microCanvasTop.opacity(0.96), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.light, for: .navigationBar)
        .task {
            guard previewState == nil else { return }
            restoreControllerGrid()
            await monitor()
        }
        .task(id: chatClient.currentSession?.id) {
            syncFocusToCurrentSession()
        }
        .refreshable {
            guard previewState == nil else { return }
            await refresh()
        }
        .sheet(item: $activeQuestion) { question in
            QuestionView(
                request: question,
                onSubmit: { answers in
                    Task { await submitQuestion(question, answers: answers) }
                },
                onDismiss: {
                    Task { await rejectQuestion(question) }
                }
            )
        }
        .alert("Micro action failed", isPresented: actionErrorBinding) {
            Button(AppText.dismiss, role: .cancel) {
                actionError = nil
            }
        } message: {
            Text(actionError ?? "Try again.")
        }
    }

    private var microCanvas: some View {
        LinearGradient(
            colors: [microCanvasTop, microCanvasBottom],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }

    private var microCanvasTop: Color { MicroPalette.canvasTop }
    private var microCanvasBottom: Color { MicroPalette.canvasBottom }

    @ViewBuilder
    private var content: some View {
            VStack(alignment: .leading, spacing: MicroLayout.sectionGap) {
                controllerDeck

                if let permission = visiblePermissions.first {
                    permissionCard(permission)
                } else if let question = visibleQuestions.first {
                    questionCard(question)
                } else {
                    allClearCard
                }

                statusLegend
                sessionsSection

                if let errorMessage {
                    errorCard(errorMessage)
                }
            }
            .padding(.horizontal, MicroLayout.screenInset)
            .padding(.vertical, MicroLayout.screenVerticalPadding)

        .background(microCanvas)
    }

    var controllerDeck: some View {
        let focused = focusedSession
        let focusedState = focused.map(agentState(for:)) ?? .idle

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {


                Spacer()

                HStack(spacing: 6) {
                    Circle()
                        .fill(connectionTint)
                        .frame(width: 8, height: 8)
                    Text(connectionTitle.uppercased())
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(MicroPalette.mutedInk)
                        .kerning(0.6)
                }
            }

            ZStack {
//                RoundedRectangle(cornerRadius: 32, style: .continuous)
//                    .fill(
//                        LinearGradient(
//                            colors: [MicroPalette.deviceTop, MicroPalette.deviceBottom],
//                            startPoint: .topLeading,
//                            endPoint: .bottomTrailing
//                        )
//                    )
//                    .overlay(alignment: .bottom) {
//                        LinearGradient(
//                            colors: [MicroPalette.complete.opacity(0.0), MicroPalette.complete.opacity(0.45)],
//                            startPoint: .top,
//                            endPoint: .bottom
//                        )
//                        .frame(height: 44)
//                        .blur(radius: 14)
//                        .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
//                    }

                VStack(spacing: 10) {
                    HStack {
                        Text("AGENT KEYS")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(MicroPalette.mutedInk)
                            .kerning(1.1)

                        Spacer()

                        if focused != nil {
                            Text(focusedState.title.uppercased())
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundStyle(focusedState.tint)
                                .lineLimit(1)
                        } else {
                            Text("READY TO BUILD")
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundStyle(MicroPalette.mutedInk)
                        }
                    }

                    controllerGrid
                }
                .padding(15)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .stroke(Color.white.opacity(0.82), lineWidth: 1)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .inset(by: 8)
                    .stroke(MicroPalette.deviceInner.opacity(0.55), lineWidth: 1)
            }
            .shadow(color: MicroPalette.mutedInk.opacity(0.20), radius: 20, y: 14)
        }
    }

    private var controllerGrid: some View {
        let focused = focusedSession
        let focusedState = focused.map { agentState(for: $0) } ?? .idle
        let columns = Array(repeating: GridItem(.flexible(minimum: 0), spacing: 9), count: 4)

        return GlassEffectContainer(spacing: 9) {
            LazyVGrid(columns: columns, spacing: 9) {
                ForEach(controllerGridSlots) { slot in
                    controllerGridSlot(
                        slot.item,
                        at: slot.index,
                        focused: focused,
                        focusedState: focusedState
                    )
                }
            }
            .animation(.snappy(duration: 0.22), value: controllerGridItems)
        }
    }

    private var controllerGridSlots: [ControllerGridSlot] {
        controllerGridItems.enumerated().map { index, item in
            ControllerGridSlot(index: index, item: item)
        }
    }

    @ViewBuilder
    private func controllerGridSlot(
        _ item: ControllerGridItem?,
        at slot: Int,
        focused: OCSession?,
        focusedState: MicroAgentState
    ) -> some View {
        let cell = controllerGridCell(item, focused: focused, focusedState: focusedState)
            .frame(maxWidth: .infinity)
            .aspectRatio(1, contentMode: .fit)
            .contentShape(Rectangle())
            .onDrop(
                of: [UTType.text],
                delegate: controllerGridDropDelegate(for: slot)
            )
            .overlay { controllerDropTargetOverlay(for: slot) }

        if let item {
            cell
                .onDrag {
                    beginControllerDrag(item.dragID)
                } preview: {
                    controllerGridDragPreview(
                        item,
                        focused: focused,
                        focusedState: focusedState
                    )
                }
        } else {
            cell
        }
    }

    private func controllerGridDragPreview(
        _ item: ControllerGridItem,
        focused: OCSession?,
        focusedState: MicroAgentState
    ) -> some View {
        controllerGridCell(item, focused: focused, focusedState: focusedState)
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: MicroLayout.keyRadius, style: .continuous))
    }

    private func controllerGridDropDelegate(for slot: Int) -> ControllerGridDropDelegate {
        ControllerGridDropDelegate(
            onEntered: { controllerDragEntered(slot) },
            onExited: { controllerDragExited(slot) },
            onPerform: finishControllerDrag
        )
    }

    private func controllerDropTargetOverlay(for slot: Int) -> some View {
        RoundedRectangle(cornerRadius: MicroLayout.keyRadius, style: .continuous)
            .stroke(
                MicroPalette.thinking.opacity(targetedControllerSlot == slot ? 0.9 : 0),
                lineWidth: 2
            )
            .animation(.easeInOut(duration: 0.15), value: targetedControllerSlot)
    }

    private func beginControllerDrag(_ identifier: String) -> NSItemProvider {
        activeControllerDragID = identifier
        targetedControllerSlot = nil
        controllerDragHaptics.playStepCompletion()
        controllerDragHaptics.prepareForSelection()
        return NSItemProvider(object: NSString(string: identifier))
    }

    private func controllerDragEntered(_ targetSlot: Int) {
        guard let identifier = activeControllerDragID,
              let sourceSlot = controllerGridItems.firstIndex(where: { $0?.dragID == identifier }),
              sourceSlot != targetSlot,
              controllerGridItems.indices.contains(targetSlot) else {
            targetedControllerSlot = targetSlot
            return
        }

        withAnimation(.snappy(duration: 0.18)) {
            controllerGridItems.swapAt(sourceSlot, targetSlot)
        }
        controllerDragHaptics.playSelection()
        controllerGridStorage = Self.encodeControllerGrid(controllerGridItems)
        targetedControllerSlot = targetSlot
    }

    private func controllerDragExited(_ slot: Int) {
        guard targetedControllerSlot == slot else { return }
        targetedControllerSlot = nil
    }

    private func finishControllerDrag() -> Bool {
        let accepted = activeControllerDragID != nil
        activeControllerDragID = nil
        targetedControllerSlot = nil
        return accepted
    }

    private func restoreControllerGrid() {
        guard let restored = Self.decodeControllerGrid(controllerGridStorage) else { return }
        controllerGridItems = restored
    }

    private static func encodeControllerGrid(_ items: [ControllerGridItem?]) -> String {
        items.map { $0?.dragID ?? "" }.joined(separator: ",")
    }

    private static func decodeControllerGrid(_ value: String) -> [ControllerGridItem?]? {
        guard !value.isEmpty else { return nil }

        let entries = value.split(separator: ",", omittingEmptySubsequences: false)
        guard entries.count == defaultControllerGridItems.count else { return nil }

        let items = entries.map { entry -> ControllerGridItem? in
            guard !entry.isEmpty else { return nil }
            return defaultControllerGridItems
                .compactMap { $0 }
                .first { $0.dragID == entry }
        }
        let nonEmptyItems = items.compactMap { $0 }
        let defaultItems = defaultControllerGridItems.compactMap { $0 }

        guard nonEmptyItems.count == defaultItems.count,
              Set(nonEmptyItems) == Set(defaultItems) else {
            return nil
        }

        return items
    }

    @ViewBuilder
    private func controllerGridCell(
        _ item: ControllerGridItem?,
        focused: OCSession?,
        focusedState: MicroAgentState
    ) -> some View {
        if let item {
            switch item {
            case let .agent(index):
                let session = index < sessions.count ? sessions[index] : nil
                MicroAgentKeycap(
                    session: session,
                    state: session.map { agentState(for: $0) } ?? .idle,
                    isFocused: session?.id == focused?.id,
                    onTap: {
                        if let session {
                            focusedSessionID = session.id
                        } else {
                            Task { await createSession() }
                        }
                    }
                )

            case .approve:
                MicroHardwareKey(
                    title: visiblePermissions.first == nil && visibleQuestions.first == nil ? "Approve" : visiblePermissions.first == nil ? "Answer" : "Approve",
                    detail: visiblePermissions.first == nil && visibleQuestions.first == nil ? "Ready" : visiblePermissions.first == nil ? "Open" : "Allow once",
                    symbol: visiblePermissions.first == nil && visibleQuestions.first == nil ? "checkmark" : visiblePermissions.first == nil ? "text.bubble" : "checkmark",
                    tint: visiblePermissions.first == nil && visibleQuestions.first == nil ? MicroPalette.complete : MicroPalette.needsInput,
                    isEnabled: visiblePermissions.first != nil || visibleQuestions.first != nil
                ) {
                    if let permission = visiblePermissions.first {
                        Task { await respondToPermission(permission, reply: .once) }
                    } else if let question = visibleQuestions.first {
                        activeQuestion = question
                    }
                }

            case .deny:
                MicroHardwareKey(
                    title: visiblePermissions.first == nil && visibleQuestions.first == nil ? "Deny" : visiblePermissions.first == nil ? "Dismiss" : "Deny",
                    detail: visiblePermissions.first == nil && visibleQuestions.first == nil ? "No request" : "Reject request",
                    symbol: "xmark",
                    tint: MicroPalette.error,
                    isEnabled: visiblePermissions.first != nil || visibleQuestions.first != nil
                ) {
                    if let permission = visiblePermissions.first {
                        Task { await respondToPermission(permission, reply: .reject) }
                    } else if let question = visibleQuestions.first {
                        Task { await rejectQuestion(question) }
                    }
                }

            case .newChat:
                MicroHardwareKey(
                    title: "New chat",
                    detail: isCreatingSession ? "Creating" : "Start fresh",
                    symbol: "plus",
                    tint: MicroPalette.lemon,
                    isEnabled: !isCreatingSession,
                    action: { Task { await createSession() } }
                )

            case .openChat:
                MicroHardwareKey(
                    title: "Open chat",
                    detail: focused == nil ? "No agent" : "Transcript",
                    symbol: "message",
                    tint: MicroPalette.ink,
                    isEnabled: focused != nil,
                    action: { openFocusedSession() }
                )

            case .dial:
                Menu {
                    Button {
                        chatClient.selectVariant(nil)
                    } label: {
                        Label(AppText.thinkingDefault, systemImage: chatClient.selectedVariant == nil ? "checkmark" : "circle")
                    }

                    ForEach(chatClient.availableReasoningVariants) { variant in
                        Button {
                            chatClient.selectVariant(variant.id)
                        } label: {
                            Label(variant.displayName, systemImage: chatClient.selectedVariant == variant.id ? "checkmark" : "circle")
                        }
                    }
                } label: {
                    MicroDialView(title: chatClient.selectedVariantDisplayName)
                }
                .disabled(chatClient.availableReasoningVariants.isEmpty)

            case .primaryChat:
                MicroHardwareKey(
                    title: focused == nil ? "New chat" : "Open chat",
                    detail: focused == nil ? "Let's build" : "View transcript",
                    symbol: focused == nil ? "plus" : "message",
                    tint: MicroPalette.ink,
                    isEnabled: focused == nil ? !isCreatingSession : true
                ) {
                    if focused == nil {
                        Task { await createSession() }
                    } else {
                        openFocusedSession()
                    }
                }

            case .skills:
                Menu {
                    Button {
                        router.selectedTab = .review
                    } label: {
                        Label("Review changes", systemImage: "magnifyingglass.circle")
                    }
                    Button {
                        Task { await createSession() }
                    } label: {
                        Label("Start new chat", systemImage: "plus")
                    }
                    Button {
                        openFocusedSession()
                    } label: {
                        Label("Open active chat", systemImage: "message")
                    }
                    .disabled(focused == nil)
                    Button {
                        Task { await stopFocusedSession() }
                    } label: {
                        Label("Stop active agent", systemImage: "stop.fill")
                    }
                    .disabled(focused.map { agentState(for: $0) != .thinking } ?? true)
                } label: {
                    MicroJoystickView(state: focusedState)
                }
            }
        } else {
            Color.clear
                .accessibilityHidden(true)
        }
    }

    private func permissionCard(_ permission: OCPermissionRequest) -> some View {
        MicroGlassPanel(tint: MicroPalette.needsInput) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 10) {
                    MicroSignalBadge(symbol: "checkmark.shield", tint: MicroPalette.needsInput)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Approval needed")
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .foregroundStyle(MicroPalette.ink)
                        Text("The agent is waiting for a decision.")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(MicroPalette.mutedInk)
                    }

                    Spacer()
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(permission.title?.nilIfBlank ?? AppText.permissionRequired)
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(MicroPalette.ink)

                    Text(permission.description?.nilIfBlank ?? AppText.permissionFallback)
                        .font(.system(size: 14))
                        .foregroundStyle(MicroPalette.mutedInk)
                        .lineLimit(3)

                    if let tool = permission.toolDisplayName?.nilIfBlank {
                        MicroMetadataChip(symbol: "terminal", text: tool, monospaced: true, tint: MicroPalette.needsInput)
                            .padding(.top, 4)
                    }
                }

                HStack(spacing: 9) {
                    MicroPillAction(
                        title: AppText.deny,
                        symbol: "xmark",
                        tint: MicroPalette.error,
                        prominent: false
                    ) {
                        Task { await respondToPermission(permission, reply: .reject) }
                    }

                    MicroPillAction(
                        title: AppText.approve,
                        symbol: "checkmark",
                        tint: MicroPalette.complete,
                        prominent: true
                    ) {
                        Task { await respondToPermission(permission, reply: .once) }
                    }
                }
            }
            .padding(18)
        }
    }

    private func questionCard(_ question: OCQuestionRequest) -> some View {
        MicroGlassPanel(tint: MicroPalette.needsInput) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 10) {
                    MicroSignalBadge(symbol: "questionmark.bubble", tint: MicroPalette.needsInput)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Answer needed")
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .foregroundStyle(MicroPalette.ink)
                        Text("The agent needs your direction.")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(MicroPalette.mutedInk)
                    }

                    Spacer()
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(question.questions.first?.header.nilIfBlank ?? AppText.questionTranscriptTitle)
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(MicroPalette.ink)

                    Text(question.questions.first?.question.nilIfBlank ?? "Open the question to choose an answer.")
                        .font(.system(size: 14))
                        .foregroundStyle(MicroPalette.mutedInk)
                        .lineLimit(3)
                }

                HStack(spacing: 9) {
                    MicroPillAction(
                        title: "Answer",
                        symbol: "text.bubble",
                        tint: MicroPalette.needsInput,
                        prominent: true
                    ) {
                        activeQuestion = question
                    }

                    MicroPillAction(
                        title: AppText.dismiss,
                        symbol: "xmark",
                        tint: MicroPalette.error,
                        prominent: false
                    ) {
                        Task { await rejectQuestion(question) }
                    }
                }
            }
            .padding(18)
        }
    }

    private var allClearCard: some View {
        MicroGlassPanel(tint: MicroPalette.complete) {
            HStack(spacing: 14) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(MicroPalette.complete)

                VStack(alignment: .leading, spacing: 4) {
                    Text("All agents clear")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(MicroPalette.ink)
                    Text("No approvals or questions are waiting")
                        .font(.system(size: 13))
                        .foregroundStyle(MicroPalette.mutedInk)
                }

                Spacer()
            }
            .padding(18)
        }
    }

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel(text: "Connected agents")

                Spacer()

                Text("\(sessions.count)")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(MicroPalette.mutedInk)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.52), in: Capsule())
            }

            if sessions.isEmpty {
                MicroGlassPanel(tint: MicroPalette.complete) {
                    HStack(spacing: 10) {
                        Image(systemName: "plus.circle")
                            .foregroundStyle(MicroPalette.complete)
                        Text("No agents yet. Press New chat to start one.")
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(MicroPalette.mutedInk)
                        Spacer()
                    }
                    .padding(16)
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(sessions) { session in
                            Button {
                                focusedSessionID = session.id
                            } label: {
                                MicroSessionPill(
                                    session: session,
                                    state: agentState(for: session),
                                    isFocused: focusedSession?.id == session.id
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var statusLegend: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: "Agent signal")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(MicroSignal.allCases) { signal in
                        HStack(spacing: 5) {
                            Circle()
                                .fill(signal.tint)
                                .frame(width: 7, height: 7)
                            Text(signal.title)
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                .foregroundStyle(MicroPalette.mutedInk)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.45), in: Capsule())
                    }
                }
                .padding(.horizontal, 4)
            }
        }
    }

    private func errorCard(_ message: String) -> some View {
        MicroGlassPanel(tint: MicroPalette.error) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(MicroPalette.error)
                Text(message)
                    .font(.system(size: 14))
                    .foregroundStyle(MicroPalette.mutedInk)
                Spacer()
            }
            .padding(16)
        }
    }

    private var focusedSession: OCSession? {
        if let focusedSessionID,
           let focused = sessions.first(where: { $0.id == focusedSessionID }) {
            return focused
        }

        if let currentSession = chatClient.currentSession,
           let current = sessions.first(where: { $0.id == currentSession.id }) {
            return current
        }

        return sessions.first
    }

    private var visiblePermissions: [OCPermissionRequest] {
        var result = inbox.permissions
        if let pending = chatClient.pendingPermission,
           !result.contains(where: { $0.id == pending.id }) {
            result.insert(pending, at: 0)
        }
        return result
    }

    private var visibleQuestions: [OCQuestionRequest] {
        var result = inbox.questions
        if let pending = chatClient.pendingQuestion,
           !result.contains(where: { $0.id == pending.id }) {
            result.insert(pending, at: 0)
        }
        return result
    }

    private func agentState(for session: OCSession) -> MicroAgentState {
        if visiblePermissions.contains(where: { $0.sessionID == session.id }) {
            return .approval
        }
        if visibleQuestions.contains(where: { $0.sessionID == session.id }) {
            return .question
        }

        if chatClient.currentSession?.id == session.id {
            switch chatClient.responseState {
            case .generating, .stopping:
                return .thinking
            case .failed:
                return .error
            case .idle, .stopped:
                break
            }
        }

        switch sessionStatuses[session.id]?.type {
        case .busy:
            return .thinking
        case .retry:
            return .error
        case .idle, .none:
            return .idle
        }
    }

    private var isInitialLoading: Bool {
        if case .loading = viewState {
            return sessions.isEmpty
        }
        return false
    }

    private var errorMessage: String? {
        if case .error(let message) = viewState {
            return message
        }
        return nil
    }

    private var actionErrorBinding: Binding<Bool> {
        Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )
    }

    private var connectionTitle: String {
        switch connection.state {
        case .connected:
            "Connected"
        case .connecting:
            "Connecting"
        case .reconnecting:
            "Reconnecting"
        case .disconnected:
            "Offline"
        case .error:
            "Connection error"
        }
    }

    private var connectionTint: Color {
        switch connection.state {
        case .connected:
            MicroPalette.complete
        case .connecting, .reconnecting:
            MicroPalette.needsInput
        case .disconnected, .error:
            MicroPalette.error
        }
    }

    private func monitor() async {
        await refresh()

        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            await refresh()
        }
    }

    private func refresh() async {
        if sessions.isEmpty {
            viewState = .loading
        }

        async let sessionsTask = sessionsService.listSessions()
        async let statusesTask = sessionsService.getSessionStatuses()
        async let inboxTask = inboxService.loadInbox()

        do {
            let loadedSessions = try await sessionsTask
            let loadedStatuses = (try? await statusesTask) ?? [:]
            let loadedInbox = (try? await inboxTask) ?? InboxSnapshot(permissions: [], questions: [])

            guard !Task.isCancelled else { return }
            sessions = loadedSessions
            sessionStatuses = loadedStatuses
            inbox = loadedInbox
            syncFocusToCurrentSession()
            viewState = .loaded
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            viewState = .error(error.localizedDescription)
        }
    }

    private func syncFocusToCurrentSession() {
        if let currentID = chatClient.currentSession?.id,
           sessions.contains(where: { $0.id == currentID }) {
            focusedSessionID = currentID
        } else if let focusedSessionID,
                  sessions.contains(where: { $0.id == focusedSessionID }) {
            self.focusedSessionID = focusedSessionID
        } else {
            focusedSessionID = sessions.first?.id
        }
    }

    private func createSession() async {
        guard !isCreatingSession else { return }
        isCreatingSession = true
        defer { isCreatingSession = false }

        do {
            let session = try await sessionsService.createSession()
            sessions.removeAll { $0.id == session.id }
            sessions.insert(session, at: 0)
            focusedSessionID = session.id
            router.selectChatSession(session)
        } catch is CancellationError {
            return
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func openFocusedSession() {
        guard let session = focusedSession else { return }
        router.selectChatSession(session)
    }

    private func stopFocusedSession() async {
        guard let session = focusedSession, agentState(for: session) == .thinking else { return }

        do {
            try await sessionsService.abortSession(id: session.id)
            await refresh()
        } catch is CancellationError {
            return
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func respondToPermission(_ permission: OCPermissionRequest, reply: OCPermissionReply) async {
        do {
            try await inboxService.respondToPermission(permission, reply: reply)

            if chatClient.pendingPermission?.id == permission.id {
                chatClient.pendingPermission = nil
                chatClient.showPermissionAlert = false
            }
            await refresh()
        } catch is CancellationError {
            return
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func submitQuestion(_ question: OCQuestionRequest, answers: [[String]]) async {
        do {
            try await inboxService.respondToQuestion(
                requestID: question.id,
                answers: answers
            )

            if chatClient.pendingQuestion?.id == question.id {
                chatClient.pendingQuestion = nil
                chatClient.showQuestionSheet = false
            }
            activeQuestion = nil
            await refresh()
        } catch is CancellationError {
            return
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func rejectQuestion(_ question: OCQuestionRequest) async {
        do {
            try await inboxService.rejectQuestion(
                requestID: question.id
            )

            if chatClient.pendingQuestion?.id == question.id {
                chatClient.pendingQuestion = nil
                chatClient.showQuestionSheet = false
            }
            activeQuestion = nil
            await refresh()
        } catch is CancellationError {
            return
        } catch {
            actionError = error.localizedDescription
        }
    }
}

private struct MicroMetadataChip: View {
    let symbol: String
    let text: String
    var monospaced = false
    var tint: Color = MicroPalette.mutedInk

    var body: some View {
        Label(text, systemImage: symbol)
            .font(monospaced
                ? .system(size: 11, weight: .medium, design: .monospaced)
                : .system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(MicroPalette.mutedInk)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(tint.opacity(0.14), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(tint.opacity(0.26), lineWidth: 1)
            }
    }
}

private struct MicroTactileKeySurface<Content: View>: View {
    let tint: Color
    let isLit: Bool
    let isSelected: Bool
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: MicroLayout.keyRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.98),
                            Color(red: 0.83, green: 0.87, blue: 0.87),
                            Color(red: 0.96, green: 0.97, blue: 0.97)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    RoundedRectangle(cornerRadius: MicroLayout.keyRadius, style: .continuous)
                        .stroke(Color(red: 0.35, green: 0.40, blue: 0.41).opacity(0.24), lineWidth: 1)
                }
                .shadow(color: Color(red: 0.18, green: 0.22, blue: 0.23).opacity(0.28), radius: 1, y: 4)
                .shadow(color: Color.black.opacity(0.18), radius: 7, y: 5)

            if isLit {
                RoundedRectangle(cornerRadius: MicroLayout.keyRadius - 2, style: .continuous)
                    .fill(tint.opacity(isSelected ? 0.62 : 0.38))
                    .padding(3)
                    .blur(radius: isSelected ? 5 : 3)
            }

            RoundedRectangle(cornerRadius: MicroLayout.keyRadius - 2, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.72),
                            Color(red: 0.87, green: 0.91, blue: 0.91).opacity(0.60),
                            Color.white.opacity(0.30)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .padding(3)
                .overlay {
                    RoundedRectangle(cornerRadius: MicroLayout.keyRadius - 2, style: .continuous)
                        .stroke(Color.white.opacity(0.72), lineWidth: 1)
                        .padding(3)
                }

            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(red: 0.91, green: 0.94, blue: 0.94),
                            Color(red: 0.80, green: 0.85, blue: 0.85).opacity(0.76),
                            Color.white.opacity(0.12)
                        ],
                        center: .center,
                        startRadius: 1,
                        endRadius: 48
                    )
                )
                .padding(17)
                .overlay {
                    Circle()
                        .stroke(Color.white.opacity(0.28), lineWidth: 1)
                        .padding(17)
                }
                .shadow(color: Color(red: 0.25, green: 0.31, blue: 0.32).opacity(0.18), radius: 3, y: 2)

            content
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
    }
}

private struct MicroHardwareKey: View {
    let title: String
    let detail: String
    let symbol: String
    let tint: Color
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            MicroTactileKeySurface(tint: tint, isLit: false, isSelected: false) {
                Image(systemName: symbol)
                    .font(.system(size: 25, weight: .medium, design: .rounded))
                    .foregroundStyle(MicroPalette.ink.opacity(isEnabled ? 0.92 : 0.40))
            }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.58)
        .accessibilityLabel(title)
        .accessibilityValue(detail)
    }
}

private struct MicroAgentKeycap: View {
    let session: OCSession?
    let state: MicroAgentState
    let isFocused: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            MicroTactileKeySurface(
                tint: session == nil ? MicroPalette.idle : state.tint,
                isLit: session != nil,
                isSelected: isFocused
            ) {
                Image(systemName: session == nil ? "plus" : state.symbol)
                    .font(.system(size: 25, weight: .medium, design: .rounded))
                    .foregroundStyle(MicroPalette.ink.opacity(session == nil ? 0.48 : 0.82))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(session == nil ? "New chat key" : "\(displayTitle), \(state.title)")
    }

    private var displayTitle: String {
        guard let title = session?.title.nilIfBlank else { return "NEW" }
        let compact = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(9))
        return compact.uppercased()
    }
}

private struct MicroDialView: View {
    let title: String

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                Circle()
                    .fill(MicroPalette.ink)
                    .frame(width: 42, height: 42)
                    .shadow(color: MicroPalette.ink.opacity(0.28), radius: 6, y: 4)

                Circle()
                    .stroke(MicroPalette.deviceTop.opacity(0.65), lineWidth: 1)
                    .frame(width: 48, height: 48)

                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(MicroPalette.keycapHighlight)
                    .offset(y: -11)
            }

            Text("DIAL")
                .font(.system(size: 7, weight: .bold, design: .rounded))
                .foregroundStyle(MicroPalette.mutedInk)
                .kerning(0.7)
            Text(title)
                .font(.system(size: 7, weight: .semibold, design: .rounded))
                .foregroundStyle(MicroPalette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Reasoning level, \(title)")
    }
}

private struct MicroJoystickView: View {
    let state: MicroAgentState

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                Circle()
                    .fill(MicroPalette.deviceInner.opacity(0.65))
                    .frame(width: 48, height: 48)
                Circle()
                    .fill(MicroPalette.ink)
                    .frame(width: 30, height: 30)
                    .shadow(color: state.tint.opacity(0.35), radius: 8)
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(state.tint)
            }

            Text("SKILLS")
                .font(.system(size: 7, weight: .bold, design: .rounded))
                .foregroundStyle(MicroPalette.mutedInk)
                .kerning(0.7)
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Skills menu")
    }
}

private struct MicroSignalBadge: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(tint)
            .frame(width: 34, height: 34)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

private struct MicroPillAction: View {
    let title: String
    let symbol: String
    let tint: Color
    let prominent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(prominent ? MicroPalette.ink : MicroPalette.mutedInk)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(
                    prominent ? tint.opacity(0.72) : Color.white.opacity(0.54),
                    in: Capsule()
                )
                .overlay {
                    Capsule()
                        .stroke(tint.opacity(prominent ? 0.65 : 0.28), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
    }
}

private struct MicroGlassPanel<Content: View>: View {
    let tint: Color
    @ViewBuilder let content: Content

    var body: some View {
        content
            .background(Color.white.opacity(0.42), in: RoundedRectangle(cornerRadius: MicroLayout.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: MicroLayout.cardRadius, style: .continuous)
                    .stroke(tint.opacity(0.32), lineWidth: 1)
            }
            .microGlassKey(tint: tint, cornerRadius: MicroLayout.cardRadius)
            .shadow(color: MicroPalette.mutedInk.opacity(0.10), radius: 12, y: 7)
    }
}

private struct MicroSessionPill: View {
    let session: OCSession
    let state: MicroAgentState
    let isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(state.tint.opacity(0.22))
                    .frame(width: 24, height: 24)
                Circle()
                    .fill(state.tint)
                    .frame(width: 7, height: 7)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(session.title.nilIfBlank ?? AppText.titleUntitled)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(MicroPalette.ink)
                    .lineLimit(1)

                Text(state.title)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(MicroPalette.mutedInk)
                    .lineLimit(1)
            }

            if isFocused {
                Image(systemName: "scope")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(state.tint)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(Color.white.opacity(isFocused ? 0.68 : 0.38), in: Capsule())
        .overlay {
            Capsule()
                .stroke(isFocused ? state.tint.opacity(0.50) : Color.white.opacity(0.46), lineWidth: 1)
        }
        .shadow(color: state.tint.opacity(isFocused ? 0.18 : 0.03), radius: 6, y: 3)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(session.title.nilIfBlank ?? AppText.titleUntitled), \(state.title)")
    }
}

private extension View {
    @ViewBuilder
    func microGlassKey(
        tint: Color,
        cornerRadius: CGFloat = MicroLayout.keyRadius,
        interactive: Bool = false
    ) -> some View {
        if interactive {
            glassEffect(.regular.tint(tint.opacity(0.20)).interactive(), in: .rect(cornerRadius: cornerRadius))
        } else {
            glassEffect(.regular.tint(tint.opacity(0.15)), in: .rect(cornerRadius: cornerRadius))
        }
    }
}

#Preview("Loaded") {
    MicroRootViewPreviewHost(state: .loaded)
}

#Preview("Empty") {
    MicroRootViewPreviewHost(state: .empty)
}

private extension MicroRootView.PreviewState {
    static let loaded = MicroRootView.PreviewState(
        sessions: ScreenshotFixtures.sessions,
        sessionStatuses: ScreenshotFixtures.sessionStatuses,
        inbox: ScreenshotFixtures.inboxSnapshot,
        focusedSessionID: ScreenshotFixtures.defaultSessionID
    )

    static let empty = MicroRootView.PreviewState(
        sessions: [],
        sessionStatuses: [:],
        inbox: InboxSnapshot(permissions: [], questions: [])
    )
}

private struct MicroRootViewPreviewHost: View {
    @State private var chatClient: ChatClient
    @State private var router = AppRouter()
    @State private var connection: ConnectionManager

    private let sessionsService: SessionsService
    private let inboxService: InboxService
    private let state: MicroRootView.PreviewState

    init(state: MicroRootView.PreviewState) {
        self.state = state

        let connection = ConnectionManager()
        connection.configureDemoState(projectName: "OpenLens", branch: "feature/micro")
        _connection = State(initialValue: connection)
        sessionsService = SessionsService(connection: connection)
        inboxService = InboxService(connection: connection)

        let chatClient = ChatClient(demoMode: true)
        chatClient.currentSession = state.sessions.first(where: { $0.id == state.focusedSessionID })
        _chatClient = State(initialValue: chatClient)
    }

    var body: some View {
        MicroRootView(chatClient: chatClient, previewState: state)
        .environment(router)
        .environment(\.connection, connection)
        .environment(\.sessionsService, sessionsService)
        .environment(\.inboxService, inboxService)
    }
}
