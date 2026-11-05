import Foundation
import os

struct SavedModelSelection: Codable, Equatable, Hashable, Identifiable {
    let providerID: String
    let modelID: String

    var id: String { "\(providerID)/\(modelID)" }
}

struct QuickModelAssignment: Codable, Equatable, Hashable, Identifiable {
    let providerID: String
    let modelID: String
    var variant: String?

    init(providerID: String, modelID: String, variant: String? = nil) {
        self.providerID = providerID
        self.modelID = modelID
        self.variant = variant
    }

    var id: String { "\(providerID)/\(modelID)" }
}

enum ModelQuickAction: String, CaseIterable, Hashable, Identifiable {
    case code
    case review
    case prsAndStuff
    case free

    var id: String { rawValue }

    var title: String {
        switch self {
        case .code: AppText.code
        case .review: AppText.review
        case .prsAndStuff: AppText.prsAndStuff
        case .free: AppText.free
        }
    }

    var systemImage: String {
        switch self {
        case .code: "chevron.left.forwardslash.chevron.right"
        case .review: "checkmark.circle"
        case .prsAndStuff: "arrow.triangle.merge"
        case .free: "gift"
        }
    }
}

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

    /// Recently selected models for this connection, newest first.
    var recentModelSelections: [SavedModelSelection]?

    /// Per-connection default model: provider ID used for new sessions.
    var defaultProviderID: String? = nil

    /// Per-connection default model: model ID used for new sessions.
    var defaultModelID: String? = nil

    /// Per-connection project/worktree directory override.
    var selectedProjectDirectory: String?

    /// Recent project/worktree directories for this connection, newest first.
    var recentProjectDirectories: [String]?

    /// Timestamp of last successful connection (drives recency queries such as
    /// auto-connect and suggestions; it does not order `connections`).
    var lastConnectedAt: Date?

    /// Optional user-chosen name for this server.
    var nickname: String?

    /// Display label: the nickname when set, otherwise the URL without its scheme.
    var displayName: String {
        if let nickname = nickname?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank {
            return nickname
        }
        // Strip scheme for a cleaner label
        return serverURL
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "https://", with: "")
    }

    // MARK: - Computed (same as old ConnectionConfig)

    nonisolated init(
        id: String,
        serverURL: String,
        username: String,
        password: String,
        selectedProviderID: String? = nil,
        selectedModelID: String? = nil,
        selectedVariant: String? = nil,
        recentModelSelections: [SavedModelSelection]? = nil,
        selectedProjectDirectory: String? = nil,
        recentProjectDirectories: [String]? = nil,
        lastConnectedAt: Date? = nil,
        nickname: String? = nil
    ) {
        self.id = id
        self.serverURL = serverURL
        self.username = username
        self.password = password
        self.selectedProviderID = selectedProviderID
        self.selectedModelID = selectedModelID
        self.selectedVariant = selectedVariant
        self.recentModelSelections = recentModelSelections
        self.defaultProviderID = nil
        self.defaultModelID = nil
        self.selectedProjectDirectory = selectedProjectDirectory
        self.recentProjectDirectories = recentProjectDirectories
        self.lastConnectedAt = lastConnectedAt
        self.nickname = nickname
    }

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

struct SavedConnectionPublicSnapshot: Codable, Equatable {
    var id: String
    var serverURL: String
    var username: String
    /// Only read to drop profiles saved by the removed OpenLens Remote feature.
    var remoteGatewayID: String?
    var selectedProviderID: String?
    var selectedModelID: String?
    var selectedVariant: String?
    var recentModelSelections: [SavedModelSelection]?
    var defaultProviderID: String? = nil
    var defaultModelID: String? = nil
    var selectedProjectDirectory: String?
    var recentProjectDirectories: [String]?
    var lastConnectedAt: Date?
    var nickname: String?

