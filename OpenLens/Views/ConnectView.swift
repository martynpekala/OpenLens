import SwiftUI
import UIKit

func shouldAttemptAutoReconnect(
    isEnabled: Bool,
    isConnected: Bool,
    isConnectionStatusPresented: Bool,
    isQRScannerPresented: Bool,
    didManuallyDisconnect: Bool,
    savedConnection: SavedConnection?,
    isConnectionSetupInProgress: Bool = false
) -> Bool {
    guard isEnabled,
          !isConnected,
          !isConnectionStatusPresented,
          !isQRScannerPresented,
          !isConnectionSetupInProgress,
          !didManuallyDisconnect,
          savedConnection?.isConfigured == true
    else {
        return false
    }

    return true
}

func connectionFailureMessage(
    localNetworkAccessRequired: Bool,
    connectionError: String?,
    isAutoReconnect: Bool
) -> String {
    if localNetworkAccessRequired {
        return AppText.localNetworkAccessRequiredBody
    }

    if let connectionError = connectionError?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .nilIfBlank
    {
        return connectionError
    }

    return isAutoReconnect
        ? AppText.autoReconnectErrorBody
        : AppText.manualConnectErrorBody
}

/// Host and port of a server address for the connection status, e.g. `192.168.1.5:4096`. Leaves
/// out credentials, paths and queries, which can carry pairing secrets.
func connectionServerDisplayName(_ serverURL: String) -> String? {
    let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
          let components = URLComponents(string: trimmed.contains("://") ? trimmed : "http://\(trimmed)"),
          let host = components.host?
              .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
              .nilIfBlank
    else {
        return nil
    }

    let displayHost = host.contains(":") ? "[\(host)]" : host
    guard let port = components.port else { return displayHost }
    return "\(displayHost):\(port)"
}

private enum ManualConnectionField: Hashable {
    case serverURL
    case username
    case password
}

/// Guided computer pairing with a manual connection form as a fallback.
struct ConnectView: View {
    /// Callback to start demo mode — provided by the parent (OpenLensApp).
    var onStartDemo: (() -> Void)?
    var onStartDebug: (() -> Void)?
    var onStartHeavyLoad: (() -> Void)?
    var onStartConcurrentSend: (() -> Void)?
    var onStartRecordedReplay: ((RecordedChatReplay, RecordedReplayPlayer.PlaybackMode) -> Void)?

    /// Deep link received from `openlens://connect` URL or QR scan.
    @Binding var pendingDeepLink: DeepLinkConnection?
    @Binding var pendingSessionNavigationID: String?
    /// True while a fresh connection shows its connected moment; the app waits for it to clear
    /// before swapping in the main interface.
    @Binding var isFinishingConnection: Bool

    @State private var discovery = BonjourDiscovery()
    @State private var manualURL: String = ""
    @State private var username: String = "opencode"
    @State private var password: String = ""

    /// The attempt shown in place of the setup step; nil while the user is setting up.
    @State private var connectionStatus: ConnectionSetupStatus?
    @State private var connectionError: String?
    @State private var connectionTask: Task<Void, Never>?
    @State private var isAutoReconnect: Bool = false
    @State private var currentConnectionMethod: ConnectionMethod = .manual
    @State private var pendingOpenCodePairingLink: OpenCodePairingLink?

    @State private var setupStep: ConnectionSetupStep = .welcome
    @FocusState private var focusedManualField: ManualConnectionField?

    @Environment(\.connection) private var connection
    @Environment(\.savedConnections) private var savedConnections
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @AppStorage(AppPreferenceKeys.autoReconnect) private var autoReconnect: Bool = true
    @AppStorage(FeatureFlags.debugFeaturesKey) private var debugFeaturesEnabled: Bool = FeatureFlags.debugFeaturesDefault

