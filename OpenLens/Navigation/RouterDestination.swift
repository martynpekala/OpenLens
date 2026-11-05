import Foundation

enum RouterDestination: Hashable {
    /// `serverID` keeps same-id sessions on different servers distinct, which `NavigationStack`
    /// and `.task(id:)` rely on.
    case chatSession(session: OCSession, serverID: String)
    case archivedSessions
    case sessionInsights(sessionID: String?)
    case reviewMessage(messageID: String)
    case reviewFile(path: String)
    case workspacePath(path: String)
}
