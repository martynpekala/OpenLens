import SwiftUI

/// Settings section for provider coding-plan usage limits: configures the
/// quota API key and region, then shows remaining usage per window with the
/// reset moment as the focal point of each row.
struct UsageQuotaSectionView: View {
    @Environment(\.usageQuotaService) private var usageQuota

    @State private var apiKeyDraft = ""
    @State private var region = UsageQuotaService.storedRegion()
    @State private var isKeyConfigured = UsageQuotaService.storedAPIKey() != nil
        || ScreenshotFixtures.usageQuotaScenario != nil

    var body: some View {
        Section {
            Picker(selection: $region) {
                ForEach(UsageQuotaService.Region.allCases) { candidate in
                    Text(candidate.displayName).tag(candidate)
                }
            } label: {
                preferenceLabel(AppText.settingsUsageRegion, icon: "globe")
            }
            .onChange(of: region) { _, newValue in
                UsageQuotaService.storeRegion(newValue)
                Task { await usageQuota.refresh(force: true) }
            }

            SecureField(
                AppText.settingsUsageAPIKey,
                text: $apiKeyDraft,
                prompt: Text(
                    isKeyConfigured
                        ? String(repeating: "•", count: 8)
                        : AppText.settingsUsageAPIKeyPlaceholder
                )
            )
            .onSubmit(saveAPIKey)

            if !apiKeyDraft.isEmpty {
                Button(action: saveAPIKey) {
                    Label(AppText.saveAPIKey, systemImage: "checkmark.circle")
                }
                .tint(Color.appUserAccent)
            } else if isKeyConfigured {
                Button(role: .destructive, action: removeAPIKey) {
                    Label(AppText.settingsUsageRemoveKey, systemImage: "key.slash")
                }
            }

            statusRows

            Button {
                Task { await usageQuota.refresh(force: true) }
            } label: {
                Label(AppText.settingsUsageRefresh, systemImage: "arrow.clockwise")
            }
            .tint(Color.appUserAccent)
            .disabled(!isKeyConfigured)
        } header: {
            Text(AppText.settingsUsageLimits)
        } footer: {
            if !isKeyConfigured {
                Text(AppText.settingsUsageNoKey)
            }
        }
        .task {
            guard ScreenshotFixtures.usageQuotaScenario == nil else { return }
            await usageQuota.refresh()
        }
    }

    // MARK: - Status

    @ViewBuilder
    private var statusRows: some View {
        switch usageQuota.state {
        case .idle:
            EmptyView()
        case .loading:
            VStack(alignment: .leading, spacing: 8) {
                ForEach(0..<2, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("5-Hour Window").font(.subheadline)
                        ProgressView(value: 0.5).tint(Color.appUserAccent)
                    }
                    .redacted(reason: .placeholder)
                }
            }
            .padding(.vertical, 4)
        case .loaded(let snapshot):
            if let planName = snapshot.planName, !planName.isEmpty {
                LabeledContent(AppText.settingsUsagePlan) {
                    Text(planName)
                }
            }
            ForEach(snapshot.windows) { window in
                QuotaWindowRow(window: window)
            }
        case .keyRejected:
            Label {
                Text(AppText.settingsUsageKeyRejected)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(.footnote)
            .foregroundStyle(.orange)
            .padding(.vertical, 2)
        case .noLimitsReported:
            Label {
                Text(AppText.settingsUsageNoLimits)
            } icon: {
                Image(systemName: "info.circle")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.vertical, 2)
        case .failed(let message):
            Label {
                Text(AppText.settingsUsageFailed + " " + message)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.vertical, 2)
        }
    }

    // MARK: - Actions

    private func saveAPIKey() {
        let trimmed = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        UsageQuotaService.storeAPIKey(trimmed)
        apiKeyDraft = ""
        isKeyConfigured = true
        Task { await usageQuota.refresh(force: true) }
    }

    private func removeAPIKey() {
        UsageQuotaService.storeAPIKey("")
        isKeyConfigured = false
        apiKeyDraft = ""
        usageQuota.reset()
    }

    private func preferenceLabel(_ title: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .frame(width: 24)
            Text(title)
        }
    }
}

/// One plan window: title and percentage lead, the bar shows progress, and
/// the reset moment ticks underneath.
private struct QuotaWindowRow: View {
    let window: UsageQuotaService.QuotaWindow

    private var barTint: Color {
        switch window.percentage {
        case ..<70: Color.appUserAccent
        case ..<90: .orange
        default: .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.title)
                    .font(.subheadline)
                Spacer()
                Text("\(window.percentage)%")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                Text(AppText.settingsUsagePercentUsed)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: Double(window.percentage) / 100)
                .tint(barTint)
            if let resetAt = window.resetAt {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(AppText.usageLimitResetsAt(resetAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
