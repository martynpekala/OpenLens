import CryptoKit
import Foundation
import Security

enum AgentKeychain {
    private static let service = "dev.openlens.remote"

    @discardableResult
    static func save(_ data: Data, account: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var query = base
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func load(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

struct AgentIdentity {
    let privateKey: Curve25519.KeyAgreement.PrivateKey

    var gatewayID: String {
        "gateway-" + RemoteCrypto.fingerprint(publicKey: publicKeyData)
    }

    var publicKeyData: Data {
        privateKey.publicKey.rawRepresentation
    }

    static func loadOrCreate() throws -> AgentIdentity {
        let account = "gateway_identity_v1"
        if let raw = AgentKeychain.load(account: account) {
            return AgentIdentity(privateKey: try RemoteCrypto.privateKey(rawRepresentation: raw))
        }

        let key = RemoteCrypto.makeIdentity()
        guard AgentKeychain.save(key.rawRepresentation, account: account) else {
            throw RemoteAgentError.keychainFailure
        }
        return AgentIdentity(privateKey: key)
    }
}

struct TrustedDevice: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    let publicKey: Data
    let pairedAt: Date
    var lastConnectedAt: Date?
}

final class DeviceRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private let storageURL: URL
    private var records: [TrustedDevice]

    init(storageURL: URL = RemoteAgentPaths.devicesFile) {
        self.storageURL = storageURL
        records = (try? Data(contentsOf: storageURL))
            .flatMap { try? JSONDecoder().decode([TrustedDevice].self, from: $0) } ?? []
    }

    func all() -> [TrustedDevice] {
        lock.withLock { records.sorted { $0.pairedAt > $1.pairedAt } }
    }

    func device(id: String) -> TrustedDevice? {
        lock.withLock { records.first(where: { $0.id == id }) }
    }

    func add(name: String, publicKey: Data) throws -> TrustedDevice {
        try lock.withLock {
            let record = TrustedDevice(
                id: UUID().uuidString,
                name: Self.sanitizedDeviceName(name),
                publicKey: publicKey,
                pairedAt: Date(),
                lastConnectedAt: nil
            )
            records.append(record)
            try persistLocked()
            return record
        }
    }

    func markConnected(id: String) {
        lock.withLock {
            guard let index = records.firstIndex(where: { $0.id == id }) else { return }
            records[index].lastConnectedAt = Date()
            try? persistLocked()
        }
    }

    func remove(id: String) {
        lock.withLock {
            records.removeAll { $0.id == id }
            try? persistLocked()
        }
    }

    func removeAll() {
        lock.withLock {
            records.removeAll()
            try? persistLocked()
        }
    }

    private func persistLocked() throws {
        try RemoteAgentPaths.prepare()
        let data = try JSONEncoder().encode(records)
        try data.write(to: storageURL, options: [.atomic, .completeFileProtection])
    }

    private static func sanitizedDeviceName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((trimmed.isEmpty ? "iPhone or iPad" : trimmed).prefix(80))
    }
}

struct AllowedWorkspace: Codable, Identifiable, Equatable {
    let id: String
    let displayName: String
    let path: String
}

final class WorkspaceRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private let storageURL: URL
    private var records: [AllowedWorkspace]

    init(storageURL: URL = RemoteAgentPaths.workspacesFile) {
        self.storageURL = storageURL
        records = (try? Data(contentsOf: storageURL))
            .flatMap { try? JSONDecoder().decode([AllowedWorkspace].self, from: $0) } ?? []
    }

    func all() -> [AllowedWorkspace] {
        lock.withLock { records }
    }

    @discardableResult
    func add(url: URL) throws -> AllowedWorkspace {
        var isDirectory: ObjCBool = false
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: canonical.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw RemoteAgentError.workspaceMissing
        }

        return try lock.withLock {
            if let existing = records.first(where: { $0.path == canonical.path }) {
                return existing
            }
            let record = AllowedWorkspace(
                id: UUID().uuidString,
                displayName: canonical.lastPathComponent.isEmpty ? "Workspace" : canonical.lastPathComponent,
                path: canonical.path
            )
            records.append(record)
            try persistLocked()
            return record
        }
    }

    func remove(id: String) {
        lock.withLock {
            records.removeAll { $0.id == id }
            try? persistLocked()
        }
    }

    func isAllowed(_ requestedPath: String?) -> Bool {
        lock.withLock {
            if requestedPath == nil || requestedPath?.isEmpty == true {
                return !records.isEmpty
            }
            guard let requestedPath else { return false }
            let canonical = URL(fileURLWithPath: requestedPath, isDirectory: true)
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .path
            return records.contains { $0.path == canonical }
        }
    }

    func resolvedPath(_ requestedPath: String?) -> String? {
        lock.withLock {
            if let requestedPath {
                let canonical = URL(fileURLWithPath: requestedPath, isDirectory: true)
                    .standardizedFileURL
                    .resolvingSymlinksInPath()
                    .path
                return records.first(where: { $0.path == canonical })?.path
            }
            return records.first?.path
        }
    }

    private func persistLocked() throws {
        try RemoteAgentPaths.prepare()
        let data = try JSONEncoder().encode(records)
        try data.write(to: storageURL, options: [.atomic, .completeFileProtection])
    }
}

