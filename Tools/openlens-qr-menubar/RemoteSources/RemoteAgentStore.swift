import CryptoKit
import Foundation
import Observation

@MainActor
@Observable
final class RemoteAgentStore {
    private(set) var gatewayRunning = false
    private(set) var openCodeRunning = false
    private(set) var tunnelRunning = false
    private(set) var lastError: String?
    private(set) var remoteEnabled: Bool

    @ObservationIgnored let deviceRegistry: DeviceRegistry
    @ObservationIgnored let workspaceRegistry: WorkspaceRegistry
    @ObservationIgnored private let identity: AgentIdentity
    @ObservationIgnored private let openCodeProcess: OpenCodeProcess
    @ObservationIgnored private let tunnelRunner: TunnelRunner
    @ObservationIgnored private let accessVerifier: CloudflareAccessVerifier
    @ObservationIgnored private let gateway: Gateway
    @ObservationIgnored private let diagnostics: DiagnosticsRecorder
    @ObservationIgnored private let defaults: UserDefaults

    private static let hostnameKey = "OpenLensRemote.hostname"
    private static let accessTeamDomainKey = "OpenLensRemote.accessTeamDomain"
    private static let accessAudienceKey = "OpenLensRemote.accessAudience"
    private static let verifiedConfigurationKey = "OpenLensRemote.verifiedConfiguration"
    private static let accessRotationRequiredKey = "OpenLensRemote.accessRotationRequired"
    private static let enabledKey = "OpenLensRemote.enabled"
    private static let tunnelTokenAccount = "cloudflare_tunnel_token_v1"
    private static let accessClientIDAccount = "cloudflare_access_client_id_v1"
    private static let accessClientSecretAccount = "cloudflare_access_client_secret_v1"

    init(defaults: UserDefaults = .standard) throws {
        self.defaults = defaults
        identity = try AgentIdentity.loadOrCreate()
        deviceRegistry = DeviceRegistry()
        workspaceRegistry = WorkspaceRegistry()
        openCodeProcess = try OpenCodeProcess()
        tunnelRunner = TunnelRunner()
        accessVerifier = CloudflareAccessVerifier()
        let forwarder = OpenCodeForwarder(
            workspaceRegistry: workspaceRegistry,
            password: openCodeProcess.password
        )
        gateway = Gateway(
            identity: identity,
            deviceRegistry: deviceRegistry,
            forwarder: forwarder,
            accessValidator: accessVerifier
        )
        diagnostics = DiagnosticsRecorder()
        remoteEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true

        openCodeProcess.onRunningChange = { [weak self] running in
            Task { @MainActor in
                self?.openCodeRunning = running
                self?.diagnostics.record(running ? .openCodeReady : .openCodeStopped)
            }
        }
        openCodeProcess.onError = { [weak self] error in
            Task { @MainActor in self?.report(error) }
        }
        tunnelRunner.onRunningChange = { [weak self] running in
            Task { @MainActor in
                self?.tunnelRunning = running
                self?.diagnostics.record(running ? .tunnelReady : .tunnelStopped)
            }
        }
        tunnelRunner.onError = { [weak self] error in
            Task { @MainActor in self?.report(error) }
        }
        gateway.onRunningChange = { [weak self] running in
            Task { @MainActor in
                self?.gatewayRunning = running
                self?.diagnostics.record(running ? .gatewayReady : .gatewayStopped)
            }
        }
        gateway.onError = { [weak self] error in
            Task { @MainActor in self?.report(error) }
        }
        diagnostics.record(.agentStarted)
        Task { await startIfConfigured() }
    }