    var body: some View {
        NavigationStack {
            ConnectionWelcomeView(
                step: $setupStep,
                status: connectionStatus,
                isCameraActive: connectionStatus == nil,
                canConnectManually: !manualURL.isEmpty,
                onScanned: handleScannedCode,
                onConnectManually: connectManual,
                onRetry: retryConnection,
                onCancel: dismissConnectionStatus,
                onOpenSettings: openAppSettings
            ) {
                manualConnectionFields
            } manualAccessories: {
                manualConnectionAccessories
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                autoReconnectIfNeeded()
            }
        }
        .onChange(of: connection.state) { _, newState in
            connectionStateChanged(to: newState)
        }
        .onAppear {
            guard !consumePendingDeepLinkIfNeeded() else { return }
            prefillFromMostRecentConnectionIfNeeded()
            // Opening the app lands here already active, so the scene phase change never fires.
            if !connection.hasAttemptedConnection, scenePhase == .active {
                autoReconnectIfNeeded()
            }
        }
        .onDisappear {
            discovery.stopBrowsing()
            isFinishingConnection = false
        }
        .onChange(of: pendingDeepLink) { _, deepLink in
            guard let deepLink else { return }
            pendingDeepLink = nil
            currentConnectionMethod = .deepLink
            applyDeepLink(deepLink)
        }
    }

    private func handleScannedCode(_ code: ScannedOpenLensCode) {
        currentConnectionMethod = .qr
        switch code {
        case .direct(let deepLink):
            applyDeepLink(deepLink)
        case .openCodePairing(let link):
            startOpenCodePairing(link)
        }
    }

    // MARK: - Discovered Servers Section

    @ViewBuilder
    private var discoveredServersSection: some View {
        if discovery.localNetworkAccessRequired {
            localNetworkAccessCard
        } else if discovery.discoveredServers.count == 1,
           let server = discovery.discoveredServers.first
        {
            Button {
                connectToDiscovered(server)
            } label: {
                nearbySuggestionRow(server)
            }
            .buttonStyle(.plain)
            .transition(.opacity.combined(with: .move(edge: .top)))
            .accessibilityLabel("Found nearby: \(server.url)")
            .accessibilityHint("Connect to this server")
        }
    }

