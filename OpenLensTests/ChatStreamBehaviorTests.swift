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
    @Test func busySessionStatusStartsGeneratingResponseStateForExternalTurn() {
        let client = ChatClient(demoMode: true)
        let handler = makeHandler(delegate: client)
        let sessionID = "session-1"
        client.currentSession = OCSession(
            id: sessionID,
            title: "Test",
            time: OCSessionTime(created: 0, updated: 0)
        )

        handler.handleEvent(
            OCEvent(
                type: "session.status",
                properties: AnyCodable([
                    "sessionID": sessionID,
                    "status": ["type": "busy"]
                ])
            )
        )

        #expect(client.isLoading)
        #expect(client.responseState == .generating)
        #expect(client.currentActivity?.currentLabel == "Thinking...")
    }

    @MainActor
    @Test func firstAssistantMessageUpdateStartsGeneratingResponseState() {
        let client = ChatClient(demoMode: true)
        let handler = makeHandler(delegate: client)
        let sessionID = "session-1"
        let messageID = "assistant-message"
        client.currentSession = OCSession(
            id: sessionID,
            title: "Test",
            time: OCSessionTime(created: 0, updated: 0)
        )

        handler.handleEvent(
            OCEvent(
                type: "message.updated",
                properties: AnyCodable([
                    "info": [
                        "id": messageID,
                        "sessionID": sessionID,
                        "role": "assistant"
                    ]
                ])
            )
        )

        #expect(client.isLoading)
        #expect(client.responseState == .generating)
        #expect(client.currentActivity?.currentLabel == "Thinking...")
        #expect(client.pendingAssistantMessage?.id == messageID)
    }

    @MainActor
    @Test func idleStatusRefreshClearsLoadingAfterMissedSSEIdle() {
        let client = ChatClient(demoMode: true)
        let sessionID = "session-1"
        client.currentSession = OCSession(
            id: sessionID,
            title: "Test",
            time: OCSessionTime(created: 0, updated: 0)
        )
        client.isLoading = true
        client.responseState = .generating
        client.currentActivity = AgentActivity()
        client.currentActivity?.currentLabel = "Thinking..."
        client.pendingAssistantMessage = ChatMessage(
            id: "assistant-message",
            role: .assistant,
            content: "Done",
            isStreaming: true
        )

        client.applyCurrentSessionStatus(
            OCSessionStatus(type: .idle, attempt: nil, message: nil, next: nil)
        )

        #expect(!client.isLoading)
        #expect(client.responseState == .idle)
        #expect(client.currentActivity == nil)
        #expect(client.pendingAssistantMessage == nil)
        #expect(client.messages.last?.content == "Done")
        #expect(client.messages.last?.isStreaming == false)
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
    @Test func permissionV2AskedShowsPendingPermissionAlert() {
        let delegate = SSEDelegateSpy()
        let handler = makeHandler(delegate: delegate)

        handler.handleEvent(
            OCEvent(
                type: "permission.v2.asked",
                properties: AnyCodable([
                    "id": "per_123",
                    "sessionID": "session-1",
                    "action": "mcp.github.list_issues",
                    "resources": ["github:list_issues"],
                    "save": ["github:*"],
                    "metadata": [
                        "server": "github",
                        "tool": "list_issues"
                    ],
                    "source": [
                        "type": "tool",
                        "messageID": "message-1",
                        "callID": "call-1"
                    ]
                ])
            )
        )

        #expect(delegate.showPermissionAlert)
        #expect(delegate.pendingPermission?.id == "per_123")
        #expect(delegate.pendingPermission?.action == "mcp.github.list_issues")
        #expect(delegate.pendingPermission?.resources == ["github:list_issues"])
        #expect(delegate.pendingPermission?.save == ["github:*"])
        #expect(delegate.pendingPermission?.toolRef?.messageID == "message-1")
        #expect(delegate.pendingPermission?.toolRef?.callID == "call-1")
    }

    @MainActor
    @Test func permissionAskedShowsAlertWhenCurrentSessionIsNotLoadedYet() {
        let delegate = SSEDelegateSpy()
        delegate.currentSessionID = nil
        let handler = makeHandler(delegate: delegate)

        handler.handleEvent(
            OCEvent(
                type: "permission.v2.asked",
                properties: AnyCodable([
                    "id": "per_early",
                    "sessionID": "session-1",
                    "action": "mcp.github.list_issues",
                    "resources": ["github:list_issues"]
                ])
            )
        )

        #expect(delegate.showPermissionAlert)
        #expect(delegate.pendingPermission?.id == "per_early")
    }

    @MainActor
    @Test func subsequentPermissionAskedReplacesCurrentPendingPermission() {
        let delegate = SSEDelegateSpy()
        let handler = makeHandler(delegate: delegate)

        handler.handleEvent(
            OCEvent(
                type: "permission.v2.asked",
                properties: AnyCodable([
                    "id": "per_first",
                    "sessionID": "session-1",
                    "action": "mcp.github.list_issues",
                    "resources": ["github:list_issues"]
                ])
            )
        )

        handler.handleEvent(
            OCEvent(
                type: "permission.v2.asked",
                properties: AnyCodable([
                    "id": "per_second",
                    "sessionID": "session-1",
                    "action": "mcp.github.create_issue",
                    "resources": ["github:create_issue"]
                ])
            )
        )

        #expect(delegate.showPermissionAlert)
        #expect(delegate.pendingPermission?.id == "per_second")
        #expect(delegate.pendingPermission?.action == "mcp.github.create_issue")
    }

    @MainActor
    @Test func subagentPermissionAskedShowsPendingPermissionAlertAfterTaskSessionIsLinked() {
        let delegate = SSEDelegateSpy()
        delegate.currentSessionID = "parent-session"
        delegate.pendingAssistantMessage = ChatMessage(
            id: "assistant-message",
            role: .assistant,
            content: "",
            isStreaming: true
        )
        let handler = makeHandler(delegate: delegate)

        handler.handleEvent(
            OCEvent(
                type: "message.part.updated",
                properties: AnyCodable([
                    "part": [
                        "id": "task-part",
                        "sessionID": "parent-session",
                        "messageID": "assistant-message",
                        "type": "tool",
                        "tool": "task",
                        "callID": "parent-task-call",
                        "state": [
                            "status": "running",
                            "metadata": [
                                "sessionId": "child-session"
                            ],
                            "input": [
                                "subagent_type": "explore"
                            ]
                        ]
                    ]
                ])
            )
        )

        handler.handleEvent(
            OCEvent(
                type: "permission.asked",
                properties: AnyCodable([
                    "id": "per_child",
                    "sessionID": "child-session",
                    "permission": "bash",
                    "patterns": ["rg models"],
                    "always": ["*"],
                    "tool": [
                        "messageID": "child-message",
                        "callID": "child-tool-call"
                    ]
                ])
            )
        )

        #expect(delegate.showPermissionAlert)
        #expect(delegate.pendingPermission?.id == "per_child")
        #expect(delegate.pendingPermission?.sessionID == "child-session")
        #expect(delegate.pendingPermission?.patterns == ["rg models"])
    }

    @MainActor
    @Test func permissionAskedFromUnrelatedSessionIsIgnored() {
        let delegate = SSEDelegateSpy()
        delegate.currentSessionID = "parent-session"
        let handler = makeHandler(delegate: delegate)

        handler.handleEvent(
            OCEvent(
                type: "permission.asked",
                properties: AnyCodable([
                    "id": "per_other",
                    "sessionID": "other-session",
                    "permission": "bash",
                    "patterns": ["rg models"]
                ])
            )
        )

        #expect(!delegate.showPermissionAlert)
        #expect(delegate.pendingPermission == nil)
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
    @Test func reasoningPartDeltaUpdatesReasoningPartWithoutAssistantContent() {
        let delegate = SSEDelegateSpy()
        let handler = makeHandler(delegate: delegate)
        let messageID = "assistant-message"
        delegate.currentActivity = AgentActivity()
        delegate.pendingAssistantMessage = ChatMessage(
            id: messageID,
            role: .assistant,
            content: "",
            parts: [
                OCPart(
                    id: "reasoning-part",
                    sessionID: "session-1",
                    messageID: messageID,
                    type: .reasoning,
                    text: ""
                )
            ],
            isStreaming: true
        )

        handler.handleEvent(
            OCEvent(
                type: "message.part.delta",
                properties: AnyCodable([
                    "sessionID": "session-1",
                    "messageID": messageID,
                    "partID": "reasoning-part",
                    "field": "text",
                    "delta": "Inspecting stream state"
                ])
            )
        )

        #expect(delegate.pendingAssistantMessage?.content == "")
        #expect(delegate.appendedStreamingTexts.isEmpty)
        #expect(delegate.currentActivity?.thinkingText == "Inspecting stream state")

        guard case .reasoning(let text) = delegate.pendingAssistantMessage?.assistantSegments.first?.kind else {
            Issue.record("Expected reasoning delta to update a reasoning segment")
            return
        }

        #expect(text == "Inspecting stream state")
    }

    @MainActor
    @Test func textPartDeltaStillAppendsStreamingText() {
        let delegate = SSEDelegateSpy()
        let handler = makeHandler(delegate: delegate)
        let messageID = "assistant-message"
        delegate.pendingAssistantMessage = ChatMessage(
            id: messageID,
            role: .assistant,
            content: "",
            parts: [
                OCPart(
                    id: "text-part",
                    sessionID: "session-1",
                    messageID: messageID,
                    type: .text,
                    text: ""
                )
            ],
            isStreaming: true
        )

        handler.handleEvent(
            OCEvent(
                type: "message.part.delta",
                properties: AnyCodable([
                    "sessionID": "session-1",
                    "messageID": messageID,
                    "partID": "text-part",
                    "field": "text",
                    "delta": "Hello"
                ])
            )
        )

        #expect(delegate.appendedStreamingTexts == ["Hello"])
        #expect(delegate.pendingAssistantMessage?.content == "")
    }

    @MainActor
    @Test func streamingSubtaskPartBuildsWorkingSubagentSegment() {
        let message = ChatMessage(
            id: "assistant-message",
            role: .assistant,
            content: "",
            parts: [
                OCPart(
                    id: "subtask-part",
                    sessionID: "session-1",
                    messageID: "assistant-message",
                    type: .subtask,
                    prompt: "Check tests",
                    partDescription: "Run the failing suite",
                    agent: AnyCodable(["id": "tester"])
                )
            ],
            isStreaming: true
        )

        #expect(message.assistantSegments.count == 1)

        guard case .subagent(let step) = message.assistantSegments.first?.kind else {
            Issue.record("Expected a visible subagent segment")
            return
        }

        #expect(step.agentName == "tester")
        #expect(step.title == "tester")
        #expect(step.detail == "Run the failing suite")
        #expect(step.prompt == "Check tests")
        #expect(!step.isCompleted)
    }

    @MainActor
    @Test func completedSubtaskPartBuildsDoneSubagentSegment() {
        let message = ChatMessage(
            id: "assistant-message",
            role: .assistant,
            content: "",
            parts: [
                OCPart(
                    id: "subtask-part",
                    sessionID: "session-1",
                    messageID: "assistant-message",
                    type: .subtask,
                    cost: 0.012,
                    prompt: "Check tests",
                    partDescription: "Run the failing suite",
                    agent: AnyCodable(["id": "tester"])
                )
            ],
            isStreaming: true
        )

        guard case .subagent(let step) = message.assistantSegments.first?.kind else {
            Issue.record("Expected a visible subagent segment")
            return
        }

        #expect(step.agentName == "tester")
        #expect(step.isCompleted)
        #expect(step.cost == 0.012)
    }

    @MainActor
    @Test func runningTaskToolBuildsWorkingSubagentSegment() {
        let message = ChatMessage(
            id: "assistant-message",
            role: .assistant,
            content: "",
            parts: [
                OCPart(
                    id: "task-part",
                    sessionID: "session-1",
                    messageID: "assistant-message",
                    type: .tool,
                    callID: "task-call",
                    tool: "task",
                    state: OCToolState(
                        status: .running,
                        input: AnyCodable([
                            "subagent_type": "explore",
                            "description": "Inspect the workspace"
                        ])
                    )
                )
            ],
            isStreaming: true
        )

        guard case .subagent(let step) = message.assistantSegments.first?.kind else {
            Issue.record("Expected task tool to render as a subagent segment")
            return
        }

        #expect(step.agentName == "explore")
        #expect(step.title == "explore")
        #expect(step.detail == "Inspect the workspace")
        #expect(!step.isCompleted)
        #expect(!step.isError)
    }

    @MainActor
    @Test func questionToolRunningBuildsQuestionTranscriptSegment() {
        let message = ChatMessage(
            id: "assistant-message",
            role: .assistant,
            content: "",
            parts: [
                questionToolPart(
                    status: .running,
                    input: questionInput(
                        header: "Zakres domyślnego modelu",
                        question: "Czy domyślny model ma być globalny czy per-połączenie?",
                        options: [
                            ("Per-połączenie (Rekomendowane)", "Lepsze, gdy serwery mają różne modele."),
                            ("Globalny", "Jedno ustawienie dla całej aplikacji.")
                        ]
                    )
                )
            ],
            isStreaming: true
        )

        #expect(message.assistantSegments.count == 1)

        guard case .question(let step) = message.assistantSegments.first?.kind else {
            Issue.record("Expected a question transcript segment")
            return
        }

        #expect(step.questions.count == 1)
        #expect(step.questions.first?.header == "Zakres domyślnego modelu")
        #expect(step.questions.first?.options.map(\.label) == [
            "Per-połączenie (Rekomendowane)",
            "Globalny"
        ])
        #expect(step.answers.isEmpty)
        #expect(!step.isAnswered)
        #expect(message.persistedToolSteps.isEmpty)
    }

    @MainActor
    @Test func questionToolCompletedIncludesSelectedAnswersWithoutGenericToolSegment() {
        let message = ChatMessage(
            id: "assistant-message",
            role: .assistant,
            content: "",
            parts: [
                questionToolPart(
                    status: .completed,
                    input: questionInput(
                        header: "Priorytet wobec serwera",
                        question: "Czy wybór użytkownika ma mieć pierwszeństwo?",
                        options: [
                            ("Wybór użytkownika zawsze wygrywa (Rekomendowane)", "Najbardziej przewidywalne."),
                            ("Serwer nadal wygrywa", "Zachowuje server default.")
                        ]
                    ),
                    metadata: [
                        "answers": AnyCodable([
                            ["Wybór użytkownika zawsze wygrywa (Rekomendowane)"]
                        ])
                    ],
                    output: "User has answered the question."
                )
            ],
            isStreaming: false
        )

        #expect(message.assistantSegments.count == 1)

        guard case .question(let step) = message.assistantSegments.first?.kind else {
            Issue.record("Expected a completed question transcript segment")
            return
        }

        #expect(step.answers == [["Wybór użytkownika zawsze wygrywa (Rekomendowane)"]])
        #expect(step.isAnswered)
        #expect(message.persistedToolSteps.isEmpty)
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

    private func questionInput(
        header: String,
        question: String,
        options: [(label: String, description: String)]
    ) -> AnyCodable {
        AnyCodable([
            "questions": [
                [
                    "header": header,
                    "question": question,
                    "options": options.map { option in
                        [
                            "label": option.label,
                            "description": option.description
                        ]
                    },
                    "multiple": false,
                    "custom": false
                ]
            ]
        ])
    }

    private func questionToolPart(
        status: OCToolStatus,
        input: AnyCodable,
        metadata: [String: AnyCodable]? = nil,
        output: String? = nil
    ) -> OCPart {
        OCPart(
            id: "question-part",
            sessionID: "session-1",
            messageID: "assistant-message",
            type: .tool,
            callID: "question-call",
            tool: "question",
            state: OCToolState(
                status: status,
                input: input,
                output: output,
                title: status == .completed ? "Asked 1 question" : nil,
                metadata: metadata
            )
        )
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
    var appendedStreamingTexts: [String] = []
    var clearedStreamingBuffers: [String] = []

    func finishLoading() {}

    func beginExternalResponse() {
        isLoading = true
        currentActivity = AgentActivity()
        currentActivity?.currentLabel = "Thinking..."
    }

    func shouldIgnoreAssistantEvent(sessionID: String, messageID: String) -> Bool {
        false
    }

    func shouldIgnoreBusyStatus(sessionID: String) -> Bool {
        false
    }

    func appendStreamingText(messageID: String, text: String) {
        appendedStreamingTexts.append(text)
    }

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