    nonisolated init(connection: SavedConnection) {
        id = connection.id
        serverURL = connection.serverURL
        username = connection.username
        selectedProviderID = connection.selectedProviderID
        selectedModelID = connection.selectedModelID
        selectedVariant = connection.selectedVariant
        recentModelSelections = connection.recentModelSelections
        defaultProviderID = connection.defaultProviderID
        defaultModelID = connection.defaultModelID
        selectedProjectDirectory = connection.selectedProjectDirectory
        recentProjectDirectories = connection.recentProjectDirectories
        lastConnectedAt = connection.lastConnectedAt
        nickname = connection.nickname
    }

    nonisolated func savedConnectionWithoutPassword() -> SavedConnection {
        var connection = SavedConnection(
            id: id,
            serverURL: serverURL,
            username: username,
            password: "",
            selectedProviderID: selectedProviderID,
            selectedModelID: selectedModelID,
            selectedVariant: selectedVariant,
            recentModelSelections: recentModelSelections,
            selectedProjectDirectory: selectedProjectDirectory,
            recentProjectDirectories: recentProjectDirectories,
            lastConnectedAt: lastConnectedAt,
            nickname: nickname
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

    /// Saved connections in stable display order: newly added first, never
    /// reordered by connect activity. Use `mostRecent` / `suggestions(for:)` for recency.
    private(set) var connections: [SavedConnection] = []

    /// The connection currently in use (set after successful connect).
    private(set) var activeConnectionID: String?

    /// The connection that was most recently made active, persisted across launches.
    /// Unlike `activeConnectionID`, disconnecting does not clear it; forgetting the connection does.
    private(set) var lastActiveConnectionID: String? {
        didSet {
            guard lastActiveConnectionID != oldValue, let lastActiveDefaults else { return }
            if let lastActiveConnectionID {
                lastActiveDefaults.set(lastActiveConnectionID, forKey: Self.lastActiveConnectionDefaultsKey)
            } else {
                lastActiveDefaults.removeObject(forKey: Self.lastActiveConnectionDefaultsKey)
            }
        }
    }

    /// Number of coalesced write attempts, counted before the `shouldPersist` guard so tests can observe coalescing.
    private(set) var persistWriteAttempts = 0

    /// Keychain key for the entire connections list.
    private static let keychainKey = "saved_connections_v1"
    private static let publicSnapshotDefaultsKey = "saved_connections_public_snapshots_v1"
    private static let lastActiveConnectionDefaultsKey = "saved_connections_last_active_id_v1"

    /// Flag to track whether migration from legacy UserDefaults has run.
    private static let migrationDoneKey = "saved_connections_migrated"
    private static let maximumSavedConnections = 20
    private static let maximumRecentModelSelections = 5
    private static let maximumRecentProjectDirectories = 5

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "OpenLens", category: "SavedConnectionsStore")
    private let shouldPersist: Bool
    private let userDefaults: UserDefaults
    /// Where `lastActiveConnectionID` is stored; nil for test stores without an injected suite.
    private let lastActiveDefaults: UserDefaults?
    private var hasPendingPersist = false
    private var isPersistFlushScheduled = false

    init() {
        userDefaults = .standard
        lastActiveDefaults = .standard
        shouldPersist = true
        connections = Self.loadPersistedConnections(userDefaults: userDefaults)
        lastActiveConnectionID = Self.loadLastActiveConnectionID(
            userDefaults: userDefaults,
            connections: connections
        )
        migrateFromLegacyIfNeeded()
        trimToSavedConnectionLimitIfNeeded()
    }

    /// Test initializer: never touches the Keychain. Pass `userDefaults` (an ephemeral suite) to
    /// exercise `lastActiveConnectionID` persistence; without it nothing is written anywhere.
    init(initialConnections: [SavedConnection], userDefaults: UserDefaults? = nil) {
        self.userDefaults = userDefaults ?? .standard
        lastActiveDefaults = userDefaults
        shouldPersist = false
        connections = Self.limited(initialConnections)
        if let userDefaults {
            lastActiveConnectionID = Self.loadLastActiveConnectionID(
                userDefaults: userDefaults,
                connections: connections
            )
        }
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
            lastActiveConnectionID = connection.id
            persistSoon()
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
            lastActiveConnectionID = connection.id
            persistSoon()
            return connection
        }
    }