    var hostname: String? {
        defaults.string(forKey: Self.hostnameKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var hasTunnelConfiguration: Bool {
        cloudflareConfiguration != nil
    }

    var accessTeamDomain: String? {
        defaults.string(forKey: Self.accessTeamDomainKey)
    }

    var accessAudience: String? {
        defaults.string(forKey: Self.accessAudienceKey)
    }

    var accessClientID: String? {
        Self.keychainString(account: Self.accessClientIDAccount)
    }

    var accessRotationRequired: Bool {
        defaults.bool(forKey: Self.accessRotationRequiredKey)
    }

    var gatewayFingerprint: String {
        RemoteCrypto.fingerprint(publicKey: identity.publicKeyData)
    }

    var statusTitle: String {
        if !remoteEnabled { return "Remote access disabled" }
        if accessRotationRequired { return "Rotate Cloudflare Access token" }
        if workspaceRegistry.all().isEmpty { return "Add a workspace" }
        if !hasTunnelConfiguration { return "Configure Cloudflare Access" }
        if !isConfigurationVerified { return "Verify Cloudflare Access" }
        if gatewayRunning && openCodeRunning && tunnelRunning { return "Remote access ready" }
        return "Starting Remote access…"
    }

    func configureCloudflare(
        hostname input: String,
        connectorToken token: String,
        teamDomain teamDomainInput: String,
        audience audienceInput: String,
        clientID clientIDInput: String,
        clientSecret clientSecretInput: String
    ) async throws {
        let previousHostname = hostname
        let previousClientID = accessClientID
        let previousClientSecret = accessClientSecret
        let normalizedHostname = try Self.normalizedHostname(input)
        let normalizedTeamDomain = try Self.normalizedTeamDomain(teamDomainInput)
        let audience = audienceInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (8...512).contains(audience.count),
              !audience.contains(where: { $0.isWhitespace || $0.isNewline })
        else { throw RemoteAgentError.invalidAccessConfiguration }

        let connectorToken = try resolvedSecret(
            input: token,
            existing: connectorToken,
            minimumLength: 20,
            invalidError: .invalidConnectorToken
        )
        let clientID = try resolvedSecret(
            input: clientIDInput,
            existing: accessClientID,
            minimumLength: 10,
            invalidError: .invalidAccessConfiguration
        )
        let clientSecret = try resolvedSecret(
            input: clientSecretInput,
            existing: accessClientSecret,
            minimumLength: 20,
            invalidError: .invalidAccessConfiguration
        )
        guard clientID.hasSuffix(".access") else {
            throw RemoteAgentError.invalidAccessConfiguration
        }
        if accessRotationRequired {
            guard clientIDInput.remoteTrimmedNonEmpty != nil,
                  clientSecretInput.remoteTrimmedNonEmpty != nil,
                  clientID != accessClientID || clientSecret != accessClientSecret
            else { throw RemoteAgentError.accessRotationRequired }
        }

        try saveKeychainString(connectorToken, account: Self.tunnelTokenAccount)
        try saveKeychainString(clientID, account: Self.accessClientIDAccount)
        try saveKeychainString(clientSecret, account: Self.accessClientSecretAccount)
        defaults.set(normalizedHostname, forKey: Self.hostnameKey)
        defaults.set(normalizedTeamDomain, forKey: Self.accessTeamDomainKey)
        defaults.set(audience, forKey: Self.accessAudienceKey)
        defaults.removeObject(forKey: Self.verifiedConfigurationKey)
        diagnostics.record(.tunnelConfigurationUpdated)
        lastError = nil

        let configuration = RemoteCloudflareConfiguration(
            hostname: normalizedHostname,
            connectorToken: connectorToken,
            access: CloudflareAccessCredential(clientID: clientID, clientSecret: clientSecret),
            teamDomain: normalizedTeamDomain,
            audience: audience
        )
        do {
            try await accessVerifier.prepare(
                configuration: configuration.verifierConfiguration,
                requiresNetworkRefresh: true
            )
            stopAll()
            try gateway.start()
            tunnelRunner.start(connectorToken: configuration.connectorToken)
            try await CloudflareAccessProbe.verify(configuration: configuration)
            defaults.set(configuration.fingerprint, forKey: Self.verifiedConfigurationKey)
            defaults.set(false, forKey: Self.accessRotationRequiredKey)
            let requiresRePairing = (previousHostname != nil && previousHostname != normalizedHostname)
                || (previousClientID != nil && previousClientID != clientID)
                || (previousClientSecret != nil && previousClientSecret != clientSecret)
            if requiresRePairing {
                deviceRegistry.removeAll()
                gateway.disconnectAllDevices()
                diagnostics.record(.allDevicesRevoked)
            }
            lastError = nil
            stopAll()
            await startIfConfigured()
        } catch {
            defaults.removeObject(forKey: Self.verifiedConfigurationKey)
            stopAll()
            throw error is RemoteAgentError ? error : RemoteAgentError.accessVerificationFailed
        }
    }

    func setRemoteEnabled(_ enabled: Bool) {
        remoteEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        lastError = nil
        if enabled {
            diagnostics.record(.remoteEnabled)
            Task { await startIfConfigured() }
        } else {
            diagnostics.record(.remoteDisabled)
            stopAll()
        }
    }

    func addWorkspace(url: URL) throws {
        _ = try workspaceRegistry.add(url: url)
        diagnostics.record(.workspaceAdded)
        lastError = nil
        Task { await startIfConfigured() }
    }

    func removeWorkspace(id: String) {
        workspaceRegistry.remove(id: id)
        diagnostics.record(.workspaceRemoved)
        if workspaceRegistry.all().isEmpty {
            stopAll()
        } else {
            restartOpenCode()
        }
    }

    func revokeDevice(id: String) {
        deviceRegistry.remove(id: id)
        diagnostics.record(.deviceRevoked)
        gateway.disconnectDevice(id: id)
    }

    func revokeAllDevices() {
        deviceRegistry.removeAll()
        diagnostics.record(.allDevicesRevoked)
        gateway.disconnectAllDevices()
    }

    func markDeviceLostOrCompromised(id: String) {
        guard deviceRegistry.device(id: id) != nil else { return }
        deviceRegistry.removeAll()
        gateway.disconnectAllDevices()
        defaults.set(true, forKey: Self.accessRotationRequiredKey)
        defaults.removeObject(forKey: Self.verifiedConfigurationKey)
        diagnostics.record(.allDevicesRevoked)
        stopAll()
    }

    func makePairingOffer() throws -> RemotePairingOffer {
        guard remoteEnabled else { throw RemoteAgentError.remoteDisabled }
        guard let hostname else { throw RemoteAgentError.invalidHostname }
        guard let endpoint = URL(string: "https://\(hostname)") else {
            throw RemoteAgentError.invalidHostname
        }
        guard isConfigurationVerified,
              !accessRotationRequired,
              let access = cloudflareConfiguration?.access
        else { throw RemoteAgentError.accessVerificationFailed }
        return try gateway.makePairingOffer(endpoint: endpoint, accessCredential: access)
    }

    func setLaunchesAtLogin(_ enabled: Bool) throws {
        try RemoteAgentLifecycle.setLaunchesAtLogin(enabled)
    }

    func exportDiagnostics(to url: URL) throws {
        let lines = [
            "OpenLens Remote diagnostics",
            "generated_at=\(ISO8601DateFormatter().string(from: Date()))",
            "app_version=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development")",
            "remote_enabled=\(remoteEnabled)",
            "gateway_running=\(gatewayRunning)",
            "opencode_running=\(openCodeRunning)",
            "tunnel_running=\(tunnelRunning)",
            "tunnel_configured=\(hasTunnelConfiguration)",
            "access_verified=\(isConfigurationVerified)",
            "access_rotation_required=\(accessRotationRequired)",
            "workspace_count=\(workspaceRegistry.all().count)",
            "trusted_device_count=\(deviceRegistry.all().count)",
            "gateway_fingerprint=\(gatewayFingerprint)",
            "last_error=\(lastError == nil ? "none" : "present")",
        ]
        let report = lines.joined(separator: "\n") + "\n\nredacted_events:\n" + diagnostics.redactedContents()
        try Data(report.utf8).write(to: url, options: .atomic)
    }

    func report(_ error: Error) {
        lastError = error.localizedDescription
        diagnostics.record(.errorPresent)
    }

    func stopAll() {
        gateway.stop()
        tunnelRunner.stop()
        openCodeProcess.stop()
        gatewayRunning = false
        tunnelRunning = false
        openCodeRunning = false
    }

    private var connectorToken: String? {
        Self.keychainString(account: Self.tunnelTokenAccount)
    }

    private var accessClientSecret: String? {
        Self.keychainString(account: Self.accessClientSecretAccount)
    }

    private var cloudflareConfiguration: RemoteCloudflareConfiguration? {
        guard let hostname,
              let connectorToken,
              let accessTeamDomain,
              let accessAudience,
              let accessClientID,
              let accessClientSecret
        else { return nil }
        return RemoteCloudflareConfiguration(
            hostname: hostname,
            connectorToken: connectorToken,
            access: CloudflareAccessCredential(
                clientID: accessClientID,
                clientSecret: accessClientSecret
            ),
            teamDomain: accessTeamDomain,
            audience: accessAudience
        )
    }

    private var isConfigurationVerified: Bool {
        guard let configuration = cloudflareConfiguration else { return false }
        return defaults.string(forKey: Self.verifiedConfigurationKey) == configuration.fingerprint
    }

    private func startIfConfigured() async {
        guard remoteEnabled,
              !workspaceRegistry.all().isEmpty,
              !accessRotationRequired,
              let configuration = cloudflareConfiguration,
              isConfigurationVerified
        else { return }
        do {
            try await accessVerifier.prepare(
                configuration: configuration.verifierConfiguration,
                requiresNetworkRefresh: false
            )
            try startComponents(configuration: configuration)
        } catch {
            report(error)
            stopAll()
        }
    }

    private func startComponents(configuration: RemoteCloudflareConfiguration) throws {
        try gateway.start()
        openCodeProcess.start(workspaceURL: workspaceRegistry.all().first.map {
            URL(fileURLWithPath: $0.path, isDirectory: true)
        })
        tunnelRunner.start(connectorToken: configuration.connectorToken)
    }

    private func restartOpenCode() {
        openCodeProcess.stop()
        openCodeProcess.start(workspaceURL: workspaceRegistry.all().first.map {
            URL(fileURLWithPath: $0.path, isDirectory: true)
        })
    }

    private static func normalizedHostname(_ input: String) throws -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let components = URLComponents(string: candidate),
              components.scheme == "https",
              let host = components.host,
              !host.isEmpty,
              components.port == nil,
              components.path.isEmpty || components.path == "/",
              components.query == nil,
              components.fragment == nil,
              host != "localhost",
              host != "127.0.0.1"
        else {
            throw RemoteAgentError.invalidHostname
        }
        return host
    }

