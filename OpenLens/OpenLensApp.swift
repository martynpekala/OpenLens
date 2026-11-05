import AppIntents
import StoreKit
import SwiftUI
import os

private enum BuiltinChatPreview {
    case demo
    case debug
    case heavyLoad
    case concurrentSend
    case streamStress
    case turnDiff

    var script: DemoScript {
        switch self {
        case .demo:
            return .showcase
        case .debug:
            return .debugBaseline
        case .heavyLoad:
            return .heavyLoad
        case .concurrentSend:
            return .concurrentSend
        case .streamStress:
            return .streamStress
        case .turnDiff:
            return .turnDiffPreview
        }
    }

    var projectName: String {
        switch self {
        case .demo:
            return "openlens-demo"
        case .debug:
            return "chat-debug-baseline"
        case .heavyLoad:
            return "chat-heavy-load"
        case .concurrentSend:
            return "chat-concurrent-send"
        case .streamStress:
            return "chat-stream-stress"
        case .turnDiff:
            return "chat-turn-diff"
        }
    }

    var branch: String {
        switch self {
        case .demo:
            return "tour"
        case .debug:
            return "baseline"
        case .heavyLoad:
            return "heavy-load"
        case .concurrentSend:
            return "concurrent-send"
        case .streamStress:
            return "stress"
        case .turnDiff:
            return "turn-diff"
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

struct InitialSessionsReadiness: Equatable {
    enum State: Equatable {
        case idle
        case loading
        case loaded([OCSession])
        case failed(String)
    }

    private(set) var state: State
    private(set) var generation = 0

    init(initialSessions: [OCSession]? = nil) {
        if let initialSessions {
            state = .loaded(initialSessions)
        } else {
            state = .idle
        }
    }

    var isResolved: Bool {
        switch state {
        case .loaded, .failed:
            true
        case .idle, .loading:
            false
        }
    }

    mutating func beginLoading() -> Int {
        generation &+= 1
        state = .loading
        return generation
    }

    mutating func succeed(with sessions: [OCSession], generation expectedGeneration: Int) {
        guard generation == expectedGeneration else { return }
        state = .loaded(sessions)
    }

    mutating func fail(with message: String, generation expectedGeneration: Int) {
        guard generation == expectedGeneration else { return }
        state = .failed(message)
    }

    mutating func cancelLoading() {
        guard case .loading = state else { return }
        reset()
    }

    mutating func reset() {
        generation &+= 1
        state = .idle
    }
}

private enum OpenLensRootDestination {
    case streamStressPreview(
        client: ChatClient,
        connection: ConnectionManager
    )
    case connected(initialSessions: SessionsListView.InitialState)
    case connect
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
    private static let streamStressLaunchArgument = "CHAT_STREAM_STRESS_MODE"
    private static let queuedPromptPreviewLaunchArgument = "CHAT_QUEUE_PROMPT_PREVIEW_MODE"
    private static let turnDiffPreviewLaunchArgument = "CHAT_TURN_DIFF_PREVIEW_MODE"
    private let screenshotModeEnabled: Bool
    private let streamStressModeEnabled: Bool
    /// Every server context. The UI still shows one at a time: the registry's active context.
    @State private var serverRegistry: ServerRegistry
    /// Set once the remaining saved servers have been connected for this launch.
    @State private var hasConnectedRemainingServers = false

    @State private var router = AppRouter()

    private let liveActivity: LiveActivityManager

    private let workspaceNameStore: WorkspaceNameStore
    private let sessionInsightsService: SessionInsightsService
    private let gitHubStarsService: GitHubStarsService
    private let usageQuotaService: UsageQuotaService
    private let savedConnectionsStore: SavedConnectionsStore
    private let recordedReplayStore: RecordedReplayStore
    private let chatEasterEgg: ChatEasterEggController
    private let pendingAppActions: PendingAppActions

    private var serverContext: ServerContext { serverRegistry.activeContext }
    private var connection: ConnectionManager { serverContext.connection }

    /// What the root observes about the active server. Including the context id makes switching
    /// the active server re-run everything that keys off connection state.
    private struct ActiveConnectionKey: Equatable {
        let contextID: String
        let state: ConnectionManager.State
    }

    private var activeConnectionKey: ActiveConnectionKey {
        ActiveConnectionKey(contextID: serverContext.id, state: connection.state)
    }
    private var chatClient: ChatClient { serverContext.chatClient }
    private var sessionsService: SessionsService { serverContext.sessionsService }

    /// When non-nil, presents a preview ChatView over the connect screen.
    @State private var activePreviewSource: ChatPreviewSource?
    @State private var previewChatClient: ChatClient?
    @State private var previewConnection: ConnectionManager?

    @AppStorage("onboardingCompleted") private var onboardingCompleted: Bool = false
    @AppStorage(FeatureFlags.debugFeaturesKey) private var debugFeaturesEnabled: Bool = FeatureFlags.debugFeaturesDefault

    /// Deep link connection received via `openlens://connect` URL.
    @State private var pendingDeepLink: DeepLinkConnection?
    @State private var pendingSessionNavigationID: String?

    /// Set by `openlens://setup` while connected or reconnecting; presented once the connected root is on screen.
    @State private var isOpenCodeV2SupportRequested = false
    @State private var isOpenCodeV2SupportPresented = false
    @AppStorage(AppPreferenceKeys.autoReconnect) private var autoReconnectEnabled: Bool = true
    @State private var initialSessionsReadiness: InitialSessionsReadiness
    /// Keeps the connect screen up while it shows a fresh connection's connected moment.
    @State private var isConnectScreenFinishing = false

    private var resolvedInitialSessions: SessionsListView.InitialState? {
        switch initialSessionsReadiness.state {
        case .loaded(let sessions):
            .loaded(sessions)
        case .failed(let message):
            .error(message)
        case .idle, .loading:
            nil
        }
    }

    private var rootDestination: OpenLensRootDestination {
        if streamStressModeEnabled,
           let previewClient = previewChatClient,
           let previewConnection = previewConnection {
            return .streamStressPreview(
                client: previewClient,
                connection: previewConnection
            )
        }

        if (connection.isConnected || connection.isReconnecting),
           !isConnectScreenFinishing,
           let resolvedInitialSessions {
            return .connected(initialSessions: resolvedInitialSessions)
        }

        return .connect
    }

    private var isShowingConnectScreen: Bool {
        if case .connect = rootDestination { true } else { false }
    }

    private var startDebugPreviewAction: (() -> Void)? {
#if DEBUG
        guard debugFeaturesEnabled else { return nil }
        return { startPreview(.builtin(.debug)) }
#else
        nil
#endif
    }

    private var startHeavyLoadPreviewAction: (() -> Void)? {
#if DEBUG
        guard debugFeaturesEnabled else { return nil }
        return { startPreview(.builtin(.heavyLoad)) }
#else
        nil
#endif
    }

    private var startConcurrentSendPreviewAction: (() -> Void)? {
#if DEBUG
        guard debugFeaturesEnabled else { return nil }
        return { startPreview(.builtin(.concurrentSend)) }
#else
        nil
#endif
    }

    init() {
#if DEBUG
        let launchArguments = ProcessInfo.processInfo.arguments
        let queuedPromptPreviewModeEnabled = launchArguments.contains(
            Self.queuedPromptPreviewLaunchArgument
        )
        let turnDiffPreviewModeEnabled = launchArguments.contains(Self.turnDiffPreviewLaunchArgument)
        let streamStressModeEnabled = launchArguments.contains(Self.streamStressLaunchArgument)
            || queuedPromptPreviewModeEnabled
            || turnDiffPreviewModeEnabled
#else
        let queuedPromptPreviewModeEnabled = false
        let turnDiffPreviewModeEnabled = false
        let streamStressModeEnabled = false
#endif
        let screenshotModeEnabled = ScreenshotFixtures.isEnabled
        self.screenshotModeEnabled = screenshotModeEnabled
        self.streamStressModeEnabled = streamStressModeEnabled
        self._initialSessionsReadiness = State(
            initialValue: InitialSessionsReadiness(
                initialSessions: screenshotModeEnabled ? ScreenshotFixtures.sessions : nil
            )
        )

        let initialRouter = AppRouter()
        // Paths are kept per server, so the router must name the server before anything is seeded.
        // The prepared screenshot context is built below with this id; otherwise it is corrected
        // to the registry's choice once the registry exists.
        initialRouter.activate(serverID: ScreenshotFixtures.defaultServerID)
        if screenshotModeEnabled,
           ScreenshotFixtures.opensDefaultChatSession
            || ScreenshotFixtures.opensPermissionSheet
            || ScreenshotFixtures.opensFormSheet {
            initialRouter.selectedTab = .chat
            initialRouter.chatPath = [initialRouter.chatSessionDestination(for: ScreenshotFixtures.defaultSession)]
        }
        if screenshotModeEnabled, ScreenshotFixtures.opensServers {
            initialRouter.selectedTab = .settings
            initialRouter.settingsPath = [.servers]
        }
        if screenshotModeEnabled, ScreenshotFixtures.opensArchivedSessions {
            initialRouter.selectedTab = .chat
            initialRouter.chatPath = [.archivedSessions]
        }
        if screenshotModeEnabled, let launchTab = ScreenshotFixtures.launchTab {
            initialRouter.selectedTab = launchTab
        }
        self._router = State(initialValue: initialRouter)

        let savedConnections = SavedConnectionsStore()

        let liveActivity = LiveActivityManager()

        let workspaceNames = WorkspaceNameStore()
        let sessionInsights = SessionInsightsService()
        let gitHubStars = GitHubStarsService()
        let usageQuota = UsageQuotaService()
        if screenshotModeEnabled {
            ScreenshotFixtures.applyUsageQuota(to: usageQuota)
        }
        let recordedReplayStore = RecordedReplayStore()
        let chatEasterEgg = ChatEasterEggController()
        let pendingAppActions = PendingAppActions()
        // App Intents can launch the app cold and run before any view appears, so register here.
        AppDependencyManager.shared.add(dependency: pendingAppActions)

        self.savedConnectionsStore = savedConnections
        self.liveActivity = liveActivity
        self.workspaceNameStore = workspaceNames
        self.sessionInsightsService = sessionInsights
        self.gitHubStarsService = gitHubStars
        self.usageQuotaService = usageQuota
        self.recordedReplayStore = recordedReplayStore
        self.chatEasterEgg = chatEasterEgg
        self.pendingAppActions = pendingAppActions

        var demoChatClient: ChatClient?
        if screenshotModeEnabled {
            let demoClient = ChatClient(demoMode: true)
            demoClient.providers = ScreenshotFixtures.providersResult.providers
            demoClient.connectedProviderIDs = ScreenshotFixtures.providersResult.connectedProviderIDs
            demoClient.selectedProviderID = ScreenshotFixtures.providersResult.defaultProviderID ?? "anthropic"
            demoClient.selectedModelID = ScreenshotFixtures.providersResult.defaultModelID ?? "claude-sonnet-4-20250514"
            demoClient.selectedVariant = "high"
            if ScreenshotFixtures.opensPermissionSheet {
                let session = ScreenshotFixtures.defaultSession
                demoClient.currentSession = session
                demoClient.pendingPermission = ScreenshotFixtures.inboxSnapshot.permissions.first
                demoClient.showPermissionAlert = demoClient.pendingPermission != nil
            }
            if ScreenshotFixtures.opensFormSheet {
                let session = ScreenshotFixtures.defaultSession
                demoClient.currentSession = session
                demoClient.pendingForm = ScreenshotFixtures.inboxSnapshot.forms.first
                demoClient.showFormSheet = demoClient.pendingForm != nil
            }
            demoChatClient = demoClient
        }
        // Screenshot mode hands the registry a ready-made demo context; otherwise the registry
        // builds one context per saved profile itself.
        var preparedContext: ServerContext?
        if screenshotModeEnabled {
            let demoConnection = ConnectionManager()
            demoConnection.savedConnectionsStore = savedConnections
            demoConnection.configureDemoState(
                projectName: ScreenshotFixtures.projectName,
                branch: ScreenshotFixtures.branchName
            )
            preparedContext = ServerContext(
                id: ScreenshotFixtures.defaultServerID,
                profile: ScreenshotFixtures.holdsTwoServers ? ScreenshotFixtures.defaultServerProfile : nil,
                connection: demoConnection,
                liveActivity: liveActivity,
                savedConnectionsStore: savedConnections,
                recordedReplayStore: recordedReplayStore,
                chatClient: demoChatClient
            )
        }
        var additionalContexts: [ServerContext] = []
        if screenshotModeEnabled, ScreenshotFixtures.holdsTwoServers {
            let secondConnection = ConnectionManager()
            secondConnection.savedConnectionsStore = savedConnections
            secondConnection.configureDemoState(projectName: "Second Server", branch: "server-b")
            let secondClient = ChatClient(demoMode: true)
            additionalContexts = [ServerContext(
                id: ScreenshotFixtures.secondServerID,
                profile: ScreenshotFixtures.secondServerProfile,
                connection: secondConnection,
                liveActivity: liveActivity,
                savedConnectionsStore: savedConnections,
                recordedReplayStore: recordedReplayStore,
                chatClient: secondClient
            )]
        }
        let registry = ServerRegistry(
            savedConnectionsStore: savedConnections,
            liveActivity: liveActivity,
            recordedReplayStore: recordedReplayStore,
            preparedContext: preparedContext,
            additionalPreparedContexts: additionalContexts
        )
        registry.onServerRemoved = { [initialRouter] id in initialRouter.forgetServer(id) }
        if !screenshotModeEnabled, let activeID = registry.activeServerID {
            initialRouter.activate(serverID: activeID)
        }
        self._serverRegistry = State(initialValue: registry)

        if streamStressModeEnabled {
            let preview = turnDiffPreviewModeEnabled
                ? BuiltinChatPreview.turnDiff
                : BuiltinChatPreview.streamStress
            let source = ChatPreviewSource.builtin(preview)
            let previewConnection = ConnectionManager()
            previewConnection.configureDemoState(
                projectName: source.projectName,
                branch: source.branch
            )
            self._activePreviewSource = State(initialValue: source)
            self._previewConnection = State(initialValue: previewConnection)
            let previewClient = ChatClient(demoMode: true, script: preview.script)

            if queuedPromptPreviewModeEnabled {
                previewClient.currentSession = OCSession(
                    id: "queued-prompt-preview",
                    title: "Debug: Queued Prompt",
                    time: OCSessionTime(created: 0, updated: 0)
                )
                previewClient.messages = [
                    ChatMessage(
                        role: .user,
                        content: "Prepare the release checklist."
                    )
                ]
                previewClient.pendingAssistantMessage = ChatMessage(
                    role: .assistant,
                    content: "I’m finishing the current response now…",
                    isStreaming: true
                )
                previewClient.isLoading = true
                previewClient.responseState = .generating
                previewClient.queuedPrompts = [
                    QueuedPrompt(
                        text: "Run the tests after this finishes.",
                        state: .queued
                    )
                ]
            }

            self._previewChatClient = State(initialValue: previewClient)
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                switch rootDestination {
                case .streamStressPreview(let previewClient, let previewConnection):
                    NavigationStack {
                        ChatView(chatClient: previewClient)
                            .environment(\.connection, previewConnection)
                    }

                case .connected(let initialSessions):
                    ConnectedRootView(
                        chatClient: chatClient,
                        initialSessions: initialSessions
                    )
                        .environment(\.connection, connection)
                        .environment(router)
                        .task {
                            openScreenshotPermissionSheetIfNeeded()
                        }
                        .onChange(of: isOpenCodeV2SupportRequested, initial: true) { _, isRequested in
                            guard isRequested else { return }
                            isOpenCodeV2SupportRequested = false
                            isOpenCodeV2SupportPresented = true
                        }
                        .sheet(isPresented: $isOpenCodeV2SupportPresented) {
                            OpenCodeV2SupportView(serverCapabilities: connection.serverCapabilities)
                                .presentationDetents([.medium, .large])
                                .presentationDragIndicator(.visible)
                                .presentationBackground(Color.appBackground)
                        }
                        .transition(.opacity)

                case .connect:
                    ConnectView(
                        onStartDemo: { startPreview(.builtin(.demo)) },
                        onStartDebug: startDebugPreviewAction,
                        onStartHeavyLoad: startHeavyLoadPreviewAction,
                        onStartConcurrentSend: startConcurrentSendPreviewAction,
                        onStartRecordedReplay: { replay, mode in
                            startPreview(.recordedReplay(replay, mode: mode))
                        },
                        pendingDeepLink: $pendingDeepLink,
                        pendingSessionNavigationID: $pendingSessionNavigationID,
                        isFinishingConnection: $isConnectScreenFinishing
                    )
                    .environment(\.connection, connection)
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.45), value: isShowingConnectScreen)
            .openLensTheme(OpenLensAppearance.fallback.theme)
            .scrollEdgeEffectStyle(.soft, for: .top)
            .environment(\.liveActivity, liveActivity)
            .environment(\.serverRegistry, serverRegistry)
            .environment(\.savedConnections, savedConnectionsStore)
            .environment(\.sessionsService, serverContext.sessionsService)
            .environment(\.messagesService, serverContext.messagesService)
            .environment(\.providersService, serverContext.providersService)
            .environment(\.questionService, serverContext.questionService)
            .environment(\.reviewService, serverContext.reviewService)
            .environment(\.inboxService, serverContext.inboxService)
            .environment(\.workspaceService, serverContext.workspaceService)
            .environment(\.workspaceNames, workspaceNameStore)
            .environment(\.sessionInsightsService, sessionInsightsService)
            .environment(\.gitHubStarsService, gitHubStarsService)
            .environment(\.usageQuotaService, usageQuotaService)
            .environment(\.recordedReplayStore, recordedReplayStore)
            .environment(\.chatEasterEgg, chatEasterEgg)
            .environment(\.requestReviewPrompt, {
                presentSystemReviewPrompt()
            })
            .onChange(of: serverRegistry.activeServerID) { _, newID in
                // Backstop for changes that bypass `switchServer`, such as removing the active server.
                if let newID { router.activate(serverID: newID) }
            }
            .task(id: activeConnectionKey) {
                await prepareInitialSessions(for: connection.state)
            }
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
                if let sessionID = OpenLensActivityAttributes.sessionID(from: url) {
                    openLiveActivitySession(sessionID)
                    return
                }
                if ConnectionSetupLink.matches(url) {
                    if isPreviewMode {
                        // Previews sit on top of connection setup.
                        exitPreview()
                    } else if connection.isConnected || connection.isReconnecting || isAutoReconnectExpected {
                        isOpenCodeV2SupportRequested = true
                    }
                    return
                }
                guard let deepLink = DeepLinkConnection(from: url) else { return }
                pendingSessionNavigationID = deepLink.sessionID
                if connection.isConnected || connection.isReconnecting {
                    // Already connected: add the server alongside the current one and switch to it.
                    Task { await addDeepLinkedServer(deepLink) }
                } else {
                    if isPreviewMode { exitPreview() }
                    pendingDeepLink = deepLink
                }
            }
            .onChange(of: activeConnectionKey) { oldKey, newKey in
                let oldState = oldKey.state
                let newState = newKey.state
                // A change of active server is a switch, not a connect.
                let isSameServer = oldKey.contextID == newKey.contextID
                switch newState {
                case .disconnected, .error:
                    // The awaited (re)connection did not happen; the user stays on connection setup.
                    isOpenCodeV2SupportRequested = false
                case .connecting, .connected, .reconnecting:
                    break
                }

                if newState == .connected {
                    onboardingCompleted = true
                    // A draft context only gets its saved profile once it connects.
                    serverRegistry.recordActiveServerAsLastActive()
                }

                if isSameServer, shouldHandleConnectionAsFreshConnect(from: oldState, to: newState) {
                    router.selectedTab = .chat
                }

                // The connect screen drives the first connection; once it is up, bring the other
                // saved servers up in the background. With one saved server this does nothing.
                if newState == .connected, !hasConnectedRemainingServers {
                    hasConnectedRemainingServers = true
                    Task { await serverRegistry.connectAll() }
                }

                if newState == .connected {
                    Task {
                        await openDeepLinkedSessionIfNeeded()
                        await createRequestedSessionIfNeeded()
                    }
                }
            }
            .onChange(of: pendingAppActions.newSessionRequest, initial: true) { _, request in
                guard request != nil else { return }
                Task {
                    await createRequestedSessionIfNeeded()
                }
            }
        }
    }

    // MARK: - Preview Modes

    private func prepareInitialSessions(for connectionState: ConnectionManager.State) async {
        guard !screenshotModeEnabled else { return }

        switch connectionState {
        case .connected:
            guard case .idle = initialSessionsReadiness.state else { return }
            let generation = initialSessionsReadiness.beginLoading()

            do {
                let sessions = try await sessionsService.listAllSessions()
                guard !Task.isCancelled, connection.isConnected else { return }
                initialSessionsReadiness.succeed(with: sessions, generation: generation)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, connection.isConnected else { return }
                initialSessionsReadiness.fail(
                    with: error.localizedDescription,
                    generation: generation
                )
            }

        case .reconnecting:
            initialSessionsReadiness.cancelLoading()

        case .disconnected, .connecting, .error:
            initialSessionsReadiness.reset()
        }
    }

    private var isPreviewMode: Bool {
        activePreviewSource != nil
    }

    /// Whether the connect screen is about to reconnect to the saved server, e.g. on a cold launch from a link.
    private var isAutoReconnectExpected: Bool {
        switch connection.state {
        case .connecting:
            true
        case .disconnected:
            shouldAttemptAutoReconnect(
                isEnabled: autoReconnectEnabled,
                isConnected: false,
                isConnectionStatusPresented: false,
                isQRScannerPresented: false,
                didManuallyDisconnect: connection.didManuallyDisconnect,
                savedConnection: savedConnectionsStore.mostRecent
            )
        case .connected, .reconnecting, .error:
            false
        }
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

    private func openScreenshotPermissionSheetIfNeeded() {
        guard screenshotModeEnabled,
              ScreenshotFixtures.opensPermissionSheet,
              router.chatPath.isEmpty else {
            return
        }

        router.selectedTab = .chat
        router.chatPath = [router.chatSessionDestination(for: ScreenshotFixtures.defaultSession)]
    }

    private var previewPresentationBinding: Binding<Bool> {
        Binding(
            get: {
                !streamStressModeEnabled
                    && isPreviewMode
                    && previewChatClient != nil
                    && previewConnection != nil
            },
            set: { isPresented in
                if !isPresented, isPreviewMode {
                    exitPreview()
                }
            }
        )
    }

    /// Switches the visible server. The registry and the router change together in one
    /// transaction with animations off, so no frame shows one server's client with the other's
    /// paths, and the stacks do not animate a push or pop for the change.
    @MainActor
    private func switchServer(to serverID: String) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            guard serverRegistry.activate(id: serverID) else { return }
            router.activate(serverID: serverID)
        }
    }

