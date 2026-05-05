import SwiftUI

/// Navigation bar toolbar content for the chat view.
struct ChatHeaderToolbar: ToolbarContent {
    let projectName: String?
    let branch: String?
    let connectionState: ConnectionManager.State
    let sessionTitle: String?

    private var statusColor: Color {
        switch connectionState {
        case .connected: .green
        case .reconnecting, .connecting: .orange
        case .disconnected, .error: Color.gray.opacity(0.5)
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

    var body: some ToolbarContent {
        ToolbarItem(placement: .title) {
                VStack(alignment: .center, spacing: 0) {
                    Text(sessionTitle ?? "OpenCode")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .padding(.vertical, 4)
                        .padding(.horizontal)
                        // .glassEffect(.regular, in: Capsule())

                    HStack(spacing: 4) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 6, height: 6)
                            .symbolEffect(.pulse, isActive: connectionState == .connected)
                            .padding(.trailing, 4)

                        if let projectName {
                            Text(projectName)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        if let branch {
                            Text("\u{00B7}")
                                .font(.system(size: 13))
                                .foregroundStyle(.gray)
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 10))
                                .foregroundStyle(.gray)
                            Text(branch)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal)
                    .glassEffect(.regular, in: Capsule())
                    
                    // HStack(spacing: 4) {
                    //     Circle()
                    //         .fill(statusColor)
                    //         .frame(width: 6, height: 6)
                    //     Text(statusText)
                    //         .font(.system(size: 13))
                    //         .foregroundStyle(.gray)
                    // }
                    // .padding(.vertical, 4)
                    // .padding(.horizontal)
                    // .glassEffect(.regular, in: Capsule())
                }
                .safeAreaPadding(.vertical)
            
        }
    }
}