    private static func normalizedTeamDomain(_ input: String) throws -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let value = trimmed.contains(".") ? trimmed : "\(trimmed).cloudflareaccess.com"
        let candidate = value.contains("://") ? value : "https://\(value)"
        guard let components = URLComponents(string: candidate),
              components.scheme == "https",
              let host = components.host,
              host.hasSuffix(".cloudflareaccess.com"),
              host != "cloudflareaccess.com",
              components.port == nil,
              components.path.isEmpty || components.path == "/",
              components.query == nil,
              components.fragment == nil,
              host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") })
        else { throw RemoteAgentError.invalidAccessConfiguration }
        return host
    }

    private func resolvedSecret(
        input: String,
        existing: String?,
        minimumLength: Int,
        invalidError: RemoteAgentError
    ) throws -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = trimmed.isEmpty ? existing : trimmed
        guard let result,
              (minimumLength...2_048).contains(result.count),
              !result.contains(where: { $0.isWhitespace || $0.isNewline })
        else { throw invalidError }
        return result
    }

    private func saveKeychainString(_ value: String, account: String) throws {
        guard AgentKeychain.save(Data(value.utf8), account: account) else {
            throw RemoteAgentError.keychainFailure
        }
    }

    private static func keychainString(account: String) -> String? {
        AgentKeychain.load(account: account).flatMap { String(data: $0, encoding: .utf8) }
    }
}

