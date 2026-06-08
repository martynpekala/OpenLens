import Foundation
import Testing
@testable import OpenLens

struct ChatStreamBehaviorTests {

    @MainActor
    @Test func streamingFlushPublishesBufferedText() async {
        let client = ChatClient(demoMode: true)
        let messageID = "assistant-message"
        client.pendingAssistantMessage = ChatMessage(
            id: messageID,
            role: .assistant,
            content: "",
            isStreaming: true
        )

        client.appendStreamingText(messageID: messageID, text: "Hello")

        #expect(client.pendingAssistantMessage?.content == "")

        await waitForMainQueue(milliseconds: 80)

        #expect(client.pendingAssistantMessage?.content == "Hello")
        #expect(client.contentVersion == 1)
    }

    @MainActor
    @Test func clearingStreamingBufferDropsStaleDeltaText() async {
        let client = ChatClient(demoMode: true)
        let messageID = "assistant-message"
        client.pendingAssistantMessage = ChatMessage(
            id: messageID,
            role: .assistant,
            content: "",
            isStreaming: true
        )

        client.appendStreamingText(messageID: messageID, text: "stale")
        client.clearStreamingBuffer(messageID: messageID)

        await waitForMainQueue(milliseconds: 80)

        #expect(client.pendingAssistantMessage?.content == "")
        #expect(client.contentVersion == 0)
    }

    @MainActor
    @Test func abortStopsLocalStreamingAndDropsLateBufferedText() async {
        let client = ChatClient(demoMode: true)
        let sessionID = "session-1"
        let messageID = "assistant-message"
        client.currentSession = OCSession(
            id: sessionID,
            title: "Test",
            time: OCSessionTime(created: 0, updated: 0)
        )
        client.isLoading = true
        client.responseState = .generating
        client.pendingAssistantMessage = ChatMessage(
            id: messageID,
            role: .assistant,
            content: "",
            isStreaming: true
        )

        client.appendStreamingText(messageID: messageID, text: "partial")
        client.abort()

        #expect(!client.isLoading)
        #expect(client.responseState == .stopped)
        #expect(client.pendingAssistantMessage == nil)
        #expect(client.messages.last?.id == messageID)
        #expect(client.messages.last?.content == "partial")
        #expect(client.messages.last?.isStreaming == false)

        client.appendStreamingText(messageID: messageID, text: " stale")
        await waitForMainQueue(milliseconds: 80)

        #expect(client.messages.last?.content == "partial")
    }

    @MainActor
    @Test func stoppedTurnIgnoresLateAssistantSSEAfterReconnect() {
        let client = ChatClient(demoMode: true)
        let handler = makeHandler(delegate: client)
        let sessionID = "session-1"
        let stoppedMessageID = "assistant-stopped"
        client.currentSession = OCSession(
            id: sessionID,
            title: "Test",
            time: OCSessionTime(created: 0, updated: 0)
        )
        client.isLoading = true
        client.responseState = .generating
        client.pendingAssistantMessage = ChatMessage(
            id: stoppedMessageID,
            role: .assistant,
            content: "partial",
            isStreaming: true
        )

        client.abort()

        handler.handleEvent(
            OCEvent(
                type: "session.status",
                properties: AnyCodable([
                    "sessionID": sessionID,
                    "status": ["type": "busy"]
                ])
            )
        )
        handler.handleEvent(
            OCEvent(
                type: "message.updated",
                properties: AnyCodable([
                    "info": [
                        "id": "assistant-late",
                        "sessionID": sessionID,
                        "role": "assistant"
                    ]
                ])
            )
        )
        handler.handleEvent(
            OCEvent(
                type: "message.part.delta",
                properties: AnyCodable([
                    "sessionID": sessionID,
                    "messageID": "assistant-late",
                    "field": "text",
                    "delta": " stale"
                ])
            )
        )

        #expect(!client.isLoading)
        #expect(client.responseState == .stopped)
        #expect(client.pendingAssistantMessage == nil)
        #expect(!client.messages.contains(where: { $0.id == "assistant-late" }))
        #expect(client.messages.last?.id == stoppedMessageID)
        #expect(client.messages.last?.content == "partial")
    }

    @MainActor
    @Test func stoppedResponseStateClearsAfterDelayAndAllowsLaterAssistantSSE() async {
        let client = ChatClient(demoMode: true)
        let handler = makeHandler(delegate: client)
        let sessionID = "session-1"
        let stoppedMessageID = "assistant-stopped"
        client.currentSession = OCSession(
            id: sessionID,
            title: "Test",
            time: OCSessionTime(created: 0, updated: 0)
        )
        client.isLoading = true
        client.responseState = .generating
        client.pendingAssistantMessage = ChatMessage(
            id: stoppedMessageID,
            role: .assistant,
            content: "partial",
            isStreaming: true
        )

        client.abort()

        #expect(client.responseState == .stopped)

        await waitForMainQueue(milliseconds: 1_700)

        #expect(client.responseState == .idle)

        handler.handleEvent(
            OCEvent(
                type: "message.part.delta",
                properties: AnyCodable([
                    "sessionID": sessionID,
                    "messageID": stoppedMessageID,
                    "field": "text",
                    "delta": " stale"
                ])
            )
        )

        #expect(client.messages.last?.content == "partial")

        handler.handleEvent(
            OCEvent(
                type: "message.updated",
                properties: AnyCodable([
                    "info": [
                        "id": "assistant-next",
                        "sessionID": sessionID,
                        "role": "assistant"
                    ]
                ])
            )
        )

        #expect(client.pendingAssistantMessage?.id == "assistant-next")
        #expect(client.messages.last?.id == stoppedMessageID)
        #expect(client.messages.last?.content == "partial")
    }

