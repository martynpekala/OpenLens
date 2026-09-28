import SwiftUI
import UIKit

struct SettingsView: View {
    private let repositoryURL = URL(string: "https://github.com/martynpekala/OpenLens")!

    @Environment(\.connection) private var connection
    @Environment(\.liveActivity) private var liveActivity
    @Environment(\.providersService) private var providersService
    @Environment(\.requestReviewPrompt) private var requestReviewPrompt

    @State private var providers: [OCProvider] = []
    @State private var connectedProviders: [String] = []
    @State private var defaultProvider = ""
    @State private var defaultModel = ""
    @State private var isLoadingProviders = false
    @State private var pathInfo: OCPathInfo?
    @State private var agentsCount: Int?
    @State private var commandsCount: Int?
    @State private var diagnosticsExpanded = false
    @State private var showDisconnectConfirmation = false

    @AppStorage(AppPreferenceKeys.showThinking) private var showThinking = true
    @AppStorage(AppPreferenceKeys.hapticsEnabled) private var hapticsEnabled = true
    @AppStorage(AppPreferenceKeys.liveActivitiesEnabled) private var liveActivitiesEnabled = true
    @AppStorage(AppPreferenceKeys.accentColor) private var accentColorHex = ""
    @AppStorage(FeatureFlags.debugFeaturesKey) private var debugFeaturesEnabled = FeatureFlags.debugFeaturesDefault

    var body: some View {
        Form {
            Section(AppText.settingsAppPreferences) {
                Toggle(isOn: $showThinking) {
                    preferenceLabel(AppText.showThinking, subtitle: AppText.showThinkingSubtitle, icon: "brain")
                }
                Toggle(isOn: $hapticsEnabled) {
                    preferenceLabel(AppText.settingsHaptics, subtitle: AppText.settingsHapticsSubtitle, icon: "hand.tap")
                }
                Toggle(isOn: $liveActivitiesEnabled) {
                    preferenceLabel(AppText.settingsLiveActivities, subtitle: AppText.settingsLiveActivitiesSubtitle, icon: "platter.filled.top.iphone")
                }
            }

            Section(AppText.appearance) {
                ColorPicker(
                    AppText.settingsAccentColor,
                    selection: accentColorSelection,
                    supportsOpacity: false
                )
            }

            Section(AppText.settingsOpenCodeDefaults) {
                detailRow(AppText.model, value: defaultModelSummary)
                detailRow(AppText.settingsConnectedProviders, value: connectedProviderSummary)
                detailRow(AppText.settingsAvailableProviders, value: availableProvidersSummary)

                Button {
                    Task { await loadSettingsData() }
                } label: {
                    HStack {
                        Label(AppText.settingsRefreshStatus, systemImage: "arrow.clockwise")
                        Spacer()
                        if isLoadingProviders {
                            ProgressView()
                        }
                    }
                }
            }

            Section(AppText.settingsDiagnostics) {
                DisclosureGroup(isExpanded: $diagnosticsExpanded) {
                    detailRow(AppText.settingsHealth, value: serverStatusText)
                    detailRow(AppText.settingsEvents, value: serverEventsText)
                    detailRow(AppText.version, value: displayValue(connection.serverVersion))
                    detailRow(AppText.settingsConfig, value: displayValue(pathInfo?.config))
                    detailRow(AppText.settingsWorktree, value: displayValue(pathInfo?.worktree ?? connection.selectedProjectDirectory))
                    detailRow(AppText.settingsDirectory, value: displayValue(pathInfo?.directory ?? connection.selectedProjectDirectory))
                    detailRow(AppText.branch, value: displayValue(connection.branch))
                    detailRow(AppText.settingsAgents, value: countText(agentsCount))
                    detailRow(AppText.settingsCommands, value: countText(commandsCount))
                } label: {
                    Label(AppText.settingsDiagnosticsSubtitle, systemImage: "stethoscope")
                }
            }

            Section {
                Link(destination: repositoryURL) {
                    Label(AppText.settingsSupportGitHubCTA, systemImage: "arrow.up.right.square")
                }
                Button {
                    requestReviewPrompt()
                } label: {
                    Label(AppText.settingsSupportReviewCTA, systemImage: "star.bubble.fill")
                }
                detailRow(AppText.settingsApp, value: appVersionBuild)
            } header: {
                Text(AppText.settingsAboutSupport)
            } footer: {
                Text(AppText.settingsSupportBody)
            }

            #if DEBUG
            Section(AppText.developer) {
                Toggle(isOn: $debugFeaturesEnabled) {
                    preferenceLabel(
                        AppText.settingsDebugFeatures,
                        subtitle: AppText.settingsDebugFeaturesSubtitle,
                        icon: "wrench.and.screwdriver"
                    )
                }

                if debugFeaturesEnabled {
                    Button {
                        liveActivity.previewLiveActivity()
                    } label: {
                        Label(AppText.settingsLiveActivityDebugTitle, systemImage: "waveform.path.ecg")
                    }
                    Button {
                        liveActivity.dismissImmediately()
                    } label: {
                        Label(AppText.settingsLiveActivityDismissTitle, systemImage: "xmark.circle")
                    }
                }
            }
            #endif
        }
        .tint(Color.appAccent)
        .navigationTitle(AppText.settings)
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
            ToolbarItem(placement: .topBarTrailing) {
                if showsDisconnectToolbarButton {
                    Button(role: .destructive) {
                        showDisconnectConfirmation = true
                    } label: {
                        Image(systemName: "power")
                    }
                    .accessibilityLabel(AppText.disconnect)
                    .accessibilityHint(AppText.disconnectMessage)
                    .confirmationDialog(
                        AppText.disconnect,
                        isPresented: $showDisconnectConfirmation
                    ) {
                        Button(AppText.disconnect, role: .destructive) {
                            liveActivity.dismissImmediately()
                            connection.manualDisconnect()
                        }
                        Button(AppText.done, role: .cancel) {}
                    } message: {
                        Text(AppText.disconnectMessage)
                    }
                }
            }
        }
    }

    private func preferenceLabel(_ title: String, subtitle: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func detailRow(_ title: String, value: String) -> some View {
        LabeledContent(title) {
            Text(value)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var accentColorSelection: Binding<Color> {
        Binding(
            get: {
                guard let value = UInt32(accentColorHex, radix: 16), accentColorHex.count == 6 else {
                    return Color.appAccent
                }
                return Color(
                    red: Double((value >> 16) & 0xFF) / 255,
                    green: Double((value >> 8) & 0xFF) / 255,
                    blue: Double(value & 0xFF) / 255
                )
            },
            set: { color in
                var red: CGFloat = 0
                var green: CGFloat = 0
                var blue: CGFloat = 0
                var alpha: CGFloat = 0
                guard UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
                    return
                }
                accentColorHex = String(
                    format: "%02X%02X%02X",
                    Int((red * 255).rounded()),
                    Int((green * 255).rounded()),
                    Int((blue * 255).rounded())
                )
            }
        )
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
