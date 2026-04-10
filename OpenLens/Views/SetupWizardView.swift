import SwiftUI

/// Interactive setup wizard that guides users through connecting to an OpenCode server.
/// Presented as a sheet from ConnectView.
struct SetupWizardView: View {
    var onScanQR: () -> Void
    var onManualEntry: () -> Void
    var onBonjourScan: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var step: WizardStep = .serverCheck

    private enum WizardStep {
        case serverCheck
        case installGuide
        case connectionMethod
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    switch step {
                    case .serverCheck:
                        serverCheckContent
                    case .installGuide:
                        installGuideContent
                    case .connectionMethod:
                        connectionMethodContent
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 28)
            }
            .background(Color.appBackground)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.appSecondary)
                    }
                }

                ToolbarItem(placement: .topBarLeading) {
                    if step != .serverCheck {
                        Button {
                            withAnimation { step = .serverCheck }
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color.appPrimary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Step 1: Server Check

    private var serverCheckContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            stepIcon("server.rack", color: Color.appPrimary)

            Text(AppText.serverCheckTitle)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(Color.appPrimary)

            Text(AppText.serverCheckBody)
                .font(.system(size: 16, design: .rounded))
                .foregroundStyle(Color.appPrimary.opacity(0.85))
                .lineSpacing(4)

            VStack(spacing: 12) {
                wizardButton(
                    title: AppText.serverCheckYes,
                    subtitle: AppText.serverCheckYesSubtitle,
                    icon: "checkmark.circle.fill",
                    isPrimary: true
                ) {
                    withAnimation { step = .connectionMethod }
                }

                wizardButton(
                    title: AppText.serverCheckNo,
                    subtitle: AppText.serverCheckNoSubtitle,
                    icon: "arrow.down.circle",
                    isPrimary: false
                ) {
                    withAnimation { step = .installGuide }
                }
            }
        }
    }

    // MARK: - Step 1b: Install Guide

    private var installGuideContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            stepIcon("terminal", color: Color.appPrimary)

            Text(AppText.wizardInstallTitle)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(Color.appPrimary)

            Text(AppText.wizardInstallBody)
                .font(.system(size: 16, design: .rounded))
                .foregroundStyle(Color.appPrimary.opacity(0.85))
                .lineSpacing(4)

            commandCard("npm install -g opencode")

            Text(AppText.wizardInstallRunTitle)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.appPrimary)

            Text(AppText.wizardInstallRunBody)
                .font(.system(size: 16, design: .rounded))
                .foregroundStyle(Color.appPrimary.opacity(0.85))
                .lineSpacing(4)

            commandCard("opencode")

            SurfaceCard {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "lightbulb")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.appSecondary)
                        .padding(.top, 1)
                    Text(AppText.wizardInstallHint)
                        .font(.system(size: 13, design: .rounded))
                        .foregroundStyle(Color.appSecondary)
                        .lineSpacing(3)
                }
            }

            wizardButton(
                title: AppText.wizardInstallReady,
                subtitle: nil,
                icon: "arrow.right",
                isPrimary: true
            ) {
                withAnimation { step = .connectionMethod }
            }
        }
    }

    // MARK: - Step 2: Connection Method

    private var connectionMethodContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            stepIcon("link", color: Color.appPrimary)

            Text(AppText.wizardConnectTitle)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(Color.appPrimary)

            Text(AppText.wizardConnectBody)
                .font(.system(size: 16, design: .rounded))
                .foregroundStyle(Color.appPrimary.opacity(0.85))
                .lineSpacing(4)

            VStack(spacing: 12) {
                wizardButton(
                    title: AppText.wizardConnectQR,
                    subtitle: AppText.wizardConnectQRSubtitle,
                    icon: "qrcode.viewfinder",
                    isPrimary: true
                ) {
                    onScanQR()
                }

                wizardButton(
                    title: AppText.wizardConnectBonjour,
                    subtitle: AppText.wizardConnectBonjourSubtitle,
                    icon: "wifi",
                    isPrimary: false
                ) {
                    onBonjourScan()
                }

                wizardButton(
                    title: AppText.wizardConnectManual,
                    subtitle: AppText.wizardConnectManualSubtitle,
                    icon: "keyboard",
                    isPrimary: false
                ) {
                    onManualEntry()
                }
            }

            // QR generation tip
            SurfaceCard {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "qrcode")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.appSecondary)
                        Text(AppText.wizardConnectQRTipTitle)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.appSecondary)
                    }
                    Text(AppText.wizardConnectQRTipBody)
                        .font(.system(size: 13, design: .rounded))
                        .foregroundStyle(Color.appSecondary)
                        .lineSpacing(3)

                    commandCard("OPENLENS_QR_PASSWORD=mySecret Tools/openlens-qr/.build/release/openlens-qr --serve")
                }
            }
        }
    }

    // MARK: - Reusable Components

    private func stepIcon(_ systemName: String, color: Color) -> some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.appTertiary)
            .frame(width: 56, height: 56)
            .overlay {
                Image(systemName: systemName)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(color)
            }
    }

    private func wizardButton(
        title: String,
        subtitle: String?,
        icon: String,
        isPrimary: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(isPrimary ? Color.appOnAccent : Color.appPrimary)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(isPrimary ? Color.appOnAccent : Color.appPrimary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 13, design: .rounded))
                            .foregroundStyle(isPrimary ? Color.appOnAccent.opacity(0.7) : Color.appSecondary)
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isPrimary ? Color.appOnAccent.opacity(0.5) : Color.appSecondary.opacity(0.4))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isPrimary ? Color.appAccent : Color.appSurface)
            )
            .surfaceShadow()
        }
        .buttonStyle(.plain)
    }

    private func commandCard(_ command: String) -> some View {
        HStack {
            Text(command)
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(Color.appPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Spacer()

            Button {
                UIPasteboard.general.string = command
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.appSecondary)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.appTertiary)
        )
    }
}
