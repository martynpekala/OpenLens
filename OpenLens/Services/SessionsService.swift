import Foundation

struct WorkspaceActivityDay: Hashable, Sendable {
    let date: Date
    let turnCount: Int
}

struct SessionExecutionSnapshot: Sendable {
    let sessions: [OCSession]
    let statuses: [String: OCSessionStatus]
    let failedOutcomeSessionIDs: Set<String>

    init(sessions: [OCSession], statuses: [String: OCSessionStatus], failedOutcomeSessionIDs: Set<String> = []) {
        self.sessions = sessions
        self.statuses = statuses
        self.failedOutcomeSessionIDs = failedOutcomeSessionIDs
    }
}

/// Session CRUD and shared, server-confirmed attention markers.
/// No SwiftUI imports, no direct UI mutations.
/// Returns domain models and throws on failure.
@Observable
final class SessionsService {

    private let connection: ConnectionManager
    private var viewedMarkers: [String: Double] = [:]
    private var viewedClientID: ObjectIdentifier?

    /// Bumped after each server-confirmed archive mutation so session lists can
    /// reconcile their catalog (a restored conversation reappears, for example).
    private(set) var archiveMutationCount = 0

    var confirmedViewedMarkers: [String: Double] {
        guard let client = connection.client, viewedClientID == ObjectIdentifier(client) else { return [:] }
        return viewedMarkers
    }

    func applyingConfirmedViewedMarkers(to sessions: [OCSession]) -> [OCSession] {
        let markers = confirmedViewedMarkers
        return sessions.map { session in
            markers[session.id].map { session.withViewedMarker($0) } ?? session
        }
    }

    private func recordViewedMarker(_ session: OCSession, client: OpenCodeClient) {
        guard connection.client === client, let viewed = session.time.viewed,
              viewed.isFinite, viewed >= 0 else { return }
        let clientID = ObjectIdentifier(client)
        if viewedClientID != clientID {
            viewedMarkers = [:]
            viewedClientID = clientID
        }
        viewedMarkers[session.id] = max(viewedMarkers[session.id] ?? 0, viewed)
    }

    init(connection: ConnectionManager) {
        self.connection = connection
    }

    // MARK: - List

    /// Fetch all sessions sorted by most recently updated first.
    func listSessions() async throws -> [OCSession] {
        if ScreenshotFixtures.isEnabled {
            return ScreenshotFixtures.sessions
        }

        guard let client = connection.client else {
            throw OpenCodeError.notConnected
        }

        let sessions = try await client.listSessions()
        return visibleSessions(
            from: resolvingProjectDirectories(in: sessions)
        )
    }

    /// Fetch one page of root sessions for the current directory, newest first.
    ///
    /// Child sessions are hidden, so a server page can become empty after
    /// filtering. Such pages are skipped until at least one visible session is
    /// found or the list ends, so callers never receive an empty page while
    /// more sessions remain.
    func listSessionsPage(cursor: String? = nil, pageSize: Int = 30) async throws -> OCSessionPage {
        if ScreenshotFixtures.isEnabled {
            guard cursor == nil else { return OCSessionPage(sessions: [], nextCursor: nil) }
            return OCSessionPage(sessions: ScreenshotFixtures.sessions, nextCursor: nil)
        }

        guard let client = connection.client else {
            throw OpenCodeError.notConnected
        }

        var cursor = cursor
        var seenCursors = Set(cursor.map { [$0] } ?? [])
        while true {
            let page = try await client.listSessionsPage(cursor: cursor, limit: pageSize)
            let sessions = Self.rootSessions(in: resolvingProjectDirectories(in: page.sessions))
            guard sessions.isEmpty, let next = page.nextCursor else {
                return OCSessionPage(sessions: sessions, nextCursor: page.nextCursor)
            }
            guard seenCursors.insert(next).inserted else {
                throw OpenCodeError.invalidPayload("The v2 response repeated a pagination cursor.")
            }
            cursor = next
        }
    }

    /// Fetch the session catalog for the Sessions screen, across directories.
    func listAllSessions() async throws -> [OCSession] {
        if ScreenshotFixtures.isEnabled {
            return ScreenshotFixtures.sessions
        }

        guard let client = connection.client else {
            throw OpenCodeError.notConnected
        }

        let sessions = try await client.listAllSessions()
        return visibleSessions(from: resolvingProjectDirectories(in: sessions))
    }

