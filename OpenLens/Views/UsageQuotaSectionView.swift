import SwiftUI

/// Settings section showing provider coding-plan usage limits. The z.ai key
/// is read automatically from the connected OpenCode server (v2); there is no
/// manual key entry. Per-window rows lead with the percentage and reset
/// moment.
struct UsageQuotaSectionView: View {
    @Environment(\.usageQuotaService) private var usageQuota
    @Environment(\.connection) private var connection

    @State private var isKeyConfigured = UsageQuotaService.storedAPIKey() != nil
        || ScreenshotFixtures.usageQuotaScenario != nil
    @State private var importFailureMessage: String?
    @State private var isBootstrapping = false

    private var isConnected: Bool {
        connection.client != nil
    }

    var body: some View {
        Section {
            if isKeyConfigured {
                statusRows

                Button {
                    Task { await refreshNow() }
                } label: {
                    Label(AppText.settingsUsageRefresh, systemImage: "arrow.clockwise")
                }
                .tint(Color.appUserAccent)
            } else {
                unavailableRows
            }
        } header: {
            Text(AppText.settingsUsageLimits)
        } footer: {
            Text(AppText.settingsUsageZaiOnlyFooter)
        }
        .task {
            guard ScreenshotFixtures.usageQuotaScenario == nil else { return }
            await bootstrap()
        }
    }

    // MARK: - Status

    @ViewBuilder
    private var statusRows: some View {
        switch usageQuota.state {
        case .idle, .loading:
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

    /// Why usage limits cannot be shown right now.
    @ViewBuilder
    private var unavailableRows: some View {
        if isBootstrapping {
            VStack(alignment: .leading, spacing: 6) {
                Text(AppText.settingsUsageReadingKey)
                    .font(.subheadline)
                    .redacted(reason: .placeholder)
            }
            .padding(.vertical, 4)
        } else if let importFailureMessage {
            Label {
                Text(importFailureMessage)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.vertical, 2)
        } else if !isConnected {
            Label {
                Text(AppText.settingsUsageImportNoServer)
            } icon: {
                Image(systemName: "plug.slash")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.vertical, 2)
        }
    }

    // MARK: - Actions

    /// Reads the z.ai key from the connected server (when needed), then
    /// refreshes the quota snapshot. Runs automatically when the section
    /// appears and from the Refresh button.
    private func bootstrap() async {
        if !isKeyConfigured, isConnected {
            await importKeyFromServer()
        }
        if isKeyConfigured {
            await usageQuota.refresh()
        }
    }

    private func refreshNow() async {
        if !isKeyConfigured, isConnected {
            await importKeyFromServer()
        }
        if isKeyConfigured {
            await usageQuota.refresh(force: true)
        }
    }

    /// Pulls the z.ai key from the connected OpenCode server's credential
    /// store. v2 servers only.
    private func importKeyFromServer() async {
        guard let client = connection.client else {
            importFailureMessage = AppText.settingsUsageImportNoServer
            return
        }
        isBootstrapping = true
        defer { isBootstrapping = false }

        do {
            let entries = try await client.getCredentialEntries()
            guard let entry = UsageQuotaService.supportedKeyEntry(in: entries) else {
                importFailureMessage = AppText.settingsUsageImportNotFound
                return
            }
            usageQuota.importKey(from: entry)
            isKeyConfigured = true
            importFailureMessage = nil
        } catch OpenCodeError.invalidPayload {
            importFailureMessage = AppText.settingsUsageImportUnsupported
        } catch {
            importFailureMessage = AppText.settingsUsageImportFailed
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
