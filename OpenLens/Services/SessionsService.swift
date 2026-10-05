import Foundation

struct WorkspaceActivityDay: Hashable, Sendable {
    let date: Date
    let turnCount: Int
}

/// Pure service for session CRUD operations.
/// No SwiftUI imports, no direct UI mutations.
/// Returns domain models and throws on failure.
final class SessionsService {

    private let connection: ConnectionManager

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
                model: session.model
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
        }
    }

    private func visibleSessions(from sessions: [OCSession]) -> [OCSession] {
        let rootSessions = sessions.filter { session in
            session.parentID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
        }

        let source = rootSessions.isEmpty ? sessions : rootSessions
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
                model: session.model
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
