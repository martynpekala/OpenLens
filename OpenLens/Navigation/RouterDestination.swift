import Foundation

enum RouterDestination: Hashable {
    case chatSession(session: OCSession)
    case sessionInsights(sessionID: String?)
    case reviewMessage(messageID: String)
    case reviewFile(path: String)
    case workspacePath(path: String)
}