    func getSession(id: String) async throws -> OCSession {
        if ScreenshotFixtures.isEnabled, ScreenshotFixtures.outcomeRefreshHasCompleted,
           ScreenshotFixtures.failsOutcomeRefresh, id == "session-screenshot-2" {
            throw URLError(.networkConnectionLost)
        }
        if ScreenshotFixtures.isEnabled, let session = ScreenshotFixtures.session(withID: id) {
            return session
        }

        guard let client = connection.client else {
            throw OpenCodeError.notConnected
        }

        let session = try await client.getSession(id: id)
        return resolvingProjectDirectory(for: session)
    }

    // MARK: - Create

    /// Create a new session, optionally with a title and workspace context.
    /// `model` is the new-session preference; nil lets a v2 server choose its
    /// default. It never alters an existing session.
    func createSession(
        title: String? = nil,
        workspaceDirectory: String? = nil,
        clearsWorkspaceContext: Bool = false,
        model: OCV2ModelRef? = nil
    ) async throws -> OCSession {
        if ScreenshotFixtures.isEnabled {
            let now = Date().timeIntervalSince1970 * 1000
            return OCSession(
                id: UUID().uuidString,
                projectID: ScreenshotFixtures.projectID,
                directory: workspaceDirectory?.nilIfBlank ?? ScreenshotFixtures.projectPath,
                title: title?.nilIfBlank ?? "Screenshot ideation",
                version: "v1",
                time: OCSessionTime(created: now, updated: now)
            )
        }

        guard let client = connection.client else {
            throw OpenCodeError.notConnected
        }

        if workspaceDirectory?.nilIfBlank != nil || clearsWorkspaceContext {
            await connection.setProjectContext(directory: workspaceDirectory)
        }

        let session = try await client.createSession(title: title, model: model)
        return resolvingProjectDirectory(for: session)
    }

    // MARK: - Delete

    /// Delete a session by its model.
    func deleteSession(_ session: OCSession) async throws {
        if ScreenshotFixtures.isEnabled {
            return
        }

        guard let client = connection.client else {
            throw OpenCodeError.notConnected
        }

        let _ = try await client.deleteSession(id: session.id)
    }

    // MARK: - Archive

    /// Archive a session, hiding it from the active list without deleting it.
    ///
    /// The response can be lost after the server commits, and older v2 servers
    /// acknowledge the mutation while silently ignoring the field. Always
    /// reconcile the canonical archive state; never hide a row the server has
    /// not confirmed archiving.
    func archiveSession(_ session: OCSession) async throws {
        if ScreenshotFixtures.isEnabled {
            return
        }

        guard let client = connection.client else {
            throw OpenCodeError.notConnected
        }

        try await client.setSessionArchived(id: session.id, archived: true)
        try Task.checkCancellation()
        let recovered = try await getSession(id: session.id)
        guard recovered.id == session.id, recovered.isArchived else {
            throw OpenCodeError.invalidPayload("The server has not confirmed archiving this session.")
        }
        archiveMutationCount &+= 1
    }

    /// Restore an archived session, returning the canonical session.
    ///
    /// Mirrors `archiveSession(_:):` older v2 servers acknowledge the mutation
    /// while silently ignoring the field, so the restored state is confirmed
    /// against the canonical session before the row leaves the archive.
    func unarchiveSession(_ session: OCSession) async throws -> OCSession {
        if ScreenshotFixtures.isEnabled {
            return session
        }

        guard let client = connection.client else {
            throw OpenCodeError.notConnected
        }

        try await client.setSessionArchived(id: session.id, archived: false)
        try Task.checkCancellation()
        let recovered = try await getSession(id: session.id)
        guard recovered.id == session.id, !recovered.isArchived else {
            throw OpenCodeError.invalidPayload("The server has not confirmed restoring this session.")
        }
        archiveMutationCount &+= 1
        return recovered
    }

    /// List archived sessions across every directory known to the connected
    /// server. Legacy v1 servers have no archive contract, so they report none.
    ///
    /// Older v2 servers acknowledge the `archived` filter by ignoring it and
    /// returning every session, so the decoded rows are confirmed against the
    /// canonical archive state instead of trusting the filter.
    func listArchivedSessions() async throws -> [OCSession] {
        if ScreenshotFixtures.isEnabled {
            return []
        }

        guard let client = connection.client else {
            throw OpenCodeError.notConnected
        }

        let sessions = try await client.listArchivedSessions()
        return resolvingProjectDirectories(in: sessions)
            .filter { $0.isArchived }
            .filter { $0.parentID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false }
            .sorted {
                ($0.time.archived ?? $0.time.updated) > ($1.time.archived ?? $1.time.updated)
            }
    }

