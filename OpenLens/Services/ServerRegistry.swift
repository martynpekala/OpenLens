import Foundation
import Observation
import os

/// Owns every `ServerContext` and decides which of them hold a live connection.
///
/// *Saved is not connected.* `SavedConnectionsStore` persists up to 20 profiles; the registry
/// keeps at most `maximumConcurrentConnections` of them live at once. The cap lives here and
/// nowhere else.
///
/// The UI still shows one server at a time: `activeContext` is the one the root views read.
/// The others stay connected in the background so that switching never has to reconnect.
@MainActor
@Observable
final class ServerRegistry {
    /// Why a connection was not started. Carries what a UI needs to explain it.
    enum ConnectionError: Error, Equatable, LocalizedError {
        case connectionLimitReached(maximum: Int)

        var errorDescription: String? {
            switch self {
            case .connectionLimitReached(let maximum):
                "OpenLens can stay connected to \(maximum) servers at once. Disconnect one before connecting another."
            }
        }
    }

    static let maximumConcurrentConnections = 4

    /// Id of the placeholder context that exists while no profile is saved, so the connect screen
    /// has a connection to drive.
    private static let draftContextID = "default"

    /// One context per saved profile, in the store's stable display order. While nothing is saved
    /// there is a single profile-less draft context.
    private(set) var contexts: [ServerContext]
    var activeServerID: String?

    /// Called with the id of a server that was just removed, so per-server state kept elsewhere
    /// (such as the router's paths) can be dropped.
    @ObservationIgnored var onServerRemoved: ((String) -> Void)?
    @ObservationIgnored private let savedConnectionsStore: SavedConnectionsStore
    @ObservationIgnored private let liveActivity: any LiveActivityProviding
    @ObservationIgnored private let recordedReplayStore: RecordedReplayStore
    @ObservationIgnored private let makeTransport: (@Sendable (URL) -> any OpenCodeTransport)?
    @ObservationIgnored private let localNetworkAccessProbe: (any LocalNetworkAccessProbing)?

    /// The context the root views read. The registry always holds at least one context, and
    /// `activeServerID` always names one of them.
    var activeContext: ServerContext {
        contexts.first { $0.id == activeServerID } ?? contexts[0]
    }

    /// - Parameters:
    ///   - preparedContext: A context the composition root built itself (the screenshot/demo
    ///     path). When given it is the only context and saved profiles are not materialised.
    ///   - additionalPreparedContexts: More ready-made contexts held beside `preparedContext`,
    ///     for the multi-server screenshot path.
    ///   - makeTransport: Fakes the network for every connection the registry builds.
    ///   - localNetworkAccessProbe: Replaces the real local-network probe, for tests.
    init(
        savedConnectionsStore: SavedConnectionsStore,
        liveActivity: any LiveActivityProviding,
        recordedReplayStore: RecordedReplayStore,
        makeTransport: (@Sendable (URL) -> any OpenCodeTransport)? = nil,
        localNetworkAccessProbe: (any LocalNetworkAccessProbing)? = nil,
        preparedContext: ServerContext? = nil,
        additionalPreparedContexts: [ServerContext] = []
    ) {
        self.savedConnectionsStore = savedConnectionsStore
        self.liveActivity = liveActivity
        self.recordedReplayStore = recordedReplayStore
        self.makeTransport = makeTransport
        self.localNetworkAccessProbe = localNetworkAccessProbe
        self.contexts = []

        if let preparedContext {
            contexts = [preparedContext] + additionalPreparedContexts
            activeServerID = preparedContext.id
            return
        }

        contexts = savedConnectionsStore.connections.map { makeContext(for: $0) }
        ensureAContextExists()
        // Same rule `ConnectionManager.reconnect()` uses to pick the server to reopen, so the
        // context the connect screen drives is the one whose profile it connects to.
        let preferred = savedConnectionsStore.lastActiveConnectionID
            .flatMap { id in savedConnectionsStore.connections.first { $0.id == id } }
            ?? savedConnectionsStore.mostRecent
        activeServerID = preferred.flatMap { context(forProfileID: $0.id)?.id } ?? contexts[0].id
        recordActiveServerAsLastActive()
    }

    // MARK: - Lookup

    func context(id: String) -> ServerContext? {
        contexts.first { $0.id == id }
    }

    /// The context built for, or currently connected to, a saved profile.
    func context(forProfileID profileID: String) -> ServerContext? {
        contexts.first { $0.profile?.id == profileID }
            ?? contexts.first { $0.connection.connectionID == profileID }
    }

    /// Connecting, connected or reconnecting: the states that occupy one of the connection slots.
    func isLive(_ context: ServerContext) -> Bool {
        switch context.connection.state {
        case .connecting, .connected, .reconnecting: true
        case .disconnected, .error: false
        }
    }

    /// The saved profile behind a context: the store's current copy (so a rename shows at once),
    /// else the snapshot the context was built from. `nil` for the draft context.
    func profile(for context: ServerContext) -> SavedConnection? {
        savedConnectionsStore.connections.first {
            $0.id == context.id || $0.id == context.connection.connectionID
        } ?? context.profile
    }

    /// Contexts that stand for a saved server, in display order.
    var savedServerContexts: [ServerContext] {
        contexts.filter { profile(for: $0) != nil }
    }

    var liveConnectionCount: Int {
        contexts.filter(isLive).count
    }

    // MARK: - Connecting

