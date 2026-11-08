import SwiftUI

/// The What's New sheet: release highlights, newest release first.
struct WhatsNewView: View {
    let releases: [ReleaseHighlights]

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    ForEach(releases) { release in
                        releaseSection(release)
                    }
                }
                .padding(28)
                .frame(maxWidth: 440, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(Color.appBackground)
            .navigationTitle(AppText.whatsNewTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .close) { dismiss() }
                        .accessibilityIdentifier("whatsNew.close")
                }
            }
        }
        .accessibilityIdentifier("whatsNew")
    }

    private func releaseSection(_ release: ReleaseHighlights) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            if releases.count > 1 {
                Text(AppText.whatsNewVersion(release.version))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.appSecondary)
                    .textCase(.uppercase)
                    .accessibilityAddTraits(.isHeader)
            }

            ForEach(release.highlights) { highlight in
                ConnectionSetupDetail(
                    systemImage: highlight.systemImage,
                    title: highlight.title,
                    text: highlight.text,
                    badge: highlight.requiresOpenCodeV2 ? AppText.whatsNewOpenCodeV2Badge : nil
                )
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// Wraps the releases a What's New sheet presents, so it can drive `.sheet(item:)`.
struct WhatsNewPresentation: Identifiable {
    let id = UUID()
    let releases: [ReleaseHighlights]
}

#Preview {
    WhatsNewView(releases: ReleaseHighlights.catalog)
}
