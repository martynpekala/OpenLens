import SwiftUI
import os

// MARK: - Placeholder Connection

/// The one connection every un-injected environment fallback binds to. It is never connected,
/// so a view rendered without injection shows "not connected" rather than talking to a server.
/// Normal app flow always injects from the composition root; this exists for SwiftUI previews.
private enum PlaceholderConnection {
    static let shared: ConnectionManager = {
#if DEBUG
        Logger(subsystem: Bundle.main.bundleIdentifier ?? "OpenLens", category: "Environment")
            .debug("Environment fallback in use: views are bound to a placeholder, never-connected ConnectionManager.")
#endif
        return ConnectionManager()
    }()
}

// MARK: - ConnectionManager Environment Key

private struct ConnectionManagerKey: EnvironmentKey {
    // Fallback only used if no explicit environment injection is provided
    // (e.g., in SwiftUI previews). Normal app flow always injects from the composition root.
    static let defaultValue: ConnectionManager = PlaceholderConnection.shared
}

// MARK: - SavedConnectionsStore Environment Key

private struct SavedConnectionsStoreKey: EnvironmentKey {
    static let defaultValue: SavedConnectionsStore = SavedConnectionsStore()
}

// MARK: - ServerRegistry Environment Key

private struct ServerRegistryKey: EnvironmentKey {
    // Fallback only used if no explicit injection is provided (e.g. SwiftUI previews).
    static let defaultValue: ServerRegistry = ServerRegistry(
        savedConnectionsStore: SavedConnectionsStore(initialConnections: []),
        liveActivity: LiveActivityManager(),
        recordedReplayStore: RecordedReplayStore()
    )
}

// MARK: - LiveActivityManager Environment Key

private struct LiveActivityManagerKey: EnvironmentKey {
    static let defaultValue: LiveActivityManager = LiveActivityManager()
}

// MARK: - Service Environment Keys

private struct SessionsServiceKey: EnvironmentKey {
    static let defaultValue: SessionsService = SessionsService(connection: PlaceholderConnection.shared)
}

private struct MessagesServiceKey: EnvironmentKey {
    static let defaultValue: MessagesService = MessagesService(connection: PlaceholderConnection.shared)
}

private struct ProvidersServiceKey: EnvironmentKey {
    static let defaultValue: ProvidersService = ProvidersService(connection: PlaceholderConnection.shared)
}

private struct QuestionServiceKey: EnvironmentKey {
    static let defaultValue: QuestionService = QuestionService(connection: PlaceholderConnection.shared)
}

private struct ReviewServiceKey: EnvironmentKey {
    static let defaultValue: ReviewService = ReviewService(connection: PlaceholderConnection.shared)
}

private struct InboxServiceKey: EnvironmentKey {
    static let defaultValue: InboxService = InboxService(connection: PlaceholderConnection.shared)
}

private struct WorkspaceServiceKey: EnvironmentKey {
    static let defaultValue: WorkspaceService = WorkspaceService(connection: PlaceholderConnection.shared)
}

private struct WorkspaceNameStoreKey: EnvironmentKey {
    static let defaultValue: WorkspaceNameStore = WorkspaceNameStore()
}

private struct SessionInsightsServiceKey: EnvironmentKey {
    static let defaultValue: SessionInsightsService = SessionInsightsService()
}

private struct GitHubStarsServiceKey: EnvironmentKey {
    static let defaultValue: GitHubStarsService = GitHubStarsService()
}

private struct UsageQuotaServiceKey: EnvironmentKey {
    static let defaultValue: UsageQuotaService = UsageQuotaService()
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

    var serverRegistry: ServerRegistry {
        get { self[ServerRegistryKey.self] }
        set { self[ServerRegistryKey.self] = newValue }
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

    var workspaceNames: WorkspaceNameStore {
        get { self[WorkspaceNameStoreKey.self] }
        set { self[WorkspaceNameStoreKey.self] = newValue }
    }

    var sessionInsightsService: SessionInsightsService {
        get { self[SessionInsightsServiceKey.self] }
        set { self[SessionInsightsServiceKey.self] = newValue }
    }

    var gitHubStarsService: GitHubStarsService {
        get { self[GitHubStarsServiceKey.self] }
        set { self[GitHubStarsServiceKey.self] = newValue }
    }

    var usageQuotaService: UsageQuotaService {
        get { self[UsageQuotaServiceKey.self] }
        set { self[UsageQuotaServiceKey.self] = newValue }
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