    /// `openlens://connect` while connected: save the server, connect it next to the current one
    /// and make it the active server. Nothing is disconnected.
    @MainActor
    private func addDeepLinkedServer(_ deepLink: DeepLinkConnection) async {
        let profile = serverRegistry.add(
            serverURL: deepLink.serverURL,
            username: deepLink.username,
            password: deepLink.password
        )
        do {
            try await serverRegistry.connect(profile: profile, method: .deepLink)
        } catch {
            Logger.connection.error("Couldn't connect the server a deep link added: \(error.localizedDescription, privacy: .public)")
            pendingSessionNavigationID = nil
            return
        }
        guard let context = serverRegistry.context(forProfileID: profile.id), context.connection.isConnected else {
            pendingSessionNavigationID = nil
            return
        }
        if context.id != serverRegistry.activeContext.id {
            // The new server needs its own first sessions load before the root shows it.
            initialSessionsReadiness.reset()
            switchServer(to: context.id)
        }
        router.selectedTab = .chat
        await openDeepLinkedSessionIfNeeded()
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
            router.chatPath = [router.chatSessionDestination(for: session)]
            pendingSessionNavigationID = nil
        } catch {
            pendingSessionNavigationID = nil
        }
    }

    /// Creates the session an App Shortcut asked for once the app is connected to a server.
    @MainActor
    private func createRequestedSessionIfNeeded() async {
        guard !isPreviewMode,
              connection.isConnected,
              let request = pendingAppActions.consumeNewSessionRequest()
        else {
            return
        }

        do {
            let session = try await sessionsService.createSession(
                title: request.title,
                model: await chatClient.newSessionModelPreference()
            )
            router.selectChatSession(session)
        } catch {
            Logger.chat.error("Couldn't create the session an App Shortcut requested: \(error, privacy: .public)")
        }
    }

    /// Opens the session a Live Activity belongs to, unless its chat is already on screen.
    private func openLiveActivitySession(_ sessionID: String) {
        if router.selectedTab == .chat,
           case .chatSession(let session, _)? = router.chatPath.last,
           session.id == sessionID {
            return
        }
        pendingSessionNavigationID = sessionID
        Task {
            await openDeepLinkedSessionIfNeeded()
        }
    }

    private func presentSystemReviewPrompt() {
        guard onboardingCompleted,
              !screenshotModeEnabled,
              !isPreviewMode,
              let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        else {
            return
        }
        AppStore.requestReview(in: windowScene)
    }
}
