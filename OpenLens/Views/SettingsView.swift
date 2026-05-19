import SwiftUI

/// Settings view with server info, provider/model selection, and disconnect.
struct SettingsView: View {
    @Environment(\.connection) private var connection
    @Environment(\.liveActivity) private var liveActivity
    @Environment(\.providersService) private var providersService

    @State private var providers: [OCProvider] = []
    @State private var connectedProviders: [String] = []
    @State private var defaultProvider: String = ""
    @State private var defaultModel: String = ""
    @State private var isLoadingProviders = false

    @State private var showDisconnectConfirmation = false
    @State private var showForgetConfirmation = false
    @Environment(\.savedConnections) private var savedConnections
    @AppStorage("autoReconnect") private var autoReconnect: Bool = true
    @AppStorage(FeatureFlags.debugFeaturesKey) private var debugFeaturesEnabled: Bool = FeatureFlags.debugFeaturesDefault

    private var activeConnection: SavedConnection? {
        savedConnections.activeConnection ?? (ScreenshotFixtures.isEnabled ? ScreenshotFixtures.savedConnection : nil)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                serverInfoCard
                providerCard
                connectionCard
#if DEBUG
                debugFeaturesCard
#endif
                actionsCard
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
        }
        .background(Color.appBackground)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadProviders()
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(AppText.settings)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.appPrimary)
            }
        }
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

    // MARK: - Server Status Helpers

    private var serverStatusColor: Color {
        switch connection.state {
        case .connected: .green
        case .reconnecting, .connecting: .orange
        case .disconnected, .error: .red
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

    // MARK: - Server Info Card

    private var serverInfoCard: some View {
        VStack(spacing: 8) {
            SectionLabel(text: AppText.server)

            SurfaceCard(padding: 0) {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.appAccent)
                                .frame(width: 36, height: 36)
                            Image(systemName: "server.rack")
                                .font(.system(size: 15))
                                .foregroundStyle(Color.appOnAccent)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(AppText.openCodeServer)
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.appPrimary)
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(serverStatusColor)
                                    .frame(width: 7, height: 7)
                                Text(serverStatusText)
                                    .font(.system(size: 13))
                                    .foregroundStyle(Color.appSecondary)
                            }
                        }

                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)

                    if connection.serverVersion != nil || connection.projectName != nil || connection.branch != nil {
                        SurfaceDivider()
                    }

                    if let version = connection.serverVersion {
                        infoRow(label: AppText.version, value: version)
                        if connection.projectName != nil || connection.branch != nil { SurfaceDivider() }
                    }

                    if let project = connection.projectName {
                        infoRow(label: AppText.project, value: project)
                        if connection.branch != nil { SurfaceDivider() }
                    }

                    if let branch = connection.branch {
                        infoRow(label: AppText.branch, value: branch)
                    }
                }
            }
        }
    }

    // MARK: - Provider Card

    private var providerCard: some View {
        VStack(spacing: 8) {
            SectionLabel(text: "AI Provider")

            SurfaceCard(padding: 0) {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.appTertiary)
                                .frame(width: 36, height: 36)
                            Image(systemName: "cpu")
                                .font(.system(size: 15))
                                .foregroundStyle(Color.appSecondary)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(AppText.providerModel)
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.appPrimary)
                            Text(AppText.providerSubtitle)
                                .font(.system(size: 13))
                                .foregroundStyle(Color.appSecondary)
                        }

                        Spacer()

                        if isLoadingProviders {
                            ProgressView().scaleEffect(0.8)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)

                    if !providers.isEmpty {
                        SurfaceDivider()

                        let displayIDs = connectedProviders.isEmpty
                            ? providers.map(\.id)
                            : connectedProviders

                        ForEach(Array(displayIDs.enumerated()), id: \.element) { idx, providerID in
                            if let provider = providers.first(where: { $0.id == providerID }) {
                                providerRow(provider, isDefault: provider.id == defaultProvider)
                                if idx < displayIDs.count - 1 { SurfaceDivider() }
                            }
                        }
                    } else if !isLoadingProviders {
                        SurfaceDivider()
                        HStack {
                            Text(AppText.noProviders)
                                .font(.system(size: 14))
                                .foregroundStyle(Color.appSecondary)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                    }
                }
            }
        }
    }

    private func providerRow(_ provider: OCProvider, isDefault: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: isDefault ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isDefault ? Color.appPrimary : Color.appSecondary.opacity(0.3))
                .font(.system(size: 18))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(provider.name.isEmpty ? provider.id : provider.name)
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.appPrimary)

                    if isDefault {
                        Text("DEFAULT")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.appOnAccent)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.appAccent)
                            )
                    }
                }

                if isDefault, !defaultModel.isEmpty {
                    Text(defaultModel)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.appSecondary)
                        .lineLimit(1)
                }

                let modelCount = provider.models.count
                if modelCount > 0, !isDefault {
                    Text("\(modelCount) model\(modelCount == 1 ? "" : "s")")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.appSecondary)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Connection Card

    private var connectionCard: some View {
        VStack(spacing: 8) {
            SectionLabel(text: AppText.connectionSection)

            SurfaceCard(padding: 0) {
                VStack(spacing: 0) {
                    let active = activeConnection

                    infoRow(label: AppText.url, value: active?.displayName ?? "—")
                    SurfaceDivider()
                    infoRow(label: AppText.user, value: active?.username ?? "—")
                    SurfaceDivider()
                    infoRow(label: "Auth", value: (active?.password.isEmpty ?? true) ? AppText.none : AppText.basicAuth)
                    SurfaceDivider()

                    Toggle(isOn: $autoReconnect) {
                        Text(AppText.autoReconnect)
                            .font(.system(size: 15, design: .rounded))
                            .foregroundStyle(Color.appPrimary)
                    }
                    .tint(Color.appAccent)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)

                    if savedConnections.activeConnection != nil {
                        SurfaceDivider()

                        Button(role: .destructive) {
                            showForgetConfirmation = true
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "trash")
                                    .font(.system(size: 13))
                                Text(AppText.forgetThisConnection)
                                    .font(.system(size: 15, weight: .medium, design: .rounded))
                            }
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                        }
                        .buttonStyle(.plain)
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

    // MARK: - Actions Card

#if DEBUG
    private var debugFeaturesCard: some View {
        VStack(spacing: 8) {
            SectionLabel(text: AppText.developer)

            SurfaceCard(padding: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(isOn: $debugFeaturesEnabled) {
                        Text(AppText.settingsDebugFeatures)
                            .font(.system(size: 15, design: .rounded))
                            .foregroundStyle(Color.appPrimary)
                    }
                    .tint(Color.appAccent)

                    Text(AppText.settingsDebugFeaturesSubtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.appSecondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
        }
    }
#endif

    private var actionsCard: some View {
        VStack(spacing: 10) {
            Button {
                Task { await loadProviders() }
            } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 14, weight: .medium))
                        Text(AppText.refreshProviders)
                            .font(.system(size: 15, weight: .medium, design: .rounded))
                    }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .foregroundStyle(Color.appPrimary)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.appSurface)
                )
                .surfaceShadow()
            }
            .buttonStyle(.plain)

            Button {
                showDisconnectConfirmation = true
            } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "wifi.slash")
                            .font(.system(size: 14, weight: .medium))
                        Text(AppText.disconnect)
                            .font(.system(size: 15, weight: .medium, design: .rounded))
                    }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .foregroundStyle(.red)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.appSurface)
                )
                .surfaceShadow()
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Helpers

    private func infoRow(label: String, value: String) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(Color.appSecondary)
                .frame(width: 52, alignment: .leading)
            Text(value)
                .font(.system(size: 15))
                .foregroundStyle(Color.appPrimary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
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
            // Silently fail -- providers are informational
        }

        if defaultProvider.isEmpty {
            let configResult = await providersService.loadConfig()
            if let providerID = configResult.defaultProviderID,
               let modelID = configResult.defaultModelID {
                defaultProvider = providerID
                defaultModel = modelID
            }
        }
    }
}
