import SwiftUI

/// Explains OpenCode v2 support; presented by the `openlens://setup` link while connected.
struct OpenCodeV2SupportView: View {
    let serverCapabilities: OpenCodeServerCapabilities?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    ConnectionSetupHeading(
                        systemImage: "sparkles",
                        title: AppText.openCodeV2SupportTitle,
                        subtitle: AppText.openCodeV2SupportSubtitle
                    )
                    .frame(maxWidth: .infinity)

                    if let serverCapabilities {
                        serverStatus(serverCapabilities)
                    }
                }
                .padding(28)
                .frame(maxWidth: 440, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(Color.appBackground)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .close) { dismiss() }
                        .accessibilityIdentifier("openCodeV2Support.close")
                }
            }
        }
        .accessibilityIdentifier("openCodeV2Support")
    }

    private func serverStatus(_ capabilities: OpenCodeServerCapabilities) -> some View {
        let isV2 = capabilities.protocolVersion == .v2
        let guidance = isV2 ? AppText.openCodeV2SupportServerV2Detail : AppText.openCodeV2SupportServerV1Detail
        let version = capabilities.serverVersion?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank

        return ConnectionSetupDetail(
            systemImage: isV2 ? "checkmark.circle" : "arrow.up.circle",
            title: isV2 ? AppText.openCodeV2SupportServerV2Title : AppText.openCodeV2SupportServerV1Title,
            text: version.map { "\(AppText.openCodeServerVersion($0)) \(guidance)" } ?? guidance
        )
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.appSeparator, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("openCodeV2Support.serverStatus")
    }
}

#Preview("v2 server") {
    OpenCodeV2SupportView(serverCapabilities: .v2(OCV2ServerInfo(version: "2.0.22")))
}

#Preview("v1 server") {
    OpenCodeV2SupportView(serverCapabilities: .v1(OCHealthResponse(healthy: true, version: "1.2.27")))
}