    private func nearbySuggestionRow(_ server: BonjourDiscovery.DiscoveredServer) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "network")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.appSecondary)

            Text("Found nearby:")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Color.appSecondary)

            Text(server.url)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color.appPrimary.opacity(0.76))
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)

            Spacer(minLength: 4)

            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.appSecondary.opacity(0.42))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: 300)
        .background(
            Capsule(style: .continuous)
                .fill(Color.appSurface.opacity(0.74))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color.appSeparator.opacity(0.45), lineWidth: 0.5)
        )
        .frame(maxWidth: .infinity)
    }

    private var localNetworkAccessCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.appSecondary)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.appTertiary))

                VStack(alignment: .leading, spacing: 3) {
                    Text(AppText.localNetworkAccessRequiredTitle)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.appPrimary)

                    Text(AppText.localNetworkAccessRequiredBody)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(Color.appSecondary)
                        .lineSpacing(2)
                }
            }

            HStack(spacing: 10) {
                Button {
                    openAppSettings()
                } label: {
                    Text(AppText.openSettings)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.appOnNeutralAction)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(Capsule().fill(Color.appNeutralAction))
                }

                Button {
                    startNearbyDiscovery()
                } label: {
                    Text(AppText.tryAgain)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.appPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(Capsule().fill(Color.appTertiary))
                }
            }
        }
        .padding(14)
        .frame(maxWidth: 340, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.appSurface.opacity(0.76))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.appSeparator.opacity(0.48), lineWidth: 0.7)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }

    // MARK: - Manual Connection Form

    private var manualConnectionFields: some View {
        VStack(spacing: 0) {
            manualField(systemImage: "link") {
                TextField(
                    AppText.server,
                    text: $manualURL,
                    prompt: Text("192.168.1.50:4096")
                        .foregroundStyle(Color.appSecondary.opacity(0.55))
                )
                    .font(.system(size: 15, design: .monospaced))
                    .foregroundStyle(Color.appPrimary)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .textContentType(.URL)
                    .focused($focusedManualField, equals: .serverURL)
            }

            savedServerSuggestions

            manualFieldDivider

            manualField(systemImage: "person.fill") {
                TextField(
                    AppText.user,
                    text: $username,
                    prompt: Text("opencode")
                        .foregroundStyle(Color.appSecondary.opacity(0.55))
                )
                    .font(.system(size: 15))
                    .foregroundStyle(Color.appPrimary)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($focusedManualField, equals: .username)
            }

            manualFieldDivider

            manualField(systemImage: "lock.fill") {
                SecureField(
                    AppText.password,
                    text: $password,
                    prompt: Text(AppText.optional)
                        .foregroundStyle(Color.appSecondary.opacity(0.55))
                )
                    .font(.system(size: 15))
                    .foregroundStyle(Color.appPrimary)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($focusedManualField, equals: .password)
            }
        }
        .animation(.spring(response: 0.24, dampingFraction: 0.88), value: isShowingServerAddressSuggestions)
        .animation(.spring(response: 0.22, dampingFraction: 0.9), value: serverAddressSuggestionIDs)
        .background {
            KeyboardDismissTapInstaller {
                focusedManualField = nil
            }
        }
    }

    private var manualConnectionAccessories: some View {
        VStack(spacing: 20) {
            discoveredServersSection

            if showsPreviewModesSection {
                previewModesSection
                    .padding(.top, 8)
            }
        }
    }

    @ViewBuilder
    private var savedServerSuggestions: some View {
        if isShowingServerAddressSuggestions {
            VStack(spacing: 0) {
                ForEach(serverAddressSuggestions) { saved in
                    Button {
                        applySavedServerSuggestion(saved)
                    } label: {
                        savedServerSuggestionRow(saved)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Use saved server \(saved.displayName)")

                    if saved.id != serverAddressSuggestions.last?.id {
                        Divider()
                            .overlay(Color.appSeparator.opacity(0.38))
                            .padding(.leading, 34)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
            .transition(
                .asymmetric(
                    insertion: .opacity
                        .combined(with: .move(edge: .top))
                        .combined(with: .scale(scale: 0.98, anchor: .top)),
                    removal: .opacity
                        .combined(with: .scale(scale: 0.98, anchor: .top))
                )
            )
        }
    }

    private var isShowingServerAddressSuggestions: Bool {
        focusedManualField == .serverURL && !serverAddressSuggestions.isEmpty
    }

    private var serverAddressSuggestionIDs: [String] {
        serverAddressSuggestions.map(\.id)
    }

    private var serverAddressSuggestions: [SavedConnection] {
        let query = manualURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentURL = normalizedServerSuggestionKey(query)

        return savedConnections.suggestions(for: query)
            .filter { normalizedServerSuggestionKey($0.serverURL) != currentURL || query.isEmpty }
            .prefix(4)
            .map { $0 }
    }

    private func savedServerSuggestionRow(_ saved: SavedConnection) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.appSecondary.opacity(0.72))
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text(saved.displayName)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.appPrimary.opacity(0.82))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(saved.username)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.appSecondary.opacity(0.72))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Image(systemName: "arrow.up.left")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.appSecondary.opacity(0.42))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }

    private func manualField<Content: View>(
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.appSecondary)
                .frame(width: 22)
                .accessibilityHidden(true)

            content()
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 54)
    }

    private var manualFieldDivider: some View {
        Divider()
            .overlay(Color.appSeparator.opacity(0.5))
            .padding(.leading, 50)
    }

    // MARK: - Preview Buttons

    private var showsPreviewModesSection: Bool {
#if DEBUG
        onStartDemo != nil || (debugFeaturesEnabled && (
            onStartDebug != nil
                || onStartHeavyLoad != nil
                || onStartConcurrentSend != nil
                || onStartRecordedReplay != nil
        ))
#else
        onStartDemo != nil
#endif
    }

    @ViewBuilder
    private var previewModesSection: some View {
        VStack(spacing: 12) {
#if DEBUG
            if debugFeaturesEnabled, let onStartRecordedReplay {
                NavigationLink {
                    RecordedReplayListView(onSelect: onStartRecordedReplay)
                } label: {
                    previewButtonLabel(
                        title: AppText.browseCaptures,
                        subtitle: AppText.browseCapturesSubtitle,
                        systemImage: "movieclapper"
                    )
                }
                .buttonStyle(.plain)
            }

            if debugFeaturesEnabled, let onStartDebug {
                previewButton(
                    title: AppText.tryDebugChat,
                    subtitle: AppText.tryDebugChatSubtitle,
                    systemImage: "ladybug.fill",
                    action: onStartDebug
                )
            }

            if debugFeaturesEnabled, let onStartHeavyLoad {
                previewButton(
                    title: AppText.tryHeavyLoadChat,
                    subtitle: AppText.tryHeavyLoadChatSubtitle,
                    systemImage: "gauge.with.dots.needle.67percent",
                    action: onStartHeavyLoad
                )
            }

            if debugFeaturesEnabled, let onStartConcurrentSend {
                previewButton(
                    title: AppText.tryConcurrentSendChat,
                    subtitle: AppText.tryConcurrentSendChatSubtitle,
                    systemImage: "arrow.up.message.fill",
                    action: onStartConcurrentSend
                )
            }
#endif

            if let onStartDemo {
                previewButton(
                    title: AppText.tryDemo,
                    subtitle: AppText.tryDemoSubtitle,
                    systemImage: "play.fill",
                    action: onStartDemo
                )
            }
        }
    }

    private func previewButton(
        title: String,
        subtitle: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            previewButtonLabel(
                title: title,
                subtitle: subtitle,
                systemImage: systemImage
            )
        }
    }

    private func previewButtonLabel(
        title: String,
        subtitle: String,
        systemImage: String
    ) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 11))
                Text(title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .foregroundStyle(Color.appSecondary)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.appSurface)
            )
            .surfaceShadow()

            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(Color.appSecondary.opacity(0.5))
        }
    }

    // MARK: - Connection Status

    private func showConnectionStatus(_ phase: ConnectionSetupStatus.Phase, serverURL: String?) {
        connectionStatus = ConnectionSetupStatus(
            phase: phase,
            serverName: serverURL.flatMap(connectionServerDisplayName)
        )
    }

    /// Settles a finished connect call. A fresh connection holds its connected moment briefly
    /// before the app swaps in the main interface.
    private func finishConnectionAttempt() async {
        guard connection.isConnected else {
            if case .error(let message) = connection.state {
                connectionError = message
            }
            showConnectionFailure()
            return
        }

        connectionStatus?.phase = .connected
        guard !isAutoReconnect else { return }
        isFinishingConnection = true
        try? await Task.sleep(for: .seconds(1.1))
        isFinishingConnection = false
    }

    private func showConnectionFailure(whilePairing: Bool = false) {
        let needsLocalNetworkAccess = connection.localNetworkAccessRequired
        let title = if needsLocalNetworkAccess {
            AppText.localNetworkAccessRequiredTitle
        } else if whilePairing {
            AppText.connectionPairingErrorTitle
        } else if isAutoReconnect {
            AppText.autoReconnectErrorTitle
        } else {
            AppText.manualConnectErrorTitle
        }
        connectionStatus = ConnectionSetupStatus(
            phase: .failed(title: title, message: failureMessage, needsLocalNetworkAccess: needsLocalNetworkAccess),
            serverName: connectionStatus?.serverName
        )
    }

    private var failureMessage: String {
        connectionFailureMessage(
            localNetworkAccessRequired: connection.localNetworkAccessRequired,
            connectionError: connectionError,
            isAutoReconnect: isAutoReconnect
        )
    }

    /// Turns the connected moment into a failure if the link drops before the app takes over.
    private func connectionStateChanged(to state: ConnectionManager.State) {
        guard connectionStatus?.phase == .connected else { return }
        switch state {
        case .connected, .reconnecting:
            return
        case .error(let message):
            connectionError = message
        case .disconnected, .connecting:
            connectionError = nil
        }
        isFinishingConnection = false
        showConnectionFailure()
    }

    // MARK: - Connection Actions

    private func startConnect(auto: Bool) {
        if !auto,
           let url = URL(string: manualURL.trimmingCharacters(in: .whitespacesAndNewlines)),
           let link = OpenCodePairingLink(url: url) {
            startOpenCodePairing(link)
            return
        }
        pendingOpenCodePairingLink = nil
        if auto {
            guard let saved = savedConnections.mostRecent, saved.isConfigured else { return }
            manualURL = saved.serverURL
            username = saved.username
            password = saved.password
        }

        connectionTask?.cancel()
        isAutoReconnect = auto
        connectionError = nil
        focusedManualField = nil
        showConnectionStatus(auto ? .reconnecting : .connecting, serverURL: manualURL)

        let method: ConnectionMethod = auto ? .autoReconnect : currentConnectionMethod

        connectionTask = Task {
            if auto {
                await connection.reconnect()
            } else {
                await connection.connect(url: manualURL, username: username, password: password, method: method)
            }

            guard !Task.isCancelled else { return }
            await finishConnectionAttempt()
        }
    }

    private func startOpenCodePairing(_ link: OpenCodePairingLink) {
        connectionTask?.cancel()
        pendingOpenCodePairingLink = link
        pendingSessionNavigationID = nil
        manualURL = link.serverURL.absoluteString
        username = "opencode"
        password = ""
        isAutoReconnect = false
        connectionError = nil
        focusedManualField = nil
        // Links that already carry credentials skip the pairing exchange.
        showConnectionStatus(link.credentials == nil ? .pairing : .connecting, serverURL: manualURL)

        connectionTask = Task {
            do {
                let credential = try await OpenCodePairingClient().pair(using: link)
                // Persist before connecting: the link is already consumed, even if
                // the subsequent connection fails or this task is cancelled.
                savedConnections.saveConnection(
                    serverURL: credential.serverURL,
                    username: credential.username,
                    password: credential.password
                )
                guard !Task.isCancelled else { return }
                pendingOpenCodePairingLink = nil
                manualURL = credential.serverURL
                username = credential.username
                password = credential.password
                connectionStatus?.phase = .connecting
                await connection.connect(
                    url: credential.serverURL,
                    username: credential.username,
                    password: credential.password,
                    method: currentConnectionMethod
                )
                guard !Task.isCancelled else { return }
                await finishConnectionAttempt()
            } catch {
                guard !Task.isCancelled else { return }
                connectionError = error.localizedDescription
                showConnectionFailure(whilePairing: true)
            }
        }
    }

    private func retryConnection() {
        connectionError = nil
        if let pendingOpenCodePairingLink {
            startOpenCodePairing(pendingOpenCodePairingLink)
            return
        }
        startConnect(auto: isAutoReconnect)
    }

    private func startNearbyDiscovery() {
        focusedManualField = nil
        discovery.startBrowsing()
    }

    private func openAppSettings() {
        guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(settingsURL)
    }

    private func cancelConnection() {
        connectionTask?.cancel()
        connectionTask = nil
        pendingOpenCodePairingLink = nil
        if case .connecting = connection.state {
            connection.disconnect()
        }
    }

    /// Stops the attempt and brings back the setup step it started from.
    private func dismissConnectionStatus() {
        cancelConnection()
        connectionStatus = nil
    }

    private func connectToDiscovered(_ server: BonjourDiscovery.DiscoveredServer) {
        pendingSessionNavigationID = nil
        currentConnectionMethod = .bonjour
        let suggestions = savedConnections.suggestions(for: server.url)
        if let saved = suggestions.first {
            manualURL = saved.serverURL
            username = saved.username
            password = saved.password
        } else {
            manualURL = server.url
        }
        connectManual()
    }

    private func applySavedServerSuggestion(_ saved: SavedConnection) {
        withAnimation(.spring(response: 0.22, dampingFraction: 0.9)) {
            manualURL = saved.serverURL
            username = saved.username
            password = saved.password
            focusedManualField = nil
        }
    }

    private func autoReconnectIfNeeded() {
        guard shouldAttemptAutoReconnect(
            isEnabled: autoReconnect,
            isConnected: connection.isConnected,
            isConnectionStatusPresented: connectionStatus != nil,
            isQRScannerPresented: setupStep == .scanner,
            didManuallyDisconnect: connection.didManuallyDisconnect,
            savedConnection: savedConnections.mostRecent,
            isConnectionSetupInProgress: setupStep == .manual
        ) else { return }
        startConnect(auto: true)
    }

    private func connectManual() {
        pendingSessionNavigationID = nil
        currentConnectionMethod = .manual
        startConnect(auto: false)
    }

    @discardableResult
    private func consumePendingDeepLinkIfNeeded() -> Bool {
        guard let deepLink = pendingDeepLink else {
            return false
        }

        pendingDeepLink = nil
        currentConnectionMethod = .deepLink
        applyDeepLink(deepLink)
        return true
    }

    private func prefillFromMostRecentConnectionIfNeeded() {
        guard manualURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let saved = savedConnections.mostRecent else { return }

        manualURL = saved.serverURL
        username = saved.username
        password = saved.password
    }

    // MARK: - Deep Link

    private func applyDeepLink(_ deepLink: DeepLinkConnection) {
        pendingSessionNavigationID = deepLink.sessionID
        manualURL = deepLink.serverURL
        username = deepLink.username
        password = deepLink.password
        startConnect(auto: false)
    }

    private func normalizedServerSuggestionKey(_ value: String) -> String {
        value
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "https://", with: "")
    }
}

