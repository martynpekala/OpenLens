import SwiftUI

/// Main chat interface.
/// Keeps view-local UI state and delegates IO to the coordinator ViewModel + services.
/// Side effects are driven by lifecycle hooks (.task, .onChange).
struct ChatView: View {
    fileprivate static let integerFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        formatter.usesGroupingSeparator = true
        return formatter
    }()

    @Bindable var chatClient: ChatClient

    @FocusState private var isInputFocused: Bool
    @GestureState private var isInputBarPressed = false

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.connection) private var connection
    @Environment(\.workspaceService) private var workspaceService
    @Environment(\.chatEasterEgg) private var chatEasterEgg
    @AppStorage(FeatureFlags.debugFeaturesKey) private var debugFeaturesEnabled: Bool = FeatureFlags.debugFeaturesDefault

    @State private var showModelPicker = false
    @State private var showContextStatus = false
    @State private var showTodoList = false
    @State private var availableSlashActions: [WorkspaceSlashActionItem] = []
    @State private var selectedSlashAction: WorkspaceSlashActionItem?
    @State private var isLoadingCommands = false
    @State private var displayedResponseState: ChatResponseState = .idle
    @State private var isComposerExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            ChatMessagesListView(
                chatClient: chatClient
            )

            if let error = chatClient.errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(isRetroChat ? RetroChatStyle.danger : .orange)
                        .font(.system(size: 13))
                    Text(error)
                        .font(isRetroChat ? RetroChatStyle.smallFont : .system(size: 13))
                        .foregroundStyle(secondaryTextColor)
                    Spacer()
                    Button(AppText.dismiss) {
                        chatClient.dismissError()
                    }
                    .font(isRetroChat ? RetroChatStyle.smallFont : .system(size: 13, weight: .medium))
                    .foregroundStyle(primaryTextColor)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
