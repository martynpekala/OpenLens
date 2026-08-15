import Foundation
import os

/// A single saved server connection — all fields stored in Keychain as JSON.
struct SavedConnection: Codable, Identifiable, Hashable {
    /// Stable identifier for this saved connection.
    var id: String

    /// Server URL (e.g. "192.168.1.50:4096" or "http://192.168.1.50:4096").
    var serverURL: String

    /// HTTP Basic Auth username.
    var username: String

    /// HTTP Basic Auth password.
    var password: String

    /// Present only for a QR-paired Remote profile. Long-lived keys remain in
    /// `RemoteConnectionSecretStore`, never in this public connection model.
    var remoteGatewayID: String?

    /// Per-connection model selection: provider ID (e.g. "anthropic").
    var selectedProviderID: String?

    /// Per-connection model selection: model ID (e.g. "claude-sonnet-4-20250514").
    var selectedModelID: String?

    /// Per-connection model variant / thinking effort (e.g. "high").
    var selectedVariant: String?

    /// Per-connection default model: provider ID used for new sessions.
    var defaultProviderID: String? = nil

    /// Per-connection default model: model ID used for new sessions.
    var defaultModelID: String? = nil

    /// Per-connection project/worktree directory override.
    var selectedProjectDirectory: String?

    /// Recent project/worktree directories for this connection, newest first.
    var recentProjectDirectories: [String]?

    /// Timestamp of last successful connection (for sorting recent-first).
    var lastConnectedAt: Date?

    /// Display label derived from the URL.
    var displayName: String {
        // Strip scheme for a cleaner label
        serverURL
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "https://", with: "")
    }

    // MARK: - Computed (same as old ConnectionConfig)

    nonisolated init(
        id: String,
        serverURL: String,
        username: String,
        password: String,
        remoteGatewayID: String? = nil,
        selectedProviderID: String? = nil,
        selectedModelID: String? = nil,
        selectedVariant: String? = nil,
        selectedProjectDirectory: String? = nil,
        recentProjectDirectories: [String]? = nil,
        lastConnectedAt: Date? = nil
    ) {
        self.id = id
        self.serverURL = serverURL
        self.username = username
        self.password = password
        self.remoteGatewayID = remoteGatewayID
        self.selectedProviderID = selectedProviderID
        self.selectedModelID = selectedModelID
        self.selectedVariant = selectedVariant
        self.defaultProviderID = nil
        self.defaultModelID = nil
        self.selectedProjectDirectory = selectedProjectDirectory
        self.recentProjectDirectories = recentProjectDirectories
        self.lastConnectedAt = lastConnectedAt
    }

    var isConfigured: Bool {
        !serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isRemote: Bool {
        remoteGatewayID != nil
    }

    /// Full base URL for API calls (e.g. "http://192.168.1.50:4096").
    var baseURL: URL? {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let urlString = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        return URL(string: urlString)
    }

    /// HTTP Basic Auth header value.
    var authHeader: String? {
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let pass = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pass.isEmpty else { return nil }
        let credentials = "\(user):\(pass)"
        guard let data = credentials.data(using: .utf8) else { return nil }
        return "Basic \(data.base64EncodedString())"
    }

    // MARK: - Hashable (by id only)

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: SavedConnection, rhs: SavedConnection) -> Bool { lhs.id == rhs.id }
}

struct SavedConnectionPublicSnapshot: Codable, Equatable {
    var id: String
    var serverURL: String
    var username: String
    var remoteGatewayID: String?
    var selectedProviderID: String?
    var selectedModelID: String?
    var selectedVariant: String?
    var defaultProviderID: String? = nil
    var defaultModelID: String? = nil
    var selectedProjectDirectory: String?
    var recentProjectDirectories: [String]?
    var lastConnectedAt: Date?

    nonisolated init(connection: SavedConnection) {
        id = connection.id
        serverURL = connection.serverURL
        username = connection.username
        remoteGatewayID = connection.remoteGatewayID
        selectedProviderID = connection.selectedProviderID
        selectedModelID = connection.selectedModelID
        selectedVariant = connection.selectedVariant
        defaultProviderID = connection.defaultProviderID
        defaultModelID = connection.defaultModelID
        selectedProjectDirectory = connection.selectedProjectDirectory
        recentProjectDirectories = connection.recentProjectDirectories
        lastConnectedAt = connection.lastConnectedAt
    }

