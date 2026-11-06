import SwiftUI

/// Names the server a group belongs to. Identity, not status: no dot and no semantic fill,
/// because the switcher and the Servers screen already own status.
///
/// A nickname is a name, so it is set in the rounded caption face; a host is data, so it is
/// monospaced like every other host in the app.
struct ServerBadge: View {
    let tag: ServerTag
    var color: Color = Color.appSecondary
    var size: CGFloat = 12
    /// Where to cut when the badge has to truncate. A group header has the width to spare and
    /// middle-truncates like every other host in the app, keeping both ends. A toolbar capsule
    /// is sharing 240pt with the workspace it qualifies, and middle truncation there keeps the
    /// port while discarding the hostname -- "macb…4096" names no machine. Tail truncation keeps
    /// the part that actually tells two machines apart.
    var truncation: Text.TruncationMode = .middle

    var body: some View {
        Text(tag.text)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(truncation)
            .accessibilityLabel(AppText.serverBadgeAccessibility(tag.text))
    }

    private var font: Font {
        switch tag.kind {
        case .nickname: .system(size: size, design: .rounded)
        case .host: .system(size: size, design: .monospaced)
        }
    }
}
