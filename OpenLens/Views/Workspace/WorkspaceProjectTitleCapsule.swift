import SwiftUI

/// Toolbar title for the Workspace tab: the active project name inside a glass
/// capsule. When several projects are available the capsule doubles as the label
/// of a project picker menu, so it shows a chevron and reacts to touches.
struct WorkspaceProjectTitleCapsule: View {
    let title: String
    let isSwitching: Bool
    let isSelectable: Bool

    var body: some View {
        HStack(spacing: 6) {
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
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(maxWidth: 240)
        .glassEffect(isSelectable ? .regular.interactive() : .regular, in: Capsule())
        .contentShape(Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Project, \(title)")
        .accessibilityHint(isSelectable ? "Choose another project" : "")
    }
}
