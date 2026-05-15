import SwiftUI

/// Initial connection screen with mDNS discovery, saved connections, and manual entry.
struct ConnectView: View {
    /// Callback to start demo mode — provided by the parent (OpenLensApp).
    var onStartDemo: (() -> Void)?
    var onStartDebug: (() -> Void)?
    var onStartRecordedReplay: ((RecordedChatReplay, RecordedReplayPlayer.PlaybackMode) -> Void)?

    /// Deep link received from `openlens://connect` URL or QR scan.
    @Binding var pendingDeepLink: DeepLinkConnection?
    @Binding var pendingSessionNavigationID: String?

    @State private var discovery = BonjourDiscovery()
    @State private var manualURL: String = ""
    @State private var username: String = "opencode"
    @State private var password: String = ""
    @State private var showManualEntry: Bool = true

    @State private var showOnboarding: Bool = false
    @State private var showConnectionSheet: Bool = false
    @State private var connectionFailed: Bool = false
    @State private var connectionError: String?
    @State private var connectionTask: Task<Void, Never>?
    @State private var isAutoReconnect: Bool = false
    @State private var currentConnectionMethod: ConnectionMethod = .manual

    @State private var showQRScanner: Bool = false

    @Environment(\.connection) private var connection
    @Environment(\.savedConnections) private var savedConnections
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("autoReconnect") private var autoReconnect: Bool = true

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    discoveredServersSection

                    qrScanSection

                    manualConnectionSection