    // MARK: - Update Title

    /// Rename a session.
    func updateTitle(session: OCSession, newTitle: String) async throws -> OCSession {
        if ScreenshotFixtures.isEnabled {
            return OCSession(
                id: session.id,
                projectID: session.projectID,
                directory: session.directory,
                parentID: session.parentID,
                title: newTitle,
                version: session.version,
                time: session.time,
                share: session.share,
                revert: session.revert,
                agent: session.agent,
                model: session.model,
                outcome: session.outcome
            )
        }

        guard let client = connection.client else {
            throw OpenCodeError.notConnected
        }

        let updatedSession = try await client.updateSession(id: session.id, title: newTitle)
        return resolvingProjectDirectory(for: updatedSession)
    }

    // MARK: - Ensure Session

    /// Returns the most recent session, or creates a new one if none exist.
    func ensureSession(model: OCV2ModelRef? = nil) async throws -> OCSession {
        if ScreenshotFixtures.isEnabled {
            return ScreenshotFixtures.defaultSession
        }

        guard connection.client != nil else {
            throw OpenCodeError.notConnected
        }

        let sorted = try await listSessions()
        if let latest = sorted.first {
            return latest
        }
        return try await createSession(model: model)
    }

    // MARK: - V2 Session Settings

    /// Explicitly switches an existing v2 session's model and variant.
    func switchModel(sessionID: String, model: OCV2ModelRef) async throws {
        guard let client = connection.client else {
            throw OpenCodeError.notConnected
        }
        try await client.switchSessionModel(sessionID: sessionID, model: model)
    }

    /// Explicitly switches an existing v2 session's agent.
    func switchAgent(sessionID: String, agent: String) async throws {
        guard let client = connection.client else {
            throw OpenCodeError.notConnected
        }
        try await client.switchSessionAgent(sessionID: sessionID, agent: agent)
    }

    static func rootSessions(in sessions: [OCSession]) -> [OCSession] {
        sessions.filter { session in
            session.parentID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
                && !session.isArchived
        }
    }

    private func visibleSessions(from sessions: [OCSession]) -> [OCSession] {
        let activeSessions = sessions.filter { !$0.isArchived }
        let rootSessions = activeSessions.filter { session in
            session.parentID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
        }

        let source = rootSessions.isEmpty ? activeSessions : rootSessions
        return source.sorted { $0.updatedAt > $1.updatedAt }
    }

    static func applyingProjectDirectories(
        _ sessions: [OCSession],
        projects: [OCProject]
    ) -> [OCSession] {
        var directoriesByProjectID: [String: String] = [:]
        for project in projects {
            guard let directory = project.worktree?.nilIfBlank,
                  directoriesByProjectID[project.id] == nil else {
                continue
            }
            directoriesByProjectID[project.id] = directory
        }

        return sessions.map { session in
            guard session.directory?.nilIfBlank == nil,
                  let projectID = session.projectID?.nilIfBlank,
                  let directory = directoriesByProjectID[projectID] else {
                return session
            }

            return OCSession(
                id: session.id,
                projectID: session.projectID,
                directory: directory,
                parentID: session.parentID,
                title: session.title,
                version: session.version,
                time: session.time,
                share: session.share,
                revert: session.revert,
                agent: session.agent,
                model: session.model,
                outcome: session.outcome
            )
        }
    }

    private func resolvingProjectDirectories(in sessions: [OCSession]) -> [OCSession] {
        Self.applyingProjectDirectories(
            sessions,
            projects: connection.currentProject.map { [$0] } ?? []
        )
    }

    private func resolvingProjectDirectory(for session: OCSession) -> OCSession {
        resolvingProjectDirectories(in: [session])[0]
    }

    /// The response can be lost after the server commits. Always reconcile the
    /// canonical watermark; never persist a locally guessed acknowledgement.
    func viewResult(_ observed: OCSession) async throws -> OCSession {
        guard connection.serverCapabilities?.protocolVersion == .v2,
              observed.hasUnreadResult, let idle = observed.completedResultMarker else { return observed }
        guard let client = connection.client else { throw OpenCodeError.notConnected }
        try Task.checkCancellation()
        var acknowledgementError: Error?
        do {
            try await client.viewSessionResult(id: observed.id, idle: idle)
        } catch {
            acknowledgementError = error
        }
        try Task.checkCancellation()
        let recovered = try await getSession(id: observed.id)
        try Task.checkCancellation()
        guard recovered.id == observed.id,
              recovered.hasViewedResult(at: idle) else {
            throw acknowledgementError ?? OpenCodeError.invalidPayload("The server has not confirmed viewing this result.")
        }
        recordViewedMarker(recovered, client: client)
        return recovered
    }

