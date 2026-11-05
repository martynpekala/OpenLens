import Foundation

/// Pure grouping for the Sessions list across every connected server. No view code, so it is
/// testable without a host view.

/// Identity of a server on a group header. Identity, not status: the switcher and the Servers
/// screen already own status.
struct ServerTag: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// A name the user chose.
        case nickname
        /// The short host (`192.168.1.50:4096`), shown monospaced as hosts are everywhere else.
        case host
    }

    let text: String
    let kind: Kind

    init(nickname: String?, serverURL: String) {
        if let nickname = nickname?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank {
            text = nickname
            kind = .nickname
        } else {
            text = connectionServerDisplayName(serverURL) ?? serverURL
            kind = .host
        }
    }
}

/// What one server returned for the list. A failure keeps the last sessions that were loaded, so
/// a flaky server degrades its own sections instead of emptying them.
struct ServerSessionsResult: Equatable, Sendable {
    let serverID: String
    var sessions: [OCSession]
    var failureMessage: String?

    init(serverID: String, sessions: [OCSession], failureMessage: String? = nil) {
        self.serverID = serverID
        self.sessions = sessions
        self.failureMessage = failureMessage
    }
}

/// One row of the flat Sessions list: a session, the server it lives on and the workspace it
/// belongs to. The list is no longer grouped by project, so the row carries that identity itself.
struct SessionListEntry: Identifiable, Equatable {
    var id: String { "\(serverID)|\(session.id)" }
    let serverID: String
    let session: OCSession
    /// Scoped to the server, so one folder on two servers counts as two workspaces.
    let workspaceID: String
    /// The server (only while several are saved) and the workspace name, as the row tag shows them.
    let label: ServerQualifiedTitle
}

enum SessionSectionKind: String, Equatable, Sendable {
    case running
    case today
    /// Everything before today, in one bucket. A separate Yesterday reads as a landmark but
    /// earns little: the row already carries its own relative time, so the section only needs
    /// to say "not today".
    case earlier
}

struct SessionListSection: Identifiable, Equatable {
    let kind: SessionSectionKind
    let entries: [SessionListEntry]

    var id: String { kind.rawValue }
}

/// A server whose sessions could not be loaded; shown as a notice, never as a full-screen error.
struct SessionServerFailure: Equatable {
    let serverID: String
    let message: String
    let tag: ServerTag?
}

struct SessionAggregation: Equatable {
    var sections: [SessionListSection]
    var failures: [SessionServerFailure]

    var entries: [SessionListEntry] { sections.flatMap(\.entries) }

    /// Rows carry a workspace tag only when the displayed set spans more than one workspace:
    /// the same word repeated down a whole list is noise, and a single-project user should see
    /// clean rows.
    var showsWorkspaceTags: Bool {
        Set(entries.map(\.workspaceID)).count > 1
    }
}

enum SessionGrouping {
    /// Unscoped identity inside one server.
    static func baseGroupID(for session: OCSession) -> String {
        if let directory = normalizedDirectory(for: session) {
            return "directory:\(directory)"
        }
        if let projectID = session.projectID?.trimmingCharacters(in: .whitespacesAndNewlines), !projectID.isEmpty {
            return "projectID:\(projectID)"
        }
        return "unknown"
    }

    static func title(for session: OCSession, customName: (String) -> String?) -> String {
        if let directory = normalizedDirectory(for: session) {
            if let name = customName(directory) { return name }
            let lastComponent = URL(fileURLWithPath: directory).lastPathComponent
            if !lastComponent.isEmpty { return lastComponent }
        }
        if let projectID = session.projectID?.trimmingCharacters(in: .whitespacesAndNewlines), !projectID.isEmpty {
            return projectID
        }
        return AppText.projectFallback
    }

    static func normalizedDirectory(for session: OCSession) -> String? {
        session.directory?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
    }

    /// Which section a session that is not running belongs to.
    static func timeBucket(for session: OCSession, now: Date, calendar: Calendar) -> SessionSectionKind {
        let updated = Date(timeIntervalSince1970: session.updatedAt)
        let startOfToday = calendar.startOfDay(for: now)
        return updated >= startOfToday ? .today : .earlier
    }