//                .background(isRetroChat ? RetroChatStyle.paperWarm : .clear)
                .overlay(alignment: .top) {
                    (isRetroChat ? RetroChatStyle.ink : Color.appSeparator)
                        .frame(height: isRetroChat ? 2 : 0.5)
                }
            }
        }
        .background {
            chatBackground
                .ignoresSafeArea()
        }
        .overlay(alignment: .top) {
            responseStatusOverlay
                .padding(.top, 8)
        }
        .safeAreaInset(edge: .bottom) {
            if chatClient.showsComposer {
                chatComposerInset
                    .background {
                        composerInsetBackground
                            .ignoresSafeArea(edges: .bottom)
                    }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ChatHeaderToolbar(
                projectName: chatClient.currentSession?.workspaceDisplayName ?? connection.projectName,
                branch: connection.branch,
                connectionState: connection.state,
                sessionTitle: chatClient.currentSession?.title,
                showsRecordingControls: chatClient.isRecordingStream || (debugFeaturesEnabled && chatClient.supportsStreamRecording),
                isRecordingStream: chatClient.isRecordingStream,
                visualMode: visualMode,
                onToggleRecording: {
                    if chatClient.isRecordingStream {
                        chatClient.stopStreamRecording()
                    } else {
                        chatClient.startStreamRecording()
                    }
                }
            )
        }
        .onAppear {
            updateShakeMonitoring(for: scenePhase)
            displayedResponseState = chatClient.responseState
        }
        .onDisappear {
            chatEasterEgg.stopShakeMonitoring()
        }
        // Initial load: ensure session is loaded when view appears
        .task {
            chatClient.setupSSEHandlers()
            await loadCommands(force: true)
            await chatClient.ensureSession()
            await chatClient.recoverPendingPermission()
            await chatClient.recoverPendingQuestions()
        }

        // Foreground recovery: refresh messages and questions when app becomes active
        .onChange(of: scenePhase) { _, newPhase in
            updateShakeMonitoring(for: newPhase)

            if newPhase == .active {
                chatClient.setupSSEHandlers()
                Task {
                    await loadCommands(force: true)
                    await chatClient.refreshCurrentSessionStatus()
                    await chatClient.loadMessages()
                    await chatClient.recoverPendingPermission()
                    await chatClient.recoverPendingQuestions()
                }
            }
        }

        // MARK: - Sheets

        .sheet(isPresented: $chatClient.showActivityCard) {
            if let activity = chatClient.currentActivity ?? chatClient.lastCompletedActivity {
                AgentActivityCard(activity: activity)
                    .presentationDetents([.medium, .large])
            }
        }
        .sheet(isPresented: $showModelPicker) {
            ModelPickerView(
                models: chatClient.availableModels,
                selectedProviderID: chatClient.selectedProviderID,
                selectedModelID: chatClient.selectedModelID,
                isLoading: chatClient.isLoadingProviders,
                defaultModelSelection: chatClient.defaultModelSelection,
                visualMode: visualMode
            ) { model in
                chatClient.selectModel(model)
                showModelPicker = false
            } onToggleDefault: { model in
                chatClient.toggleDefaultModel(model)
            }
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $showContextStatus) {
            if let contextUsage = chatClient.contextUsageSummary {
                ChatContextStatusSheet(summary: contextUsage, visualMode: visualMode)
                    .presentationDetents([.fraction(0.34), .medium])
                    .presentationDragIndicator(.visible)
            }
        }
        .sheet(isPresented: $chatClient.showQuestionSheet, onDismiss: {
            // Handle swipe-dismiss: reject the question and clear state.
            if chatClient.pendingQuestion != nil {
                chatClient.rejectQuestion()
            }
        }) {
            if let question = chatClient.pendingQuestion {
                QuestionView(
                    request: question,
                    onSubmit: { answers in
                        chatClient.respondToQuestion(answers: answers)
                    },
                    onDismiss: {
                        chatClient.rejectQuestion()
                    }
                )
                .presentationDetents([.medium, .large])
            }
        }
        .onChange(of: chatClient.inputText) { _, newValue in
            handleComposerTextChange(newValue)
        }
        .onChange(of: chatClient.responseState) { _, newState in
            updateDisplayedResponseState(newState)
        }
        .onChange(of: isInputFocused) { _, focused in
            setComposerExpanded(focused)
        }
        .onChange(of: chatClient.currentSession?.id) { _, _ in
            clearSelectedSlashAction()
        }
        .onChange(of: connection.selectedProjectDirectory) { _, _ in
            clearSelectedSlashAction()
        }
    }

    private var visualMode: ChatVisualMode {
        chatEasterEgg.visualMode
    }

    private var isRetroChat: Bool {
        visualMode.isRetro
    }

    @ViewBuilder
    private var chatBackground: some View {
        if isRetroChat {
            RetroChatScreenBackground()
        } else {
            Color.appBackground
        }
    }

    @ViewBuilder
    private var composerInsetBackground: some View {
        if isRetroChat {
            LinearGradient(
                gradient: Gradient(
                    colors: [
                        .clear,
                        RetroChatStyle.screenBottom.opacity(0.7)
                    ],
                ),
                startPoint: .top,
                endPoint: .bottom
            )
        } else {
            LinearGradient(
                gradient: Gradient(
                    colors: [
                        .clear,
                        Color.appBackground.opacity(0.7)
                    ]
                ),
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private var primaryTextColor: Color {
        isRetroChat ? RetroChatStyle.ink : Color.appPrimary
    }

    private var secondaryTextColor: Color {
        isRetroChat ? RetroChatStyle.secondaryInk : Color.appSecondary
    }

    @ViewBuilder
    private var responseStatusOverlay: some View {
        if let label = responseStatusLabel(for: displayedResponseState) {
            ResponseStatusSiriIndicator(
                state: displayedResponseState,
                label: label,
                icon: responseStatusIcon(for: displayedResponseState),
                color: responseStatusColor(for: displayedResponseState),
                isRetroChat: isRetroChat
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .allowsHitTesting(false)
            .transition(
                .asymmetric(
                    insertion: .move(edge: .top)
                        .combined(with: .opacity)
                        .combined(with: .scale(scale: 0.92)),
                    removal: .opacity
                        .combined(with: .scale(scale: 0.86))
                )
            )
        }
    }

    private func updateDisplayedResponseState(_ state: ChatResponseState) {
        let animation: Animation = state == .idle
            ? .easeInOut(duration: 0.24)
            : .spring(response: 0.32, dampingFraction: 0.78)

        withAnimation(animation) {
            displayedResponseState = state
        }
    }

    private func updateShakeMonitoring(for phase: ScenePhase) {
        if phase == .active {
            chatEasterEgg.startShakeMonitoring()
        } else {
            chatEasterEgg.stopShakeMonitoring()
        }
    }

    private var todoChip: some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                showTodoList.toggle()
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: todoChipIcon)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(todoChipColor)
                Text(todoChipLabel)
                    .font(isRetroChat ? RetroChatStyle.smallFont : .system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(secondaryTextColor)
                Image(systemName: showTodoList ? "chevron.down" : "chevron.up")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(secondaryTextColor.opacity(0.7))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .chatModeChipChrome(visualMode)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showTodoList, arrowEdge: .bottom) {
            todoExpandedList
        }
    }

    private var todoChipLabel: String {
        let completed = chatClient.todos.filter { $0.status == "completed" }.count
        let visible = chatClient.todos.count
        guard chatClient.hiddenTodoCount > 0 else {
            return "\(completed)/\(visible)"
        }
        return "\(completed)/\(visible) +\(chatClient.hiddenTodoCount)"
    }

    private var todoChipIcon: String {
        let allDone = chatClient.hiddenTodoCount == 0
            && !chatClient.todos.isEmpty
            && chatClient.todos.allSatisfy { $0.status == "completed" }
        if allDone { return "checkmark.circle.fill" }
        let hasInProgress = chatClient.todos.contains { $0.status == "in_progress" }
        return hasInProgress ? "circle.dashed" : "checklist"
    }

    private var todoChipColor: Color {
        let allDone = chatClient.hiddenTodoCount == 0
            && !chatClient.todos.isEmpty
            && chatClient.todos.allSatisfy { $0.status == "completed" }
        if allDone { return isRetroChat ? RetroChatStyle.blueAccent : .green }
        let hasInProgress = chatClient.todos.contains { $0.status == "in_progress" }
        if hasInProgress { return isRetroChat ? RetroChatStyle.magentaAccent : .orange }
        return secondaryTextColor
    }

    private var todoExpandedList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(chatClient.todos) { todo in
                HStack(spacing: 6) {
                    Image(systemName: todoIcon(for: todo.status))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(todoColor(for: todo.status))
                    Text(todo.content)
                        .font(isRetroChat ? RetroChatStyle.smallFont : .system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(todo.status == "completed" || todo.status == "cancelled"
                            ? secondaryTextColor.opacity(0.6)
                            : primaryTextColor)
                        .strikethrough(todo.status == "cancelled")
                        .lineLimit(1)
                }
                .padding(.vertical, 4)
            }

            if chatClient.hiddenTodoCount > 0 {
                Text("Showing the first \(chatClient.todos.count) of \(chatClient.todos.count + chatClient.hiddenTodoCount) tasks")
                    .font(isRetroChat ? RetroChatStyle.smallFont : .system(size: 12, weight: .medium))
                    .foregroundStyle(secondaryTextColor)
                    .padding(.top, 4)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .presentationCompactAdaptation(.popover)
    }

    private func todoIcon(for status: String) -> String {
        switch status {
        case "completed": "checkmark.circle.fill"
        case "in_progress": "circle.dashed"
        case "cancelled": "xmark.circle"
        default: "circle"
        }
    }

    private func todoColor(for status: String) -> Color {
        switch status {
        case "completed": isRetroChat ? RetroChatStyle.blueAccent : .green
        case "in_progress": isRetroChat ? RetroChatStyle.magentaAccent : .orange
        case "cancelled": secondaryTextColor
        default: secondaryTextColor.opacity(0.7)
        }
    }

    private var chatComposerInset: some View {
        VStack(spacing: 8) {
            if chatClient.currentSession != nil && chatClient.showsComposer {
                modelSelectionRow
            }
            inputBar
        }
        .padding(.horizontal, isComposerExpanded ? 0 : 16)
        .padding(.bottom, isComposerExpanded ? 12 : 0)
        .animation(.easeOut(duration: 0.4), value: isComposerExpanded)
    }

    // MARK: - Model Selector

    private var modelSelectionRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ViewThatFits {
                HStack {
                    modelSelectorButton

                    if chatClient.showsThinkingEffortPicker {
                        thinkingEffortMenu
                    }
                }

                VStack(alignment: .leading) {
                    modelSelectorButton

                    if chatClient.showsThinkingEffortPicker {
                        thinkingEffortMenu
                    }
                }
            }

            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                if !chatClient.todos.isEmpty {
                    todoChip
                }
                if let contextUsage = chatClient.contextUsageSummary {
                    Button {
                        showContextStatus = true
                    } label: {
                        ChatContextUsageRing(summary: contextUsage)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    private var modelSelectorButton: some View {
        Button {
            showModelPicker = true
        } label: {
            HStack(alignment: .center, spacing: 5) {
                Circle()
                    .fill(isRetroChat ? RetroChatStyle.magentaAccent : Color.appSecondary.opacity(0.3))
                    .frame(width: 6, height: 6)
                Text(chatClient.selectedModelDisplayName)
                    .font(isRetroChat ? RetroChatStyle.smallFont : .system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(secondaryTextColor)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(secondaryTextColor.opacity(0.75))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .chatModeChipChrome(visualMode)
        }
    }

    private var thinkingEffortMenu: some View {
        Menu {
            Button {
                chatClient.selectVariant(nil)
            } label: {
                if chatClient.selectedVariant == nil {
                    Label(AppText.thinkingDefault, systemImage: "checkmark")
                } else {
                    Text(AppText.thinkingDefault)
                }
            }

            ForEach(chatClient.availableReasoningVariants) { variant in
                Button {
                    chatClient.selectVariant(variant.id)
                } label: {
                    if chatClient.selectedVariant == variant.id {
                        Label(variant.displayName, systemImage: "checkmark")
                    } else {
                        Text(variant.displayName)
                    }
                }
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: "brain")
                    .font(.system(size: 11, weight: .medium))
                Text(chatClient.selectedVariantDisplayName)
                    .font(isRetroChat ? RetroChatStyle.smallFont : .system(size: 12, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(secondaryTextColor.opacity(0.75))
            }
            .foregroundStyle(secondaryTextColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .chatModeChipChrome(visualMode, usesGlassInStandardMode: false)
        }
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsCommandPicker {
                slashCommandPicker
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            HStack(alignment: .center, spacing: 8) {
                HStack(alignment: .center, spacing: 8) {
                    if let selectedSlashAction {
                        selectedSlashActionChip(selectedSlashAction)
                    }

                    TextField(composerPlaceholder, text: $chatClient.inputText, axis: .vertical)
                        .focused($isInputFocused)
                        .onTapGesture {
                            setComposerExpanded(true)
                        }
                        .lineLimit(1 ... 5)
                        .font(isRetroChat ? RetroChatStyle.bodyFont : .system(size: 16))
                        .foregroundStyle(primaryTextColor)
                        .disabled(chatClient.currentSession == nil)
                        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)

                    composerActionButton
                        .padding(4)
                }
                .padding(.leading, 16)
                .padding(.trailing, 4)
                .padding(.vertical, 4)
                .chatComposerFieldChrome(visualMode)
            }
        }
        .padding(.horizontal, 16)
    }

    private var composerActionButton: some View {
        Button {
            performComposerAction()
        } label: {
            composerActionButtonLabel
                .animation(.spring(duration: 0.25), value: chatClient.isLoading)
        }
        .disabled(isComposerActionDisabled)
        .accessibilityLabel(composerActionAccessibilityLabel)
    }

    private var composerPlaceholder: String {
        selectedSlashAction == nil ? AppText.messagePlaceholder : "Add arguments..."
    }

    private var selectedSlashActionTint: Color {
        isRetroChat ? RetroChatStyle.magentaAccent : .purple
    }

    private func selectedSlashActionChip(_ action: WorkspaceSlashActionItem) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol(for: action))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(selectedSlashActionTint)

            Text(action.prompt)
                .font(isRetroChat ? RetroChatStyle.smallFont : .system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(selectedSlashActionTint)
                .lineLimit(1)
                .minimumScaleFactor(0.82)

            Button {
                removeSelectedSlashAction()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(selectedSlashActionTint.opacity(0.75))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove slash command")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            selectedSlashActionTint.opacity(isRetroChat ? 0.18 : 0.12),
            in: Capsule()
        )
        .overlay {
            Capsule()
                .stroke(selectedSlashActionTint.opacity(isRetroChat ? 0.75 : 0.32), lineWidth: isRetroChat ? 1.5 : 1)
        }
        .frame(maxWidth: 180, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var composerActionButtonLabel: some View {
        if chatClient.isLoading {
            ZStack {
                Circle()
                    .fill(isRetroChat ? RetroChatStyle.danger : Color.red)

                if chatClient.isStoppingResponse {
                    ProgressView()
                        .controlSize(.small)
                        .tint(isRetroChat ? RetroChatStyle.paper : .white)
                } else {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isRetroChat ? RetroChatStyle.paper : .white)
                }
            }
            .frame(width: 32, height: 32)
            .contentShape(Circle())
            .transition(.scale(scale: 0.7).combined(with: .opacity))
        } else {
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: isRetroChat ? 28 : 30, weight: isRetroChat ? .bold : .regular))
                .symbolRenderingMode(.palette)
                .foregroundStyle(
                    isRetroChat ? RetroChatStyle.paper : Color.appOnAccent,
                    isRetroChat ? RetroChatStyle.ink : Color.appAccent
                )
                .frame(width: 32, height: 32)
                .contentShape(Circle())
                .transition(.scale(scale: 0.7).combined(with: .opacity))
        }
    }

    private var isComposerActionDisabled: Bool {
        chatClient.isLoading ? chatClient.isStoppingResponse : !canSend
    }

    private var composerActionAccessibilityLabel: String {
        if chatClient.isStoppingResponse {
            return AppText.responseStopping
        }

        return chatClient.isLoading ? "Stop" : "Send"
    }

    private func performComposerAction() {
        collapseComposerFocus()

        if chatClient.isLoading {
            chatClient.abort()
        } else {
            sendComposerInput()
        }
    }

    private func sendComposerInput() {
        guard let selectedSlashAction else {
            chatClient.send()
            return
        }

        let composedText = composedSlashActionText(for: selectedSlashAction)
        guard !composedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        chatClient.inputText = composedText
        self.selectedSlashAction = nil
        chatClient.send()
    }

    private func composedSlashActionText(for action: WorkspaceSlashActionItem) -> String {
        let prompt = action.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let arguments = chatClient.inputText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !arguments.isEmpty else { return prompt }
        guard !prompt.isEmpty else { return arguments }
        return "\(prompt) \(arguments)"
    }

    private func removeSelectedSlashAction() {
        clearSelectedSlashAction()
        isInputFocused = true
    }

    private func clearSelectedSlashAction() {
        selectedSlashAction = nil
    }

    private func collapseComposerFocus() {
        withAnimation(.easeOut(duration: 0.4)) {
            isComposerExpanded = false
            isInputFocused = false
        }
    }

    private func setComposerExpanded(_ isExpanded: Bool) {
        withAnimation(.easeOut(duration: 0.4)) {
            isComposerExpanded = isExpanded
        }
    }

    private func responseStatusLabel(for state: ChatResponseState) -> String? {
        switch state {
        case .idle:
            nil
        case .generating:
            AppText.responseGenerating
        case .stopping:
            AppText.responseStopping
        case .stopped:
            AppText.responseStopped
        case .failed:
            AppText.responseFailed
        }
    }

    private func responseStatusIcon(for state: ChatResponseState) -> String {
        switch state {
        case .idle:
            "circle"
        case .generating:
            "sparkles"
        case .stopping:
            "stopwatch"
        case .stopped:
            "stop.circle"
        case .failed:
            "exclamationmark.triangle"
        }
    }

    private func responseStatusColor(for state: ChatResponseState) -> Color {
        switch state {
        case .idle:
            secondaryTextColor
        case .generating:
            isRetroChat ? RetroChatStyle.blueAccent : Color.appAccent
        case .stopping:
            isRetroChat ? RetroChatStyle.danger : Color.orange
        case .stopped:
            secondaryTextColor
        case .failed:
            isRetroChat ? RetroChatStyle.danger : Color.red
        }
    }

    private var slashCommandPicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isLoadingCommands {
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(isRetroChat ? RetroChatStyle.ink : Color.appAccent)

                    Text("Loading slash commands...")
                        .font(isRetroChat ? RetroChatStyle.bodyFont : .system(size: 14))
                        .foregroundStyle(secondaryTextColor)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            } else if availableSlashActions.isEmpty {
                Text("No slash actions available for this server.")
                    .font(isRetroChat ? RetroChatStyle.bodyFont : .system(size: 14))
                    .foregroundStyle(secondaryTextColor)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
            } else if filteredSlashActions.isEmpty {
                Text("No matching slash commands.")
                    .font(isRetroChat ? RetroChatStyle.bodyFont : .system(size: 14))
                    .foregroundStyle(secondaryTextColor)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(filteredSlashActions.enumerated()), id: \.element.id) { index, action in
                            Button {
                                applySlashAction(action)
                            } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    Image(systemName: symbol(for: action))
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(primaryTextColor)
                                        .frame(width: 22)
                                        .padding(.top, 2)

                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(spacing: 8) {
                                            Text(commandDisplayTitle(action.title))
                                                .font(isRetroChat ? RetroChatStyle.bodyFont : .system(size: 17, weight: .semibold, design: .rounded))
                                                .foregroundStyle(primaryTextColor)

                                            Text(action.kind == .command ? "Command" : "Agent")
                                                .font(isRetroChat ? RetroChatStyle.smallFont : .system(size: 11, weight: .semibold, design: .rounded))
                                                .foregroundStyle(secondaryTextColor)
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 3)
                                                .chatModeChipChrome(visualMode, usesGlassInStandardMode: false)
                                        }
                                        if !action.description.isEmpty {
                                            Text(action.description)
                                                .font(isRetroChat ? RetroChatStyle.smallFont : .system(size: 14))
                                                .foregroundStyle(secondaryTextColor)
                                                .lineLimit(2)
                                        }
                                    }

                                    Spacer(minLength: 12)

                                    Text(action.prompt)
                                        .font(.system(size: 15, weight: .medium, design: .monospaced))
                                        .foregroundStyle(secondaryTextColor.opacity(0.8))
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 14)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            if index < filteredSlashActions.count - 1 {
                                Divider()
                                    .overlay(isRetroChat ? RetroChatStyle.ink.opacity(0.6) : Color.clear)
                                    .padding(.leading, 50)
                            }
                        }
                    }
                }
                .frame(maxHeight: 252)
            }
        }
        .chatPopoverChrome(visualMode)
    }

    private var canSend: Bool {
        !composerSendText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !chatClient.isLoading &&
            chatClient.currentSession != nil &&
            chatClient.pendingQuestion == nil &&
            chatClient.canCompose
    }

    private var composerSendText: String {
        guard let selectedSlashAction else {
            return chatClient.inputText
        }

        return composedSlashActionText(for: selectedSlashAction)
    }

    private var slashQuery: String? {
        guard selectedSlashAction == nil else { return nil }
        let text = chatClient.inputText
        guard text.hasPrefix("/") else { return nil }

        let raw = String(text.dropFirst())
        if raw.contains(where: { $0.isWhitespace || $0.isNewline }) {
            return nil
        }

        return raw
    }

    private var filteredSlashActions: [WorkspaceSlashActionItem] {
        guard let slashQuery else { return [] }
        let query = slashQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return availableSlashActions }

        return availableSlashActions.filter { action in
            action.token.localizedCaseInsensitiveContains(query) ||
                action.title.localizedCaseInsensitiveContains(query) ||
                action.description.localizedCaseInsensitiveContains(query)
        }
    }

    private var showsCommandPicker: Bool {
        selectedSlashAction == nil && slashQuery != nil && chatClient.currentSession != nil
    }

    @MainActor
    private func loadCommands(force: Bool = false) async {
        guard force || availableSlashActions.isEmpty else { return }
        guard !isLoadingCommands else { return }

        isLoadingCommands = true
        let slashActions = await workspaceService.loadSlashActions()
        availableSlashActions = slashActions
        chatClient.updateSlashCatalog(
            commands: slashActions.filter { $0.kind == .command }.map(\.token),
            agents: slashActions.filter { $0.kind == .agent }.map(\.token)
        )
        isLoadingCommands = false
    }

    private func applySlashAction(_ action: WorkspaceSlashActionItem) {
        selectedSlashAction = action
        chatClient.inputText = ""
        isInputFocused = true
    }

    private func handleComposerTextChange(_ newValue: String) {
        if shouldClearSelectedSlashAction(forComposerText: newValue) {
            clearSelectedSlashAction()
        }

        guard selectedSlashAction == nil,
              newValue.hasPrefix("/"),
              !newValue.dropFirst().contains(where: { $0.isWhitespace || $0.isNewline }),
              availableSlashActions.isEmpty,
              !isLoadingCommands
        else {
            return
        }

        Task {
            await loadCommands(force: true)
        }
    }

    private func shouldClearSelectedSlashAction(forComposerText newValue: String) -> Bool {
        selectedSlashAction != nil &&
            !isInputFocused &&
            !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func commandDisplayTitle(_ title: String) -> String {
        title.replacingOccurrences(of: "/", with: "").replacingOccurrences(of: "-", with: " ").capitalized
    }

    private func symbol(for action: WorkspaceSlashActionItem) -> String {
        if action.kind == .agent {
            return "person.crop.circle.badge.sparkles"
        }

        switch action.token.lowercased() {
        case let id where id.contains("review"):
            return "ladybug"
        case let id where id.contains("status"):
            return "gauge.with.dots.needle.50percent"
        case let id where id.contains("share"):
            return "square.and.arrow.up"
        case let id where id.contains("model"):
            return "sparkles.rectangle.stack"
        default:
            return "command"
        }
    }

}

