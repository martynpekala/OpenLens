import StoreKit
import SwiftUI

private enum BuiltinChatPreview {
    case demo
    case debug

    var script: DemoScript {
        switch self {
        case .demo:
            return .showcase
        case .debug:
            return .debugBaseline
        }
    }

    var projectName: String {
        switch self {
        case .demo:
            return "openlens-demo"
        case .debug:
            return "chat-debug-baseline"
        }
    }

    var branch: String {
        switch self {
        case .demo:
            return "tour"
        case .debug:
            return "baseline"
        }
    }
}

private enum ChatPreviewSource {
    case builtin(BuiltinChatPreview)
    case recordedReplay(RecordedChatReplay, mode: RecordedReplayPlayer.PlaybackMode)

    var projectName: String {
        switch self {
        case .builtin(let preview):
            return preview.projectName
        case .recordedReplay(let replay, _):
            return replay.projectName ?? AppText.captureProjectFallback
        }
    }

    var branch: String {
        switch self {
        case .builtin(let preview):
            return preview.branch
        case .recordedReplay(let replay, let mode):
            return [replay.branch, mode.displayName]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank }
                .joined(separator: " · ")
        }
    }
}

private enum ReviewPromptTrigger {
    case completedOnboarding
    case connectedUsage

    static let fallbackConnectionThreshold = 3
    static let maximumAttempts = 2

    var delayNanoseconds: UInt64 {
        switch self {
        case .completedOnboarding:
            return 1_500_000_000
        case .connectedUsage:
            return 750_000_000
        }
    }
}

func shouldHandleConnectionAsFreshConnect(
    from oldState: ConnectionManager.State,
    to newState: ConnectionManager.State
) -> Bool {
    guard newState == .connected else { return false }
    if case .reconnecting = oldState {
        return false
    }
    return true
}

@main
struct OpenLensApp: App {
    private let screenshotModeEnabled: Bool
    @State private var connection: ConnectionManager
    
    @State private var router = AppRouter()

    private let liveActivity: LiveActivityManager
    private let sessionsService: SessionsService
    private let messagesService: MessagesService
    private let providersService: ProvidersService
    private let questionService: QuestionService
    private let reviewService: ReviewService
    private let inboxService: InboxService
    private let workspaceService: WorkspaceService
    private let sessionInsightsService: SessionInsightsService
    private let savedConnectionsStore: SavedConnectionsStore
    private let recordedReplayStore: RecordedReplayStore
    private let chatEasterEgg: ChatEasterEggController

    @State private var chatClient: ChatClient

    /// When non-nil, presents a preview ChatView over the connect screen.
    @State private var activePreviewSource: ChatPreviewSource?
    @State private var previewChatClient: ChatClient?
    @State private var previewConnection: ConnectionManager?

    @AppStorage("onboardingCompleted") private var onboardingCompleted: Bool = false
    @AppStorage(FeatureFlags.debugFeaturesKey) private var debugFeaturesEnabled: Bool = FeatureFlags.debugFeaturesDefault
    @AppStorage("reviewPromptAttemptCount") private var reviewPromptAttemptCount: Int = 0
    @AppStorage("reviewPromptSuccessfulConnections") private var reviewPromptSuccessfulConnections: Int = 0

    /// Deep link connection received via `openlens://connect` URL.
    @State private var pendingDeepLink: DeepLinkConnection?
    @State private var pendingSessionNavigationID: String?

    /// Alert shown when a deep link arrives while already connected.
    @State private var showDeepLinkSwitch: Bool = false
    @State private var reviewPromptTask: Task<Void, Never>?
    @State private var showReviewPrePrompt = false

    private var startDebugPreviewAction: (() -> Void)? {
#if DEBUG
        guard debugFeaturesEnabled else { return nil }
        return { startPreview(.builtin(.debug)) }
#else
        nil
#endif
    }

