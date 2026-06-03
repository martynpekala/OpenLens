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
    @State private var isLoadingCommands = false

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
                        chatClient.errorMessage = nil
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
                projectName: connection.projectName,
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
        }
        .onDisappear {
            chatEasterEgg.stopShakeMonitoring()
        }
        // Initial load: ensure session is loaded when view appears
        .task {
            chatClient.setupSSEHandlers()
            await loadCommands(force: true)
            await chatClient.ensureSession()
        }

        // Foreground recovery: refresh messages and questions when app becomes active
        .onChange(of: scenePhase) { _, newPhase in
            updateShakeMonitoring(for: newPhase)

            if newPhase == .active {
                chatClient.setupSSEHandlers()
                Task {
                    await loadCommands(force: true)
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
                visualMode: visualMode
            ) { model in
                chatClient.selectModel(model)
                showModelPicker = false
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
        .alert(
            AppText.permissionRequired,
            isPresented: $chatClient.showPermissionAlert,
            presenting: chatClient.pendingPermission
        ) { permission in
            Button(AppText.approve, role: .none) {
                Task {
                    await chatClient.respondToPermission(requestID: permission.id, approve: true)
                }
            }
            Button(AppText.deny, role: .destructive) {
                Task {
                    await chatClient.respondToPermission(requestID: permission.id, approve: false)
                }
            }
        } message: { permission in
            Text(permissionMessage(permission))
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
            guard newValue.hasPrefix("/"),
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
                        RetroChatStyle.screenBottom.opacity(0.7),
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
                        Color.appBackground.opacity(0.7),
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
        let total = chatClient.todos.count
        return "\(completed)/\(total)"
    }

    private var todoChipIcon: String {
        let allDone = chatClient.todos.allSatisfy { $0.status == "completed" }
        if allDone { return "checkmark.circle.fill" }
        let hasInProgress = chatClient.todos.contains { $0.status == "in_progress" }
        return hasInProgress ? "circle.dashed" : "checklist"
    }

    private var todoChipColor: Color {
        let allDone = chatClient.todos.allSatisfy { $0.status == "completed" }
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
        .padding(.bottom, isInputFocused ? 12 : 0)
        .padding(.horizontal, isInputFocused ? 0 : 16)
        .animation(.easeOut(duration: 0.4), value: isInputFocused)
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
            HStack(spacing: 4) {
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
                    TextField(AppText.messagePlaceholder, text: $chatClient.inputText, axis: .vertical)
                        .focused($isInputFocused)
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
        Group {
            if chatClient.isLoading {
                Button {
                    chatClient.abort()
                } label: {
                    ZStack {
                        Circle()
                            .fill(isRetroChat ? RetroChatStyle.danger : Color.red)
                            .frame(width: 32, height: 32)
                        Image(systemName: "stop.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(isRetroChat ? RetroChatStyle.paper : .white)
                    }
                }
            } else {
                Button {
                    isInputFocused = false
                    chatClient.send()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: isRetroChat ? 28 : 30, weight: isRetroChat ? .bold : .regular))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(
                            isRetroChat ? RetroChatStyle.paper : Color.appOnAccent,
                            isRetroChat ? RetroChatStyle.ink : Color.appAccent
                        )
                        .contentShape(Circle())
                }
                .disabled(!canSend)
            }
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
        !chatClient.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !chatClient.isLoading &&
            chatClient.currentSession != nil &&
            chatClient.pendingQuestion == nil &&
            chatClient.canCompose
    }

    private var slashQuery: String? {
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
        slashQuery != nil && chatClient.currentSession != nil
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
        chatClient.inputText = action.prompt + " "
        isInputFocused = true
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

    private func permissionMessage(_ permission: OCPermissionRequest) -> String {
        var parts: [String] = []
        if let title = permission.title, !title.isEmpty {
            parts.append(title)
        }
        if let tool = permission.toolDisplayName, !tool.isEmpty {
            parts.append("Tool: \(tool)")
        }
        if let desc = permission.description, !desc.isEmpty {
            parts.append(desc)
        }
        if parts.isEmpty {
            return AppText.permissionFallback
        }
        return parts.joined(separator: "\n")
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

    @State private var lastAutoScrollDate: Date = .distantPast
    @State private var bottomMarkerMinY: CGFloat = 0
    @State private var followLatest = true

    private let bottomAnchorID = "bottom"
    private let scrollCoordinateSpace = "chat-scroll"
    private let streamingScrollInterval: TimeInterval = 0.18
    private let followLatestThreshold: CGFloat = 96
    private let scrollToBottomVisibilityThreshold: CGFloat = 56

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ZStack(alignment: .bottomTrailing) {
                    ScrollView {
                        Color.clear.frame(height: isRetroChat ? 150 : 72)

                        LazyVStack(alignment: .leading, spacing: isRetroChat ? 13 : 16) {
                            if chatClient.hasEarlierMessages {
                                Button {
                                    chatClient.loadEarlierMessages()
                                } label: {
                                    Text("Load earlier messages")
                                        .font(isRetroChat ? RetroChatStyle.smallFont : .system(size: 14, weight: .medium))
                                        .foregroundStyle(isRetroChat ? RetroChatStyle.secondaryInk : .secondary)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 8)
                                        .ifRetroPanel(isRetroChat)
                                }
                            }

                            ForEach(chatClient.displayedMessages) { message in
                                MessageBubbleView(message: message)
                            }
                        }
                        .padding(.horizontal, isRetroChat ? 12 : 16)

                        Color.clear
                            .frame(height: 17)
                            .background {
                                GeometryReader { proxy in
                                    Color.clear.preference(
                                        key: ChatBottomMarkerMinYPreferenceKey.self,
                                        value: proxy.frame(in: .named(scrollCoordinateSpace)).minY
                                    )
                                }
                            }
                            .id(bottomAnchorID)
                            .padding(.horizontal, 16)
                    }
                    .coordinateSpace(name: scrollCoordinateSpace)
                    .onPreferenceChange(ChatBottomMarkerMinYPreferenceKey.self) { minY in
                        bottomMarkerMinY = minY
                        followLatest = ChatScrollPolicy.isNearBottom(
                            bottomMarkerMinY: minY,
                            viewportHeight: geometry.size.height,
                            threshold: followLatestThreshold
                        )
                    }
                    .onChange(of: chatClient.contentVersion) {
                        let now = Date()
                        guard ChatScrollPolicy.shouldAutoFollow(
                            isLoading: chatClient.isLoading,
                            followLatest: followLatest,
                            now: now,
                            lastAutoScrollDate: lastAutoScrollDate,
                            minimumInterval: streamingScrollInterval
                        ) else { return }

                        scrollToBottom(using: proxy, animated: false, now: now)
                    }
                    .onChange(of: chatClient.scrollAnchor) {
                        scrollToBottom(
                            using: proxy,
                            animated: false,
                            now: Date(),
                            forceFollowLatest: true
                        )
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onTapGesture {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }

                    if showsScrollToBottomButton(in: geometry.size.height) {
                        Button {
                            scrollToBottom(
                                using: proxy,
                                animated: true,
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
                .animation(.easeOut(duration: 0.18), value: showsScrollToBottomButton(in: geometry.size.height))
            }
        }
    }

    private var isRetroChat: Bool {
        chatEasterEgg.visualMode.isRetro
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
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(bottomAnchorID, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(bottomAnchorID, anchor: .bottom)
        }
    }

    private func showsScrollToBottomButton(in viewportHeight: CGFloat) -> Bool {
        guard !chatClient.displayedMessages.isEmpty else { return false }
        return ChatScrollPolicy.shouldShowScrollToLatest(
            followLatest: followLatest,
            bottomMarkerMinY: bottomMarkerMinY,
            viewportHeight: viewportHeight,
            visibilityThreshold: scrollToBottomVisibilityThreshold
        )
    }
}

enum ChatScrollPolicy {
    static func isNearBottom(bottomMarkerMinY: CGFloat, viewportHeight: CGFloat, threshold: CGFloat) -> Bool {
        bottomMarkerMinY <= viewportHeight + threshold
    }

    static func shouldAutoFollow(
        isLoading: Bool,
        followLatest: Bool,
        now: Date,
        lastAutoScrollDate: Date,
        minimumInterval: TimeInterval
    ) -> Bool {
        guard isLoading, followLatest else { return false }
        return now.timeIntervalSince(lastAutoScrollDate) >= minimumInterval
    }

    static func shouldShowScrollToLatest(
        followLatest: Bool,
        bottomMarkerMinY: CGFloat,
        viewportHeight: CGFloat,
        visibilityThreshold: CGFloat
    ) -> Bool {
        guard !followLatest else { return false }
        return bottomMarkerMinY > viewportHeight + visibilityThreshold
    }
}

private struct ChatBottomMarkerMinYPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