struct RemoteCloudflareConfiguration: Sendable {
    let hostname: String
    let connectorToken: String
    let access: CloudflareAccessCredential
    let teamDomain: String
    let audience: String

    var verifierConfiguration: CloudflareAccessConfiguration {
        CloudflareAccessConfiguration(
            teamDomain: teamDomain,
            audience: audience,
            clientID: access.clientID
        )
    }

    var fingerprint: String {
        let value = [
            hostname,
            connectorToken,
            access.clientID,
            access.clientSecret,
            teamDomain,
            audience,
        ].joined(separator: "\u{0}")
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

private enum CloudflareAccessProbe {
    static func verify(configuration: RemoteCloudflareConfiguration) async throws {
        guard !configuration.hostname.isEmpty else {
            throw RemoteAgentError.accessVerificationFailed
        }
        var components = URLComponents()
        components.scheme = "wss"
        components.host = configuration.hostname
        components.path = "/remote"
        guard let url = components.url else {
            throw RemoteAgentError.accessVerificationFailed
        }

        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            try Task.checkCancellation()
            do {
                try await attempt(
                    url: url,
                    accessCredential: configuration.access
                )
                break
            } catch {
                if error is CancellationError { throw error }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        guard Date() < deadline else { throw RemoteAgentError.accessVerificationFailed }

        if (try? await attempt(url: url, accessCredential: nil)) != nil {
            throw RemoteAgentError.accessVerificationFailed
        }
    }

    private static func attempt(
        url: URL,
        accessCredential: CloudflareAccessCredential?
    ) async throws {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = 5
        sessionConfiguration.timeoutIntervalForResource = 5
        let session = URLSession(configuration: sessionConfiguration)
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.setValue(
            RemoteProtocolVersion.webSocketSubprotocol,
            forHTTPHeaderField: "Sec-WebSocket-Protocol"
        )
        if let accessCredential {
            request.setValue(
                accessCredential.clientID,
                forHTTPHeaderField: "CF-Access-Client-Id"
            )
            request.setValue(
                accessCredential.clientSecret,
                forHTTPHeaderField: "CF-Access-Client-Secret"
            )
        }
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-OpenLens-Handshake-ID")
        let socket = session.webSocketTask(with: request)
        socket.resume()
        defer {
            socket.cancel(with: .normalClosure, reason: nil)
            session.invalidateAndCancel()
        }
        try await ping(socket, timeout: .seconds(5))
    }

    private static func ping(
        _ socket: URLSessionWebSocketTask,
        timeout: Duration
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    socket.sendPing { error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume()
                        }
                    }
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw RemoteProtocolError.timeout
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }
}

private extension String {
    var remoteTrimmedNonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