    init() {
        self.screenshotModeEnabled = ScreenshotFixtures.isEnabled

//        if screenshotModeEnabled, let launchTab = ScreenshotFixtures.launchTab {
//            router.selectedTab = launchTab
//        }
//        if screenshotModeEnabled, ScreenshotFixtures.opensDefaultChatSession {
//            router.selectedTab = .chat
//            router.chatPath = [.chatSession(session: ScreenshotFixtures.defaultSession)]
//        }

        let savedConnections = SavedConnectionsStore()
        let connection = ConnectionManager()
        connection.savedConnectionsStore = savedConnections

        if screenshotModeEnabled {
            connection.configureDemoState(
                projectName: ScreenshotFixtures.projectName,
                branch: ScreenshotFixtures.branchName
            )
        }

        let liveActivity = LiveActivityManager()

        let sessions = SessionsService(connection: connection)
        let messages = MessagesService(connection: connection)
        let providers = ProvidersService(connection: connection)
        let questions = QuestionService(connection: connection)
        let review = ReviewService(connection: connection)
        let inbox = InboxService(connection: connection)
        let workspace = WorkspaceService(connection: connection)
        let sessionInsights = SessionInsightsService()
        let recordedReplayStore = RecordedReplayStore()
        let chatEasterEgg = ChatEasterEggController()

        self.savedConnectionsStore = savedConnections
        self.liveActivity = liveActivity
        self.sessionsService = sessions
        self.messagesService = messages
        self.providersService = providers
        self.questionService = questions
        self.reviewService = review
        self.inboxService = inbox
        self.workspaceService = workspace
        self.sessionInsightsService = sessionInsights
        self.recordedReplayStore = recordedReplayStore
        self.chatEasterEgg = chatEasterEgg

        self._connection = State(initialValue: connection)

        if screenshotModeEnabled {
            let demoClient = ChatClient(demoMode: true)
            demoClient.providers = ScreenshotFixtures.providersResult.providers
            demoClient.connectedProviderIDs = ScreenshotFixtures.providersResult.connectedProviderIDs
            demoClient.selectedProviderID = ScreenshotFixtures.providersResult.defaultProviderID ?? "anthropic"
            demoClient.selectedModelID = ScreenshotFixtures.providersResult.defaultModelID ?? "claude-sonnet-4-20250514"
            demoClient.selectedVariant = "high"
            self._chatClient = State(initialValue: demoClient)
        } else {
            self._chatClient = State(initialValue: ChatClient(
                connection: connection,
                liveActivity: liveActivity,
                sessionsService: sessions,
                messagesService: messages,
                providersService: providers,
                questionService: questions,
                savedConnectionsStore: savedConnections,
                recordedReplayStore: recordedReplayStore
            ))
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if !screenshotModeEnabled && !onboardingCompleted {
                    OnboardingView(onDone: { onboardingCompleted = true })
                        .transition(.opacity)
                } else if screenshotModeEnabled || connection.isConnected || connection.isReconnecting {
                    ConnectedRootView(chatClient: chatClient)
                        .environment(\.connection, connection)
                        .environment(router)
                        .transition(.opacity)
                } else {
                    ConnectView(
                        onStartDemo: { startPreview(.builtin(.demo)) },
                        onStartDebug: startDebugPreviewAction,
                        onStartRecordedReplay: { replay, mode in
                            startPreview(.recordedReplay(replay, mode: mode))
                        },
                        pendingDeepLink: $pendingDeepLink,
                        pendingSessionNavigationID: $pendingSessionNavigationID
                    )
                    .environment(\.connection, connection)
                    .transition(.opacity)
                }
            }
            .openLensTheme(OpenLensAppearance.fallback.theme)
            .environment(\.liveActivity, liveActivity)
            .environment(\.savedConnections, savedConnectionsStore)
            .environment(\.sessionsService, sessionsService)
            .environment(\.messagesService, messagesService)
            .environment(\.providersService, providersService)
            .environment(\.questionService, questionService)
            .environment(\.reviewService, reviewService)
            .environment(\.inboxService, inboxService)
            .environment(\.workspaceService, workspaceService)
            .environment(\.sessionInsightsService, sessionInsightsService)
            .environment(\.recordedReplayStore, recordedReplayStore)
            .environment(\.chatEasterEgg, chatEasterEgg)
            .environment(\.requestReviewPrompt, {
                presentReviewPrePrompt()
            })
            .sheet(isPresented: previewPresentationBinding) {
                if let previewClient = previewChatClient, let previewConn = previewConnection {
                    NavigationStack {
                        ChatView(chatClient: previewClient)
                            .environment(\.connection, previewConn)
                            .toolbar {
                                ToolbarItem(placement: .topBarLeading) {
                                    Button {
                                        exitPreview()
                                    } label: {
                                        Image(systemName: "xmark")
                                    }
                                }
                            }
                    }
                    .interactiveDismissDisabled(true)
                    .onChange(of: previewConn.state) { _, newState in
                        if case .disconnected = newState {
                            exitPreview()
                        }
                    }
                }
            }
            .sheet(isPresented: $showReviewPrePrompt) {
                ReviewRequestSheet(
                    onReview: {
                        presentSystemReviewPrompt()
                    },
                    onNotNow: {
                        showReviewPrePrompt = false
                    }
                )
                .presentationDetents([.fraction(0.7)])
                .presentationDragIndicator(.visible)
                .presentationBackground(Color.appBackground)
            }
            .onOpenURL { url in
                guard let deepLink = DeepLinkConnection(from: url) else { return }
                pendingSessionNavigationID = deepLink.sessionID
                if connection.isConnected || connection.isReconnecting || isPreviewMode {
                    pendingDeepLink = deepLink
                    showDeepLinkSwitch = true
                } else {
                    pendingDeepLink = deepLink
                }
            }
            .onChange(of: connection.state) { oldState, newState in
                if shouldHandleConnectionAsFreshConnect(from: oldState, to: newState) {
                    reviewPromptSuccessfulConnections += 1
                    requestReviewIfNeeded(for: .connectedUsage)
                    router.selectedTab = .chat
                }

                if newState == .connected {
                    Task {
                        await openDeepLinkedSessionIfNeeded()
                    }
                }
            }
            .onChange(of: onboardingCompleted) { _, completed in
                guard completed else { return }
                requestReviewIfNeeded(for: .completedOnboarding)
            }
            .alert(
                AppText.switchServerTitle,
                isPresented: $showDeepLinkSwitch
            ) {
                Button(AppText.switchAction, role: .destructive) {
                    if isPreviewMode { exitPreview() }
                    connection.disconnect()
                    // pendingDeepLink is already set — ConnectView will pick it up
                }
                Button(AppText.cancel, role: .cancel) {
                    pendingDeepLink = nil
                    pendingSessionNavigationID = nil
                }
            } message: {
                Text(AppText.switchMessage)
            }
        }
    }

    // MARK: - Preview Modes

    private var isPreviewMode: Bool {
        activePreviewSource != nil
    }

    private func startPreview(_ source: ChatPreviewSource) {
        previewChatClient?.stopPreviewPlayback()

        let previewConn = ConnectionManager()
        previewConn.configureDemoState(
            projectName: source.projectName,
            branch: source.branch
        )

        let previewClient: ChatClient
        switch source {
        case .builtin(let preview):
            previewClient = ChatClient(demoMode: true, script: preview.script)
        case .recordedReplay(let replay, let mode):
            previewClient = ChatClient(recordedReplay: replay, playbackMode: mode)
        }

        self.previewConnection = previewConn
        self.previewChatClient = previewClient
        self.activePreviewSource = source
    }

    private func exitPreview() {
        previewChatClient?.stopPreviewPlayback()
        activePreviewSource = nil
        previewChatClient = nil
        previewConnection = nil
    }

    private var previewPresentationBinding: Binding<Bool> {
        Binding(
            get: { isPreviewMode && previewChatClient != nil && previewConnection != nil },
            set: { isPresented in
                if !isPresented, isPreviewMode {
                    exitPreview()
                }
            }
        )
    }

    @MainActor
    private func openDeepLinkedSessionIfNeeded() async {
        guard !isPreviewMode,
              connection.isConnected,
              let sessionID = pendingSessionNavigationID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        else {
            return
        }

        do {
            let session = try await sessionsService.getSession(id: sessionID)
            router.selectedTab = .chat
            router.chatPath = [.chatSession(session: session)]
            pendingSessionNavigationID = nil
        } catch {
            pendingSessionNavigationID = nil
        }
    }

    private func requestReviewIfNeeded(for trigger: ReviewPromptTrigger) {
        guard onboardingCompleted,
              !screenshotModeEnabled,
              !isPreviewMode
        else {
            return
        }

        switch trigger {
        case .completedOnboarding:
            guard reviewPromptAttemptCount == 0 else { return }
        case .connectedUsage:
            guard reviewPromptSuccessfulConnections >= ReviewPromptTrigger.fallbackConnectionThreshold,
                  reviewPromptAttemptCount < ReviewPromptTrigger.maximumAttempts
            else {
                return
            }
        }

        scheduleReviewPrompt(for: trigger)
    }

    private func scheduleReviewPrompt(for trigger: ReviewPromptTrigger) {
        reviewPromptAttemptCount += 1
        reviewPromptTask?.cancel()
        reviewPromptTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: trigger.delayNanoseconds)

            guard !Task.isCancelled,
                  onboardingCompleted,
                  !screenshotModeEnabled,
                  !isPreviewMode,
                  !showReviewPrePrompt
            else {
                return
            }

            presentReviewPrePrompt()
            reviewPromptTask = nil
        }
    }

    private func presentReviewPrePrompt() {
        guard !showReviewPrePrompt else { return }
        showReviewPrePrompt = true
    }

    private func presentSystemReviewPrompt() {
        showReviewPrePrompt = false

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard onboardingCompleted,
                  !screenshotModeEnabled,
                  !isPreviewMode
            else {
                return
            }
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                AppStore.requestReview(in: windowScene)
            }
        }
    }
}

private struct ReviewRequestSheet: View {
    let onReview: () -> Void
    let onNotNow: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 16) {
                Image("ReviewPanda")
                    .resizable()
                    .scaledToFill()
                    .frame(width: 116, height: 116)
                    .shadow(color: Color.appAccent.opacity(0.16), radius: 18, x: 0, y: 8)
                    .accessibilityHidden(true)

                Text(AppText.reviewRequestSubtitle)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Color.appPrimary)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 16)
                
                Text(AppText.reviewRequestBody)
                    .font(.system(size: 15, design: .rounded))
                    .foregroundStyle(Color.appPrimary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }


            Spacer()

            VStack(spacing: 10) {
                Button {
                    onReview()
                } label: {
                    Label(AppText.reviewRequestPrimaryAction, systemImage: "star.bubble.fill")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .foregroundStyle(Color.appOnAccent)
                .tint(Color.appAccent)
                .controlSize(.large)

                Button {
                    onNotNow()
                } label: {
                    Text(AppText.reviewRequestLater)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.appSecondary)
                .padding(.vertical, 6)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.appBackground)
        .accessibilityElement(children: .contain)
    }
}
