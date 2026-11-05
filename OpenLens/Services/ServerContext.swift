import Foundation
import Observation

/// Everything that belongs to one server: its connection, the seven services built against
/// that connection, and the chat client that drives them.
///
/// The composition root decides which `ChatClient` a context carries. Pass one in for the
/// screenshot/demo path; omit it and the context builds the networked client itself.
@MainActor
@Observable
final class ServerContext: Identifiable {
    /// This context's identity. When the context is built from a saved profile it is that
    /// profile's `SavedConnection.id`.
    ///
    /// It does **not** yet always agree with `connection.connectionID`: while there is a single
    /// app-wide context it is built before any profile is known, so it carries a placeholder and
    /// the connection learns its real id from `saveConnection` on connecting. The two converge
    /// once the registry builds one context per saved profile; until then, prefer
    /// `connection.connectionID` for anything that must name the server actually connected to.
    let id: String
    /// The saved profile this context was built from, if one existed at construction time.
    let profile: SavedConnection?

    let connection: ConnectionManager
    let sessionsService: SessionsService
    let messagesService: MessagesService
    let providersService: ProvidersService
    let questionService: QuestionService
    let reviewService: ReviewService
    let inboxService: InboxService
    let workspaceService: WorkspaceService
    let chatClient: ChatClient

    init(
        id: String,
        profile: SavedConnection? = nil,
        connection: ConnectionManager,
        liveActivity: any LiveActivityProviding,
        savedConnectionsStore: SavedConnectionsStore,
        recordedReplayStore: RecordedReplayStore,
        chatClient suppliedChatClient: ChatClient? = nil
    ) {
        self.id = id
        self.profile = profile
        self.connection = connection

        let sessions = SessionsService(connection: connection)
        let messages = MessagesService(connection: connection)
        let providers = ProvidersService(connection: connection)
        let questions = QuestionService(connection: connection)
        self.sessionsService = sessions
        self.messagesService = messages
        self.providersService = providers
        self.questionService = questions
        self.reviewService = ReviewService(connection: connection)
        self.inboxService = InboxService(connection: connection)
        self.workspaceService = WorkspaceService(connection: connection)

        self.chatClient = suppliedChatClient ?? ChatClient(
            connection: connection,
            liveActivity: liveActivity,
            sessionsService: sessions,
            messagesService: messages,
            providersService: providers,
            questionService: questions,
            savedConnectionsStore: savedConnectionsStore,
            recordedReplayStore: recordedReplayStore
        )
    }
}