    @MainActor
    @Test func serverIdleAfterStopAllowsNextAssistantTurnBeforeBadgeExpires() {
        let client = ChatClient(demoMode: true)
        let handler = makeHandler(delegate: client)
        let sessionID = "session-1"
        client.currentSession = OCSession(
            id: sessionID,
            title: "Test",
            time: OCSessionTime(created: 0, updated: 0)
        )
        client.isLoading = true
        client.responseState = .generating
        client.pendingAssistantMessage = ChatMessage(
            id: "assistant-stopped",
            role: .assistant,
            content: "partial",
            isStreaming: true
        )

        client.abort()

        handler.handleEvent(
            OCEvent(
                type: "session.status",
                properties: AnyCodable([
                    "sessionID": sessionID,
                    "status": ["type": "idle"]
                ])
            )
        )

        #expect(client.responseState == .stopped)

        handler.handleEvent(
            OCEvent(
                type: "message.updated",
                properties: AnyCodable([
                    "info": [
                        "id": "assistant-next",
                        "sessionID": sessionID,
                        "role": "assistant"
                    ]
                ])
            )
        )

        #expect(client.pendingAssistantMessage?.id == "assistant-next")
    }

    @MainActor
    @Test func finishLoadingCommitsPendingAssistantMessageWithoutDuplicates() {
        let client = ChatClient(demoMode: true)
        let assistantID = "assistant-message"

        client.messages = [
            ChatMessage(id: "user-message", role: .user, content: "Hello")
        ]
        client.pendingAssistantMessage = ChatMessage(
            id: assistantID,
            role: .assistant,
            content: "",
            isStreaming: true
        )

        client.appendStreamingText(messageID: assistantID, text: "Hello")
        client.finishLoading()

        let displayedIDs = client.displayedMessages.map(\.id)

        #expect(client.pendingAssistantMessage == nil)
        #expect(client.messages.count == 2)
        #expect(client.messages.last?.id == assistantID)
        #expect(client.messages.last?.content == "Hello")
        #expect(client.messages.last?.isStreaming == false)
        #expect(Set(displayedIDs).count == displayedIDs.count)
        #expect(displayedIDs == client.messages.map(\.id))
    }

    @MainActor
    @Test func finishLoadingReturnsGeneratingResponseToIdle() {
        let client = ChatClient(demoMode: true)
        client.responseState = .generating
        client.isLoading = true

        client.finishLoading()

        #expect(!client.isLoading)
        #expect(client.responseState == .idle)
    }

    @MainActor
    @Test func finishLoadingDoesNotForceScrollJump() {
        let client = ChatClient(demoMode: true)
        let initialScrollAnchor = client.scrollAnchor
        let assistantID = "assistant-message"

        client.pendingAssistantMessage = ChatMessage(
            id: assistantID,
            role: .assistant,
            content: "",
            isStreaming: true
        )

        client.appendStreamingText(messageID: assistantID, text: "Hello")
        client.finishLoading()

        #expect(client.scrollAnchor == initialScrollAnchor)
    }