    /// Connects the most recently used profiles, up to the cap, and leaves the rest saved but idle.
    /// Contexts that are already live count toward the cap and are left alone, so this is safe to
    /// call while the active server is mid-connect.
    func connectAll() async {
        var freeSlots = Self.maximumConcurrentConnections - liveConnectionCount
        var picks: [(ServerContext, SavedConnection)] = []
        for profile in savedConnectionsStore.connectionsByRecency where profile.isConfigured {
            guard freeSlots > 0 else { break }
            guard let context = context(forProfileID: profile.id), !isLive(context) else { continue }
            picks.append((context, profile))
            freeSlots -= 1
        }

        await withTaskGroup(of: Void.self) { group in
            for (context, profile) in picks {
                group.addTask { @MainActor in
                    await context.connection.connect(profile: profile, method: .autoReconnect)
                }
            }
        }
    }

    /// Connects one profile, building its context if it has none yet.
    /// Throws `ConnectionError.connectionLimitReached` when every slot is taken; the profile
    /// stays saved either way.
    func connect(profile: SavedConnection, method: ConnectionMethod = .manual) async throws {
        let context = context(forProfileID: profile.id) ?? appendContext(for: profile)
        if !isLive(context), liveConnectionCount >= Self.maximumConcurrentConnections {
            throw ConnectionError.connectionLimitReached(maximum: Self.maximumConcurrentConnections)
        }
        await context.connection.connect(profile: profile, method: method)
    }

    func disconnect(id: String) {
        context(id: id)?.connection.disconnect()
    }

    /// Makes a connected (or connecting) context the one the UI shows. Others are not touched.
    @discardableResult
    func activate(id: String) -> Bool {
        guard context(id: id) != nil else { return false }
        activeServerID = id
        recordActiveServerAsLastActive()
        return true
    }

    /// Persists the active server as the one to reopen on the next launch. Call again once a
    /// draft context has connected, because only then does it have a saved profile to name.
    func recordActiveServerAsLastActive() {
        let context = activeContext
        guard let profileID = context.profile?.id ?? context.connection.connectionID else { return }
        savedConnectionsStore.setLastActiveConnection(id: profileID)
    }

    // MARK: - Saved profiles

    /// Saves a server (or refreshes the existing profile for the same URL and user) and gives it
    /// a context. Saving does not connect.
    @discardableResult
    func add(serverURL: String, username: String, password: String, nickname: String? = nil) -> SavedConnection {
        let saved = savedConnectionsStore.saveConnection(
            serverURL: serverURL,
            username: username,
            password: password
        )
        if let nickname {
            savedConnectionsStore.updateNickname(connectionID: saved.id, nickname: nickname)
        }
        if context(forProfileID: saved.id) == nil {
            discardIdleDraftContext()
            appendContext(for: saved)
        }
        return savedConnectionsStore.connections.first { $0.id == saved.id } ?? saved
    }

    func update(id: String, nickname: String?) {
        savedConnectionsStore.updateNickname(connectionID: id, nickname: nickname)
    }

    /// Forgets a server: disconnects it, drops its context and deletes the saved profile.
    func remove(id: String) {
        guard let context = context(id: id) else { return }
        let profileID = context.connection.connectionID ?? context.profile?.id
        context.connection.disconnect()
        contexts.removeAll { $0.id == id }
        if let profileID {
            savedConnectionsStore.removeConnection(id: profileID)
        }
        ensureAContextExists()
        if activeServerID == id {
            activeServerID = contexts[0].id
            recordActiveServerAsLastActive()
        }
        onServerRemoved?(id)
    }

    // MARK: - Building contexts

    @discardableResult
    private func appendContext(for profile: SavedConnection) -> ServerContext {
        let context = makeContext(for: profile)
        contexts.append(context)
        return context
    }

    private func makeContext(for profile: SavedConnection) -> ServerContext {
        ServerContext(
            id: profile.id,
            profile: profile,
            connection: makeConnection(),
            liveActivity: liveActivity,
            savedConnectionsStore: savedConnectionsStore,
            recordedReplayStore: recordedReplayStore
        )
    }

    /// The draft exists only so the connect screen has a connection to drive before anything is
    /// saved. A manual connect adopts it, because the context is matched by its connection id. A
    /// server added without connecting does not, so drop the draft rather than leave a
    /// profile-less context that a servers list would render as a phantom row.
    private func discardIdleDraftContext() {
        contexts.removeAll { context in
            context.id == Self.draftContextID
                && context.profile == nil
                && context.connection.connectionID == nil
                && !isLive(context)
        }
        if let activeServerID, context(id: activeServerID) == nil {
            self.activeServerID = contexts.first?.id
        }
    }

    private func ensureAContextExists() {
        guard contexts.isEmpty else { return }
        contexts = [ServerContext(
            id: Self.draftContextID,
            connection: makeConnection(),
            liveActivity: liveActivity,
            savedConnectionsStore: savedConnectionsStore,
            recordedReplayStore: recordedReplayStore
        )]
    }

    private func makeConnection() -> ConnectionManager {
        let connection = if let localNetworkAccessProbe {
            ConnectionManager(localNetworkAccessProbe: localNetworkAccessProbe, makeTransport: makeTransport)
        } else {
            ConnectionManager(makeTransport: makeTransport)
        }
        connection.savedConnectionsStore = savedConnectionsStore
        return connection
    }
}