                    if !savedConnections.connections.isEmpty {
                        savedConnectionsSection
                    }

#if DEBUG
                    if onStartDebug != nil || onStartDemo != nil || onStartRecordedReplay != nil {
                        previewModesSection
                    }
#endif
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
            }
            .background(Color.appBackground)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showOnboarding = true
                    } label: {
                        Text(AppText.help)
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.appPrimary)
                    }
                }
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active, autoReconnect, !connection.isConnected, !showConnectionSheet,
               !connection.didManuallyDisconnect,
               savedConnections.mostRecent?.isConfigured == true
            {
                startConnect(auto: true)
            }
        }
        .sheet(isPresented: $showConnectionSheet, onDismiss: cancelConnection) {
            connectionSheetContent
                .presentationDetents(connectionFailed ? [.fraction(0.5), .medium] : [.fraction(0.35)])
                .presentationDragIndicator(.hidden)
                .interactiveDismissDisabled(false)
                .presentationBackground(Color.appBackground)
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView(onDone: { showOnboarding = false })
                .presentationBackground(Color.appBackground)
        }
        .fullScreenCover(isPresented: $showQRScanner) {
            QRScannerView(
                onScanned: { deepLink in
                    showQRScanner = false
                    currentConnectionMethod = .qr
                    applyDeepLink(deepLink)
                },
                onDismiss: { showQRScanner = false }
            )
        }
        .onChange(of: pendingDeepLink) { _, deepLink in
            guard let deepLink else { return }
            pendingDeepLink = nil
            currentConnectionMethod = .deepLink
            applyDeepLink(deepLink)
        }
    }

    // MARK: - QR Scan Section

    private var qrScanSection: some View {
        SurfaceCard(padding: 0) {
            Button {
                showQRScanner = true
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.appAccent)
                            .frame(width: 36, height: 36)
                        Image(systemName: "qrcode.viewfinder")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Color.appOnAccent)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(AppText.qrScan)
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.appPrimary)
                        Text(AppText.qrScanSubtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.appSecondary)
                    }

                    Spacer()

                    Image(systemName: "camera.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.appSecondary.opacity(0.4))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Discovered Servers Section

    private var discoveredServersSection: some View {
        VStack(spacing: 8) {
            HStack {
                SectionLabel(text: AppText.nearby)
                Spacer()
                if discovery.isSearching {
                    ProgressView().scaleEffect(0.75)
                } else {
                    Button {
                        discovery.startBrowsing()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.appSecondary)
                    }
                }
            }

            SurfaceCard(padding: 0) {
                if !discovery.discoveredServers.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(discovery.discoveredServers) { server in
                            Button {
                                connectToDiscovered(server)
                            } label: {
                                discoveredServerRow(server)
                            }
                            .buttonStyle(.plain)

                            if server.id != discovery.discoveredServers.last?.id {
                                SurfaceDivider()
                            }
                        }
                    }
                } else if !discovery.hasSearched && !discovery.isSearching {
                    Button {
                        discovery.startBrowsing()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "wifi")
                                .font(.system(size: 13))
                                .foregroundStyle(Color.appPrimary)
                            Text(AppText.scanPrompt)
                                .font(.system(size: 14))
                                .foregroundStyle(Color.appPrimary)
                            Spacer()
                        }
                        .padding(16)
                    }
                    .buttonStyle(.plain)
                } else {
                    HStack(spacing: 10) {
                        Image(systemName: "wifi.slash")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.appSecondary.opacity(0.4))
                        Text(discovery.isSearching
                            ? AppText.searchingServers
                            : discovery.lastErrorMessage ?? AppText.noServersFound)
                            .font(.system(size: 14))
                            .foregroundStyle(Color.appSecondary)
                        Spacer()
                    }
                    .padding(16)
                }
            }
        }
    }

    private func discoveredServerRow(_ server: BonjourDiscovery.DiscoveredServer) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.appAccent)
                    .frame(width: 36, height: 36)
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.appOnAccent)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.appPrimary)
                Text(server.url)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.appSecondary)
                    .lineLimit(1)
            }

            Spacer()

            Image(systemName: "arrow.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.appSecondary.opacity(0.4))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Saved Connections Section

    private var savedConnectionsSection: some View {
        VStack(spacing: 8) {
            SectionLabel(text: AppText.saved)

            SurfaceCard(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(savedConnections.connections) { saved in
                        Button {
                            connectToSaved(saved)
                        } label: {
                            savedConnectionRow(saved)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                fillFromSaved(saved)
                            } label: {
                                Label(AppText.editBeforeConnecting, systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                savedConnections.removeConnection(saved)
                            } label: {
                                Label(AppText.forgetConnection, systemImage: "trash")
                            }
                        }

                        if saved.id != savedConnections.connections.last?.id {
                            SurfaceDivider()
                        }
                    }
                }
            }
        }
    }

    private func savedConnectionRow(_ saved: SavedConnection) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.appTertiary)
                    .frame(width: 36, height: 36)
                Image(systemName: saved.password.isEmpty ? "server.rack" : "lock.fill")
                    .font(.system(size: saved.password.isEmpty ? 14 : 13))
                    .foregroundStyle(Color.appSecondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(saved.displayName)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.appPrimary)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text(saved.username)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.appSecondary)
                    if !saved.password.isEmpty {
                        Text("·")
                            .foregroundStyle(Color.appSecondary.opacity(0.4))
                        Text("Protected")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.appSecondary)
                    }
                }
            }

            Spacer()

            if let date = saved.lastConnectedAt {
                Text(date, format: .relative(presentation: .named))
                    .font(.system(size: 11))
                    .foregroundStyle(Color.appSecondary.opacity(0.5))
                    .lineLimit(1)
            }

            Image(systemName: "arrow.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.appSecondary.opacity(0.4))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Manual Connection Section

    private var manualConnectionSection: some View {
        VStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showManualEntry.toggle()
                }
            } label: {
                HStack {
                    SectionLabel(text: AppText.manualConnection)
                    Spacer()
                    Image(systemName: showManualEntry ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.appSecondary.opacity(0.5))
                }
            }
            .buttonStyle(.plain)

            if showManualEntry {
                SurfaceCard(padding: 0) {
                    VStack(spacing: 0) {
                        HStack(spacing: 12) {
                            Text(AppText.url)
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundStyle(Color.appSecondary)
                                .frame(width: 52, alignment: .leading)
                            TextField("192.168.1.50:4096", text: $manualURL)
                                .font(.system(size: 15, design: .monospaced))
                                .foregroundStyle(Color.appPrimary)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .textContentType(.URL)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)

                        SurfaceDivider()

                        HStack(spacing: 12) {
                            Text(AppText.user)
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundStyle(Color.appSecondary)
                                .frame(width: 52, alignment: .leading)
                            TextField("opencode", text: $username)
                                .font(.system(size: 15))
                                .foregroundStyle(Color.appPrimary)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)

                        SurfaceDivider()

                        HStack(spacing: 12) {
                            Text(AppText.pass)
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundStyle(Color.appSecondary)
                                .frame(width: 52, alignment: .leading)
                            SecureField(AppText.optional, text: $password)
                                .font(.system(size: 15))
                                .foregroundStyle(Color.appPrimary)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)

                        SurfaceDivider()

                        Toggle(isOn: $autoReconnect) {
                            Text(AppText.autoReconnect)
                                .font(.system(size: 15, design: .rounded))
                                .foregroundStyle(Color.appPrimary)
                        }
                        .tint(Color.appAccent)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)

                        SurfaceDivider()

                        Button {
                            connectManual()
                        } label: {
                            Text(AppText.connect)
                                .font(.system(size: 16, weight: .semibold, design: .rounded))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 15)
                                .foregroundStyle(manualURL.isEmpty ? Color.appSecondary.opacity(0.5) : Color.appOnAccent)
                                .background(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(manualURL.isEmpty ? Color.appTertiary : Color.appAccent)
                                )
                        }
                        .disabled(manualURL.isEmpty)
                        .padding(16)
                    }
                }
            }
        }
    }

    // MARK: - Preview Buttons