    @MainActor
    @Test func chatScrollPolicyTracksNearBottomAndButtonVisibility() {
        #expect(ChatScrollPolicy.bottomDistance(contentHeight: 700, visibleMaxY: 640) == 60)
        #expect(ChatScrollPolicy.bottomDistance(contentHeight: 500, visibleMaxY: 640) == 0)
        #expect(ChatScrollPolicy.isNearBottom(bottomDistance: 40, threshold: 48))
        #expect(!ChatScrollPolicy.isNearBottom(bottomDistance: 70, threshold: 48))

        #expect(ChatScrollPolicy.state(
            contentHeight: 700,
            visibleMaxY: 640,
            followLatestThreshold: 96,
            visibilityThreshold: 56
        ) == ChatScrollState(isNearBottom: true, isPastVisibilityThreshold: true))

        #expect(ChatScrollPolicy.shouldShowScrollToLatest(
            followLatest: false,
            isPastVisibilityThreshold: true
        ))
        #expect(!ChatScrollPolicy.shouldShowScrollToLatest(
            followLatest: true,
            isPastVisibilityThreshold: true
        ))
    }

    @MainActor
    @Test func chatScrollPolicyRespectsFollowLatestAndThrottle() {
        let now = Date()

        #expect(ChatScrollPolicy.shouldAutoFollow(
            isLoading: true,
            followLatest: true,
            now: now,
            lastAutoScrollDate: now.addingTimeInterval(-0.3),
            minimumInterval: 0.18
        ))
        #expect(!ChatScrollPolicy.shouldAutoFollow(
            isLoading: true,
            followLatest: false,
            now: now,
            lastAutoScrollDate: now.addingTimeInterval(-0.3),
            minimumInterval: 0.18
        ))
        #expect(!ChatScrollPolicy.shouldAutoFollow(
            isLoading: false,
            followLatest: true,
            now: now,
            lastAutoScrollDate: now.addingTimeInterval(-0.3),
            minimumInterval: 0.18
        ))
        #expect(!ChatScrollPolicy.shouldAutoFollow(
            isLoading: true,
            followLatest: true,
            now: now,
            lastAutoScrollDate: now.addingTimeInterval(-0.05),
            minimumInterval: 0.18
        ))
    }

    @MainActor
    @Test func chatScrollPolicyDisablesManualScrollAnimationDuringStreaming() {
        #expect(!ChatScrollPolicy.shouldAnimateManualScroll(isLoading: true))
        #expect(ChatScrollPolicy.shouldAnimateManualScroll(isLoading: false))
    }

    @MainActor
    @Test(arguments: ["file", "patch", "retry", "compaction", "agent", "subtask"])
    func partUpdatedPreservesKnownNonRenderableParts(_ rawType: String) {
        let delegate = SSEDelegateSpy()
        let handler = makeHandler(delegate: delegate)
        let messageID = "assistant-message"

        let pending = ChatMessage(
            id: messageID,
            role: .assistant,
            content: "Visible",
            isStreaming: true
        )
        delegate.pendingAssistantMessage = pending

        handler.handleEvent(
            OCEvent(
                type: "message.part.updated",
                properties: AnyCodable([
                    "part": [
                        "id": "part-1",
                        "sessionID": "session-1",
                        "messageID": messageID,
                        "type": rawType,
                        "snapshot": ["value": 1],
                        "hash": "abc",
                        "files": [["path": "File.swift"]],
                        "attempt": 2,
                        "error": "retry",
                        "auto": true,
                        "name": "agent-name",
                        "prompt": "subtask prompt",
                        "description": "subtask description",
                        "source": "planner",
                        "agent": ["id": "agent-1"]
                    ]
                ])
            )
        )

        #expect(delegate.pendingAssistantMessage?.parts.count == 1)
        #expect(delegate.pendingAssistantMessage?.parts.first?.type == OCPartType(rawValue: rawType))
        #expect(delegate.pendingAssistantMessage?.content == "Visible")
        #expect(delegate.clearedStreamingBuffers.isEmpty)
    }

    @MainActor
    private func waitForMainQueue(milliseconds: Int) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(milliseconds)) {
                continuation.resume()
            }
        }
    }

    @MainActor
    private func makeHandler(delegate: any SSEEventHandlerDelegate) -> SSEEventHandler {
        let tracker = LiveActivityTracker(liveActivity: TestLiveActivityProvider())
        let handler = SSEEventHandler(haptics: HapticController(), liveActivityTracker: tracker)
        handler.delegate = delegate
        return handler
    }
}

@MainActor
private final class SSEDelegateSpy: SSEEventHandlerDelegate {
    var currentSessionID: String? = "session-1"
    var messages: [ChatMessage] = []
    var pendingAssistantMessage: ChatMessage?
    var currentActivity: AgentActivity?
    var sessionStatus: OCSessionStatus?
    var isLoading: Bool = false
    var currentSession: OCSession?
    var pendingPermission: OCPermissionRequest?
    var showPermissionAlert: Bool = false
    var pendingQuestion: OCQuestionRequest?
    var showQuestionSheet: Bool = false
    var todos: [OCTodo] = []
    var clearedStreamingBuffers: [String] = []

    func finishLoading() {}

    func shouldIgnoreAssistantEvent(sessionID: String, messageID: String) -> Bool {
        false
    }

    func shouldIgnoreBusyStatus(sessionID: String) -> Bool {
        false
    }

    func appendStreamingText(messageID: String, text: String) {}

    func clearStreamingBuffer(messageID: String) {
        clearedStreamingBuffers.append(messageID)
    }

    func questionDidPresent() {}
}

private final class TestLiveActivityProvider: LiveActivityProviding {
    var isActive: Bool { false }

    func startActivity(agentName: String, userTask: String, subject: String?) {}

    func update(
        subject: String?,
        currentIntent: String,
        currentIntentIcon: String?,
        previousIntent: String?,
        secondPreviousIntent: String?,
        stepNumber: Int,
        costTotal: String?,
        pendingUserResponse: OpenLensActivityAttributes.PendingUserResponse?
    ) {}

    func endActivity(completionSummary: String?) {}

    func previewLiveActivity() {}
}
