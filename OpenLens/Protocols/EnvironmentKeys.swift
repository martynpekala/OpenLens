import SwiftUI

// MARK: - ConnectionManager Environment Key

private struct ConnectionManagerKey: EnvironmentKey {
    // Fallback only used if no explicit environment injection is provided
    // (e.g., in SwiftUI previews). Normal app flow always injects from the composition root.
    static let defaultValue: ConnectionManager = ConnectionManager()
}

// MARK: - SavedConnectionsStore Environment Key

private struct SavedConnectionsStoreKey: EnvironmentKey {
    static let defaultValue: SavedConnectionsStore = SavedConnectionsStore()
}

// MARK: - LiveActivityManager Environment Key

private struct LiveActivityManagerKey: EnvironmentKey {
    static let defaultValue: LiveActivityManager = LiveActivityManager()
}

// MARK: - Service Environment Keys

private struct SessionsServiceKey: EnvironmentKey {
    static let defaultValue: SessionsService = {
        let conn = ConnectionManager()
        return SessionsService(connection: conn)
    }()
}

private struct MessagesServiceKey: EnvironmentKey {
    static let defaultValue: MessagesService = {
        let conn = ConnectionManager()
        return MessagesService(connection: conn)
    }()
}

private struct ProvidersServiceKey: EnvironmentKey {
    static let defaultValue: ProvidersService = {
        let conn = ConnectionManager()
        return ProvidersService(connection: conn)
    }()
}

private struct QuestionServiceKey: EnvironmentKey {
    static let defaultValue: QuestionService = {
        let conn = ConnectionManager()
        return QuestionService(connection: conn)
    }()
}

private struct ReviewServiceKey: EnvironmentKey {
    static let defaultValue: ReviewService = {
        let conn = ConnectionManager()
        return ReviewService(connection: conn)
    }()
}

private struct InboxServiceKey: EnvironmentKey {
    static let defaultValue: InboxService = {
        let conn = ConnectionManager()
        return InboxService(connection: conn)
    }()
}

private struct WorkspaceServiceKey: EnvironmentKey {
    static let defaultValue: WorkspaceService = {
        let conn = ConnectionManager()
        return WorkspaceService(connection: conn)
    }()
}

private struct SessionInsightsServiceKey: EnvironmentKey {
    static let defaultValue: SessionInsightsService = SessionInsightsService()
}

private struct RecordedReplayStoreKey: EnvironmentKey {
    static let defaultValue: RecordedReplayStore = RecordedReplayStore()
}

private struct ChatEasterEggControllerKey: EnvironmentKey {
    static let defaultValue: ChatEasterEggController = ChatEasterEggController()
}

private struct ReviewPromptActionKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

// MARK: - EnvironmentValues Extensions

extension EnvironmentValues {
    var connection: ConnectionManager {
        get { self[ConnectionManagerKey.self] }
        set { self[ConnectionManagerKey.self] = newValue }
    }

    var savedConnections: SavedConnectionsStore {
        get { self[SavedConnectionsStoreKey.self] }
        set { self[SavedConnectionsStoreKey.self] = newValue }
    }

    var liveActivity: LiveActivityManager {
        get { self[LiveActivityManagerKey.self] }
        set { self[LiveActivityManagerKey.self] = newValue }
    }

    var sessionsService: SessionsService {
        get { self[SessionsServiceKey.self] }
        set { self[SessionsServiceKey.self] = newValue }
    }

    var messagesService: MessagesService {
        get { self[MessagesServiceKey.self] }
        set { self[MessagesServiceKey.self] = newValue }
    }

    var providersService: ProvidersService {
        get { self[ProvidersServiceKey.self] }
        set { self[ProvidersServiceKey.self] = newValue }
    }

    var questionService: QuestionService {
        get { self[QuestionServiceKey.self] }
        set { self[QuestionServiceKey.self] = newValue }
    }

    var reviewService: ReviewService {
        get { self[ReviewServiceKey.self] }
        set { self[ReviewServiceKey.self] = newValue }
    }

    var inboxService: InboxService {
        get { self[InboxServiceKey.self] }
        set { self[InboxServiceKey.self] = newValue }
    }

    var workspaceService: WorkspaceService {
        get { self[WorkspaceServiceKey.self] }
        set { self[WorkspaceServiceKey.self] = newValue }
    }

    var sessionInsightsService: SessionInsightsService {
        get { self[SessionInsightsServiceKey.self] }
        set { self[SessionInsightsServiceKey.self] = newValue }
    }

    var recordedReplayStore: RecordedReplayStore {
        get { self[RecordedReplayStoreKey.self] }
        set { self[RecordedReplayStoreKey.self] = newValue }
    }

    var chatEasterEgg: ChatEasterEggController {
        get { self[ChatEasterEggControllerKey.self] }
        set { self[ChatEasterEggControllerKey.self] = newValue }
    }

    var requestReviewPrompt: () -> Void {
        get { self[ReviewPromptActionKey.self] }
        set { self[ReviewPromptActionKey.self] = newValue }
    }

}
