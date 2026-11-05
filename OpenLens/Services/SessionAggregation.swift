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

struct SessionGroup: Identifiable, Equatable {
    /// Scoped to the server, so the same folder (or two directory-less sessions) on two servers
    /// never share a group, nor an expanded/collapsed state.
    let id: String
    let serverID: String
    let title: String
    let subtitle: String?
    let sessions: [OCSession]
    /// Set only while more than one server is saved; the header shows it.
    let tag: ServerTag?

    var latestActivity: Double { sessions.map(\.updatedAt).max() ?? 0 }
}

/// A server whose sessions could not be loaded; shown as a notice, never as a full-screen error.
struct SessionServerFailure: Equatable {
    let serverID: String
    let message: String
    let tag: ServerTag?
}

struct SessionAggregation: Equatable {
    var groups: [SessionGroup]
    var failures: [SessionServerFailure]
}

enum SessionGrouping {
    static func groupID(serverID: String, for session: OCSession) -> String {
        "\(serverID)|\(baseGroupID(for: session))"
    }

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

    /// Groups every server's sessions by project and orders the groups by their most recent
    /// session, whichever machine it is on.
    ///
    /// - Parameters:
    ///   - results: One entry per server, in the order the servers are displayed.
    ///   - tags: Server identities by id. Used only when `showsServerTags` is set.
    ///   - showsServerTags: `isMultiServerUIEnabled(savedServerCount:)`. When false no group or
    ///     failure carries a tag, which is what keeps one saved server looking as it always did.
    static func aggregate(
        results: [ServerSessionsResult],
        tags: [String: ServerTag],
        showsServerTags: Bool,
        customName: (String) -> String?
    ) -> SessionAggregation {
        var groups: [SessionGroup] = []
        var failures: [SessionServerFailure] = []

        for result in results {
            let tag = showsServerTags ? tags[result.serverID] : nil
            groups += groupsForOneServer(result, tag: tag, customName: customName)
            if let message = result.failureMessage {
                failures.append(SessionServerFailure(serverID: result.serverID, message: message, tag: tag))
            }
        }

        // One server has nothing to merge across: keep its own order exactly as before.
        let contributing = Set(groups.map(\.serverID))
        if contributing.count > 1 {
            // Stable by construction: `sorted` is not guaranteed stable, so break ties by position.
            groups = groups.enumerated()
                .sorted { lhs, rhs in
                    if lhs.element.latestActivity != rhs.element.latestActivity {
                        return lhs.element.latestActivity > rhs.element.latestActivity
                    }
                    return lhs.offset < rhs.offset
                }
                .map(\.element)
        }
        return SessionAggregation(groups: groups, failures: failures)
    }

    private static func groupsForOneServer(
        _ result: ServerSessionsResult,
        tag: ServerTag?,
        customName: (String) -> String?
    ) -> [SessionGroup] {
        var sessionsByID: [String: [OCSession]] = [:]
        var order: [String] = []
        var titles: [String: String] = [:]
        var subtitles: [String: String] = [:]

        for session in result.sessions {
            let id = groupID(serverID: result.serverID, for: session)
            if sessionsByID[id] == nil { order.append(id) }
            sessionsByID[id, default: []].append(session)
            titles[id] = title(for: session, customName: customName)
            subtitles[id] = normalizedDirectory(for: session)
        }

        return order.compactMap { id in
            guard let sessions = sessionsByID[id] else { return nil }
            return SessionGroup(
                id: id,
                serverID: result.serverID,
                title: titles[id] ?? AppText.projectFallback,
                subtitle: subtitles[id],
                sessions: sessions,
                tag: tag
            )
        }
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