private struct KeyboardDismissTapInstaller: UIViewRepresentable {
    var onTapOutsideInput: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onTapOutsideInput: onTapOutsideInput)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false

        DispatchQueue.main.async {
            context.coordinator.installIfNeeded(from: view)
        }

        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.onTapOutsideInput = onTapOutsideInput

        DispatchQueue.main.async {
            context.coordinator.installIfNeeded(from: view)
        }
    }

    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onTapOutsideInput: () -> Void

        private weak var installedWindow: UIWindow?
        private weak var tapGesture: UITapGestureRecognizer?

        init(onTapOutsideInput: @escaping () -> Void) {
            self.onTapOutsideInput = onTapOutsideInput
        }

        func installIfNeeded(from view: UIView) {
            guard let window = view.window, installedWindow !== window else { return }

            uninstall()

            let gesture = UITapGestureRecognizer(target: self, action: #selector(handleTap))
            gesture.cancelsTouchesInView = false
            gesture.delegate = self
            window.addGestureRecognizer(gesture)

            installedWindow = window
            tapGesture = gesture
        }

        func uninstall() {
            guard let tapGesture else { return }
            installedWindow?.removeGestureRecognizer(tapGesture)
            self.tapGesture = nil
            installedWindow = nil
        }

        @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
            onTapOutsideInput()
            recognizer.view?.endEditing(true)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let touchedView = touch.view else { return true }
            return !touchedView.hasAncestor(ofType: UITextField.self)
                && !touchedView.hasAncestor(ofType: UITextView.self)
        }
    }
}

private extension UIView {
    func hasAncestor<T: UIView>(ofType type: T.Type) -> Bool {
        var view: UIView? = self

        while let currentView = view {
            if currentView is T {
                return true
            }
            view = currentView.superview
        }

        return false
    }
}

#Preview("Connect") {
    ConnectViewPreviewHost()
}

private struct ConnectViewPreviewHost: View {
    @State private var connection = ConnectionManager()
    @State private var savedConnections = SavedConnectionsStore(initialConnections: [])
    @State private var pendingDeepLink: DeepLinkConnection?
    @State private var pendingSessionNavigationID: String?

    var body: some View {
        ConnectView(
            onStartDemo: {},
            pendingDeepLink: $pendingDeepLink,
            pendingSessionNavigationID: $pendingSessionNavigationID,
            isFinishingConnection: .constant(false)
        )
        .environment(\.connection, connection)
        .environment(\.savedConnections, savedConnections)
    }
}
