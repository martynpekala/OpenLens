import Foundation

/// Abstraction over the connection layer for testability.
/// Concrete implementation: `ConnectionManager`.
protocol ConnectionProviding: AnyObject {
    var state: ConnectionManager.State { get }
    var isConnected: Bool { get }
    var isReconnecting: Bool { get }

    var client: OpenCodeClient? { get }
    var sseClient: SSEClient? { get }

    var serverVersion: String? { get }
    var projectName: String? { get }
    var branch: String? { get }

    @MainActor func connect(url: String, username: String, password: String) async
    @MainActor func disconnect()
    @MainActor func manualDisconnect()
    @MainActor func reconnect() async
    @MainActor func setChatReconnectEnabled(_ isEnabled: Bool)
}
