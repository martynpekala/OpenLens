import SwiftUI

/// Names the server a group belongs to. Identity, not status: no dot and no semantic fill,
/// because the switcher and the Servers screen already own status.
///
/// A nickname is a name, so it is set in the rounded caption face; a host is data, so it is
/// monospaced like every other host in the app.
struct ServerBadge: View {
    let tag: ServerTag

    var body: some View {
        Text(tag.text)
            .font(font)
            .foregroundStyle(Color.appSecondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .accessibilityLabel(AppText.serverBadgeAccessibility(tag.text))
    }

    private var font: Font {
        switch tag.kind {
        case .nickname: .system(size: 12, design: .rounded)
        case .host: .system(size: 12, design: .monospaced)
        }
    }
}