final class DiagnosticsRecorder: @unchecked Sendable {
    enum Event: String {
        case agentStarted = "agent_started"
        case remoteEnabled = "remote_enabled"
        case remoteDisabled = "remote_disabled"
        case tunnelConfigurationUpdated = "tunnel_configuration_updated"
        case workspaceAdded = "workspace_added"
        case workspaceRemoved = "workspace_removed"
        case deviceRevoked = "device_revoked"
        case allDevicesRevoked = "all_devices_revoked"
        case gatewayReady = "gateway_ready"
        case gatewayStopped = "gateway_stopped"
        case openCodeReady = "opencode_ready"
        case openCodeStopped = "opencode_stopped"
        case tunnelReady = "tunnel_ready"
        case tunnelStopped = "tunnel_stopped"
        case errorPresent = "error_present"
    }

    private let queue = DispatchQueue(label: "dev.openlens.remote.diagnostics")
    private let fileURL: URL
    private let maximumFileBytes = 256 * 1_024
    private let retainedFileCount = 3

    init(fileURL: URL = RemoteAgentPaths.diagnosticsFile) {
        self.fileURL = fileURL
    }

    func record(_ event: Event) {
        queue.async { [self] in
            do {
                try RemoteAgentPaths.prepare()
                let timestamp = ISO8601DateFormatter().string(from: Date())
                let line = Data("\(timestamp) \(event.rawValue)\n".utf8)
                try rotateIfNeeded(incomingByteCount: line.count)
                if !FileManager.default.fileExists(atPath: fileURL.path) {
                    try Data().write(to: fileURL, options: .atomic)
                    try FileManager.default.setAttributes(
                        [.posixPermissions: NSNumber(value: Int16(0o600))],
                        ofItemAtPath: fileURL.path
                    )
                }
                let handle = try FileHandle(forWritingTo: fileURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
                try handle.close()
            } catch {
                // Diagnostics must never affect availability or contain the error itself.
            }
        }
    }

    func redactedContents() -> String {
        queue.sync {
            (0..<retainedFileCount).reversed().compactMap { index in
                let url = rotatedURL(index: index)
                return try? String(contentsOf: url, encoding: .utf8)
            }.joined()
        }
    }

    private func rotateIfNeeded(incomingByteCount: Int) throws {
        let currentSize = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard currentSize + incomingByteCount > maximumFileBytes else { return }
        try? FileManager.default.removeItem(at: rotatedURL(index: retainedFileCount - 1))
        if retainedFileCount > 2 {
            for index in stride(from: retainedFileCount - 2, through: 1, by: -1) {
                let source = rotatedURL(index: index)
                guard FileManager.default.fileExists(atPath: source.path) else { continue }
                try? FileManager.default.moveItem(at: source, to: rotatedURL(index: index + 1))
            }
        }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.moveItem(at: fileURL, to: rotatedURL(index: 1))
        }
    }

    private func rotatedURL(index: Int) -> URL {
        index == 0
            ? fileURL
            : fileURL.deletingPathExtension().appendingPathExtension("\(index).log")
    }
}

enum RemoteAgentPaths {
    static let directory: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenLensRemote", isDirectory: true)
    }()
    static let devicesFile = directory.appendingPathComponent("devices.json")
    static let workspacesFile = directory.appendingPathComponent("workspaces.json")
    static let diagnosticsFile = directory.appendingPathComponent("diagnostics.log")
    static let accessJWKSFile = directory.appendingPathComponent("cloudflare-access-jwks.json")

    static func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}

enum RemoteAgentError: LocalizedError {
    case keychainFailure
    case workspaceMissing
    case openCodeNotFound
    case cloudflaredNotBundled
    case invalidConnectorToken
    case tokenFileFailure
    case invalidHostname
    case invalidAccessConfiguration
    case accessJWKSUnavailable
    case accessVerificationFailed
    case accessRotationRequired
    case gatewayUnavailable
    case remoteDisabled

    var errorDescription: String? {
        switch self {
        case .keychainFailure: "OpenLens Remote could not access Keychain."
        case .workspaceMissing: "The selected workspace is no longer available."
        case .openCodeNotFound: "The opencode executable was not found. Install OpenCode first."
        case .cloudflaredNotBundled: "The pinned cloudflared executable is missing from this build."
        case .invalidConnectorToken: "Paste a valid Cloudflare Tunnel connector token."
        case .tokenFileFailure: "OpenLens Remote could not create a protected token file for cloudflared."
        case .invalidHostname: "Enter the hostname configured for this Tunnel, for example remote.example.com."
        case .invalidAccessConfiguration: "Enter a valid Cloudflare Access team domain, application AUD, Client ID, and Client Secret."
        case .accessJWKSUnavailable: "OpenLens Remote could not download valid Cloudflare Access signing keys."
        case .accessVerificationFailed: "Cloudflare Access verification failed. The Tunnel was stopped and Remote access remains unavailable."
        case .accessRotationRequired: "Create a new Cloudflare Access Service Token and enter both its Client ID and Client Secret."
        case .gatewayUnavailable: "The local encrypted gateway is unavailable."
        case .remoteDisabled: "Remote access is disabled by the local kill switch."
        }
    }
}

extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
