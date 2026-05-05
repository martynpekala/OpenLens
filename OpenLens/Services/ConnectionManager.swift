import Foundation
import os.log

/// Central connection manager that owns the API client and SSE client.
@MainActor @Observable
final class ConnectionManager: ConnectionProviding {

    enum State: Equatable {
        case disconnected
        case connecting
        case connected
        case reconnecting
        case error(String)
    }

    private(set) var state: State = .disconnected
    private(set) var serverVersion: String?
    private(set) var projectName: String?
    private(set) var branch: String?
    private(set) var selectedProjectDirectory: String?
    private(set) var connectionMethod: ConnectionMethod?

    /// Set to `true` when the user explicitly disconnects via Settings.
    /// Prevents auto-reconnect from firing until the user manually connects again.
    private(set) var didManuallyDisconnect: Bool = false

    /// Reference to the shared saved connections store, set from the composition root.
    @ObservationIgnored var savedConnectionsStore: SavedConnectionsStore?

    private(set) var client: OpenCodeClient?
    private(set) var sseClient: SSEClient?

    /// Continuation used to bridge the SSE callback-based connection into async/await.
    /// Resumed once when SSE reports `.connected` or fails to connect.
    private var sseConnectionContinuation: CheckedContinuation<Void, Never>?

    /// Timestamp of the last received `server.heartbeat` or `server.connected` event.
    /// Used by the heartbeat watchdog to detect silently dead connections.
    private var lastHeartbeat: Date = .distantPast
    private var heartbeatWatchdog: Timer?

    /// If no heartbeat arrives within this interval, the connection is considered stale.
    /// OpenCode server typically sends heartbeats every ~30s; 90s allows 3 missed beats.
    private static let heartbeatTimeout: TimeInterval = 90

    init() {}

    var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    /// True when SSE is reconnecting after a drop. UI can show "Reconnecting..." state.
    var isReconnecting: Bool {
        if case .reconnecting = state { return true }
        return false
    }

    // MARK: - Connect

    func connect(url: String, username: String, password: String) async {
        await connect(url: url, username: username, password: password, method: .manual)
    }

    func connect(
        url: String,
        username: String = "opencode",
        password: String = "",
        method: ConnectionMethod = .manual
    ) async {
        didManuallyDisconnect = false
        connectionMethod = method

        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            state = .error("Server URL is empty.")
            return
        }

        let normalizedInput = normalizeScopedIPv4Address(in: trimmed)
        let urlString = normalizedInput.contains("://") ? normalizedInput : "http://\(normalizedInput)"
        guard let baseURL = URL(string: urlString) else {
            state = .error("Invalid URL: \(urlString)")
            return
        }

        state = .connecting

        var authHeader: String?
        if !password.isEmpty {
            let credentials = "\(username):\(password)"
            if let data = credentials.data(using: .utf8) {
                authHeader = "Basic \(data.base64EncodedString())"
            }
        }

        let restoredProjectDirectory = savedConnectionsStore?
            .matchingConnection(serverURL: urlString, username: username)?
            .selectedProjectDirectory?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        Logger.connection.debug("Connecting to \(urlString, privacy: .public) with restored project directory \(restoredProjectDirectory ?? "nil", privacy: .public)")

        let apiClient = OpenCodeClient(
            baseURL: baseURL,
            authHeader: authHeader,
            contextDirectory: restoredProjectDirectory
        )
        let sse = SSEClient(baseURL: baseURL, authHeader: authHeader)

