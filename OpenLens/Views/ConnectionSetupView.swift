import SwiftUI

enum ConnectionSetupDestination: Hashable {
    case pairingInstructions
    case scanner
    case manual
}

struct ConnectionWelcomeView: View {
    let onContinue: () -> Void
    let onManualConnection: () -> Void

    var body: some View {
        ConnectionSetupPage {
            VStack(spacing: 32) {
                ConnectionSetupHeading(
                    systemImage: "macbook.and.iphone",
                    title: AppText.connectionSetupTitle,
                    subtitle: AppText.connectionSetupSubtitle
                )

                VStack(alignment: .leading, spacing: 24) {
                    ConnectionSetupDetail(
                        systemImage: "terminal",
                        text: AppText.connectionSetupOpenCodeDetail
                    )
                    ConnectionSetupDetail(
                        systemImage: "wifi",
                        text: AppText.connectionSetupNetworkDetail
                    )
                }
            }
        } actions: {
            ConnectionSetupButton(
                title: AppText.connectionSetupContinue,
                action: onContinue
            )
            .accessibilityIdentifier("connection.setup.continue")

            ConnectionSetupButton(
                title: AppText.connectionSetupV1,
                isPrimary: false,
                action: onManualConnection
            )
            .accessibilityHint(AppText.connectionSetupV1Hint)
            .accessibilityIdentifier("connection.setup.v1")
        }
    }
}

struct OpenCodePairingInstructionsView: View {
    let onScan: () -> Void

    var body: some View {
        ConnectionSetupPage {
            VStack(spacing: 24) {
                ConnectionSetupHeading(
                    systemImage: "desktopcomputer",
                    title: AppText.connectionPairingTitle,
                    subtitle: AppText.connectionPairingBody
                )

                Text("opencode pair")
                    .font(.system(size: 20, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.appPrimary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 18)
                    .frame(maxWidth: .infinity)
                    .background(Color.appTertiary, in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityLabel("Terminal command: opencode pair")

                Text(AppText.connectionPairingHint)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.appSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            ConnectionSetupButton(title: AppText.connectionPairingScan, action: onScan)
                .accessibilityIdentifier("connection.setup.scan")
        }
    }
}

struct ConnectionPairingScannerView: View {
    let isActive: Bool
    let onScanned: (ScannedOpenLensCode) -> Void
    let onManualPairing: () -> Void

    @State private var isVisible = false

    var body: some View {
        ConnectionSetupPage {
            VStack(spacing: 24) {
                QRCodeCameraView(isActive: isActive && isVisible, onScanned: onScanned)
                    .frame(width: 260, height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))

                Text(AppText.connectionScanTitle)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.appPrimary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Text(AppText.connectionScanBody)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.appSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            ConnectionSetupButton(
                title: AppText.connectionPairManually,
                isPrimary: false,
                action: onManualPairing
            )
            .accessibilityIdentifier("connection.setup.manual")
        }
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
    }
}

private struct ConnectionSetupPage<Content: View, Actions: View>: View {
    private let content: Content
    private let actions: Actions

    init(@ViewBuilder content: () -> Content, @ViewBuilder actions: () -> Actions) {
        self.content = content()
        self.actions = actions()
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 32)
                    content
                        .frame(maxWidth: 340)
                    Spacer(minLength: 32)
                }
                .padding(.horizontal, 28)
                .frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 12) {
                actions
            }
                .frame(maxWidth: 340)
                .padding(.horizontal, 28)
                .padding(.top, 16)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity)
                .background(Color.appBackground)
        }
        .background(Color.appBackground)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ConnectionSetupHeading: View {
    let systemImage: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 42, weight: .regular))
                .foregroundStyle(Color.appPrimary)
                .padding(.bottom, 12)
                .accessibilityHidden(true)

            Text(title)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.appPrimary)
                .accessibilityAddTraits(.isHeader)
                .fixedSize(horizontal: false, vertical: true)

            Text(subtitle)
                .font(.system(size: 15))
                .foregroundStyle(Color.appSecondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .multilineTextAlignment(.center)
    }
}

private struct ConnectionSetupDetail: View {
    let systemImage: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 21))
                .foregroundStyle(Color.appSecondary)
                .frame(width: 28)
                .accessibilityHidden(true)

            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(Color.appSecondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ConnectionSetupButton: View {
    let title: String
    var isPrimary = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .multilineTextAlignment(.center)
                .foregroundStyle(isPrimary ? Color.appOnAccent : Color.appPrimary)
                .frame(maxWidth: .infinity, minHeight: 20)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .background(isPrimary ? Color.appAccent : Color.clear, in: Capsule())
                .overlay {
                    if !isPrimary {
                        Capsule().stroke(Color.appSeparator, lineWidth: 1)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

#Preview("Connect to your computer") {
    NavigationStack {
        ConnectionWelcomeView(onContinue: {}, onManualConnection: {})
    }
}

#Preview("Get a pairing code") {
    NavigationStack {
        OpenCodePairingInstructionsView(onScan: {})
    }
}
