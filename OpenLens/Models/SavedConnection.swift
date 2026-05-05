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

    /// Per-connection model selection: provider ID (e.g. "anthropic").
    var selectedProviderID: String?

    /// Per-connection model selection: model ID (e.g. "claude-sonnet-4-20250514").
    var selectedModelID: String?

    /// Per-connection model variant / thinking effort (e.g. "high").
    var selectedVariant: String?

    /// Per-connection project/worktree directory override.
    var selectedProjectDirectory: String?

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

    var isConfigured: Bool {
        !serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

// MARK: - SavedConnectionsStore

/// Manages a list of saved server connections, all stored in Keychain.
/// Injected via @Environment into views that need connection suggestions.
@Observable
final class SavedConnectionsStore {

    /// All saved connections, sorted most-recently-used first.
    private(set) var connections: [SavedConnection] = []

    /// The connection currently in use (set after successful connect).
    private(set) var activeConnectionID: String?

    /// Keychain key for the entire connections list.
    private static let keychainKey = "saved_connections_v1"

    /// Flag to track whether migration from legacy UserDefaults has run.
    private static let migrationDoneKey = "saved_connections_migrated"

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "OpenLens", category: "SavedConnectionsStore")

    init() {
        connections = Self.loadFromKeychain()
        migrateFromLegacyIfNeeded()
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

    /// Updates model selection for a specific connection.
    func updateModelSelection(connectionID: String, providerID: String, modelID: String, variant: String?) {
        guard let index = connections.firstIndex(where: { $0.id == connectionID }) else { return }
        connections[index].selectedProviderID = providerID
        connections[index].selectedModelID = modelID
        connections[index].selectedVariant = variant
        persist()
    }

    /// Updates the project context directory for a specific connection.
    func updateProjectSelection(connectionID: String, directory: String?) {
        guard let index = connections.firstIndex(where: { $0.id == connectionID }) else { return }
        connections[index].selectedProjectDirectory = directory?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
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

    /// Returns saved model selection for the given connection ID.
    func savedModelSelection(connectionID: String) -> (providerID: String, modelID: String, variant: String?)? {
        guard let conn = connections.first(where: { $0.id == connectionID }),
              let provider = conn.selectedProviderID, !provider.isEmpty,
              let model = conn.selectedModelID, !model.isEmpty else { return nil }
        return (providerID: provider, modelID: model, variant: conn.selectedVariant)
    }

    /// Returns saved project directory for the given connection ID.
    func savedProjectSelection(connectionID: String) -> String? {
        connections.first(where: { $0.id == connectionID })?.selectedProjectDirectory?.nilIfBlank
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
        connections.removeAll { $0.id == connection.id }
        if activeConnectionID == connection.id {
            activeConnectionID = nil
        }
        persist()
    }

    /// Removes a connection by ID.
    func removeConnection(id: String) {
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

    /// All saved connections matching a URL prefix (for suggestions/autocomplete).
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
        connections.sort { ($0.lastConnectedAt ?? .distantPast) > ($1.lastConnectedAt ?? .distantPast) }
        let success = KeychainService.saveCodable(connections, key: Self.keychainKey)
        if !success {
            logger.error("Failed to persist saved connections to Keychain")
        }
    }

    private static func loadFromKeychain() -> [SavedConnection] {
        KeychainService.loadCodable([SavedConnection].self, key: keychainKey) ?? []
    }

    // MARK: - Migration from Legacy UserDefaults + Keychain

    private func migrateFromLegacyIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.migrationDoneKey) else { return }
        defer { UserDefaults.standard.set(true, forKey: Self.migrationDoneKey) }

        let legacyURL = UserDefaults.standard.string(forKey: "opencode_server_url") ?? ""
        let legacyUsername = UserDefaults.standard.string(forKey: "opencode_server_username") ?? "opencode"
        let legacyPassword = KeychainService.load(key: "opencode_server_password") ?? ""

        guard !legacyURL.isEmpty else { return }

        // Check if we already have this connection (avoid duplicate on re-migration)
        let normalizedURL = normalizeURL(legacyURL)
        guard !connections.contains(where: {
            normalizeURL($0.serverURL) == normalizedURL && $0.username == legacyUsername
        }) else { return }

        // Migrate legacy model selection too
        let legacyProvider = UserDefaults.standard.string(forKey: "selectedProviderID")
        let legacyModel = UserDefaults.standard.string(forKey: "selectedModelID")

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
        UserDefaults.standard.removeObject(forKey: "opencode_server_url")
        UserDefaults.standard.removeObject(forKey: "opencode_server_username")
        UserDefaults.standard.removeObject(forKey: "selectedProviderID")
        UserDefaults.standard.removeObject(forKey: "selectedModelID")
        KeychainService.delete(key: "opencode_server_password")

        logger.info("Migrated legacy connection config to SavedConnectionsStore")
    }

    // MARK: - Helpers

    private func normalizeURL(_ url: String) -> String {
        url.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "https://", with: "")
    }
}

extension String {
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