struct PermissionRequestSheet: View {
    static let defaultPresentationDetent: PresentationDetent = .height(390)

    let permission: OCPermissionRequest
    @Binding var selectedDetent: PresentationDetent
    private let initiallyConfirmsAllowAll: Bool
    let onRespond: (OCPermissionReply) async -> Bool

    @State private var pendingReply: OCPermissionReply?
    @State private var confirmsAllowAll: Bool

    init(
        permission: OCPermissionRequest,
        selectedDetent: Binding<PresentationDetent>,
        initiallyConfirmsAllowAll: Bool = false,
        onRespond: @escaping (OCPermissionReply) async -> Bool
    ) {
        let safePermission = Self.safeDisplayPermission(permission)
        let canOfferAllowAll = !safePermission.displayScopeWasTruncated

        self.permission = safePermission
        self._selectedDetent = selectedDetent
        self.initiallyConfirmsAllowAll = initiallyConfirmsAllowAll && canOfferAllowAll
        self.onRespond = onRespond
        self._confirmsAllowAll = State(initialValue: initiallyConfirmsAllowAll && canOfferAllowAll)
    }

    static func presentationDetents(for permission: OCPermissionRequest) -> Set<PresentationDetent> {
        let safePermission = safeDisplayPermission(permission)
        var detents: Set<PresentationDetent> = [
            defaultPresentationDetent,
            .medium
        ]

        if !safePermission.displayScopeWasTruncated {
            detents.insert(.height(allowAllPresentationHeight(for: safePermission)))
        }

        return detents
    }

