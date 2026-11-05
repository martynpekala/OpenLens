import SwiftUI

/// Toolbar title for the Workspace tab: the active project name inside a glass
/// capsule. When several projects are available the capsule doubles as the label
/// of a project picker menu, so it shows a chevron and reacts to touches.
struct WorkspaceProjectTitleCapsule: View {
    let title: String
    /// Set only while several servers are saved; shown before the workspace, never instead of it.
    var serverTag: ServerTag?
    let isSwitching: Bool
    let isSelectable: Bool

    var body: some View {
        GlassToolbarCapsule(isInteractive: isSelectable) {
            if let serverTag {
                // Context, so it gives way first: it is the server that truncates, never the workspace.
                ServerBadge(tag: serverTag, size: 15, truncation: .tail)
                    .layoutPriority(-1)
                Text("\u{00B7}")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.appSecondary)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.appPrimary)
                .lineLimit(1)
                .truncationMode(.middle)

            if isSwitching {
                ProgressView()
                    .controlSize(.mini)
            } else if isSelectable {
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.appSecondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(AppText.workspaceProjectAccessibilityLabel(
            serverTag.map { "\($0.text) · \(title)" } ?? title
        ))
        .accessibilityHint(isSelectable ? AppText.workspaceProjectHint : "")
    }
}