    /// Read-marker events need session info only, without recovering history.
    func refreshViewedMarker(id: String) async throws -> OCSession {
        guard let client = connection.client else { throw OpenCodeError.notConnected }
        let recovered = try await getSession(id: id)
        try Task.checkCancellation()
        guard connection.client === client else { throw CancellationError() }
        guard recovered.id == id else { throw OpenCodeError.invalidPayload("Mismatched viewed session.") }
        recordViewedMarker(recovered, client: client)
        return recovered
    }

    // MARK: - Abort

    /// Abort the active generation on a session.
    func abortSession(id: String) async throws {
        guard let client = connection.client else {
            throw OpenCodeError.notConnected
        }
        let _ = try await client.abortSession(id: id)
    }

    // MARK: - Status

    /// Fetch the status (busy/idle) for all sessions.
    func getSessionStatuses() async throws -> [String: OCSessionStatus] {
        if ScreenshotFixtures.isEnabled {
            return ScreenshotFixtures.sessionStatuses
        }

        guard let client = connection.client else {
            throw OpenCodeError.notConnected
        }
        return try await client.getSessionStatus()
    }

    /// Recover terminal and opened-session results independently of the catalog.
    /// Keep the last active snapshot if status recovery fails; invalidate a result
    /// if its canonical session cannot be read, and return IDs that need a retry.
    func refreshSessionOutcomes(
        in sessions: [OCSession],
        previousStatuses: [String: OCSessionStatus],
        openedSessionIDs: Set<String> = [],
        refreshInactive: Bool = false
    ) async -> SessionExecutionSnapshot {
        guard let statuses = try? await getSessionStatuses() else {
            let retryIDs = refreshInactive ? Set(sessions.map(\.id)) : openedSessionIDs
            return SessionExecutionSnapshot(sessions: sessions, statuses: previousStatuses, failedOutcomeSessionIDs: retryIDs)
        }
        guard !Task.isCancelled else {
            return SessionExecutionSnapshot(sessions: sessions, statuses: previousStatuses)
        }
        guard connection.serverCapabilities?.protocolVersion == .v2
                || (ScreenshotFixtures.isEnabled && ScreenshotFixtures.showsExecutionOutcomes) else {
            return SessionExecutionSnapshot(sessions: sessions, statuses: statuses)
        }
        let activeIDs = Set(statuses.filter { $0.value.type != .idle }.map(\.key))
        let endedIDs = Set(previousStatuses.filter { $0.value.type != .idle }.map(\.key)).subtracting(activeIDs)
        var refreshIDs = openedSessionIDs.union(endedIDs)
        if refreshInactive { refreshIDs.formUnion(sessions.map(\.id).filter { !activeIDs.contains($0) }) }
        let candidates = sessions.filter { refreshIDs.contains($0.id) }
        let freshSessions = await readCanonicalSessions(candidates)
        guard !Task.isCancelled else {
            return SessionExecutionSnapshot(sessions: sessions, statuses: previousStatuses)
        }
        var failures: Set<String> = []
        let refreshed = sessions.map { session in
            guard refreshIDs.contains(session.id) else { return session }
            if let fresh = freshSessions[session.id] { return fresh }
            failures.insert(session.id)
            return session.withoutExecutionOutcome()
        }
        return SessionExecutionSnapshot(sessions: refreshed, statuses: statuses, failedOutcomeSessionIDs: failures)
    }

    /// Periodic attention recovery reads only unread, inactive rows. Failure
    /// leaves their outcome and marker intact instead of entering outcome retries.
    func refreshUnreadResults(in sessions: [OCSession], statuses: [String: OCSessionStatus]) async -> [OCSession] {
        guard connection.serverCapabilities?.protocolVersion == .v2, let client = connection.client else { return sessions }
        let candidates = sessions.filter { $0.hasUnreadResult && (statuses[$0.id]?.type ?? .idle) == .idle }
        let fresh = await readCanonicalSessions(candidates)
        guard !Task.isCancelled, connection.client === client else { return sessions }
        let recovered = sessions.map { session in
            guard let canonical = fresh[session.id], canonical.hasUnreadResult,
                  let idle = canonical.completedResultMarker,
                  idle > (session.completedResultMarker ?? 0) else { return session }
            // A viewed watermark for an older completion must be compared
            // against the newly discovered result, not this row's stale idle.
            return canonical
        }
        for session in fresh.values { recordViewedMarker(session, client: client) }
        return applyingConfirmedViewedMarkers(to: recovered)
    }

