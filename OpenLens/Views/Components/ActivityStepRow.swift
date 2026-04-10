import SwiftUI

/// Inline row for a completed activity step.
struct ActivityStepRow: View {
    let step: ActivityStep
    var onTap: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: step.isCompleted ? "checkmark.circle.fill" : step.toolCategory.iconName)
                .font(.system(size: 11))
                .foregroundStyle(step.isCompleted ? Color.appSecondary.opacity(0.4) : Color.appSecondary.opacity(0.6))
                .frame(width: 16)

            Text(step.label)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(Color.appSecondary.opacity(0.7))
                .lineLimit(1)

            Spacer()
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }
}
