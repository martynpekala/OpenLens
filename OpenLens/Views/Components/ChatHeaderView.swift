import SwiftUI

/// Navigation bar toolbar content for the chat view.
struct ChatHeaderToolbar: ToolbarContent {
    let projectName: String?
    let branch: String?
    let connectionState: ConnectionManager.State
    let sessionTitle: String?
    let showsRecordingControls: Bool
    let isRecordingStream: Bool
    let visualMode: ChatVisualMode
    let onToggleRecording: (() -> Void)?

    private var statusColor: Color {
        if visualMode.isRetro {
            switch connectionState {
            case .connected: return RetroChatStyle.blueAccent
            case .reconnecting, .connecting: return RetroChatStyle.magentaAccent
            case .disconnected: return RetroChatStyle.mutedInk.opacity(0.7)
            case .error: return RetroChatStyle.danger
            }
        }

        switch connectionState {
        case .connected: return .green
        case .reconnecting, .connecting: return .orange
        case .disconnected, .error: return Color.gray.opacity(0.5)
        }
    }

    private var statusText: String {
        switch connectionState {
        case .connected: AppText.statusConnected
        case .reconnecting: AppText.statusReconnecting
        case .connecting: AppText.statusConnecting
        case .disconnected: AppText.statusOffline
        case .error: AppText.statusError
        }
    }

    private var recordingLabel: String {
        isRecordingStream ? AppText.recordingStop : AppText.recordingStart
    }

    private var recordingIcon: String {
        isRecordingStream ? "stop.circle.fill" : "record.circle"
    }

    private var recordingTint: Color {
        if visualMode.isRetro {
            return isRecordingStream ? RetroChatStyle.danger : RetroChatStyle.secondaryInk
        }
        return isRecordingStream ? .red : Color.appSecondary
    }

    private var isRetroChat: Bool {
        visualMode.isRetro
    }

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            VStack(alignment: .center, spacing: 0) {
                Text(sessionTitle ?? "OpenCode")
                    .font(isRetroChat ? RetroChatStyle.headerFont : .system(size: 16, weight: .semibold))
                    .foregroundStyle(isRetroChat ? RetroChatStyle.ink : .primary)
                    .lineLimit(1)
                    .padding(.vertical, 4)
                    .padding(.horizontal)

                HStack(spacing: 4) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                        .symbolEffect(.pulse, isActive: connectionState == .connected)
                        .padding(.trailing, 4)

                    if let projectName {
                        Image(systemName: "folder")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(isRetroChat ? RetroChatStyle.mutedInk : .gray)
                        Text(projectName)
                            .font(isRetroChat ? RetroChatStyle.smallFont : .system(size: 13, weight: .medium))
                            .foregroundStyle(isRetroChat ? RetroChatStyle.secondaryInk : .secondary)
                            .lineLimit(1)
                    }

                    if let branch {
                        if projectName != nil {
                            Text("\u{00B7}")
                                .font(isRetroChat ? RetroChatStyle.smallFont : .system(size: 13))
                                .foregroundStyle(isRetroChat ? RetroChatStyle.mutedInk : .gray)
                        }
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 10))
                            .foregroundStyle(isRetroChat ? RetroChatStyle.mutedInk : .gray)
                        Text(branch)
                            .font(isRetroChat ? RetroChatStyle.smallFont : .system(size: 13, weight: .medium))
                            .foregroundStyle(isRetroChat ? RetroChatStyle.secondaryInk : .secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal)
                .chatHeaderStatusChrome(visualMode)
            }
            .safeAreaPadding(.vertical)
        }

        if showsRecordingControls, let onToggleRecording {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onToggleRecording) {
                    HStack(spacing: 6) {
                        Image(systemName: recordingIcon)
                            .font(.system(size: 13, weight: .semibold))
                        Text(recordingLabel)
                            .font(isRetroChat ? RetroChatStyle.smallFont : .system(size: 13, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(recordingTint)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .chatRecordingButtonChrome(visualMode)
                }
                .accessibilityLabel(recordingLabel)
                .accessibilityHint(statusText)
            }
        }
    }
}