    /// Updates model selection for a specific connection.
    func updateModelSelection(connectionID: String, providerID: String, modelID: String, variant: String?) {
        guard let index = connections.firstIndex(where: { $0.id == connectionID }) else { return }
        connections[index].selectedProviderID = providerID
        connections[index].selectedModelID = modelID
        connections[index].selectedVariant = variant
        connections[index].recentModelSelections = Self.updatedRecentModelSelections(
            existing: connections[index].recentModelSelections ?? [],
            selected: SavedModelSelection(providerID: providerID, modelID: modelID)
        )
        persist()
    }

    /// Records a model in the recent-model history without changing the
    /// connection's saved selection.
    func recordRecentModelSelection(connectionID: String, providerID: String, modelID: String) {
        guard let index = connections.firstIndex(where: { $0.id == connectionID }) else { return }
        connections[index].recentModelSelections = Self.updatedRecentModelSelections(
            existing: connections[index].recentModelSelections ?? [],
            selected: SavedModelSelection(providerID: providerID, modelID: modelID)
        )
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
        persistSoon()
    }

    /// Sets or clears (nil or blank) the nickname for a specific connection.
    func updateNickname(connectionID: String, nickname: String?) {
        guard let index = connections.firstIndex(where: { $0.id == connectionID }) else { return }
        connections[index].nickname = nickname?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
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

    /// Returns recently selected models for the given connection, newest first.
    /// The current selection is included for connections saved before model
    /// history was added.
    func recentModelSelections(connectionID: String) -> [SavedModelSelection] {
        guard let connection = connections.first(where: { $0.id == connectionID }) else { return [] }

        let currentSelection: SavedModelSelection?
        if let providerID = connection.selectedProviderID?.nilIfBlank,
           let modelID = connection.selectedModelID?.nilIfBlank {
            currentSelection = SavedModelSelection(providerID: providerID, modelID: modelID)
        } else {
            currentSelection = nil
        }

        return Self.updatedRecentModelSelections(
            existing: connection.recentModelSelections ?? [],
            selected: currentSelection
        )
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
        connections.removeAll { $0.id == connection.id }
        if activeConnectionID == connection.id {
            activeConnectionID = nil
        }
        if lastActiveConnectionID == connection.id {
            lastActiveConnectionID = nil
        }
        persist()
    }

    /// Removes a connection by ID.
    func removeConnection(id: String) {
        connections.removeAll { $0.id == id }
        if activeConnectionID == id {
            activeConnectionID = nil
        }
        if lastActiveConnectionID == id {
            lastActiveConnectionID = nil
        }
        persist()
    }

    /// Clears the active connection marker (on disconnect).
    func clearActiveConnection() {
        activeConnectionID = nil
    }

    /// Returns the most recently connected connection.
    var mostRecent: SavedConnection? {
        connectionsByRecency.first
    }

    /// Connections ordered by `lastConnectedAt`, newest first; ties keep array order.
    var connectionsByRecency: [SavedConnection] {
        Self.byRecency(connections)
    }

    /// Saved connections matching a URL prefix (for suggestions/autocomplete).
    func suggestions(for urlPrefix: String) -> [SavedConnection] {
        let prefix = urlPrefix.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty else { return connectionsByRecency }
        return connectionsByRecency.filter {
            $0.displayName.lowercased().contains(prefix) ||
            $0.serverURL.lowercased().contains(prefix)
        }
    }

    // MARK: - Persistence

    /// Marks the store dirty and schedules one write for the next main-actor turn, so several
    /// synchronous mutations collapse into a single Keychain write. The in-memory cap applies immediately.
    /// Writes now. Use for anything the user did on purpose -- naming a server, forgetting one,
    /// choosing a model -- so a termination straight after the action cannot lose it.
    private func persist() {
        limitConnections()
        hasPendingPersist = true
        flushPendingPersist()
    }

    /// Defers the write to the next main-actor turn, collapsing a burst into one. Only for state
    /// the connect path re-derives anyway: a single connect calls `updateProjectSelection` three
    /// times, so N servers connecting at launch would otherwise cost 3N whole-array Keychain
    /// writes -- passwords included -- in the first second.
    private func persistSoon() {
        limitConnections()
        hasPendingPersist = true
        guard !isPersistFlushScheduled else { return }
        isPersistFlushScheduled = true
        Task { [weak self] in
            self?.flushPendingPersist()
        }
    }

    /// Writes pending changes now. Safe to call at any time; does nothing when nothing is pending.
    func flushPendingPersist() {
        isPersistFlushScheduled = false
        guard hasPendingPersist else { return }
        hasPendingPersist = false
        persistWriteAttempts += 1
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

    private static func loadLastActiveConnectionID(
        userDefaults: UserDefaults,
        connections: [SavedConnection]
    ) -> String? {
        guard let id = userDefaults.string(forKey: lastActiveConnectionDefaultsKey),
              connections.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    private static func loadFromKeychain() -> [SavedConnection] {
        KeychainService.loadCodable([SavedConnection].self, key: keychainKey) ?? []
    }

    static func mergeKeychainConnections(
        _ keychainConnections: [SavedConnection],
        withPublicSnapshots snapshots: [SavedConnectionPublicSnapshot]
    ) -> [SavedConnection] {
        // OpenLens Remote was removed; its profiles can no longer connect.
        let legacyRemoteIDs = Set(snapshots.filter { $0.remoteGatewayID != nil }.map(\.id))
        for id in legacyRemoteIDs {
            KeychainService.delete(key: "openlens_remote_connection_v1_" + id)
        }
        var merged = keychainConnections.filter { !legacyRemoteIDs.contains($0.id) }

        for snapshot in snapshots where !legacyRemoteIDs.contains(snapshot.id) {
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

        return limited(merged)
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
        let originalCount = connections.count
        limitConnections()

        if connections.count != originalCount {
            persistSoon()
        }
    }

    private func limitConnections() {
        connections = Self.limited(connections)

        if let activeConnectionID, !connections.contains(where: { $0.id == activeConnectionID }) {
            self.activeConnectionID = nil
        }
    }

    /// Caps the list while preserving array order, dropping the least recently connected first.
    private static func limited(_ connections: [SavedConnection]) -> [SavedConnection] {
        guard connections.count > maximumSavedConnections else { return connections }
        let keptIDs = Set(byRecency(connections).prefix(maximumSavedConnections).map(\.id))
        return connections.filter { keptIDs.contains($0.id) }
    }

    private static func byRecency(_ connections: [SavedConnection]) -> [SavedConnection] {
        connections.enumerated().sorted { lhs, rhs in
            let l = lhs.element.lastConnectedAt ?? .distantPast
            let r = rhs.element.lastConnectedAt ?? .distantPast
            return l != r ? l > r : lhs.offset < rhs.offset
        }.map(\.element)
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

    private static func updatedRecentModelSelections(
        existing: [SavedModelSelection],
        selected: SavedModelSelection?
    ) -> [SavedModelSelection] {
        var selections = [selected].compactMap { $0 }
        selections.append(contentsOf: existing)

        var seen = Set<String>()
        let deduplicated = selections.filter { seen.insert($0.id).inserted }
        return Array(deduplicated.prefix(maximumRecentModelSelections))
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
        // Synchronous, because the legacy password is deleted just below and a kill in between
        // would lose the credential.
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
        selectedProviderID = snapshot.selectedProviderID
        selectedModelID = snapshot.selectedModelID
        selectedVariant = snapshot.selectedVariant
        recentModelSelections = snapshot.recentModelSelections
        defaultProviderID = snapshot.defaultProviderID
        defaultModelID = snapshot.defaultModelID
        selectedProjectDirectory = snapshot.selectedProjectDirectory
        recentProjectDirectories = snapshot.recentProjectDirectories
        lastConnectedAt = snapshot.lastConnectedAt
        nickname = snapshot.nickname
    }
}

extension String {
    nonisolated var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