    /// Merges every server's sessions into one recency-ordered list: running sessions pinned in
    /// their own section, everything else in coarse time buckets. There is deliberately no
    /// per-section cap, so a session touched minutes ago is never hidden behind a busy project.
    ///
    /// - Parameters:
    ///   - results: One entry per server, in the order the servers are displayed.
    ///   - tags: Server identities by id. Used only when `showsServerTags` is set.
    ///   - showsServerTags: `isMultiServerUIEnabled(savedServerCount:)`. When false no entry or
    ///     failure carries a server name.
    ///   - statuses: Live session statuses by server id then session id. Busy and retry run.
    ///   - workspaceFilterID: Keeps only that workspace's entries. Applied before the entries are
    ///     sectioned, so nothing downstream (section counts included) ever sees the others.
    static func aggregate(
        results: [ServerSessionsResult],
        tags: [String: ServerTag],
        showsServerTags: Bool,
        statuses: [String: [String: OCSessionStatus]] = [:],
        workspaceFilterID: String? = nil,
        now: Date = Date(),
        calendar: Calendar = .current,
        customName: (String) -> String?
    ) -> SessionAggregation {
        var entries: [SessionListEntry] = []
        var failures: [SessionServerFailure] = []

        for result in results {
            let tag = showsServerTags ? tags[result.serverID] : nil
            for session in result.sessions {
                entries.append(SessionListEntry(
                    serverID: result.serverID,
                    session: session,
                    workspaceID: "\(result.serverID)|\(baseGroupID(for: session))",
                    label: ServerQualifiedTitle(workspace: title(for: session, customName: customName), showingServer: tag)
                ))
            }
            if let message = result.failureMessage {
                failures.append(SessionServerFailure(serverID: result.serverID, message: message, tag: tag))
            }
        }

        if let workspaceFilterID {
            entries = entries.filter { $0.workspaceID == workspaceFilterID }
        }

        // Newest first. `sorted` is not guaranteed stable, so break ties by position.
        let ordered = entries.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.session.updatedAt != rhs.element.session.updatedAt {
                    return lhs.element.session.updatedAt > rhs.element.session.updatedAt
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)

        func isRunning(_ entry: SessionListEntry) -> Bool {
            let type = statuses[entry.serverID]?[entry.session.id]?.type
            return type == .busy || type == .retry
        }

        var buckets: [SessionSectionKind: [SessionListEntry]] = [:]
        for entry in ordered {
            let kind = isRunning(entry)
                ? SessionSectionKind.running
                : timeBucket(for: entry.session, now: now, calendar: calendar)
            buckets[kind, default: []].append(entry)
        }
        let order: [SessionSectionKind] = [.running, .today, .earlier]
        let sections = order.compactMap { kind -> SessionListSection? in
            guard let entries = buckets[kind], !entries.isEmpty else { return nil }
            return SessionListSection(kind: kind, entries: entries)
        }
        return SessionAggregation(sections: sections, failures: failures)
    }
}

/// What the Sessions toolbar capsule offers. One saved server gets no switcher at all.
struct ServerSwitchTargets: Equatable {
    struct Target: Equatable, Identifiable {
        let id: String
        let tag: ServerTag
    }

    let targets: [Target]

    /// Interactive only when there is something to choose between.
    var isInteractive: Bool { targets.count > 1 }
}

func serverSwitchTargets(_ targets: [(id: String, tag: ServerTag)]) -> ServerSwitchTargets {
    ServerSwitchTargets(
        targets: isMultiServerUIEnabled(savedServerCount: targets.count)
            ? targets.map { .init(id: $0.id, tag: $0.tag) }
            : []
    )
}

/// The server a new session is created on. The server the user is looking at (the list filter)
/// wins, then the active one; an id that is no longer saved falls back rather than creating on
/// a server the user cannot see.
func resolveNewSessionTarget(preferredServerID: String?, activeServerID: String, savedServerIDs: [String]) -> String {
    if savedServerIDs.isEmpty { return activeServerID }
    if let preferredServerID, savedServerIDs.contains(preferredServerID) { return preferredServerID }
    if savedServerIDs.contains(activeServerID) { return activeServerID }
    return savedServerIDs[0]
}

