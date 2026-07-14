import SwiftUI
import UIKit

func shouldAttemptAutoReconnect(
    isEnabled: Bool,
    isConnected: Bool,
    isConnectionSheetPresented: Bool,
    isQRScannerPresented: Bool,
    didManuallyDisconnect: Bool,
    savedConnection: SavedConnection?
) -> Bool {
    guard isEnabled,
          !isConnected,
          !isConnectionSheetPresented,
          !isQRScannerPresented,
          !didManuallyDisconnect,
          savedConnection?.isConfigured == true
    else {
        return false
    }

    return true
}

private enum ManualConnectionField: Hashable {
    case serverURL
    case username
    case password
}

/// Initial connection screen with manual entry, QR scanning, mDNS discovery, and last-connection prefill.
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

    @State private var discovery = BonjourDiscovery()
    @State private var manualURL: String = ""
    @State private var username: String = "opencode"
    @State private var password: String = ""

    @State private var showOnboarding: Bool = false
    @State private var showConnectionSheet: Bool = false
    @State private var connectionFailed: Bool = false
    @State private var connectionError: String?
    @State private var connectionTask: Task<Void, Never>?
    @State private var isAutoReconnect: Bool = false
    @State private var currentConnectionMethod: ConnectionMethod = .manual

    @State private var showQRScanner: Bool = false
    @FocusState private var focusedManualField: ManualConnectionField?

    @Environment(\.connection) private var connection
    @Environment(\.savedConnections) private var savedConnections
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @AppStorage("autoReconnect") private var autoReconnect: Bool = true
    @AppStorage(FeatureFlags.debugFeaturesKey) private var debugFeaturesEnabled: Bool = FeatureFlags.debugFeaturesDefault

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    manualConnectionSection

                    connectionChoiceSeparator
                    qrScanSection

                    discoveredServersSection

                    if showsPreviewModesSection {
                        previewModesSection
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
            }
            .background(Color.appBackground)
            .background {
                KeyboardDismissTapInstaller {
                    focusedManualField = nil
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        startNearbyDiscovery()
                    } label: {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(discovery.isSearching ? Color.appAccent : Color.appPrimary)
                            .symbolEffect(.breathe, isActive: discovery.isSearching)
                    }
                    .accessibilityLabel(discovery.isSearching ? AppText.searchingServers : AppText.scanPrompt)
                    .accessibilityHint("Searches for nearby OpenCode servers on your local network")
                }

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
            if newPhase == .active, shouldAttemptAutoReconnect(
                isEnabled: autoReconnect,
                isConnected: connection.isConnected,
                isConnectionSheetPresented: showConnectionSheet,
                isQRScannerPresented: showQRScanner,
                didManuallyDisconnect: connection.didManuallyDisconnect,
                savedConnection: savedConnections.mostRecent
            ) {
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
        .onAppear {
            guard !consumePendingDeepLinkIfNeeded() else { return }
            prefillFromMostRecentConnectionIfNeeded()
        }
        .onDisappear {
            discovery.stopBrowsing()
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
        Button {
            showQRScanner = true
        } label: {
            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Color.appAccent)
                        .frame(width: 56, height: 56)
                    Image(systemName: "qrcode.viewfinder")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(Color.appOnAccent)
                }

                VStack(spacing: 3) {
                    Text(AppText.qrScan)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.appPrimary)
                    Text(AppText.qrScanSubtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.appSecondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 18)
            .padding(.vertical, 22)
            .background {
                connectionSectionBackground(cornerRadius: 20)
            }
            .glassEffect(.clear.tint(Color.appSurface.opacity(0.08)), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.appSeparator.opacity(0.18), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.018), radius: 10, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 300)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Connection Choice Separator

    private var connectionChoiceSeparator: some View {
        HStack(spacing: 12) {
            Color.appSeparator
                .frame(height: 0.5)
            Text("OR")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.appSecondary)
                .padding(.horizontal, 2)
            Color.appSeparator
                .frame(height: 0.5)
        }
        .padding(.horizontal, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Or")
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
                        .foregroundStyle(Color.appOnAccent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(Capsule().fill(Color.appAccent))
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

    // MARK: - Manual Connection Section

    private var manualConnectionSection: some View {
        VStack(spacing: 12) {
            VStack(spacing: 10) {
                VStack(spacing: 6) {
                    manualGlassField(systemImage: "link") {
                        TextField(
                            "",
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
                            .frame(maxWidth: .infinity)
                    }

                    savedServerSuggestions
                }
                .animation(.spring(response: 0.24, dampingFraction: 0.88), value: isShowingServerAddressSuggestions)
                .animation(.spring(response: 0.22, dampingFraction: 0.9), value: serverAddressSuggestionIDs)

                manualGlassField(systemImage: "person.fill") {
                    TextField("opencode", text: $username)
                        .font(.system(size: 15))
                        .foregroundStyle(Color.appPrimary)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .focused($focusedManualField, equals: .username)
                }

                manualGlassField(systemImage: "lock.fill") {
                    SecureField(
                        "",
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

                HStack(spacing: 16) {
                    Text(AppText.autoReconnect)
                        .font(.system(size: 19, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.appPrimary)

                    Spacer()

                    Toggle(AppText.autoReconnect, isOn: $autoReconnect)
                        .labelsHidden()
                        .tint(Color.appAccent)
                }
                .padding(.top, 4)

                Button {
                    connectManual()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 17, weight: .semibold))
                        Text(AppText.connect)
                    }
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .foregroundStyle(manualURL.isEmpty ? Color.appSecondary.opacity(0.52) : Color.appOnAccent)
                    .background(
                        Capsule()
                            .fill(manualURL.isEmpty ? Color.appTertiary.opacity(0.48) : Color.appAccent)
                    )
                    .overlay {
                        Capsule()
                            .stroke(Color.appSeparator.opacity(manualURL.isEmpty ? 0.70 : 0.22), lineWidth: 1.1)
                    }
                }
                .disabled(manualURL.isEmpty)
            }
        }
        .padding(20)
        .background {
            connectionSectionBackground(cornerRadius: 36)
        }
        .glassEffect(.clear.tint(Color.appSurface.opacity(0.08)), in: RoundedRectangle(cornerRadius: 36, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 36, style: .continuous)
                .stroke(Color.appSeparator.opacity(0.18), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.018), radius: 10, x: 0, y: 4)
    }

    private func connectionSectionBackground(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color.appSurface.opacity(0.20),
                        Color.appTertiary.opacity(0.08),
                        Color.appSurface.opacity(0.16)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(alignment: .topTrailing) {
                LinearGradient(
                    colors: [
                        Color.cyan.opacity(0.010),
                        Color.blue.opacity(0.006),
                        Color.clear
                    ],
                    startPoint: .topTrailing,
                    endPoint: .bottomLeading
                )
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
            .overlay(alignment: .bottomLeading) {
                LinearGradient(
                    colors: [
                        Color.purple.opacity(0.007),
                        Color.clear
                    ],
                    startPoint: .bottomLeading,
                    endPoint: .center
                )
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
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
            .padding(.horizontal, 8)
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

    private func manualGlassField<Content: View>(
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.appSecondary)
                .frame(width: 22)

            content()
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.appSurface.opacity(0.24))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.appSeparator.opacity(0.38), lineWidth: 1)
        }
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
                if connection.localNetworkAccessRequired {
                    Button {
                        openAppSettings()
                    } label: {
                        Text(AppText.openSettings)
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .foregroundStyle(Color.appOnAccent)
                            .background(Color.appAccent)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }

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
                    .foregroundStyle(connection.localNetworkAccessRequired ? Color.appPrimary : Color.appOnAccent)
                    .background(connection.localNetworkAccessRequired ? Color.appTertiary : Color.appAccent)
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
        if connection.localNetworkAccessRequired {
            return AppText.localNetworkAccessRequiredTitle
        }
        return isAutoReconnect
            ? AppText.autoReconnectErrorTitle
            : AppText.manualConnectErrorTitle
    }

    private var failureMessage: String {
        if connection.localNetworkAccessRequired {
            return AppText.localNetworkAccessRequiredBody
        }
        if isAutoReconnect {
            return AppText.autoReconnectErrorBody
        }
        if let error = connectionError { return error }
        return AppText.manualConnectErrorBody
    }

    // MARK: - Connection Actions

    private func startConnect(auto: Bool) {
        if auto {
            guard let saved = savedConnections.mostRecent, saved.isConfigured else { return }
            manualURL = saved.serverURL
            username = saved.username
            password = saved.password
        }

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

    private func applySavedServerSuggestion(_ saved: SavedConnection) {
        withAnimation(.spring(response: 0.22, dampingFraction: 0.9)) {
            manualURL = saved.serverURL
            username = saved.username
            password = saved.password
            focusedManualField = nil
        }
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
            pendingSessionNavigationID: $pendingSessionNavigationID
        )
        .environment(\.connection, connection)
        .environment(\.savedConnections, savedConnections)
    }
}