        do {
            let health = try await apiClient.checkHealth()
            guard health.healthy else {
                state = .error("Server is not healthy.")
                return
            }
            serverVersion = health.version

            self.client = apiClient
            self.sseClient = sse
            self.selectedProjectDirectory = restoredProjectDirectory?.nilIfBlank

            SharedConnectionStore.save(baseURL: baseURL.absoluteString, authHeader: authHeader)

            await refreshProjectMetadata()

            savedConnectionsStore?.saveConnection(
                serverURL: urlString,
                username: username,
                password: password
            )
            if let activeConnectionID = savedConnectionsStore?.activeConnectionID {
                savedConnectionsStore?.updateProjectSelection(
                    connectionID: activeConnectionID,
                    directory: self.selectedProjectDirectory
                )
            }

            sse.onStateChange = { [weak self] sseState in
                guard let self else { return }
                switch sseState {
                case .connected:
                    self.state = .connected
                    self.startHeartbeatWatchdog()
                    self.sseConnectionContinuation?.resume()
                    self.sseConnectionContinuation = nil
                case .connecting:
                    // Only show reconnecting if we were previously connected.
                    // During initial connect we already show .connecting.
                    if self.state == .connected {
                        self.enterReconnectingState(trackDisconnection: false)
                    }
                case .disconnected:
                    // SSE dropped. It will auto-reconnect, so show reconnecting
                    // unless we explicitly disconnected (shouldReconnect = false).
                    if self.state == .connected || self.state == .reconnecting {
                        self.enterReconnectingState(trackDisconnection: true)
                    }
                }
            }

            sse.connect()

            // Wait for SSE to actually connect before returning to the caller.
            // This ensures ConnectView sees .connected after connect() returns.
            await withCheckedContinuation { continuation in
                if self.state == .connected {
                    // SSE connected synchronously (unlikely but safe)
                    continuation.resume()
                } else {
                    self.sseConnectionContinuation = continuation
                }
            }
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    /// Reconnect using saved config.
    func reconnect() async {
        guard let saved = savedConnectionsStore?.mostRecent, saved.isConfigured else { return }
        await connect(
            url: saved.serverURL,
            username: saved.username,
            password: saved.password,
            method: .autoReconnect
        )
    }

    // MARK: - Disconnect

    func disconnect() {
        sseConnectionContinuation?.resume()
        sseConnectionContinuation = nil
        stopHeartbeatWatchdog()
        sseClient?.disconnect()
        sseClient = nil
        client = nil
        state = .disconnected
        serverVersion = nil
        projectName = nil
        branch = nil
        selectedProjectDirectory = nil
        connectionMethod = nil
        savedConnectionsStore?.clearActiveConnection()
        SharedConnectionStore.clear()
    }

    func setProjectContext(directory: String?) async {
        let normalizedDirectory = directory?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        Logger.connection.debug("Setting project context to \(normalizedDirectory ?? "nil", privacy: .public)")
        guard let client else {
            selectedProjectDirectory = normalizedDirectory
            return
        }

        await client.updateContextDirectory(normalizedDirectory)
        selectedProjectDirectory = normalizedDirectory

        if let activeConnectionID = savedConnectionsStore?.activeConnectionID {
            savedConnectionsStore?.updateProjectSelection(
                connectionID: activeConnectionID,
                directory: normalizedDirectory
            )
        }

        await refreshProjectMetadata()
    }

    func clearProjectContext() async {
        await setProjectContext(directory: nil)
    }

    private func refreshProjectMetadata() async {
        guard let client else {
            projectName = nil
            branch = nil
            return
        }

        if let project = try? await client.getCurrentProject() {
            projectName = project.displayName ?? project.worktree
        } else {
            projectName = nil
            Logger.connection.warning("Failed to fetch project info")
        }

        do {
            let vcs = try await client.getVCS()
            branch = vcs.branch
        } catch {
            branch = nil
            Logger.connection.warning("Failed to fetch VCS info: \(error, privacy: .public)")
        }

        if selectedProjectDirectory == nil,
           let pathInfo = try? await client.getPath() {
            let inferredDirectory = pathInfo.directory?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
            Logger.connection.debug("Inferred project context from /path as \(inferredDirectory ?? "nil", privacy: .public)")
            selectedProjectDirectory = inferredDirectory

            if inferredDirectory != nil {
                await client.updateContextDirectory(inferredDirectory)

                if let activeConnectionID = savedConnectionsStore?.activeConnectionID {
                    savedConnectionsStore?.updateProjectSelection(
                        connectionID: activeConnectionID,
                        directory: inferredDirectory
                    )
                }
            }
        }
    }

    /// Disconnect triggered explicitly by the user (e.g. from Settings).
    /// Suppresses auto-reconnect until the next manual connect.
    func manualDisconnect() {
        disconnect()
        didManuallyDisconnect = true
    }

    // MARK: - Heartbeat

    /// Called by SSEEventHandler when `server.connected` or `server.heartbeat` arrives.
    /// Resets the heartbeat watchdog timer.
    func receivedHeartbeat() {
        lastHeartbeat = Date()

        // If we were in .reconnecting due to a stale heartbeat, recover to .connected.
        if state == .reconnecting {
            state = .connected
        }
    }

    /// Start the heartbeat watchdog that checks for stale connections.
    private func startHeartbeatWatchdog() {
        stopHeartbeatWatchdog()
        lastHeartbeat = Date()

        let timer = Timer(timeInterval: Self.heartbeatTimeout / 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let elapsed = Date().timeIntervalSince(self.lastHeartbeat)
                if elapsed > Self.heartbeatTimeout, self.state == .connected {
                    Logger.connection.warning("Heartbeat timeout (\(elapsed, format: .fixed(precision: 0))s since last heartbeat)")
                    self.enterReconnectingState(trackDisconnection: true)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeatWatchdog = timer
    }

    private func enterReconnectingState(trackDisconnection: Bool) {
        state = .reconnecting
    }

    private func stopHeartbeatWatchdog() {
        heartbeatWatchdog?.invalidate()
        heartbeatWatchdog = nil
    }

    private func normalizeScopedIPv4Address(in rawURL: String) -> String {
        guard let schemeRange = rawURL.range(of: "://") else {
            return normalizeScopedIPv4Address(inHostPort: rawURL)
        }

        let prefix = String(rawURL[..<schemeRange.upperBound])
        let rest = String(rawURL[schemeRange.upperBound...])
        return prefix + normalizeScopedIPv4Address(inHostPort: rest)
    }

    private func normalizeScopedIPv4Address(inHostPort hostPortAndPath: String) -> String {
        let separators = ["/", "?", "#"]
        let splitIndex = separators
            .compactMap { hostPortAndPath.firstIndex(of: Character($0)) }
            .min() ?? hostPortAndPath.endIndex

        let authority = String(hostPortAndPath[..<splitIndex])
        let suffix = String(hostPortAndPath[splitIndex...])

        guard let portSeparator = authority.lastIndex(of: ":") else {
            return sanitizeIPv4Scope(in: authority) + suffix
        }

        let host = String(authority[..<portSeparator])
        let port = String(authority[portSeparator...])
        return sanitizeIPv4Scope(in: host) + port + suffix
    }

    private func sanitizeIPv4Scope(in host: String) -> String {
        guard let percentIndex = host.firstIndex(of: "%") else {
            return host
        }

        let candidate = String(host[..<percentIndex])
        let parts = candidate.split(separator: ".")
        guard parts.count == 4 else { return host }

        let isIPv4 = parts.allSatisfy { part in
            guard let octet = Int(part) else { return false }
            return (0...255).contains(octet)
        }

        return isIPv4 ? candidate : host
    }

    // MARK: - Demo Mode

    /// Configures the connection manager with fake state for demo mode.
    /// The header toolbar reads projectName/branch/state from the connection.
    func configureDemoState(projectName: String = "my-project", branch: String = "main") {
        self.state = .connected
        self.projectName = projectName
        self.branch = branch
        self.serverVersion = "demo"
    }
}