/// What a workspace-naming capsule shows: the workspace, with the server in front of it once
/// there is more than one saved server to tell apart.
struct ServerQualifiedTitle: Equatable {
    /// Nil at one saved server, which is what keeps the capsule exactly as it always was.
    let server: ServerTag?
    let workspace: String

    init(workspace: String, server: ServerTag?, savedServerCount: Int) {
        self.workspace = workspace
        self.server = isMultiServerUIEnabled(savedServerCount: savedServerCount) ? server : nil
    }

    /// For callers that already decided whether the server is shown (nil means it is not).
    init(workspace: String, showingServer server: ServerTag?) {
        self.workspace = workspace
        self.server = server
    }

    /// The server, separator and workspace as one phrase.
    var text: String {
        server.map { "\($0.text) · \(workspace)" } ?? workspace
    }

    /// The same phrase, for accessibility.
    var spokenText: String { text }
}

/// One workspace the Sessions filter can narrow to.
struct SessionWorkspaceOption: Identifiable, Equatable {
    /// `SessionListEntry.workspaceID`: scoped to the server.
    let id: String
    let label: ServerQualifiedTitle
}

extension SessionGrouping {
    /// The workspaces present in `entries`, one option each, ordered by name so the menu is
    /// findable. Pass the entries of the servers in view, before any workspace filter, so
    /// choosing a server narrows the options to that server's workspaces.
    static func workspaceOptions(in entries: [SessionListEntry]) -> [SessionWorkspaceOption] {
        var seen: Set<String> = []
        let options = entries.compactMap { entry -> SessionWorkspaceOption? in
            guard seen.insert(entry.workspaceID).inserted else { return nil }
            return SessionWorkspaceOption(id: entry.workspaceID, label: entry.label)
        }
        return options.sorted { lhs, rhs in
            let order = lhs.label.workspace.localizedCaseInsensitiveCompare(rhs.label.workspace)
            return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
        }
    }

    /// A workspace selection that is no longer among the options (the server filter moved, or
    /// its last session went away) means All, not a list filtered to nothing.
    static func resolvedWorkspaceFilter(_ selected: String?, options: [SessionWorkspaceOption]) -> String? {
        guard let selected, options.contains(where: { $0.id == selected }) else { return nil }
        return selected
    }
}

/// The capsule is a filter only when there is something to choose between: several servers or
/// several workspaces. One server with one workspace stays the plain host capsule.
func sessionFilterIsInteractive(serverCount: Int, workspaceCount: Int) -> Bool {
    serverCount > 1 || workspaceCount > 1
}

/// What the Sessions capsule says for the active filter. Composed with `ServerQualifiedTitle`:
/// a server alone is its tag, a workspace alone is its name, both read `server · workspace`.
/// With nothing chosen it says what is unfiltered: servers when several are saved, otherwise
/// workspaces.
func sessionFilterTitle(server: ServerTag?, workspace: String?, hasSeveralServers: Bool) -> String {
    if let workspace {
        return ServerQualifiedTitle(workspace: workspace, showingServer: server).text
    }
    if let server { return server.text }
    return hasSeveralServers ? AppText.sessionsAllServers : AppText.sessionsAllWorkspaces
}

extension ServerRegistry {
    /// The active server's identity, or nil while one server (or none) is saved.
    var activeServerTagWhenMultiServer: ServerTag? {
        guard isMultiServerUIEnabled(savedServerCount: savedServerContexts.count),
              let profile = profile(for: activeContext) else { return nil }
        return ServerTag(nickname: profile.nickname, serverURL: profile.serverURL)
    }
}

/// The servers to ask, in order, for the session a Live Activity link points at.
///
/// A link naming a server asks only that server, and only while it is connected. A legacy link
/// names none, because activities started before multi-server support carry no server: every
/// connected server is searched, the active one first.
func activityLinkCandidateServerIDs(
    linkedServerID: String?,
    activeServerID: String,
    connectedServerIDs: [String]
) -> [String] {
    if let linkedServerID {
        return connectedServerIDs.contains(linkedServerID) ? [linkedServerID] : []
    }
    var ordered = connectedServerIDs.filter { $0 == activeServerID }
    ordered += connectedServerIDs.filter { $0 != activeServerID }
    return ordered
}