    static func offersAlwaysApproval(for permission: OCPermissionRequest) -> Bool {
        !safeDisplayPermission(permission).displayScopeWasTruncated
    }

    private static func safeDisplayPermission(_ permission: OCPermissionRequest) -> OCPermissionRequest {
        PermissionRequestDisplaySafety.sanitize(permission)
            ?? OCPermissionRequest(
                id: "invalid-permission",
                displayScopeWasTruncated: true
            )
    }

    private static func allowAllPresentationHeight(for permission: OCPermissionRequest) -> CGFloat {
        let visiblePatternCount = min(allowAllPatterns(for: permission).count, 4)
        let usesWildcardScope = allowAllPatterns(for: permission).contains("*")
        let patternListHeight: CGFloat = visiblePatternCount == 0
            ? 0
            : CGFloat(visiblePatternCount) * 41 + 24

        let baseHeight: CGFloat = usesWildcardScope ? 492 : 360
        return min(max(baseHeight + patternListHeight, usesWildcardScope ? 540 : 430), 620)
    }

    private static func allowAllDetent(for permission: OCPermissionRequest) -> PresentationDetent {
        .height(allowAllPresentationHeight(for: permission))
    }

    private static func allowAllPatterns(for permission: OCPermissionRequest) -> [String] {
        let candidates = [
            permission.save,
            permission.always,
            permission.resources,
            permission.patterns
        ]

        return candidates
            .first(where: { !$0.cleanedForDisplay.isEmpty })?
            .cleanedForDisplay ?? []
    }

    private var isResponding: Bool {
        pendingReply != nil
    }

    private var title: String {
        permission.title?.nilIfBlank ?? AppText.permissionRequired
    }

    private var detail: String {
        permission.description?.nilIfBlank ?? AppText.permissionFallback
    }

    private var toolName: String? {
        guard let tool = permission.toolDisplayName?.nilIfBlank, tool != title else { return nil }
        return tool
    }

    private var resourceSummary: String? {
        compactList(permission.resources, fallback: permission.patterns)
    }

    private var allowAllPatterns: [String] {
        Self.allowAllPatterns(for: permission)
    }

    private var hasWildcardAllowAllScope: Bool {
        allowAllPatterns.contains("*")
    }

    private var canOfferAllowAll: Bool {
        !permission.displayScopeWasTruncated
    }

    private var rawAllowAllPermissionKind: String? {
        toolName ?? permission.permission?.nilIfBlank ?? permission.action?.nilIfBlank
    }

    private var allowAllPermissionKind: String? {
        rawAllowAllPermissionKind.map { rawKind in
            let keepsOriginalCasing = rawKind.contains(" ") || rawKind.rangeOfCharacter(from: .uppercaseLetters) != nil
            return keepsOriginalCasing ? rawKind : rawKind.capitalized
        }
    }

    private var allowAllScopeTitle: String {
        if hasWildcardAllowAllScope {
            if let allowAllPermissionKind {
                return "Every future \(allowAllPermissionKind) permission prompt"
            }
            return "Every future permission prompt of this type"
        }

        if allowAllPatterns.isEmpty {
            return "Future matching permission requests"
        }

        return "Only requests matching these rules"
    }

    private var allowAllScopeDetail: String {
        if hasWildcardAllowAllScope {
            if let allowAllPermissionKind {
                return "OpenCode sent a wildcard rule. Future \(allowAllPermissionKind) permission prompts can be approved automatically until OpenCode is restarted."
            }
            return "OpenCode sent a wildcard rule. Future prompts of this type can be approved automatically until OpenCode is restarted."
        }

        return "OpenLens will auto-approve future permission prompts only when they match this scope, until OpenCode is restarted."
    }

