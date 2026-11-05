import SwiftUI

/// What a server row's dot and trailing label mean. One place decides it.
enum ServerRowStatus: Equatable {
    /// The server the UI is showing, and it is connected.
    case active
    case connected
    /// Connecting or reconnecting: a slot is in use but the server isn't reachable yet.
    case connecting
    case reconnecting
    case failed
    /// Saved but not holding a connection.
    case idle

    /// The meaning the dot carries. Colours are dynamic and not comparable, so the decision is
    /// this value and `dotColor` only paints it.
    enum Tone: Equatable {
        case success, warning, danger, neutral
    }

    var tone: Tone {
        switch self {
        case .active, .connected: .success
        case .connecting, .reconnecting: .warning
        case .failed: .danger
        case .idle: .neutral
        }
    }

    var dotColor: Color {
        switch tone {
        case .success: Color.appSuccess
        case .warning: Color.appWarning
        case .danger: Color.appDanger
        case .neutral: Color.appSecondary
        }
    }

    var label: String {
        switch self {
        case .active: AppText.serversStatusActive
        case .connected: AppText.serversStatusConnected
        case .connecting: AppText.serversStatusConnecting
        case .reconnecting: AppText.serversStatusReconnecting
        case .failed: AppText.serversStatusFailed
        case .idle: AppText.serversStatusNotConnected
        }
    }
}

func serverRowStatus(connectionState: ConnectionManager.State, isActive: Bool) -> ServerRowStatus {
    switch connectionState {
    case .connected: isActive ? .active : .connected
    case .connecting: .connecting
    case .reconnecting: .reconnecting
    case .error: .failed
    case .disconnected: .idle
    }
}

/// Multi-server chrome appears only once there is more than one *saved* server. Saved, not
/// connected: connection states flicker and the chrome must not.
func isMultiServerUIEnabled(savedServerCount: Int) -> Bool {
    savedServerCount > 1
}
