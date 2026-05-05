import SwiftUI

/// Chat message bubble view, styled differently for user vs assistant messages.
///
/// Uses a dual-render strategy for assistant messages:
/// - **Streaming** (`isStreaming == true`): plain `Text` — zero markdown parsing cost.
/// - **Completed** (`isStreaming == false`): `MarkdownContentView` — one-time parse.
struct MessageBubbleView: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if message.role == .user {
                Spacer(minLength: 64)
                userBubble
            } else {
                assistantBubble
                Spacer(minLength: 32)
            }
        }
    }

    // MARK: - User Bubble

    private var userBubble: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(message.content)
                .font(.system(size: 16))
                .foregroundStyle(Color.appOnAccent)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.appAccent)
                )
        }
    }

    // MARK: - Assistant Bubble

    private var assistantBubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(message.assistantSegments) { segment in
                segmentView(segment)
            }

            if message.isStreaming,
               !message.parts.contains(where: { $0.type == .text && $0.text?.nilIfBlank != nil }),
               let text = message.content.nilIfBlank {
                assistantTextBubble(text)
            }

            if let cost = message.cost, cost > 0 {
                Text(String(format: "$%.4f", cost))
                    .font(.system(size: 11))
                    .foregroundStyle(Color.appSecondary.opacity(0.5))
            }
        }
    }

    // MARK: - Segments

    @ViewBuilder
    private func segmentView(_ segment: ChatMessage.AssistantSegment) -> some View {
        switch segment.kind {
        case .text(let text):
            assistantTextBubble(text)
        case .reasoning(let text, let todoItems):
            reasoningSegment(text: text, todoItems: todoItems)
        case .tool(let step):
            toolSegment(step)
        }
    }

    private func assistantTextBubble(_ text: String) -> some View {
        Group {
            if message.isStreaming {
                Text(text)
                    .font(.system(size: 16))
                    .foregroundStyle(Color.appPrimary)
            } else {
                MarkdownContentView(text, foregroundColor: Color.appPrimary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.appSurface)
        )
        .surfaceShadow()
        .animation(nil, value: text)
    }

    private func reasoningSegment(text: String, todoItems: [TodoListCardView.Item]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if todoItems.count >= 2 {
                TodoListCardView(title: "Todos", items: todoItems)
            } else {
                Label("Thinking", systemImage: "brain.head.profile")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.appSecondary.opacity(0.8))

                Text(text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.appSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.appSurface)
                    )
            }
        }
        .padding(.leading, 4)
    }

    private func toolSegment(_ step: ChatMessage.PersistedToolStep) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: step.isError ? "exclamationmark.circle" : step.toolCategory.iconName)
                .font(.system(size: 10))
                .foregroundStyle(step.isError ? .orange : Color.appSecondary.opacity(0.6))

            VStack(alignment: .leading, spacing: 4) {
                Text(step.label)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.appSecondary.opacity(0.85))
                    .lineLimit(2)

                if !step.detail.isEmpty {
                    Text(step.detail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.appSecondary.opacity(0.65))
                        .lineLimit(3)
                }

                if step.todoItems.count >= 2 {
                    TodoListCardView(title: "Todos", items: step.todoItems)
                } else if let output = step.output {
                    Text(output)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.appSecondary.opacity(0.6))
                        .lineLimit(4)
                }
            }
        }
        .padding(.leading, 4)
    }
}