    private func readCanonicalSessions(_ sessions: [OCSession]) async -> [String: OCSession] {
        return await withTaskGroup(of: (String, OCSession?).self) { group in
            var remaining = sessions.makeIterator()
            // Limit concurrent reads; callers choose the total candidate set.
            for _ in 0..<4 {
                guard let session = remaining.next() else { break }
                group.addTask { (session.id, try? await self.getSession(id: session.id)) }
            }
            var fresh: [String: OCSession] = [:]
            for await (id, session) in group {
                if Task.isCancelled { group.cancelAll(); continue }
                if let session, session.id == id { fresh[id] = session }
                if let next = remaining.next() {
                    group.addTask { (next.id, try? await self.getSession(id: next.id)) }
                }
            }
            return fresh
        }
    }

    // MARK: - Activity

    /// Returns per-day turn activity for the selected project/worktree.
    func loadActivityDays(
        projectID: String?,
        directory: String?,
        since startDate: Date,
        calendar: Calendar = .current
    ) async throws -> [WorkspaceActivityDay] {
        if ScreenshotFixtures.isEnabled {
            return ScreenshotFixtures.activityDays(since: startDate, calendar: calendar)
        }

        guard let client = connection.client else {
            throw OpenCodeError.notConnected
        }

        let sessions = visibleSessions(from: try await client.listSessions())
        let startOfDay = calendar.startOfDay(for: startDate)
        let matchingSessions = sessions.filter {
            matchesProjectScope($0, projectID: projectID, directory: directory)
                && mayContainActivitySince($0, startOfDay: startOfDay)
        }

        let messagesBySession = try await loadMessages(for: matchingSessions, client: client)
        return Self.turnActivityDays(from: messagesBySession, since: startOfDay, calendar: calendar)
    }

    static func turnActivityDays(
        from messagesBySession: [[OCMessageWithParts]],
        since startDate: Date,
        calendar: Calendar = .current
    ) -> [WorkspaceActivityDay] {
        var countsByDay: [Date: Int] = [:]

        let startOfDay = calendar.startOfDay(for: startDate)
        for message in messagesBySession.flatMap({ $0 }) {
            // A user message starts one conversational turn; assistant/tool messages are part of that turn.
            guard message.info.role == .user,
                  let createdTimestamp = message.info.createdTimestamp else {
                continue
            }

            let createdDate = Date(timeIntervalSince1970: createdTimestamp)
            let bucket = calendar.startOfDay(for: createdDate)
            guard bucket >= startOfDay else { continue }
            countsByDay[bucket, default: 0] += 1
        }

        return countsByDay
            .map { WorkspaceActivityDay(date: $0.key, turnCount: $0.value) }
            .sorted { $0.date < $1.date }
    }

    private func loadMessages(for sessions: [OCSession], client: OpenCodeClient) async throws -> [[OCMessageWithParts]] {
        var messagesBySession: [[OCMessageWithParts]] = []
        messagesBySession.reserveCapacity(sessions.count)

        for session in sessions {
            messagesBySession.append(try await client.listMessages(sessionID: session.id))
        }

        return messagesBySession
    }

    private func mayContainActivitySince(_ session: OCSession, startOfDay: Date) -> Bool {
        guard session.updatedAt > 0 else { return true }
        return Date(timeIntervalSince1970: session.updatedAt) >= startOfDay
    }

    private func matchesProjectScope(_ session: OCSession, projectID: String?, directory: String?) -> Bool {
        let normalizedProjectID = normalizedIdentifier(projectID)
        let normalizedDirectory = normalizedPath(directory)

        if let normalizedProjectID,
           normalizedIdentifier(session.projectID) == normalizedProjectID {
            return true
        }

        if let normalizedDirectory,
              let sessionDirectory = normalizedPath(session.directory),
              pathsOverlap(sessionDirectory, normalizedDirectory) {
            return true
        }

        return normalizedProjectID == nil && normalizedDirectory == nil
    }

    private func normalizedIdentifier(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
    }

    private func normalizedPath(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank else {
            return nil
        }

        return URL(fileURLWithPath: trimmed).standardizedFileURL.path
    }

    private func pathsOverlap(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs || lhs.hasPrefix(rhs + "/") || rhs.hasPrefix(lhs + "/")
    }
}