    nonisolated func savedConnectionWithoutPassword() -> SavedConnection {
        var connection = SavedConnection(
            id: id,
            serverURL: serverURL,
            username: username,
            password: "",
            remoteGatewayID: remoteGatewayID,
            selectedProviderID: selectedProviderID,
            selectedModelID: selectedModelID,
            selectedVariant: selectedVariant,
            selectedProjectDirectory: selectedProjectDirectory,
            recentProjectDirectories: recentProjectDirectories,
            lastConnectedAt: lastConnectedAt
        )
        connection.defaultProviderID = defaultProviderID
        connection.defaultModelID = defaultModelID
        return connection
    }
}

// MARK: - SavedConnectionsStore

/// Manages recently used server connections, stored in Keychain.
/// Injected via @Environment into views that need connection suggestions.
@Observable
final class SavedConnectionsStore {

    /// Saved connections, kept most-recently-used first.
    private(set) var connections: [SavedConnection] = []

    /// The connection currently in use (set after successful connect).
    private(set) var activeConnectionID: String?

    /// Keychain key for the entire connections list.
    private static let keychainKey = "saved_connections_v1"
    private static let publicSnapshotDefaultsKey = "saved_connections_public_snapshots_v1"

    /// Flag to track whether migration from legacy UserDefaults has run.
    private static let migrationDoneKey = "saved_connections_migrated"
    private static let maximumSavedConnections = 20
    private static let maximumRecentProjectDirectories = 5

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "OpenLens", category: "SavedConnectionsStore")
    private let shouldPersist: Bool
    private let userDefaults: UserDefaults

    init() {
        userDefaults = .standard
        shouldPersist = true
        connections = Self.loadPersistedConnections(userDefaults: userDefaults)
        migrateFromLegacyIfNeeded()
        trimToSavedConnectionLimitIfNeeded()
    }

    init(initialConnections: [SavedConnection]) {
        userDefaults = .standard
        shouldPersist = false
        connections = initialConnections
        sortAndLimitConnections()
    }

    // MARK: - Public API

    /// The currently active connection (if any).
    var activeConnection: SavedConnection? {
        guard let id = activeConnectionID else { return nil }
        return connections.first { $0.id == id }
    }

    /// Saves or updates a connection after successful connect.
    /// If a connection with the same URL+username already exists, updates it.
    /// Otherwise creates a new entry. Returns the saved connection.
    @discardableResult
    func saveConnection(
        serverURL: String,
        username: String,
        password: String
    ) -> SavedConnection {
        let normalizedURL = normalizeURL(serverURL)

        if let index = connections.firstIndex(where: {
            normalizeURL($0.serverURL) == normalizedURL && $0.username == username
        }) {
            // Update existing
            connections[index].serverURL = serverURL
            connections[index].username = username
            connections[index].password = password
            connections[index].lastConnectedAt = Date()
            let connection = connections[index]
            activeConnectionID = connection.id
            persist()
            return connection
        } else {
            // Create new
            let connection = SavedConnection(
                id: UUID().uuidString,
                serverURL: serverURL,
                username: username,
                password: password,
                lastConnectedAt: Date()
            )
            connections.insert(connection, at: 0)
            activeConnectionID = connection.id
            persist()
            return connection
        }
    }

    /// Adds the non-secret half of a QR-paired Remote profile. The credential
    /// itself is persisted independently in this-device-only Keychain storage.
    @discardableResult
    func saveRemoteConnection(_ credential: RemoteDeviceCredential) -> SavedConnection {
        if let index = connections.firstIndex(where: { $0.id == credential.connectionID }) {
            connections[index].serverURL = credential.endpoint.absoluteString
            connections[index].remoteGatewayID = credential.gatewayID
            connections[index].lastConnectedAt = Date()
            let connection = connections[index]
            activeConnectionID = connection.id
            persist()
            return connection
        }

        let replacedConnections = connections.filter {
            $0.remoteGatewayID == credential.gatewayID && $0.id != credential.connectionID
        }
        replacedConnections.forEach {
            RemoteConnectionSecretStore.delete(connectionID: $0.id)
        }
        let connection = SavedConnection(
            id: credential.connectionID,
            serverURL: credential.endpoint.absoluteString,
            username: "OpenLens Remote",
            password: "",
            remoteGatewayID: credential.gatewayID,
            lastConnectedAt: Date()
        )
        connections.removeAll { $0.remoteGatewayID == credential.gatewayID }
        connections.insert(connection, at: 0)
        activeConnectionID = connection.id
        persist()
        return connection
    }

    /// Updates model selection for a specific connection.
    func updateModelSelection(connectionID: String, providerID: String, modelID: String, variant: String?) {
        guard let index = connections.firstIndex(where: { $0.id == connectionID }) else { return }
        connections[index].selectedProviderID = providerID
        connections[index].selectedModelID = modelID
        connections[index].selectedVariant = variant
        persist()
    }

    /// Updates the default model for a specific connection.
    func updateDefaultModelSelection(connectionID: String, providerID: String, modelID: String) {
        guard let index = connections.firstIndex(where: { $0.id == connectionID }) else { return }
        connections[index].defaultProviderID = providerID
        connections[index].defaultModelID = modelID
        persist()
    }

    /// Updates the project context directory for a specific connection.
    func updateProjectSelection(connectionID: String, directory: String?) {
        guard let index = connections.firstIndex(where: { $0.id == connectionID }) else { return }
        let normalizedDirectory = normalizeProjectDirectory(directory)
        connections[index].selectedProjectDirectory = normalizedDirectory
        if let normalizedDirectory {
            connections[index].recentProjectDirectories = Self.updatedRecentProjectDirectories(
                existing: connections[index].recentProjectDirectories ?? [],
                selected: normalizedDirectory
            )
        }
        persist()
    }

    /// Clears model selection for a specific connection.
    func clearModelSelection(connectionID: String) {
        guard let index = connections.firstIndex(where: { $0.id == connectionID }) else { return }
        connections[index].selectedProviderID = nil
        connections[index].selectedModelID = nil
        connections[index].selectedVariant = nil
        persist()
    }

    /// Clears the default model for a specific connection.
    func clearDefaultModelSelection(connectionID: String) {
        guard let index = connections.firstIndex(where: { $0.id == connectionID }) else { return }
        connections[index].defaultProviderID = nil
        connections[index].defaultModelID = nil
        persist()
    }

    /// Returns saved model selection for the given connection ID.
    func savedModelSelection(connectionID: String) -> (providerID: String, modelID: String, variant: String?)? {
        guard let conn = connections.first(where: { $0.id == connectionID }),
              let provider = conn.selectedProviderID, !provider.isEmpty,
              let model = conn.selectedModelID, !model.isEmpty else { return nil }
        return (providerID: provider, modelID: model, variant: conn.selectedVariant)
    }

    /// Returns default model selection for the given connection ID.
    func defaultModelSelection(connectionID: String) -> (providerID: String, modelID: String)? {
        guard let conn = connections.first(where: { $0.id == connectionID }),
              let provider = conn.defaultProviderID, !provider.isEmpty,
              let model = conn.defaultModelID, !model.isEmpty else { return nil }
        return (providerID: provider, modelID: model)
    }

    /// Returns saved project directory for the given connection ID.
    func savedProjectSelection(connectionID: String) -> String? {
        connections.first(where: { $0.id == connectionID })?.selectedProjectDirectory?.nilIfBlank
    }

    /// Returns recent project directories for the given connection ID, newest first.
    func recentProjectSelections(connectionID: String) -> [String] {
        guard let connection = connections.first(where: { $0.id == connectionID }) else { return [] }

        return Self.updatedRecentProjectDirectories(
            existing: connection.recentProjectDirectories ?? [],
            selected: connection.selectedProjectDirectory
        )
    }

    /// Finds an existing saved connection matching a server URL and username.
    func matchingConnection(serverURL: String, username: String) -> SavedConnection? {
        let normalizedURL = normalizeURL(serverURL)
        return connections.first {
            normalizeURL($0.serverURL) == normalizedURL && $0.username == username
        }
    }

    /// Removes a saved connection ("forget").
    func removeConnection(_ connection: SavedConnection) {
        if connection.isRemote {
            RemoteConnectionSecretStore.delete(connectionID: connection.id)
        }
        connections.removeAll { $0.id == connection.id }
        if activeConnectionID == connection.id {
            activeConnectionID = nil
        }
        persist()
    }

    /// Removes a connection by ID.
    func removeConnection(id: String) {
        if connections.first(where: { $0.id == id })?.isRemote == true {
            RemoteConnectionSecretStore.delete(connectionID: id)
        }
        connections.removeAll { $0.id == id }
        if activeConnectionID == id {
            activeConnectionID = nil
        }
        persist()
    }

    /// Clears the active connection marker (on disconnect).
    func clearActiveConnection() {
        activeConnectionID = nil
    }

    /// Returns the most recently used connection (for auto-reconnect).
    var mostRecent: SavedConnection? {
        connections.first
    }

    /// Saved connections matching a URL prefix (for suggestions/autocomplete).
    func suggestions(for urlPrefix: String) -> [SavedConnection] {
        let prefix = urlPrefix.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty else { return connections }
        return connections.filter {
            $0.displayName.lowercased().contains(prefix) ||
            $0.serverURL.lowercased().contains(prefix)
        }
    }

    // MARK: - Persistence

    private func persist() {
        // Sort most-recently-used first
        sortAndLimitConnections()
        guard shouldPersist else { return }

        let snapshotsSaved = Self.savePublicSnapshots(
            connections.map(SavedConnectionPublicSnapshot.init(connection:)),
            userDefaults: userDefaults
        )
        if !snapshotsSaved {
            logger.error("Failed to persist saved connection public snapshots to UserDefaults")
        }

        let success = KeychainService.saveCodable(connections, key: Self.keychainKey)
        if !success {
            logger.error("Failed to persist saved connections to Keychain")
        }
    }

    private static func loadPersistedConnections(userDefaults: UserDefaults) -> [SavedConnection] {
        mergeKeychainConnections(
            loadFromKeychain(),
            withPublicSnapshots: loadPublicSnapshots(userDefaults: userDefaults)
        )
    }

    private static func loadFromKeychain() -> [SavedConnection] {
        KeychainService.loadCodable([SavedConnection].self, key: keychainKey) ?? []
    }

    static func mergeKeychainConnections(
        _ keychainConnections: [SavedConnection],
        withPublicSnapshots snapshots: [SavedConnectionPublicSnapshot]
    ) -> [SavedConnection] {
        var merged = keychainConnections

        for snapshot in snapshots {
            if let index = merged.firstIndex(where: { $0.id == snapshot.id }) {
                merged[index].applyPublicSnapshot(snapshot)
            } else if let index = merged.firstIndex(where: {
                normalizeURL($0.serverURL) == normalizeURL(snapshot.serverURL) && $0.username == snapshot.username
            }) {
                merged[index].applyPublicSnapshot(snapshot)
            } else {
                merged.append(snapshot.savedConnectionWithoutPassword())
            }
        }

        return sortedAndLimited(merged)
    }

    private static func loadPublicSnapshots(userDefaults: UserDefaults) -> [SavedConnectionPublicSnapshot] {
        guard let data = userDefaults.data(forKey: publicSnapshotDefaultsKey) else { return [] }
        do {
            return try JSONDecoder().decode([SavedConnectionPublicSnapshot].self, from: data)
        } catch {
            Logger(
                subsystem: Bundle.main.bundleIdentifier ?? "OpenLens",
                category: "SavedConnectionsStore"
            ).error("Failed to decode saved connection public snapshots: \(error, privacy: .public)")
            return []
        }
    }

    @discardableResult
    private static func savePublicSnapshots(
        _ snapshots: [SavedConnectionPublicSnapshot],
        userDefaults: UserDefaults
    ) -> Bool {
        do {
            let data = try JSONEncoder().encode(snapshots)
            userDefaults.set(data, forKey: publicSnapshotDefaultsKey)
            return true
        } catch {
            Logger(
                subsystem: Bundle.main.bundleIdentifier ?? "OpenLens",
                category: "SavedConnectionsStore"
            ).error("Failed to encode saved connection public snapshots: \(error, privacy: .public)")
            return false
        }
    }

    private func trimToSavedConnectionLimitIfNeeded() {
        let originalIDs = connections.map(\.id)
        sortAndLimitConnections()

        if connections.map(\.id) != originalIDs {
            persist()
        }
    }

    private func sortAndLimitConnections() {
        connections = Self.sortedAndLimited(connections)

        if let activeConnectionID, !connections.contains(where: { $0.id == activeConnectionID }) {
            self.activeConnectionID = nil
        }
    }

    private static func sortedAndLimited(_ connections: [SavedConnection]) -> [SavedConnection] {
        let sorted = connections.sorted {
            ($0.lastConnectedAt ?? .distantPast) > ($1.lastConnectedAt ?? .distantPast)
        }
        return Array(sorted.prefix(maximumSavedConnections))
    }

    private func normalizeProjectDirectory(_ directory: String?) -> String? {
        Self.normalizeProjectDirectory(directory)
    }

    nonisolated private static func normalizeProjectDirectory(_ directory: String?) -> String? {
        guard let trimmed = directory?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }

        return URL(fileURLWithPath: trimmed).standardizedFileURL.path
    }

    private static func updatedRecentProjectDirectories(existing: [String], selected: String?) -> [String] {
        var directories: [String] = []

        if let selected = normalizeProjectDirectory(selected) {
            directories.append(selected)
        }

        directories.append(contentsOf: existing.compactMap(normalizeProjectDirectory))

        var seen = Set<String>()
        let deduplicated = directories.filter { seen.insert($0).inserted }
        return Array(deduplicated.prefix(maximumRecentProjectDirectories))
    }

    // MARK: - Migration from Legacy UserDefaults + Keychain

    private func migrateFromLegacyIfNeeded() {
        guard !userDefaults.bool(forKey: Self.migrationDoneKey) else { return }
        defer { userDefaults.set(true, forKey: Self.migrationDoneKey) }

        let legacyURL = userDefaults.string(forKey: "opencode_server_url") ?? ""
        let legacyUsername = userDefaults.string(forKey: "opencode_server_username") ?? "opencode"
        let legacyPassword = KeychainService.load(key: "opencode_server_password") ?? ""

        guard !legacyURL.isEmpty else { return }

        // Check if we already have this connection (avoid duplicate on re-migration)
        let normalizedURL = normalizeURL(legacyURL)
        guard !connections.contains(where: {
            normalizeURL($0.serverURL) == normalizedURL && $0.username == legacyUsername
        }) else { return }

        // Migrate legacy model selection too
        let legacyProvider = userDefaults.string(forKey: "selectedProviderID")
        let legacyModel = userDefaults.string(forKey: "selectedModelID")

        let migrated = SavedConnection(
            id: UUID().uuidString,
            serverURL: legacyURL,
            username: legacyUsername,
            password: legacyPassword,
            selectedProviderID: legacyProvider,
            selectedModelID: legacyModel,
            lastConnectedAt: Date()
        )

        connections.insert(migrated, at: 0)
        persist()

        // Clean up legacy storage
        userDefaults.removeObject(forKey: "opencode_server_url")
        userDefaults.removeObject(forKey: "opencode_server_username")
        userDefaults.removeObject(forKey: "selectedProviderID")
        userDefaults.removeObject(forKey: "selectedModelID")
        KeychainService.delete(key: "opencode_server_password")

        logger.info("Migrated legacy connection config to SavedConnectionsStore")
    }

    // MARK: - Helpers

    private func normalizeURL(_ url: String) -> String {
        Self.normalizeURL(url)
    }

    private static func normalizeURL(_ url: String) -> String {
        url.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "https://", with: "")
    }
}

private extension SavedConnection {
    mutating func applyPublicSnapshot(_ snapshot: SavedConnectionPublicSnapshot) {
        serverURL = snapshot.serverURL
        username = snapshot.username
        remoteGatewayID = snapshot.remoteGatewayID
        selectedProviderID = snapshot.selectedProviderID
        selectedModelID = snapshot.selectedModelID
        selectedVariant = snapshot.selectedVariant
        defaultProviderID = snapshot.defaultProviderID
        defaultModelID = snapshot.defaultModelID
        selectedProjectDirectory = snapshot.selectedProjectDirectory
        recentProjectDirectories = snapshot.recentProjectDirectories
        lastConnectedAt = snapshot.lastConnectedAt
    }
}

extension String {
    nonisolated var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