    var body: some View {
        VStack(spacing: 0) {
            SurfaceCard(padding: 0, cornerRadius: 24) {
                VStack(alignment: .leading, spacing: 18) {
                    if confirmsAllowAll && canOfferAllowAll {
                        allowAllConfirmation
                    } else {
                        permissionRequest
                    }
                }
                .padding(20)
                .animation(.snappy(duration: 0.2), value: confirmsAllowAll)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.appBackground)
        .onAppear {
            if initiallyConfirmsAllowAll && canOfferAllowAll {
                selectedDetent = Self.allowAllDetent(for: permission)
            }
        }
    }

    private var permissionRequest: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            if detail != title {
                Text(detail)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.appSecondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }

            metadata
            actions
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            SurfaceIconTile(
                icon: "lock.shield",
                fill: Color.appWarning.opacity(0.14),
                foreground: Color.appWarning
            )

            VStack(alignment: .leading, spacing: 4) {
                Text("Permission")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.appWarning)
                    .textCase(.uppercase)

                Text(title)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.appPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var allowAllConfirmation: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                SurfaceIconTile(
                    icon: "checkmark.shield",
                    fill: Color.appWarning.opacity(0.14),
                    foreground: Color.appWarning
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text("Always Allow")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.appWarning)
                        .textCase(.uppercase)

                    Text(AppText.allowAll)
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.appPrimary)
                }
            }

            Text(allowAllExplanation)
                .font(.system(size: 14))
                .foregroundStyle(Color.appSecondary)
                .fixedSize(horizontal: false, vertical: true)

            allowAllScopeCard

            HStack(spacing: 10) {
                permissionControlButton(
                    title: AppText.cancel,
                    systemImage: "chevron.left",
                    fill: Color.appTertiary,
                    foreground: Color.appPrimary
                ) {
                    withAnimation(.snappy(duration: 0.2)) {
                        confirmsAllowAll = false
                        selectedDetent = Self.defaultPresentationDetent
                    }
                }

                permissionReplyButton(
                    title: AppText.allowAll,
                    systemImage: "checkmark.shield",
                    fill: Color.appWarning,
                    foreground: Color.appBackground,
                    reply: .always
                )
            }
        }
    }

    private var allowAllExplanation: String {
        if hasWildcardAllowAllScope {
            return "Use this only if you trust this agent to continue with this kind of action without asking again."
        }
        return "This keeps the current run moving without approving unrelated future actions."
    }

    private var allowAllScopeCard: some View {
        VStack(spacing: 0) {
            allowAllScopeRow(
                icon: hasWildcardAllowAllScope ? "exclamationmark.triangle" : "scope",
                title: allowAllScopeTitle,
                detail: allowAllScopeDetail,
                emphasis: hasWildcardAllowAllScope
            )

            if hasWildcardAllowAllScope {
                SurfaceDivider(leadingPadding: 28)
                allowAllScopeRow(
                    icon: "asterisk",
                    title: "Wildcard rule from OpenCode",
                    detail: "The raw rule is *, meaning all future prompts of this same type.",
                    emphasis: false
                )
            } else {
                ForEach(Array(allowAllPatterns.prefix(4).enumerated()), id: \.offset) { index, pattern in
                    SurfaceDivider(leadingPadding: 28)
                    allowAllScopeRow(
                        icon: "scope",
                        title: pattern,
                        detail: nil,
                        emphasis: false
                    )

                    if index == 3, allowAllPatterns.count > 4 {
                        SurfaceDivider(leadingPadding: 28)
                        allowAllScopeRow(
                            icon: "ellipsis",
                            title: "\(allowAllPatterns.count - 4) more matching rules",
                            detail: nil,
                            emphasis: false
                        )
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .background(Color.appTertiary.opacity(0.72), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func allowAllScopeRow(icon: String, title: String, detail: String?, emphasis: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(emphasis ? Color.appWarning : Color.appSecondary)
                .frame(width: 18)
                .padding(.top, detail == nil ? 0 : 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.appPrimary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.appSecondary)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var metadata: some View {
        let rows = metadataRows

        if !rows.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    HStack(spacing: 10) {
                        Image(systemName: row.icon)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.appSecondary)
                            .frame(width: 18)

                        Text(row.value)
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.appPrimary)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 10)

                    if index < rows.count - 1 {
                        SurfaceDivider(leadingPadding: 28)
                    }
                }
            }
            .padding(.horizontal, 12)
            .background(Color.appTertiary.opacity(0.72), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private var metadataRows: [(icon: String, value: String)] {
        var rows: [(icon: String, value: String)] = []

        if let toolName {
            rows.append((icon: "wrench.and.screwdriver", value: toolName))
        }

        if let resourceSummary, resourceSummary != detail {
            rows.append((icon: "scope", value: resourceSummary))
        }

        return rows
    }

    private var actions: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                permissionReplyButton(
                    title: AppText.deny,
                    systemImage: "xmark",
                    fill: Color.appTertiary,
                    foreground: Color.appPrimary,
                    reply: .reject
                )

                permissionReplyButton(
                    title: AppText.allowOnce,
                    systemImage: "checkmark",
                    fill: Color.appAccent,
                    foreground: Color.appOnAccent,
                    reply: .once
                )
            }

            if canOfferAllowAll {
                permissionControlButton(
                    title: AppText.allowAll,
                    systemImage: "checkmark.shield",
                    fill: Color.appWarning.opacity(0.14),
                    foreground: Color.appWarning
                ) {
                    withAnimation(.snappy(duration: 0.2)) {
                        confirmsAllowAll = true
                        selectedDetent = Self.allowAllDetent(for: permission)
                    }
                }
            }
        }
        .padding(.top, 2)
    }

    private func permissionReplyButton(
        title: String,
        systemImage: String,
        fill: Color,
        foreground: Color,
        reply: OCPermissionReply
    ) -> some View {
        permissionControlButton(
            title: title,
            systemImage: systemImage,
            fill: fill,
            foreground: foreground,
            isLoading: pendingReply == reply
        ) {
            Task {
                pendingReply = reply
                let didMovePastCurrentRequest = await onRespond(reply)
                if !didMovePastCurrentRequest {
                    pendingReply = nil
                }
            }
        }
    }

    private func permissionControlButton(
        title: String,
        systemImage: String,
        fill: Color,
        foreground: Color,
        isLoading: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
        } label: {
            HStack(spacing: 7) {
                if isLoading {
                    ProgressView()
                        .tint(foreground)
                        .controlSize(.small)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .bold))
                }

                Text(title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(fill, in: Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isResponding)
    }

    private func compactList(_ values: [String], fallback: [String]) -> String? {
        let visibleValues = (values.isEmpty ? fallback : values)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !visibleValues.isEmpty else { return nil }

        let visiblePrefix = visibleValues.prefix(3).joined(separator: ", ")
        let hiddenCount = visibleValues.count - 3

        guard hiddenCount > 0 else { return visiblePrefix }
        return "\(visiblePrefix) +\(hiddenCount)"
    }
}

private extension Array where Element == String {
    var cleanedForDisplay: [String] {
        map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

private struct ResponseStatusSiriIndicator: View {
    let state: ChatResponseState
    let label: String
    let icon: String
    let color: Color
    let isRetroChat: Bool

    private var isAnimatedState: Bool {
        state == .generating || state == .stopping
    }

    private var showsTextLabel: Bool {
        state == .stopped || state == .failed
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            ZStack {
                capsuleBackground

                if isAnimatedState {
                    animatedBars(time: timeline.date.timeIntervalSinceReferenceDate)
                } else if showsTextLabel {
                    Text(label)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(color)
                        .contentTransition(.opacity)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(color)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(width: showsTextLabel ? 74 : 62, height: 34)
            .clipShape(Capsule(style: .continuous))
            .shadow(color: .black.opacity(isRetroChat ? 0 : 0.1), radius: 12, y: 5)
            .animation(.easeInOut(duration: 0.18), value: state)
        }
    }

    @ViewBuilder
    private var capsuleBackground: some View {
        let palette = indicatorPalette

        ZStack {
            Capsule(style: .continuous)
                .fill(isRetroChat ? RetroChatStyle.paperWarm : Color.appSurface.opacity(0.82))

            if !isRetroChat {
                LinearGradient(
                    colors: palette.map { $0.opacity(0.2) },
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .blur(radius: 6)
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
            }

            Capsule(style: .continuous)
                .strokeBorder(
                    isRetroChat ? RetroChatStyle.ink : Color.white.opacity(0.46),
                    lineWidth: isRetroChat ? 2 : 0.7
                )
        }
    }

    private func animatedBars(time: TimeInterval) -> some View {
        HStack(spacing: 4) {
            ForEach(0 ..< 5, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(barGradient(index: index))
                    .frame(width: 4, height: barHeight(index: index, time: time))
                    .shadow(color: indicatorPalette[index % indicatorPalette.count].opacity(isRetroChat ? 0 : 0.45), radius: 3)
            }
        }
        .frame(height: 24, alignment: .center)
    }

    private func barHeight(index: Int, time: TimeInterval) -> CGFloat {
        let speed = state == .stopping ? 6.2 : 4.7
        let phase = Double(index) * 0.74
        let wave = (sin(time * speed + phase) + 1) / 2
        let accent = (sin(time * (speed * 0.58) - phase) + 1) / 2
        return CGFloat(7 + (wave * 10) + (accent * 4))
    }

    private func barGradient(index: Int) -> LinearGradient {
        let palette = indicatorPalette
        return LinearGradient(
            colors: [
                palette[index % palette.count],
                palette[(index + 1) % palette.count]
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var indicatorPalette: [Color] {
        if isRetroChat {
            return [
                RetroChatStyle.blueAccent,
                RetroChatStyle.magentaAccent,
                RetroChatStyle.danger,
                RetroChatStyle.blueAccent
            ]
        }

        switch state {
        case .stopping:
            return [
                Color(red: 1.0, green: 0.54, blue: 0.16),
                Color(red: 1.0, green: 0.24, blue: 0.36),
                Color(red: 0.94, green: 0.24, blue: 0.78),
                Color(red: 1.0, green: 0.72, blue: 0.2)
            ]
        case .failed:
            return [.red, .orange]
        case .stopped:
            return [Color.appSecondary, Color.appPrimary]
        case .idle, .generating:
            return [
                Color(red: 0.16, green: 0.73, blue: 1.0),
                Color(red: 0.42, green: 0.38, blue: 1.0),
                Color(red: 0.96, green: 0.24, blue: 0.78),
                Color(red: 0.2, green: 0.86, blue: 0.56)
            ]
        }
    }
}

private struct ChatContextUsageRing: View {
    let summary: ChatClient.ContextUsageSummary

    @Environment(\.chatEasterEgg) private var chatEasterEgg

    private var tintColor: Color {
        if chatEasterEgg.visualMode.isRetro {
            return RetroChatStyle.magentaAccent
        }

        guard let usagePercent = summary.usagePercent else { return Color.appSecondary }

        switch usagePercent {
        case ..<70:
            return Color.appSecondary
        case ..<85:
            return .orange
        default:
            return .red
        }
    }

    private var progressValue: Double {
        guard let usagePercent = summary.usagePercent else { return 0 }
        return min(max(Double(usagePercent) / 100, 0), 1)
    }

    var body: some View {
        ZStack {
            if chatEasterEgg.visualMode.isRetro {
                Circle()
                    .fill(RetroChatStyle.paperWarm)
                    .shadow(color: RetroChatStyle.shadow.opacity(0.75), radius: 0, x: 2, y: 2)
            }

            Circle()
                .stroke(chatEasterEgg.visualMode.isRetro ? RetroChatStyle.ink.opacity(0.5) : Color.appSeparator.opacity(0.7), lineWidth: 3)

            Circle()
                .trim(from: 0, to: progressValue)
                .stroke(tintColor, style: StrokeStyle(lineWidth: 4, lineCap: chatEasterEgg.visualMode.isRetro ? .butt : .round))
                .rotationEffect(.degrees(-90))

            Text("%")
                .font(chatEasterEgg.visualMode.isRetro ? RetroChatStyle.smallFont : .system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(chatEasterEgg.visualMode.isRetro ? RetroChatStyle.ink : Color.appPrimary)
        }
        .frame(width: 20, height: 20)
        .overlay {
            if chatEasterEgg.visualMode.isRetro {
                Circle()
                    .stroke(RetroChatStyle.ink, lineWidth: 1.5)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(AppText.showContextStatus)
    }

    private var accessibilityLabel: String {
        if let usagePercent = summary.usagePercent,
           let limitTokens = summary.limitTokens,
           limitTokens > 0
        {
            return AppText.contextUsageLabel(usagePercent, usedTokens: summary.usedTokens, limitTokens: limitTokens)
        }

        return AppText.contextUsageLabel(summary.usedTokens)
    }

    private func format(_ value: Int) -> String {
        ChatView.integerFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

private struct ChatContextStatusSheet: View {
    let summary: ChatClient.ContextUsageSummary
    let visualMode: ChatVisualMode

    private var usedRatio: Double {
        guard let usagePercent = summary.usagePercent else { return 0 }
        return min(max(Double(usagePercent) / 100, 0), 1)
    }

    var body: some View {
        ZStack {
            sheetBackground
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Text("Status")
                    .font(isRetroChat ? RetroChatStyle.headerFont : .system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(primaryTextColor)
                    .padding(.vertical, 16)

                contextDetails

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .presentationBackground(isRetroChat ? RetroChatStyle.screenBottom : Color.appBackground)
    }

    private var isRetroChat: Bool {
        visualMode.isRetro
    }

    private var primaryTextColor: Color {
        isRetroChat ? RetroChatStyle.ink : Color.appPrimary
    }

    private var secondaryTextColor: Color {
        isRetroChat ? RetroChatStyle.secondaryInk : Color.appSecondary
    }

    private var contextProgressTint: Color {
        guard isRetroChat else { return Color.appPrimary.opacity(0.72) }
        guard let usagePercent = summary.usagePercent else { return RetroChatStyle.blueAccent }

        switch usagePercent {
        case ..<70:
            return RetroChatStyle.blueAccent
        case ..<85:
            return RetroChatStyle.magentaAccent
        default:
            return RetroChatStyle.danger
        }
    }

    @ViewBuilder
    private var sheetBackground: some View {
        if isRetroChat {
            RetroChatScreenBackground()
        } else {
            Color.appBackground
        }
    }

    @ViewBuilder
    private var contextDetails: some View {
        if isRetroChat {
            contextDetailsContent
                .padding(14)
                .modifier(RetroChatPanelChrome(fill: RetroChatStyle.paper, cornerRadius: 7, shadowOffset: 3))
        } else {
            contextDetailsContent
        }
    }

    private var contextDetailsContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            contextUsageHeader

            contextProgressBar

            if let modelLabel = summary.modelLabel {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles.rectangle.stack")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(secondaryTextColor)
                    Text(modelLabel)
                        .font(isRetroChat ? RetroChatStyle.smallFont : .system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(secondaryTextColor)
                        .lineLimit(2)
                }
            }
        }
    }

    @ViewBuilder
    private var contextUsageHeader: some View {
        if isRetroChat {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("Context")
                        .font(RetroChatStyle.smallFont)
                        .foregroundStyle(secondaryTextColor)

                    Text(usageText)
                        .font(RetroChatStyle.bodyFont)
                        .foregroundStyle(primaryTextColor)

                    Spacer(minLength: 8)
                }

                Text(tokenDetailText)
                    .font(RetroChatStyle.smallFont)
                    .foregroundStyle(secondaryTextColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Context")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(secondaryTextColor)

                Text(usageText)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(primaryTextColor)

                Spacer(minLength: 8)

                Text(tokenDetailText)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(secondaryTextColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
    }

    private var usageText: String {
        if let usagePercent = summary.usagePercent {
            return "\(usagePercent)% used"
        }
        return "\(format(summary.usedTokens)) used"
    }

    private var tokenDetailText: String {
        if let limitTokens = summary.limitTokens {
            return "(\(compactFormat(summary.usedTokens)) used / \(compactFormat(limitTokens)))"
        }
        return "(\(compactFormat(summary.usedTokens)) used)"
    }

    private var contextProgressBar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: isRetroChat ? 2 : 4, style: .continuous)
                    .fill(isRetroChat ? RetroChatStyle.paperWarm : Color.appSeparator.opacity(0.65))
                    .frame(height: isRetroChat ? 10 : 8)
                    .overlay {
                        if isRetroChat {
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .stroke(RetroChatStyle.ink, lineWidth: 1.5)
                        }
                    }

                if usedRatio > 0 {
                    RoundedRectangle(cornerRadius: isRetroChat ? 1 : 4, style: .continuous)
                        .fill(contextProgressTint)
                        .frame(
                            width: max(isRetroChat ? 8 : 12, proxy.size.width * usedRatio),
                            height: isRetroChat ? 10 : 8
                        )
                }
            }
        }
        .frame(height: isRetroChat ? 10 : 8)
    }

    private func format(_ value: Int) -> String {
        ChatView.integerFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private func compactFormat(_ value: Int) -> String {
        let number = Double(value)
        if number >= 1_000_000 {
            return String(format: "%.1fM", number / 1_000_000)
        }
        if number >= 1_000 {
            return String(format: "%.1fK", number / 1_000)
        }
        return format(value)
    }
}

private struct ChatMessagesListView: View {
    @Bindable var chatClient: ChatClient

    @Environment(\.chatEasterEgg) private var chatEasterEgg
    @AppStorage("showThinking") private var showThinking: Bool = true

    @State private var lastAutoScrollDate: Date = .distantPast
    @State private var lastHandledContentVersion: UInt?
    @State private var followLatest = true
    @State private var scrollInteraction = ChatScrollInteraction.idle
    @State private var scrollState = ChatScrollState.initial
    @State private var pendingForcedScroll = false
    @State private var paginationRestoreAnchorID: String?
    @State private var timelineItems: [ChatTimelineItem] = []

    private let bottomAnchorID = "bottom"
    private let streamingScrollInterval: TimeInterval = 0.18
    private let settledBottomTolerance: CGFloat = 8
    private let scrollToBottomVisibilityThreshold: CGFloat = 56

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    Color.clear.frame(height: isRetroChat ? 150 : 72)

                    LazyVStack(alignment: .leading, spacing: isRetroChat ? 13 : 16) {
                        if chatClient.hasEarlierMessages {
                            Button {
                                loadEarlierMessages(using: proxy)
                            } label: {
                                Text("Load earlier messages")
                                    .font(isRetroChat ? RetroChatStyle.smallFont : .system(size: 14, weight: .medium))
                                    .foregroundStyle(isRetroChat ? RetroChatStyle.secondaryInk : .secondary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                    .ifRetroPanel(isRetroChat)
                            }
                        }

                        ForEach(timelineItems) { item in
                            timelineRow(item)
                        }
                    }
                    .padding(.horizontal, isRetroChat ? 12 : 16)

                    Color.clear
                        .frame(height: 17)
                        .id(bottomAnchorID)
                        .padding(.horizontal, 16)

                    ChatStreamingAutoFollowObserver(
                        chatClient: chatClient,
                        proxy: proxy,
                        bottomAnchorID: bottomAnchorID,
                        minimumInterval: streamingScrollInterval,
                        settledBottomTolerance: settledBottomTolerance,
                        followLatest: $followLatest,
                        scrollInteraction: $scrollInteraction,
                        scrollState: $scrollState,
                        lastHandledContentVersion: $lastHandledContentVersion,
                        lastAutoScrollDate: $lastAutoScrollDate
                    )
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
                }
                .onScrollGeometryChange(for: ChatScrollState.self) { geometry in
                    ChatScrollPolicy.state(
                        contentHeight: geometry.contentSize.height,
                        containerHeight: geometry.containerSize.height,
                        contentOffsetY: geometry.contentOffset.y,
                        topInset: geometry.contentInsets.top,
                        bottomInset: geometry.contentInsets.bottom,
                        settledBottomTolerance: settledBottomTolerance,
                        visibilityThreshold: scrollToBottomVisibilityThreshold
                    )
                } action: { _, state in
                    scrollState = state
                }
                .onScrollPhaseChange { _, newPhase, context in
                    let state = ChatScrollPolicy.state(
                        contentHeight: context.geometry.contentSize.height,
                        containerHeight: context.geometry.containerSize.height,
                        contentOffsetY: context.geometry.contentOffset.y,
                        topInset: context.geometry.contentInsets.top,
                        bottomInset: context.geometry.contentInsets.bottom,
                        settledBottomTolerance: settledBottomTolerance,
                        visibilityThreshold: scrollToBottomVisibilityThreshold
                    )
                    scrollState = state
                    handleScrollPhaseChange(
                        newPhase,
                        state: state,
                        using: proxy
                    )
                }
                .onChange(of: chatClient.scrollAnchor) {
                    requestForcedScrollToBottom(using: proxy)
                }
                .scrollDismissesKeyboard(.interactively)
                .onTapGesture {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }

                if showsScrollToBottomButton {
                    Button {
                        guard scrollInteraction.allowsProgrammaticScroll else { return }
                        pendingForcedScroll = false
                        paginationRestoreAnchorID = nil
                        scrollToBottom(
                            using: proxy,
                            animated: ChatScrollPolicy.shouldAnimateManualScroll(isLoading: chatClient.isLoading),
                            now: Date(),
                            forceFollowLatest: true
                        )
                    } label: {
                        scrollToBottomLabel
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 20)
                    .padding(.bottom, 16)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    .accessibilityLabel("Scroll to latest message")
                }
            }
            .animation(.easeOut(duration: 0.18), value: showsScrollToBottomButton)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear(perform: rebuildTimeline)
        .onChange(of: chatClient.timelineVersion) { _, _ in
            rebuildTimeline()
        }
        .onChange(of: showThinking) { _, _ in
            rebuildTimeline()
        }
    }

    private var isRetroChat: Bool {
        chatEasterEgg.visualMode.isRetro
    }

    private func rebuildTimeline() {
        timelineItems = ChatTimeline.items(
            from: chatClient.displayedMessages,
            showsThinking: showThinking
        )
#if DEBUG
        print(
            "CHAT_STRESS_TIMELINE_REBUILD displayed=\(chatClient.displayedMessages.count) "
                + "items=\(timelineItems.count) version=\(chatClient.timelineVersion)"
        )
#endif
    }

    @ViewBuilder
    private func timelineRow(_ item: ChatTimelineItem) -> some View {
        switch item.content {
        case .message(let message):
            MessageBubbleView(message: message)
        case .assistantSegment(let message, let segment):
            AssistantSegmentTimelineRow(
                message: message,
                segmentID: segment.id,
                animatesSubagentStatus: item.animatesSubagentStatus
            )
        case .streamingAssistantText(let message, let projection):
            MessageBubbleView(
                message: message,
                assistantSegments: [],
                streamingText: projection
            )
        }
    }

    @ViewBuilder
    private var scrollToBottomLabel: some View {
        if isRetroChat {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(RetroChatStyle.paperWarm)
                RetroChatDoubleBorder(cornerRadius: 6)
                Image(systemName: "arrow.down")
                    .font(.system(size: 18, weight: .black, design: .monospaced))
                    .foregroundStyle(RetroChatStyle.ink)
            }
            .frame(width: 42, height: 42)
        } else {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 34))
                .symbolRenderingMode(.palette)
                .foregroundStyle(Color.appOnAccent, Color.appAccent)
        }
    }

    private func scrollToBottom(
        using proxy: ScrollViewProxy,
        animated: Bool,
        now: Date,
        forceFollowLatest: Bool = false
    ) {
        if forceFollowLatest {
            followLatest = true
        }

        lastAutoScrollDate = now
        ChatStreamInstrumentation.recordScrollToBottom()

        if animated {
            withAnimation(.smooth(duration: streamingScrollInterval, extraBounce: 0)) {
                proxy.scrollTo(bottomAnchorID, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(bottomAnchorID, anchor: .bottom)
        }
    }

    private func requestForcedScrollToBottom(using proxy: ScrollViewProxy) {
        guard followLatest else {
            pendingForcedScroll = false
            return
        }

        guard ChatScrollPolicy.shouldPerformProgrammaticScroll(
            interaction: scrollInteraction
        ) else {
            pendingForcedScroll = true
            return
        }

        pendingForcedScroll = false
        paginationRestoreAnchorID = nil
        scrollToBottom(
            using: proxy,
            animated: false,
            now: Date(),
            forceFollowLatest: true
        )
    }

    private func handleScrollPhaseChange(
        _ phase: ScrollPhase,
        state: ChatScrollState,
        using proxy: ScrollViewProxy
    ) {
        let interaction = ChatScrollPolicy.interaction(for: phase)
        scrollInteraction = interaction
        followLatest = ChatScrollPolicy.updatedFollowLatest(
            currentValue: followLatest,
            interaction: interaction,
            isAtBottom: state.isAtBottom
        )

        if interaction.isUserControlled {
            // User intent wins immediately, before the drag has moved far
            // enough for geometry thresholds to change.
            return
        }

        guard interaction == .idle else { return }

        if pendingForcedScroll {
            requestForcedScrollToBottom(using: proxy)
            return
        }

        if let anchorID = paginationRestoreAnchorID {
            restorePositionAfterLoadingEarlierMessages(
                anchorID: anchorID,
                using: proxy
            )
        }
    }

    private func loadEarlierMessages(using proxy: ScrollViewProxy) {
        guard ChatScrollPolicy.shouldLoadEarlierMessages(
            hasEarlierMessages: chatClient.hasEarlierMessages,
            interaction: scrollInteraction,
            hasPendingRestoration: paginationRestoreAnchorID != nil
        ), let anchorID = timelineItems.first?.id else { return }

        paginationRestoreAnchorID = anchorID
        chatClient.loadEarlierMessages()
        restorePositionAfterLoadingEarlierMessages(
            anchorID: anchorID,
            using: proxy
        )
    }

    private func restorePositionAfterLoadingEarlierMessages(
        anchorID: String,
        using proxy: ScrollViewProxy
    ) {
        Task { @MainActor in
            // Give the rebuilt LazyVStack one layout pass before restoring the
            // first item that was visible before older messages were prepended.
            try? await Task.sleep(for: .milliseconds(32))
            guard paginationRestoreAnchorID == anchorID,
                  scrollInteraction.allowsProgrammaticScroll else { return }

            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) {
                proxy.scrollTo(anchorID, anchor: .top)
            }
            paginationRestoreAnchorID = nil
        }
    }

    private var showsScrollToBottomButton: Bool {
        guard !timelineItems.isEmpty else { return false }
        return ChatScrollPolicy.shouldShowScrollToLatest(
            followLatest: followLatest,
            isPastVisibilityThreshold: scrollState.isPastVisibilityThreshold
        )
    }
}

/// The flattened timeline keeps a stable segment identity, while the row reads
/// the current value directly from its observable message. A tool status change
/// therefore invalidates only this row instead of rebuilding the entire chat
/// timeline to replace a copied `AssistantSegment` value.
private struct AssistantSegmentTimelineRow: View {
    let message: ChatMessage
    let segmentID: String
    let animatesSubagentStatus: Bool

    var body: some View {
        if let segment = message.assistantSegment(withID: segmentID) {
            MessageBubbleView(
                message: message,
                assistantSegments: [segment],
                animatesSubagentStatus: animatesSubagentStatus
            )
        }
    }
}

/// A deliberately tiny observation subtree for stream ticks. It keeps
/// auto-follow responsive without causing the parent list to materialize its
/// complete timeline again for each text-buffer flush.
private struct ChatStreamingAutoFollowObserver: View {
    @Bindable var chatClient: ChatClient

    let proxy: ScrollViewProxy
    let bottomAnchorID: String
    let minimumInterval: TimeInterval
    let settledBottomTolerance: CGFloat
    @Binding var followLatest: Bool
    @Binding var scrollInteraction: ChatScrollInteraction
    @Binding var scrollState: ChatScrollState
    @Binding var lastHandledContentVersion: UInt?
    @Binding var lastAutoScrollDate: Date

    var body: some View {
        Color.clear
            .task(id: chatClient.contentVersion) {
                let contentVersion = chatClient.contentVersion
                guard lastHandledContentVersion != nil else {
                    lastHandledContentVersion = contentVersion
                    return
                }

                // Coalesce a burst and let the new row height reach the scroll
                // geometry before deciding whether any movement is necessary.
                try? await Task.sleep(for: .milliseconds(32))
                guard !Task.isCancelled else { return }

                let now = Date()
                let shouldAutoFollow = ChatScrollPolicy.shouldAutoFollow(
                    isLoading: chatClient.isLoading,
                    followLatest: followLatest,
                    interaction: scrollInteraction,
                    bottomDistance: scrollState.bottomDistance,
                    bottomOverscroll: scrollState.bottomOverscroll,
                    settledBottomTolerance: settledBottomTolerance,
                    contentVersion: contentVersion,
                    lastHandledContentVersion: lastHandledContentVersion,
                    now: now,
                    lastAutoScrollDate: lastAutoScrollDate,
                    minimumInterval: minimumInterval
                )
                lastHandledContentVersion = contentVersion
                guard shouldAutoFollow else { return }

                lastAutoScrollDate = now
                ChatStreamInstrumentation.recordScrollToBottom()
                // A stream emits many small content updates. Scrolling them
                // with a fresh animation every ~180 ms keeps the scroll view
                // in perpetual layout/animation work and can amplify a busy
                // transcript into visible hitching. Auto-follow is therefore
                // deliberately immediate; the explicit user action remains
                // the only animated scroll path.
                var transaction = Transaction()
                transaction.animation = nil
                withTransaction(transaction) {
                    proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                }
            }
    }
}

struct ChatScrollState: Equatable {
    var bottomDistance: CGFloat
    var bottomOverscroll: CGFloat
    var isAtBottom: Bool
    var isPastVisibilityThreshold: Bool

    static let initial = ChatScrollState(
        bottomDistance: .infinity,
        bottomOverscroll: 0,
        isAtBottom: false,
        isPastVisibilityThreshold: false
    )
}

enum ChatScrollInteraction: Equatable {
    case idle
    case userControlled
    case programmatic

    var isUserControlled: Bool {
        self == .userControlled
    }

    var allowsProgrammaticScroll: Bool {
        self == .idle
    }
}

enum ChatScrollPolicy {
    static func bottomMetrics(
        contentHeight: CGFloat,
        containerHeight: CGFloat,
        contentOffsetY: CGFloat,
        topInset: CGFloat,
        bottomInset: CGFloat
    ) -> (distance: CGFloat, overscroll: CGFloat) {
        let minimumOffset = -topInset
        let maximumOffset = max(
            minimumOffset,
            contentHeight - containerHeight + bottomInset
        )
        return (
            distance: max(0, maximumOffset - contentOffsetY),
            overscroll: max(0, contentOffsetY - maximumOffset)
        )
    }

    static func state(
        contentHeight: CGFloat,
        containerHeight: CGFloat,
        contentOffsetY: CGFloat,
        topInset: CGFloat,
        bottomInset: CGFloat,
        settledBottomTolerance: CGFloat,
        visibilityThreshold: CGFloat
    ) -> ChatScrollState {
        let metrics = bottomMetrics(
            contentHeight: contentHeight,
            containerHeight: containerHeight,
            contentOffsetY: contentOffsetY,
            topInset: topInset,
            bottomInset: bottomInset
        )
        return ChatScrollState(
            bottomDistance: metrics.distance,
            bottomOverscroll: metrics.overscroll,
            isAtBottom: isAtBottom(
                bottomDistance: metrics.distance,
                bottomOverscroll: metrics.overscroll,
                tolerance: settledBottomTolerance
            ),
            isPastVisibilityThreshold: metrics.distance > visibilityThreshold
        )
    }

    static func isAtBottom(
        bottomDistance: CGFloat,
        bottomOverscroll: CGFloat,
        tolerance: CGFloat
    ) -> Bool {
        bottomDistance <= tolerance && bottomOverscroll <= tolerance
    }

    static func interaction(for phase: ScrollPhase) -> ChatScrollInteraction {
        switch phase {
        case .idle:
            .idle
        case .tracking, .interacting, .decelerating:
            .userControlled
        case .animating:
            .programmatic
        }
    }

    static func updatedFollowLatest(
        currentValue: Bool,
        interaction: ChatScrollInteraction,
        isAtBottom: Bool
    ) -> Bool {
        if interaction.isUserControlled {
            return false
        }
        if interaction == .idle, isAtBottom {
            return true
        }
        return currentValue
    }

    static func shouldAutoFollow(
        isLoading: Bool,
        followLatest: Bool,
        interaction: ChatScrollInteraction,
        bottomDistance: CGFloat,
        bottomOverscroll: CGFloat,
        settledBottomTolerance: CGFloat,
        contentVersion: UInt,
        lastHandledContentVersion: UInt?,
        now: Date,
        lastAutoScrollDate: Date,
        minimumInterval: TimeInterval
    ) -> Bool {
        guard isLoading,
              followLatest,
              interaction.allowsProgrammaticScroll,
              (bottomDistance > settledBottomTolerance
                || bottomOverscroll > settledBottomTolerance),
              contentVersion != lastHandledContentVersion else { return false }
        return now.timeIntervalSince(lastAutoScrollDate) >= minimumInterval
    }

    static func shouldLoadEarlierMessages(
        hasEarlierMessages: Bool,
        interaction: ChatScrollInteraction,
        hasPendingRestoration: Bool
    ) -> Bool {
        hasEarlierMessages
            && interaction.allowsProgrammaticScroll
            && !hasPendingRestoration
    }

    static func shouldPerformProgrammaticScroll(
        interaction: ChatScrollInteraction
    ) -> Bool {
        interaction.allowsProgrammaticScroll
    }

    static func shouldShowScrollToLatest(
        followLatest: Bool,
        isPastVisibilityThreshold: Bool
    ) -> Bool {
        guard !followLatest else { return false }
        return isPastVisibilityThreshold
    }

    static func shouldAnimateManualScroll(isLoading: Bool) -> Bool {
        !isLoading
    }
}
