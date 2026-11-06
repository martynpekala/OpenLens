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

    @ObservationIgnored private var recoveryTask: Task<Void, Never>?

    /// Whether a foreground recovery started by `resume()` is still running.
    var isRecovering: Bool { recoveryTask != nil }

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

        // The connection, not a view, decides when the stream is wired: a server that is never on
        // screen must still consume its events.
        connection.onSSEClientReady = { [weak self] _ in
            self?.chatClient.setupSSEHandlers()
        }
    }

    // MARK: - Scene phase

    /// Brings this server back after the app returns to the foreground: re-binds the stream,
    /// reconciles the open session and re-reads pending prompts, since events may have been
    /// missed while iOS suspended the socket. Idempotent: a call while recovery is in flight
    /// coalesces into it. It does not refresh any catalogue; that stays with the active view.
    func resume() {
        chatClient.setupSSEHandlers()
        // Recovery is about the session this client has open. Without one the recovery reads
        // would be unscoped and could surface another session's prompt.
        guard chatClient.currentSession != nil else { return }
        chatClient.synchronizeCurrentSessionFromServer()
        guard recoveryTask == nil else { return }
        recoveryTask = Task { [weak self] in
            guard let chatClient = self?.chatClient else { return }
            await chatClient.recoverPendingPermission()
            await chatClient.recoverPendingQuestions()
            await chatClient.recoverPendingForms()
            self?.recoveryTask = nil
        }
    }

    /// Nothing destructive: the connection, `activeConnectionID` and the App Group credentials
    /// all survive, so a Live Activity button still works while the app is suspended. Only
    /// foreground recovery that has not finished is dropped; `resume()` redoes it.
    func suspend() {
        recoveryTask?.cancel()
        recoveryTask = nil
    }
}

/// The order a foreground resume visits servers: the active one first so the screen the user is
/// looking at recovers before anything else, then the rest in their stable display order.
func resumeOrder(contexts: [ServerContext], activeID: String?) -> [ServerContext] {
    guard let active = contexts.first(where: { $0.id == activeID }) else { return contexts }
    return [active] + contexts.filter { $0.id != active.id }
}
