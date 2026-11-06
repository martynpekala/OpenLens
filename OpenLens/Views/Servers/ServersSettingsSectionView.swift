import SwiftUI

/// Settings entry for servers. With one saved server it is a plain row naming it (no status dot,
/// no list); the Servers screen behind it is how a second gets added.
struct ServersSettingsSectionView: View {
    @Environment(\.serverRegistry) private var registry

    var body: some View {
        let contexts = registry.savedServerContexts
        if let only = contexts.first, !isMultiServerUIEnabled(savedServerCount: contexts.count),
           let profile = registry.profile(for: only)
        {
            Section {
                NavigationLink(value: RouterDestination.servers) {
                    singleServerLabel(profile)
                }
            } header: {
                Text(AppText.servers)
            } footer: {
                Text(AppText.serversSettingsFooter)
            }
        } else if !contexts.isEmpty {
            Section {
                NavigationLink(value: RouterDestination.servers) {
                    LabeledContent(AppText.servers) {
                        Text(AppText.serversCount(contexts.count))
                            .monospacedDigit()
                    }
                }
            }
        }
    }

    private func singleServerLabel(_ profile: SavedConnection) -> some View {
        let host = connectionServerDisplayName(profile.serverURL) ?? profile.serverURL
        let nickname = profile.nickname?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank

        return VStack(alignment: .leading, spacing: 2) {
            if let nickname {
                Text(nickname)
                Text(host)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text(host)
                    .font(.system(size: 15, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}
