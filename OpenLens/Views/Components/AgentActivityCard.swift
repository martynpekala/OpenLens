import SwiftUI

/// Detail card shown when tapping the thinking shimmer.
/// Displays thinking text and a timeline of tool steps.
struct AgentActivityCard: View {
    let activity: AgentActivity
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if !activity.thinkingText.isEmpty {
                        thinkingSection
                    }

                    if !activity.steps.isEmpty {
                        stepsSection
                    }

                    if activity.thinkingText.isEmpty && activity.steps.isEmpty {
                        Text(AppText.activityEmpty)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 40)
                    }
                }
                .padding(16)
            }
            .navigationTitle(AppText.activityTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppText.done) { dismiss() }
                }
            }
        }
    }

    private var thinkingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(AppText.activityThinking, systemImage: "brain.head.profile")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)

            Text(activity.thinkingText)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Color(.systemGray))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private var stepsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(AppText.activitySteps(activity.steps.count), systemImage: "list.bullet")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)

            ForEach(activity.steps) { step in
                stepRow(step)
            }
        }
    }

    private func stepRow(_ step: ActivityStep) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: step.isCompleted ? "checkmark.circle.fill" : step.toolCategory.iconName)
                .font(.system(size: 12))
                .foregroundStyle(step.isCompleted ? .green : .gray)
                .frame(width: 20, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(step.label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)

                if !step.detail.isEmpty && step.type == .toolCall {
                    Text(step.detail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Text(step.timestamp, style: .time)
                    .font(.system(size: 10))
                    .foregroundStyle(Color(.systemGray3))
            }
        }
        .padding(.vertical, 2)
    }
}