#if DEBUG
    @ViewBuilder
    private var previewModesSection: some View {
        VStack(spacing: 12) {
            if let onStartRecordedReplay {
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

            if let onStartDebug {
                previewButton(
                    title: AppText.tryDebugChat,
                    subtitle: AppText.tryDebugChatSubtitle,
                    systemImage: "ladybug.fill",
                    action: onStartDebug
                )
            }

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
#endif

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

    // MARK: - Connection Sheet

    @ViewBuilder
    private var connectionSheetContent: some View {
        if connectionFailed {
            errorStateContent
        } else {
            connectingStateContent
        }
    }

    // MARK: - Connecting State

    private var connectingStateContent: some View {
        VStack(spacing: 24) {
            Spacer()
            ZStack {
                Circle()
                    .stroke(Color.appSeparator, lineWidth: 1.5)
                    .frame(width: 64, height: 64)
                ProgressView()
                    .tint(Color.appAccent)
                    .scaleEffect(1.4)
            }

            VStack(spacing: 8) {
                Text(isAutoReconnect
                    ? AppText.reconnecting
                    : AppText.connecting)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.appPrimary)

                Text(isAutoReconnect
                    ? AppText.reconnectingSubtitle
                    : AppText.connectingSubtitle)
                    .font(.body)
                    .foregroundStyle(Color.appSecondary)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            Button {
                showConnectionSheet = false
            } label: {
                Text(AppText.cancel)
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .foregroundStyle(Color.appPrimary)
                    .background(Color.appTertiary)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Error State

    private var errorStateContent: some View {
        VStack(spacing: 24) {
            Spacer()

            ZStack {
                Circle()
                    .stroke(Color.appSeparator, lineWidth: 1.5)
                    .frame(width: 64, height: 64)
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(Color.appSecondary)
            }

            VStack(spacing: 8) {
                Text(failureTitle)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.appPrimary)

                Text(failureMessage)
                    .lineLimit(3)
                    .font(.footnote)
                    .foregroundStyle(Color.appSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 16)

            Spacer()

            VStack(spacing: 10) {
                Button {
                    retryConnection()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 14, weight: .semibold))
                        Text(AppText.tryAgain)
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .foregroundStyle(Color.appOnAccent)
                    .background(Color.appAccent)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                Button {
                    showConnectionSheet = false
                } label: {
                    Text(AppText.cancel)
                        .font(.system(size: 16, weight: .medium, design: .rounded))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .foregroundStyle(Color.appPrimary)
                        .background(Color.appTertiary)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Failure Copy

    private var failureTitle: String {
        isAutoReconnect
            ? AppText.autoReconnectErrorTitle
            : AppText.manualConnectErrorTitle
    }

    private var failureMessage: String {
        if isAutoReconnect {
            return AppText.autoReconnectErrorBody
        }
        if let error = connectionError { return error }
        return AppText.manualConnectErrorBody
    }

    // MARK: - Connection Actions

    private func startConnect(auto: Bool) {
        connectionTask?.cancel()
        isAutoReconnect = auto
        connectionFailed = false
        connectionError = nil
        showConnectionSheet = true

        let method: ConnectionMethod = auto ? .autoReconnect : currentConnectionMethod

        connectionTask = Task {
            if auto {
                await connection.reconnect()
            } else {
                await connection.connect(url: manualURL, username: username, password: password, method: method)
            }

            guard !Task.isCancelled else { return }

            if connection.isConnected {
                showConnectionSheet = false
            } else {
                if case .error(let msg) = connection.state {
                    connectionError = msg
                }
                connectionFailed = true
            }
        }
    }

    private func retryConnection() {
        connectionFailed = false
        connectionError = nil
        startConnect(auto: isAutoReconnect)
    }

    private func cancelConnection() {
        connectionTask?.cancel()
        connectionTask = nil
        if case .connecting = connection.state {
            connection.disconnect()
        }
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

    private func connectToSaved(_ saved: SavedConnection) {
        pendingSessionNavigationID = nil
        currentConnectionMethod = .saved
        manualURL = saved.serverURL
        username = saved.username
        password = saved.password
        startConnect(auto: false)
    }

    private func fillFromSaved(_ saved: SavedConnection) {
        manualURL = saved.serverURL
        username = saved.username
        password = saved.password
        showManualEntry = true
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

    // MARK: - Deep Link

    private func applyDeepLink(_ deepLink: DeepLinkConnection) {
        pendingSessionNavigationID = deepLink.sessionID
        manualURL = deepLink.serverURL
        username = deepLink.username
        password = deepLink.password
        showManualEntry = true
        startConnect(auto: false)
    }
}
