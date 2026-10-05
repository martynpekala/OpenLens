import SwiftUI
import UIKit

struct SettingsView: View {
    private let repositoryURL = URL(string: "https://github.com/martynpekala/OpenLens")!

    @Environment(\.connection) private var connection
    @Environment(\.liveActivity) private var liveActivity
    @Environment(\.requestReviewPrompt) private var requestReviewPrompt
    @Environment(\.gitHubStarsService) private var gitHubStars

    @State private var showDisconnectConfirmation = false

    @AppStorage(AppPreferenceKeys.showThinking) private var showThinking = true
    @AppStorage(AppPreferenceKeys.autoReconnect) private var autoReconnect = true
    @AppStorage(AppPreferenceKeys.hapticsEnabled) private var hapticsEnabled = true
    @AppStorage(AppPreferenceKeys.liveActivitiesEnabled) private var liveActivitiesEnabled = true
    private let accentColor = AccentColorPreference.shared
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
                Toggle(isOn: $autoReconnect) {
                    preferenceLabel(AppText.autoReconnect, subtitle: AppText.autoReconnectSubtitle, icon: "arrow.triangle.2.circlepath")
                }
            }
            .tint(Color.appUserAccent)

            Section(AppText.appearance) {
                ColorPicker(
                    AppText.settingsAccentColor,
                    selection: accentColor.binding,
                    supportsOpacity: false
                )
                if accentColor.hasCustomColor {
                    Button(AppText.settingsAccentColorReset, role: .destructive) {
                        accentColor.reset()
                    }
                }
            }

            Section {
                if gitHubStars.state != .failed {
                    starGoalRow
                }
                Link(destination: repositoryURL) {
                    Label(AppText.settingsSupportGitHubCTA, systemImage: "arrow.up.right.square")
                }
                .tint(Color.appUserAccent)
                Button {
                    requestReviewPrompt()
                } label: {
                    Label(AppText.settingsSupportReviewCTA, systemImage: "star.bubble.fill")
                }
            } header: {
                Text(AppText.settingsAboutSupport)
            }

            Text(appVersionBuild)

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

            if showsDisconnectToolbarButton {
                Section {
                    Button(role: .destructive) {
                        showDisconnectConfirmation = true
                    } label: {
                        HStack {
                            Spacer()
                            Text(AppText.disconnect)
                            Spacer()
                        }
                    }
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
        .navigationBarTitleDisplayMode(.inline)
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        .onChange(of: liveActivitiesEnabled) { _, enabled in
            if !enabled {
                liveActivity.dismissImmediately()
            }
        }
        .task {
            await gitHubStars.refresh()
        }
    }

    private var starGoalRow: some View {
        let isLoaded = gitHubStars.starCount != nil
        let count = gitHubStars.starCount ?? 0

        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(AppText.settingsStarGoalTitle, systemImage: "star.fill")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(AppText.settingsStarGoalProgress(count, goal: gitHubStars.goal))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: gitHubStars.progress)
                    .tint(Color.appUserAccent)
            }
            .redacted(reason: isLoaded ? [] : .placeholder)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(AppText.settingsStarGoalTitle)
            .accessibilityValue(isLoaded ? AppText.settingsStarGoalProgress(count, goal: gitHubStars.goal) : "")

            Text(AppText.settingsStarGoalBody(goal: gitHubStars.goal))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
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

    private var showsDisconnectToolbarButton: Bool {
        switch connection.state {
        case .connected, .reconnecting, .connecting:
            true
        case .disconnected, .error:
            false
        }
    }

    private var appVersionBuild: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        guard let build, !build.isEmpty, build != version else {
            return version
        }
        return "Version \(version) (\(build))"
    }
}
