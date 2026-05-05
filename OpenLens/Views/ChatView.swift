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

    @State private var showModelPicker = false
    @State private var showContextStatus = false
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
                        .foregroundStyle(.orange)
                        .font(.system(size: 13))
                    Text(error)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.appSecondary)
                    Spacer()
                    Button(AppText.dismiss) {
                        chatClient.errorMessage = nil
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.appPrimary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .overlay(alignment: .top) {
                    Color.appSeparator.frame(height: 0.5)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            chatComposerInset
                .background(
                    LinearGradient(
                        gradient: Gradient(colors: [.clear, Color.appBackground.opacity(0.7)]), startPoint: .top, endPoint: .bottom
                    )
                )
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ChatHeaderToolbar(
                projectName: connection.projectName,
                branch: connection.branch,
                connectionState: connection.state,
                sessionTitle: chatClient.currentSession?.title
            )
        }

        // Initial load: ensure session is loaded when view appears
        .task {
            connection.setChatReconnectEnabled(true)
            chatClient.setupSSEHandlers()
            await loadCommands(force: true)
            await chatClient.ensureSession()
        }
        .onDisappear {
            connection.setChatReconnectEnabled(false)
        }

        // Foreground recovery: refresh messages and questions when app becomes active
        .onChange(of: scenePhase) { _, newPhase in
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
                isLoading: chatClient.isLoadingProviders
            ) { model in
                chatClient.selectModel(model)
                showModelPicker = false
            }
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $showContextStatus) {
            if let contextUsage = chatClient.contextUsageSummary {
                ChatContextStatusSheet(summary: contextUsage)
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

    private var chatComposerInset: some View {
        VStack(spacing: 8) {
            if chatClient.currentSession != nil {
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
        HStack(spacing: 8) {
            modelSelectorButton

            if chatClient.showsThinkingEffortPicker {
                thinkingEffortMenu
            }
            Spacer()
            if let contextUsage = chatClient.contextUsageSummary {
                Button {
                    showContextStatus = true
                } label: {
                    ChatContextUsageRing(summary: contextUsage)
                }
                .buttonStyle(.plain)
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
            HStack(spacing: 5) {
                Circle()
                    .fill(Color.appSecondary.opacity(0.3))
                    .frame(width: 6, height: 6)
                Text(chatClient.selectedModelDisplayName)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.appSecondary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.appSecondary.opacity(0.6))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.appTertiary)
            .clipShape(Capsule())
            .glassEffect()
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
            HStack(spacing: 5) {
                Image(systemName: "brain")
                    .font(.system(size: 11, weight: .medium))
                Text(chatClient.selectedVariantDisplayName)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.appSecondary.opacity(0.6))
            }
            .foregroundStyle(Color.appSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.appTertiary)
            .clipShape(Capsule())
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
                        .font(.system(size: 16))
                        .foregroundStyle(Color.appPrimary)
                        .disabled(chatClient.currentSession == nil)
                        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)

                    composerActionButton
                        .padding(4)
                }
                .padding(.leading, 16)
                .padding(.trailing, 4)
                .padding(.vertical, 4)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.appSeparator.opacity(0.8), lineWidth: 1)
                }
                .subtleShadow()
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
                            .fill(Color.red)
                            .frame(width: 32, height: 32)
                        Image(systemName: "stop.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
            } else {
                Button {
                    isInputFocused = false
                    chatClient.send()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(
                            canSend ? Color.white : Color.appSecondary.opacity(0.55),
                            canSend ? Color.appAccent : Color.appTertiary
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
                        .tint(Color.appAccent)

                    Text("Loading slash commands...")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.appSecondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            } else if availableSlashActions.isEmpty {
                Text("No slash actions available for this server.")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.appSecondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
            } else if filteredSlashActions.isEmpty {
                Text("No matching slash commands.")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.appSecondary)
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
                                        .foregroundStyle(Color.appPrimary)
                                        .frame(width: 22)
                                        .padding(.top, 2)

                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(spacing: 8) {
                                            Text(commandDisplayTitle(action.title))
                                                .font(.system(size: 17, weight: .semibold, design: .rounded))
                                                .foregroundStyle(Color.appPrimary)

                                            Text(action.kind == .command ? "Command" : "Agent")
                                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                                .foregroundStyle(Color.appSecondary)
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 3)
                                                .background(Color.appTertiary)
                                                .clipShape(Capsule())
                                        }
                                        if !action.description.isEmpty {
                                            Text(action.description)
                                                .font(.system(size: 14))
                                                .foregroundStyle(Color.appSecondary)
                                                .lineLimit(2)
                                        }
                                    }

                                    Spacer(minLength: 12)

                                    Text(action.prompt)
                                        .font(.system(size: 15, weight: .medium, design: .monospaced))
                                        .foregroundStyle(Color.appSecondary.opacity(0.8))
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 14)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            if index < filteredSlashActions.count - 1 {
                                Divider()
                                    .padding(.leading, 50)
                            }
                        }
                    }
                }
                .frame(maxHeight: 252)
            }
        }
        .background(Color.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.appSeparator.opacity(0.7), lineWidth: 1)
        }
    }

    private var canSend: Bool {
        !chatClient.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !chatClient.isLoading &&
            chatClient.currentSession != nil &&
            chatClient.pendingQuestion == nil
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

    private var tintColor: Color {
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
            Circle()
                .stroke(Color.appSeparator.opacity(0.7), lineWidth: 3)

            Circle()
                .trim(from: 0, to: progressValue)
                .stroke(tintColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))

            Text("%")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(Color.appPrimary)
        }
        .frame(width: 20, height: 20)
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

    private var usedRatio: Double {
        guard let usagePercent = summary.usagePercent else { return 0 }
        return min(max(Double(usagePercent) / 100, 0), 1)
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Status")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.appPrimary)
                .padding(.vertical, 16)

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("Context")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.appSecondary)

                    if let usagePercent = summary.usagePercent {
                        Text("\(usagePercent)% used")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.appPrimary)
                    } else {
                        Text("\(format(summary.usedTokens)) used")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.appPrimary)
                    }

                    Spacer(minLength: 8)

                    if let limitTokens = summary.limitTokens {
                        Text("(\(compactFormat(summary.usedTokens)) used / \(compactFormat(limitTokens)))")
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.appSecondary)
                    } else {
                        Text("(\(compactFormat(summary.usedTokens)) used)")
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.appSecondary)
                    }
                }

                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.appSeparator.opacity(0.65))
                            .frame(height: 8)

                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.appPrimary.opacity(0.72))
                            .frame(width: max(12, proxy.size.width * usedRatio), height: 8)
                    }
                }
                .frame(height: 8)

                if let modelLabel = summary.modelLabel {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles.rectangle.stack")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.appSecondary)
                        Text(modelLabel)
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.appSecondary)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.appBackground)
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

    @State private var lastAutoScrollDate: Date = .distantPast
    @State private var bottomMarkerMinY: CGFloat = 0
    @State private var shouldAutoScrollStreaming = true

    private let bottomAnchorID = "bottom"
    private let scrollCoordinateSpace = "chat-scroll"
    private let streamingScrollInterval: TimeInterval = 0.18
    private let scrollToBottomVisibilityThreshold: CGFloat = 56

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ZStack(alignment: .bottomTrailing) {
                    ScrollView {
                        Color.clear.frame(height: 72)

                        LazyVStack(alignment: .leading, spacing: 16) {
                            if chatClient.hasEarlierMessages {
                                Button {
                                    chatClient.loadEarlierMessages()
                                } label: {
                                    Text("Load earlier messages")
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 8)
                                }
                            }

                            ForEach(chatClient.displayedMessages) { message in
                                MessageBubbleView(message: message)
                            }
                        }
                        .padding(.horizontal, 16)

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
                    .onPreferenceChange(ChatBottomMarkerMinYPreferenceKey.self) { bottomMarkerMinY = $0 }
                    .onChange(of: chatClient.contentVersion) {
                        guard chatClient.isLoading else { return }
                        guard shouldAutoScrollStreaming else { return }

                        let now = Date()
                        guard now.timeIntervalSince(lastAutoScrollDate) >= streamingScrollInterval else { return }

                        lastAutoScrollDate = now
                        proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                    }
                    .onChange(of: chatClient.scrollAnchor) {
                        // No animation — feels natural during streaming and avoids
                        // queued-up easeOut animations on rapid 40ms flushes.
                        lastAutoScrollDate = Date()
                        proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                    }
                    .onChange(of: chatClient.completedStreamAnchor) {
                        guard shouldAutoScrollStreaming else { return }
                        lastAutoScrollDate = Date()
                        proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                    }
                    .onChange(of: bottomMarkerMinY) { _, newValue in
                        shouldAutoScrollStreaming = newValue <= geometry.size.height + scrollToBottomVisibilityThreshold
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onTapGesture {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }

                    if showsScrollToBottomButton(in: geometry.size.height) {
                        Button {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                            }
                            shouldAutoScrollStreaming = true
                        } label: {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: 34))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(Color.white, Color.appAccent)
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

    private func showsScrollToBottomButton(in viewportHeight: CGFloat) -> Bool {
        guard !chatClient.displayedMessages.isEmpty else { return false }
        return bottomMarkerMinY > viewportHeight + scrollToBottomVisibilityThreshold
    }
}

private struct ChatBottomMarkerMinYPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
