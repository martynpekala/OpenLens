import SwiftUI

private enum ChatPreviewMode: String {
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

    @State private var chatClient: ChatClient

    /// When non-nil, presents a preview ChatView over the connect screen.
    @State private var activePreviewMode: ChatPreviewMode?
    @State private var previewChatClient: ChatClient?
    @State private var previewConnection: ConnectionManager?

    @AppStorage("onboardingCompleted") private var onboardingCompleted: Bool = false

    /// Deep link connection received via `openlens://connect` URL.
    @State private var pendingDeepLink: DeepLinkConnection?
    @State private var pendingSessionNavigationID: String?

    /// Alert shown when a deep link arrives while already connected.
    @State private var showDeepLinkSwitch: Bool = false

    init() {
        self.screenshotModeEnabled = ScreenshotFixtures.isEnabled

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
                savedConnectionsStore: savedConnections
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
                        onStartDemo: { startPreview(.demo) },
                        onStartDebug: { startPreview(.debug) },
                        pendingDeepLink: $pendingDeepLink,
                        pendingSessionNavigationID: $pendingSessionNavigationID
                    )
                        .environment(\.connection, connection)
                        .transition(.opacity)
                }
            }
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
            .onChange(of: connection.state) { _, newState in
                if newState == .connected {
                    router.selectedTab = .chat
                    Task {
                        await openDeepLinkedSessionIfNeeded()
                    }
                }
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
        activePreviewMode != nil
    }

    private func startPreview(_ mode: ChatPreviewMode) {
        let previewConn = ConnectionManager()
        previewConn.configureDemoState(
            projectName: mode.projectName,
            branch: mode.branch
        )

        let previewClient = ChatClient(demoMode: true, script: mode.script)

        self.previewConnection = previewConn
        self.previewChatClient = previewClient
        self.activePreviewMode = mode
    }

    private func exitPreview() {
        activePreviewMode = nil
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
               let sessionID = pendingSessionNavigationID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank else {
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
}
