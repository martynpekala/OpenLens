import Foundation

/// One row of the Review session picker: a session and the server it lives on.
struct ReviewPickerOption: Identifiable, Equatable {
    let serverID: String
    /// Set only while several servers are saved; the row shows it.
    let tag: ServerTag?
    let session: OCSession

    var id: String { "\(serverID)|\(session.id)" }
}

/// Builds the picker's rows. The active server's pages come first, in the order they were
/// paged in; every other connected server follows, in display order.
///
/// - Parameters:
///   - showsServerTags: `isMultiServerUIEnabled(savedServerCount:)`. When false no row carries a
///     tag, which keeps one saved server's picker as it always was.
func reviewPickerOptions(
    activeServerID: String,
    activeSessions: [OCSession],
    otherServers: [ServerSessionsResult],
    tags: [String: ServerTag],
    showsServerTags: Bool
) -> [ReviewPickerOption] {
    func options(serverID: String, sessions: [OCSession]) -> [ReviewPickerOption] {
        let tag = showsServerTags ? tags[serverID] : nil
        return sessions.map { ReviewPickerOption(serverID: serverID, tag: tag, session: $0) }
    }
    var result = options(serverID: activeServerID, sessions: activeSessions)
    for server in otherServers where server.serverID != activeServerID {
        result += options(serverID: server.serverID, sessions: server.sessions)
    }
    return result
}
