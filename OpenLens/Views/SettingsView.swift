import SwiftUI

/// Settings view focused on app preferences, connection controls, and compact server details.
struct SettingsView: View {
    private let repositoryURL = URL(string: "https://github.com/martynpekala/OpenLens")!

    @Environment(\.connection) private var connection
    @Environment(\.liveActivity) private var liveActivity
    @Environment(\.providersService) private var providersService
    @Environment(\.savedConnections) private var savedConnections

    @State private var providers: [OCProvider] = []
    @State private var connectedProviders: [String] = []
    @State private var defaultProvider: String = ""
    @State private var defaultModel: String = ""
    @State private var isLoadingProviders = false
    @State private var pathInfo: OCPathInfo?
    @State private var agentsCount: Int?
    @State private var commandsCount: Int?
    @State private var diagnosticsExpanded = false

    @State private var showDisconnectConfirmation = false
    @State private var showForgetConfirmation = false

    @AppStorage(AppPreferenceKeys.autoReconnect) private var autoReconnect: Bool = true
    @AppStorage(AppPreferenceKeys.showThinking) private var showThinking: Bool = true
    @AppStorage(AppPreferenceKeys.hapticsEnabled) private var hapticsEnabled: Bool = true
    @AppStorage(AppPreferenceKeys.liveActivitiesEnabled) private var liveActivitiesEnabled: Bool = true
    @AppStorage(FeatureFlags.debugFeaturesKey) private var debugFeaturesEnabled: Bool = FeatureFlags.debugFeaturesDefault

    private var activeConnection: SavedConnection? {
        savedConnections.activeConnection ?? (ScreenshotFixtures.isEnabled ? ScreenshotFixtures.savedConnection : nil)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                appPreferencesCard
//                connectionCard
                openCodeDefaultsCard
                diagnosticsCard
                supportCard
                 #if DEBUG
                    debugFeaturesCard
                 #endif
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
        }
        .background(Color.appBackground)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadSettingsData()
        }
        .onChange(of: liveActivitiesEnabled) { _, enabled in
            if !enabled {
                liveActivity.endActivity()
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(AppText.settings)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.appPrimary)
            }

            ToolbarItem(placement: .topBarTrailing) {
                if showsDisconnectToolbarButton {
                    Button(role: .destructive) {
                        showDisconnectConfirmation = true
                    } label: {
                        Image(systemName: "power")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Color.appDanger)
                    }
                    .accessibilityLabel(AppText.disconnect)
                    .accessibilityHint(AppText.disconnectMessage)
                    .confirmationDialog(
                        AppText.disconnect,
                        isPresented: $showDisconnectConfirmation
                    ) {
                        Button(AppText.disconnect, role: .destructive) {
                            connection.manualDisconnect()
                        }
                        Button(AppText.done, role: .cancel) {}
                    } message: {
                        Text(AppText.disconnectMessage)
                    }
                }
            }
        }
        .toolbarBackground(Color.appBackground, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
    }

    // MARK: - Connection Card

    private var connectionCard: some View {
        VStack(spacing: 8) {
            SectionLabel(text: AppText.connectionSection)

            settingsPanel {
                VStack(spacing: 10) {
                    let active = activeConnection

                    settingsSummaryRow(
                        icon: "server.rack",
                        title: AppText.openCodeServer,
                        subtitle: serverStatusText,
                        iconFill: serverStatusColor.opacity(0.16),
                        iconForeground: serverStatusColor
                    )
                    infoRow(label: AppText.url, value: active?.displayName ?? "—")
                    infoRow(label: AppText.user, value: active?.username ?? "—")
                    infoRow(label: "Auth", value: (active?.password.isEmpty ?? true) ? AppText.none : AppText.basicAuth)
                    settingsToggleRow(
                        icon: "arrow.triangle.2.circlepath",
                        title: AppText.autoReconnect,
                        subtitle: "Reconnect to the last saved server when the app opens",
                        isOn: $autoReconnect
                    )

                    if connection.state != .disconnected {
                        disconnectActionRow
                    }

                    if savedConnections.activeConnection != nil {
                        destructiveActionRow(icon: "trash", title: AppText.forgetThisConnection) {
                            showForgetConfirmation = true
                        }
                    }
                }
            }
            .confirmationDialog(
                AppText.settingsForgetDialogTitle,
                isPresented: $showForgetConfirmation
            ) {
                Button(AppText.forget, role: .destructive) {
                    if let active = savedConnections.activeConnection {
                        savedConnections.removeConnection(active)
                    }
                }
                Button(AppText.cancel, role: .cancel) {}
            } message: {
                Text(AppText.forgetConnectionMessage)
            }
        }
    }

    // MARK: - App Preferences Card

    private var appPreferencesCard: some View {
        VStack(spacing: 8) {
            settingsPanel {
                VStack(spacing: 10) {
                    settingsToggleRow(
                        icon: "brain",
                        title: AppText.showThinking,
                        subtitle: AppText.showThinkingSubtitle,
                        isOn: $showThinking
                    )
                    settingsToggleRow(
                        icon: "hand.tap",
                        title: AppText.settingsHaptics,
                        subtitle: AppText.settingsHapticsSubtitle,
                        isOn: $hapticsEnabled
                    )
                    settingsToggleRow(
                        icon: "platter.filled.top.iphone",
                        title: AppText.settingsLiveActivities,
                        subtitle: AppText.settingsLiveActivitiesSubtitle,
                        isOn: $liveActivitiesEnabled
                    )
                }
            }
        }
    }

    // MARK: - OpenCode Defaults Card

    private var openCodeDefaultsCard: some View {
        VStack(spacing: 8) {
            SectionLabel(text: AppText.settingsOpenCodeDefaults)

            settingsPanel {
                VStack(spacing: 10) {
                    settingsSummaryRow(
                        icon: "sparkles",
                        title: AppText.providerModel,
                        subtitle: AppText.settingsDefaultsSubtitle,
                        iconFill: Color.appAccent.opacity(0.14),
                        iconForeground: Color.appAccent
                    ) {
                        if isLoadingProviders {
                            ProgressView()
                                .scaleEffect(0.8)
                        }
                    }

                    infoRow(label: AppText.model, value: defaultModelSummary)
                    infoRow(label: AppText.settingsConnectedProviders, value: connectedProviderSummary)
                    infoRow(label: AppText.settingsAvailableProviders, value: availableProvidersSummary)
                    actionRow(icon: "arrow.clockwise", title: AppText.settingsRefreshStatus) {
                        Task { await loadSettingsData() }
                    }
                }
            }
        }
    }

    // MARK: - Diagnostics Card

    private var diagnosticsCard: some View {
        VStack(spacing: 8) {
            SectionLabel(text: AppText.settingsDiagnostics)

            settingsPanel {
                VStack(spacing: 10) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            diagnosticsExpanded.toggle()
                        }
                    } label: {
                        settingsSummaryRow(
                            icon: "stethoscope",
                            title: AppText.settingsDiagnostics,
                            subtitle: AppText.settingsDiagnosticsSubtitle
                        ) {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.appSecondary.opacity(0.7))
                                .rotationEffect(.degrees(diagnosticsExpanded ? 180 : 0))
                        }
                    }
                    .buttonStyle(.plain)

                    if diagnosticsExpanded {
                        infoRow(label: AppText.settingsHealth, value: serverStatusText)
                        infoRow(label: AppText.settingsEvents, value: serverEventsText)
                        infoRow(label: AppText.version, value: displayValue(connection.serverVersion))
                        infoRow(label: AppText.settingsConfig, value: displayValue(pathInfo?.config))
                        infoRow(label: AppText.settingsWorktree, value: displayValue(pathInfo?.worktree ?? connection.selectedProjectDirectory))
                        infoRow(label: AppText.settingsDirectory, value: displayValue(pathInfo?.directory ?? connection.selectedProjectDirectory))
                        infoRow(label: AppText.branch, value: displayValue(connection.branch))
                        infoRow(label: AppText.settingsAgents, value: countText(agentsCount))
                        infoRow(label: AppText.settingsCommands, value: countText(commandsCount))
                    }
                }
            }
        }
    }

    // MARK: - Support Card

    private var supportCard: some View {
        VStack(spacing: 8) {
            SectionLabel(text: AppText.settingsAboutSupport)

            settingsPanel {
                VStack(spacing: 10) {
                    settingsSummaryRow(
                        icon: "star.fill",
                        title: AppText.settingsSupportTitle,
                        subtitle: AppText.settingsSupportBody,
                        iconFill: Color.appAccent,
                        iconForeground: Color.appOnAccent
                    )

                    Link(destination: repositoryURL) {
                        settingsNavigationRow(
                            icon: "arrow.up.right.square",
                            title: AppText.settingsSupportGitHubCTA,
                            subtitle: AppText.settingsSupportRepository
                        )
                    }
                    .buttonStyle(.plain)

                    infoRow(label: AppText.settingsApp, value: appVersionBuild)
                }
            }
        }
    }

    // MARK: - Developer Card

    #if DEBUG
        private var debugFeaturesCard: some View {
            VStack(spacing: 8) {
                SectionLabel(text: AppText.developer)

                settingsPanel {
                    settingsToggleRow(
                        icon: "wrench.and.screwdriver",
                        title: AppText.settingsDebugFeatures,
                        subtitle: AppText.settingsDebugFeaturesSubtitle,
                        isOn: $debugFeaturesEnabled
                    )
                }
            }
        }
    #endif

    // MARK: - Rows

    private func settingsPanel<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(.horizontal, 8)
            .padding(.vertical, 20)
            .background {
                RoundedRectangle(cornerRadius: 36, style: .continuous)
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
                        .clipShape(RoundedRectangle(cornerRadius: 36, style: .continuous))
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
                        .clipShape(RoundedRectangle(cornerRadius: 36, style: .continuous))
                    }
            }
            .glassEffect(.clear.tint(Color.appSurface.opacity(0.08)), in: RoundedRectangle(cornerRadius: 36, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 36, style: .continuous)
                    .stroke(Color.appSeparator.opacity(0.18), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.018), radius: 10, x: 0, y: 4)
    }

    private func settingsRow<Content: View>(
        minHeight: CGFloat = 50,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .center)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.appSurface.opacity(0.24))
            )
    }

    private func settingsIcon(
        _ icon: String,
        fill: Color? = nil,
        foreground: Color = Color.appSecondary
    ) -> some View {
        Group {
            if let fill {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(fill)
                        .frame(width: 40, height: 40)
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(foreground)
                }
            } else {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(foreground)
                    .frame(width: 40, height: 40)
            }
        }
    }

    private func settingsSummaryRow(
        icon: String,
        title: String,
        subtitle: String,
        iconFill: Color? = nil,
        iconForeground: Color = Color.appSecondary
    ) -> some View {
        settingsSummaryRow(
            icon: icon,
            title: title,
            subtitle: subtitle,
            iconFill: iconFill,
            iconForeground: iconForeground
        ) {
            EmptyView()
        }
    }

    private func settingsSummaryRow<Trailing: View>(
        icon: String,
        title: String,
        subtitle: String,
        iconFill: Color? = nil,
        iconForeground: Color = Color.appSecondary,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        settingsRow(minHeight: 64) {
            HStack(spacing: 12) {
                settingsIcon(icon, fill: iconFill, foreground: iconForeground)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.appPrimary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.appSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)
                trailing()
            }
        }
    }

    private func infoRow(label: String, value: String) -> some View {
        settingsRow {
            HStack(spacing: 12) {
                Text(label)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.appSecondary)
                    .lineLimit(1)
                    .frame(width: 92, alignment: .leading)
                Text(value)
                    .font(.system(size: 15))
                    .foregroundStyle(Color.appPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
        }
    }

    private func settingsToggleRow(
        icon: String,
        title: String,
        subtitle: String,
        isOn: Binding<Bool>
    ) -> some View {
        settingsRow(minHeight: 64) {
            Toggle(isOn: isOn) {
                HStack(spacing: 12) {
                    settingsIcon(icon)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.system(size: 16, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.appPrimary)
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.system(size: 13))
                            .foregroundStyle(Color.appSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .tint(Color.appAccent)
        }
    }

    private func actionRow(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            settingsRow {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .medium))
                    Text(title)
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                }
                .foregroundStyle(Color.appPrimary)
                .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.plain)
    }

    private func destructiveActionRow(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(role: .destructive, action: action) {
            settingsRow {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .medium))
                    Text(title)
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                }
                .foregroundStyle(Color.appDanger)
                .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.plain)
    }

    private var disconnectActionRow: some View {
        destructiveActionRow(icon: "wifi.slash", title: AppText.disconnect) {
            showDisconnectConfirmation = true
        }
    }

    private func settingsNavigationRow(
        icon: String,
        title: String,
        subtitle: String
    ) -> some View {
        settingsRow(minHeight: 64) {
            HStack(spacing: 12) {
                settingsIcon(icon)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 16, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.appPrimary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.appSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.appSecondary.opacity(0.6))
            }
        }
    }

    // MARK: - Display Helpers

    private var serverStatusColor: Color {
        switch connection.state {
        case .connected: Color.appSuccess
        case .reconnecting, .connecting: Color.appWarning
        case .disconnected, .error: Color.appDanger
        }
    }

    private var showsDisconnectToolbarButton: Bool {
        switch connection.state {
        case .connected, .reconnecting, .connecting:
            true
        case .disconnected, .error:
            false
        }
    }

    private var serverStatusText: String {
        switch connection.state {
        case .connected: AppText.statusConnected
        case .reconnecting: AppText.statusReconnecting
        case .connecting: AppText.statusConnecting
        case .disconnected: AppText.statusDisconnected
        case .error: AppText.statusError
        }
    }

    private var serverEventsText: String {
        switch connection.state {
        case .connected: AppText.settingsServerEventsStreaming
        case .reconnecting: AppText.statusReconnecting
        case .connecting: AppText.statusConnecting
        case .disconnected, .error: AppText.settingsServerEventsUnavailable
        }
    }

    private var defaultModelSummary: String {
        if !defaultProvider.isEmpty, !defaultModel.isEmpty {
            return "\(providerName(for: defaultProvider))/\(defaultModel)"
        }
        if !defaultModel.isEmpty {
            return defaultModel
        }
        return AppText.settingsNoDefaultModel
    }

    private var connectedProviderSummary: String {
        guard !connectedProviders.isEmpty else {
            return AppText.settingsNoProvidersConnected
        }

        let names = connectedProviders.prefix(3).map { providerName(for: $0) }
        let suffix = connectedProviders.count > 3 ? " +\(connectedProviders.count - 3)" : ""
        return names.joined(separator: ", ") + suffix
    }

    private var availableProvidersSummary: String {
        providers.isEmpty ? AppText.noProviders : "\(providers.count)"
    }

    private var appVersionBuild: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        guard let build, !build.isEmpty, build != version else {
            return version
        }
        return "\(version) (\(build))"
    }

    private func providerName(for id: String) -> String {
        guard let provider = providers.first(where: { $0.id == id }) else {
            return id
        }

        let name = provider.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? provider.id : name
    }

    private func displayValue(_ value: String?) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "—" : trimmed
    }

    private func countText(_ count: Int?) -> String {
        count.map { String($0) } ?? "—"
    }

    // MARK: - Loading

    private func loadSettingsData() async {
        await loadProviders()
        await loadDiagnostics()
    }

    private func loadProviders() async {
        isLoadingProviders = true
        defer { isLoadingProviders = false }

        do {
            let result = try await providersService.loadProviders()
            providers = result.providers
            connectedProviders = result.connectedProviderIDs
            defaultProvider = result.defaultProviderID ?? ""
            defaultModel = result.defaultModelID ?? ""
        } catch {
            providers = []
            connectedProviders = []
        }

        if defaultProvider.isEmpty {
            let configResult = await providersService.loadConfig()
            if let providerID = configResult.defaultProviderID,
               let modelID = configResult.defaultModelID
            {
                defaultProvider = providerID
                defaultModel = modelID
            }
        }
    }

    private func loadDiagnostics() async {
        if ScreenshotFixtures.isEnabled {
            let snapshot = ScreenshotFixtures.workspaceSnapshot(path: nil)
            pathInfo = snapshot.pathInfo
            commandsCount = snapshot.commands.count
            agentsCount = nil
            return
        }

        guard let client = connection.client else {
            pathInfo = nil
            agentsCount = nil
            commandsCount = nil
            return
        }

        do {
            pathInfo = try await client.getPath()
        } catch {
            pathInfo = nil
        }

        do {
            agentsCount = try await client.listAgents().count
        } catch {
            agentsCount = nil
        }

        do {
            commandsCount = try await client.listCommands().count
        } catch {
            commandsCount = nil
        }
    }
}
