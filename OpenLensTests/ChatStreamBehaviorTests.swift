import Foundation
import SwiftUI
import Testing
@testable import OpenLens

struct ChatStreamBehaviorTests {

    @MainActor
    @Test func streamingFlushPublishesBufferedTextProjection() async {
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

        #expect(client.pendingAssistantMessage?.content == "")
        #expect(client.pendingAssistantMessage?.streamingTextProjection.copyText() == "Hello")
        #expect(client.contentVersion == 1)
    }

    @MainActor
    @Test func largeSnapshotsUseBoundedFlushesAndMaterializeRemainingChunksOffMain() async {
        let client = ChatClient(demoMode: true)
        let handler = makeHandler(delegate: client)
        let sessionID = "session-1"
        let messageID = "assistant-message"
        let reasoningPartID = "reasoning-part"
        client.currentSession = OCSession(
            id: sessionID,
            title: "Test",
            time: OCSessionTime(created: 0, updated: 0)
        )
        let message = ChatMessage(
            id: messageID,
            role: .assistant,
            content: "",
            isStreaming: true
        )
        client.pendingAssistantMessage = message

        let reasoning = String(repeating: "Inspecting a large streamed reasoning snapshot. ", count: 2_500)
        let answer = String(repeating: "## Large streamed snapshot\n\nThis answer stays responsive.\n\n", count: 2_500)
        let reasoningPayload = SSETextDelta(
            sessionID: sessionID,
            messageID: messageID,
            partID: reasoningPartID,
            field: "text",
            text: reasoning
        )
        let answerPayload = SSETextDelta(
            sessionID: sessionID,
            messageID: messageID,
            partID: nil,
            field: "text",
            text: answer
        )
        #expect(reasoningPayload.textChunks.count > 8)
        #expect(answerPayload.textChunks.count > 8)

        let reasoningPart = OCPart(
            id: reasoningPartID,
            sessionID: sessionID,
            messageID: messageID,
            type: .reasoning,
            text: reasoning
        )
        handler.handleInboundEvent(
            .partUpdated(
                part: reasoningPart,
                textChunks: reasoningPayload.textChunks,
                questionPayload: nil,
                rawEvent: OCEvent(type: "message.part.updated", properties: nil)
            )
        )
        let textPart = OCPart(
            id: "text-part",
            sessionID: sessionID,
            messageID: messageID,
            type: .text,
            text: answer
        )
        handler.handleInboundEvent(
            .partUpdated(
                part: textPart,
                textChunks: answerPayload.textChunks,
                questionPayload: nil,
                rawEvent: OCEvent(type: "message.part.updated", properties: nil)
            )
        )

        await waitForMainQueue(milliseconds: 80)
        let partialReasoning = message.assistantSegments
            .first(where: { $0.id == reasoningPartID })?
            .streamingText?
            .copyText() ?? ""
        #expect(!partialReasoning.isEmpty)
        #expect(partialReasoning.count < reasoning.count)

        client.finishLoading()
        await waitForMainQueue(milliseconds: 300)

        guard let finalized = client.messages.last else {
            Issue.record("Expected the finalized assistant message")
            return
        }
        #expect(finalized.content == answer)
        #expect(finalized.parts.first(where: { $0.id == reasoningPartID })?.text == reasoning)
        #expect(!finalized.isStreaming)
    }

    @MainActor
    @Test func authoritativeReplacementInvalidatesQueuedLargeSnapshotInConstantTimePath() async {
        let client = ChatClient(demoMode: true)
        let handler = makeHandler(delegate: client)
        let sessionID = "session-1"
        let messageID = "assistant-message"
        client.currentSession = OCSession(
            id: sessionID,
            title: "Test",
            time: OCSessionTime(created: 0, updated: 0)
        )
        let message = ChatMessage(
            id: messageID,
            role: .assistant,
            content: "",
            isStreaming: true
        )
        client.pendingAssistantMessage = message

        let superseded = String(repeating: "old snapshot fragment ", count: 8_000)
        let replacement = String(repeating: "new snapshot fragment ", count: 8_000)
        let supersededChunks = SSETextDelta(
            sessionID: sessionID,
            messageID: messageID,
            partID: nil,
            field: "text",
            text: superseded
        ).textChunks
        let replacementChunks = SSETextDelta(
            sessionID: sessionID,
            messageID: messageID,
            partID: nil,
            field: "text",
            text: replacement
        ).textChunks

        handler.handleInboundEvent(
            .partUpdated(
                part: OCPart(
                    id: "text-part",
                    sessionID: sessionID,
                    messageID: messageID,
                    type: .text,
                    text: superseded
                ),
                textChunks: supersededChunks,
                questionPayload: nil,
                rawEvent: OCEvent(type: "message.part.updated", properties: nil)
            )
        )
        handler.handleInboundEvent(
            .partUpdated(
                part: OCPart(
                    id: "text-part",
                    sessionID: sessionID,
                    messageID: messageID,
                    type: .text,
                    text: replacement
                ),
                textChunks: replacementChunks,
                questionPayload: nil,
                rawEvent: OCEvent(type: "message.part.updated", properties: nil)
            )
        )

        await waitForMainQueue(milliseconds: 80)
        #expect(message.streamingTextProjection.copyText().hasPrefix("new snapshot"))
        #expect(!message.streamingTextProjection.copyText().contains("old snapshot"))

        client.finishLoading()
        await waitForMainQueue(milliseconds: 300)
        #expect(client.messages.last?.content == replacement)
    }

    @MainActor
    @Test func reasoningSnapshotWithLongLeadingWhitespaceSurvivesFinalization() async {
        let client = ChatClient(demoMode: true)
        let handler = makeHandler(delegate: client)
        let sessionID = "session-1"
        let messageID = "assistant-message"
        let partID = "reasoning-part"
        client.currentSession = OCSession(
            id: sessionID,
            title: "Test",
            time: OCSessionTime(created: 0, updated: 0)
        )
        client.pendingAssistantMessage = ChatMessage(
            id: messageID,
            role: .assistant,
            content: "",
            isStreaming: true
        )

        let reasoning = String(repeating: " ", count: 4_096) + "Visible reasoning after a long prefix."
        let payload = SSETextDelta(
            sessionID: sessionID,
            messageID: messageID,
            partID: partID,
            field: "text",
            text: reasoning
        )
        handler.handleInboundEvent(
            .partUpdated(
                part: OCPart(
                    id: partID,
                    sessionID: sessionID,
                    messageID: messageID,
                    type: .reasoning,
                    text: reasoning
                ),
                textChunks: payload.textChunks,
                questionPayload: nil,
                rawEvent: OCEvent(type: "message.part.updated", properties: nil)
            )
        )

        // Finish before the normal timer needs to render the entire snapshot.
        // The worker still receives the reset projection plus every pending
        // chunk and computes exact whitespace semantics there.
        client.finishLoading()

        guard let finalized = client.messages.last else {
            Issue.record("Expected a finalized assistant message")
            return
        }
        #expect(finalized.parts.first(where: { $0.id == partID })?.text == reasoning)
        #expect(finalized.assistantSegments.contains(where: { $0.id == partID }))
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
    @Test func longStreamingProjectionKeepsSealedChunksStableAndCopiesOnDemand() {
        let message = ChatMessage(
            id: "assistant-message",
            role: .assistant,
            content: "",
            isStreaming: true
        )
        let firstDelta = String(repeating: "first stream segment ", count: 7_000)
        let firstPayload = SSETextDelta(
            sessionID: "session-1",
            messageID: message.id,
            partID: nil,
            field: "text",
            text: firstDelta
        )

        message.appendStreamingText(firstPayload.text, chunks: firstPayload.textChunks)

        let sealedIDs = message.streamingTextProjection.sealedChunks.map(\.id)
        let secondDelta = String(repeating: "second stream segment ", count: 7_000)
        let secondPayload = SSETextDelta(
            sessionID: "session-1",
            messageID: message.id,
            partID: nil,
            field: "text",
            text: secondDelta
        )

        message.appendStreamingText(secondPayload.text, chunks: secondPayload.textChunks)

        #expect(!sealedIDs.isEmpty)
        #expect(message.streamingTextProjection.sealedChunks.map(\.id).starts(with: sealedIDs))
        #expect(
            message.streamingTextProjection.tail.count
                <= ChatMessage.StreamingTextProjection.targetChunkLength
        )
        let liveWindow = message.streamingTextProjection.liveWindow
        #expect(
            liveWindow.sealedChunks.count
                == ChatMessage.StreamingTextProjection.maximumLiveSealedChunkCount
        )
        #expect(
            liveWindow.omittedSealedChunkCount
                == message.streamingTextProjection.sealedChunks.count
                    - ChatMessage.StreamingTextProjection.maximumLiveSealedChunkCount
        )
        #expect(
            liveWindow.sealedChunks.map(\.id)
                == message.streamingTextProjection.sealedChunks.suffix(3).map(\.id)
        )
        #expect(message.streamingTextProjection.copyText() == firstDelta + secondDelta)
        #expect(message.content.isEmpty)
        message.materializeStreamingProjections()
        #expect(message.content.count == firstDelta.count + secondDelta.count)
    }

    @MainActor
    @Test func reasoningDeltasUpdateProjectionWithoutRebuildingAssistantSegments() async {
        let client = ChatClient(demoMode: true)
        let messageID = "assistant-message"
        let message = ChatMessage(
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
        client.pendingAssistantMessage = message

        let initialSegments = message.assistantSegments
        client.appendStreamingReasoning(
            messageID: messageID,
            partID: "reasoning-part",
            text: "Inspecting stream state",
            chunks: ["Inspecting stream state"]
        )
        await waitForMainQueue(milliseconds: 80)

        guard let segment = message.assistantSegments.first(where: { $0.id == "reasoning-part" }),
              let projection = segment.streamingText else {
            Issue.record("Expected a projected reasoning segment")
            return
        }

        #expect(message.content.isEmpty)
        #expect(projection.copyText() == "Inspecting stream state")
        #expect(message.assistantSegments.count >= initialSegments.count)
    }

    @MainActor
    @Test func reasoningSnapshotUpdatesExistingProjectionWithoutRebuildingTimeline() async {
        let client = ChatClient(demoMode: true)
        let handler = makeHandler(delegate: client)
        let messageID = "assistant-message"
        client.currentSession = OCSession(
            id: "session-1",
            title: "Test",
            time: OCSessionTime(created: 0, updated: 0)
        )
        let message = ChatMessage(
            id: messageID,
            role: .assistant,
            content: "",
            parts: [
                OCPart(
                    id: "reasoning-part",
                    sessionID: "session-1",
                    messageID: messageID,
                    type: .reasoning,
                    text: "Initial reasoning"
                )
            ],
            isStreaming: true
        )
        client.pendingAssistantMessage = message
        let timelineVersion = client.timelineVersion

        let updatedText = "Initial reasoning, with an appended snapshot."
        let part = OCPart(
            id: "reasoning-part",
            sessionID: "session-1",
            messageID: messageID,
            type: .reasoning,
            text: updatedText
        )
        handler.handleInboundEvent(
            .partUpdated(part: part, textChunks: SSETextDelta(
                sessionID: "session-1",
                messageID: messageID,
                partID: part.id,
                field: "text",
                text: updatedText
            ).textChunks, questionPayload: nil, rawEvent: OCEvent(type: "message.part.updated", properties: nil))
        )

        #expect(client.timelineVersion == timelineVersion)
        #expect(client.contentVersion > 0)
        await waitForMainQueue(milliseconds: 80)
        #expect(message.assistantSegments.first?.streamingText?.copyText() == updatedText)
    }

    @MainActor
    @Test func serverIDRemapPreservesBufferedProjectionAndFutureDeltas() async {
        let client = ChatClient(demoMode: true)
        let handler = makeHandler(delegate: client)
        let temporaryID = "temporary-assistant-id"
        let serverID = "server-assistant-id"
        client.currentSession = OCSession(
            id: "session-1",
            title: "Test",
            time: OCSessionTime(created: 0, updated: 0)
        )
        client.pendingAssistantMessage = ChatMessage(
            id: temporaryID,
            role: .assistant,
            content: "",
            isStreaming: true
        )

        client.appendStreamingText(messageID: temporaryID, text: "before ")
        handler.handleEvent(
            OCEvent(
                type: "message.updated",
                properties: AnyCodable([
                    "info": [
                        "id": serverID,
                        "sessionID": "session-1",
                        "role": "assistant"
                    ]
                ])
            )
        )
        client.appendStreamingText(messageID: serverID, text: "after")

        await waitForMainQueue(milliseconds: 80)
        client.finishLoading()

        #expect(client.pendingAssistantMessage == nil)
        #expect(client.messages.last?.id == serverID)
        #expect(client.messages.last?.content == "before after")
    }

    @MainActor
    @Test func largeFinalizationMaterializesOffMainBeforeMarkdownHandoff() async {
        let client = ChatClient(demoMode: true)
        let messageID = "assistant-message"
        let text = String(repeating: "long response segment ", count: 2_000)
        let message = ChatMessage(
            id: messageID,
            role: .assistant,
            content: "",
            isStreaming: true
        )
        message.appendStreamingText(text, chunks: SSETextDelta(
            sessionID: "session-1",
            messageID: messageID,
            partID: nil,
            field: "text",
            text: text
        ).textChunks)
        client.pendingAssistantMessage = message

        client.finishLoading()

        #expect(client.pendingAssistantMessage == nil)
        #expect(client.messages.last?.id == messageID)
        #expect(client.messages.last?.isStreaming == true)
        let timelineVersionWhileStreaming = client.timelineVersion

        // A new external turn must not cancel finalization of the previous
        // detached transcript.
        client.beginExternalResponse()
        await waitForMainQueue(milliseconds: 250)

        #expect(client.messages.last?.isStreaming == false)
        #expect(client.messages.last?.content == text)
        #expect(client.timelineVersion > timelineVersionWhileStreaming)
    }

    @MainActor
    @Test func workerMaterializationPreservesLargeWhitespaceOnlyContentAndReasoningSemantics() async {
        let whitespace = String(repeating: " \n", count: 50_000)
        let snapshot = ChatMessage.StreamingMaterialization(
            contentChunks: [whitespace],
            reasoningChunksByPartID: ["reasoning-part": [whitespace]],
            estimatedCharacterCount: whitespace.utf8.count * 2
        )

        let materialized = await Task.detached {
            ChatMessage.materialize(snapshot)
        }.value

        #expect(!materialized.hasVisibleContent)
        #expect(materialized.hasVisibleReasoningByPartID["reasoning-part"] == false)

        let message = ChatMessage(
            id: "assistant-message",
            role: .assistant,
            content: "",
            parts: [
                OCPart(
                    id: "reasoning-part",
                    sessionID: "session-1",
                    messageID: "assistant-message",
                    type: .reasoning,
                    text: ""
                )
            ],
            isStreaming: true
        )

        message.applyStreamingMaterialization(materialized)
        message.isStreaming = false

        #expect(message.content == whitespace)
        #expect(message.assistantSegments.isEmpty)
    }

    @MainActor
    @Test func largeReasoningSnapshotsKeepVisibleContentAndSkipWhitespaceOnlyRows() {
        let message = ChatMessage(
            id: "assistant-message",
            role: .assistant,
            content: "",
            isStreaming: true
        )
        let whitespace = String(repeating: " ", count: 100_000)
        let visible = "Inspecting " + String(repeating: "detail ", count: 15_000)

        _ = message.applyPartUpdate(
            OCPart(
                id: "blank-reasoning",
                sessionID: "session-1",
                messageID: message.id,
                type: .reasoning,
                text: whitespace
            ),
            textChunks: []
        )
        _ = message.applyPartUpdate(
            OCPart(
                id: "visible-reasoning",
                sessionID: "session-1",
                messageID: message.id,
                type: .reasoning,
                text: visible
            ),
            textChunks: ["Inspecting "]
        )

        #expect(!message.assistantSegments.contains(where: { $0.id == "blank-reasoning" }))
        #expect(message.assistantSegments.contains(where: { $0.id == "visible-reasoning" }))
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
    @Test func sessionUpdatedPreservesCurrentSessionWorkspaceMetadata() {
        let delegate = SSEDelegateSpy()
        delegate.currentSession = OCSession(
            id: "session-1",
            projectID: "project-openlens",
            directory: "/Users/developer/Projects/OpenLens",
            parentID: "parent-session",
            title: "Original title",
            version: "v1",
            time: OCSessionTime(created: 100, updated: 200)
        )
        let handler = makeHandler(delegate: delegate)

        handler.handleEvent(
            OCEvent(
                type: "session.updated",
                properties: AnyCodable([
                    "info": [
                        "id": "session-1",
                        "title": "Renamed session"
                    ]
                ])
            )
        )

        #expect(delegate.currentSession?.title == "Renamed session")
        #expect(delegate.currentSession?.projectID == "project-openlens")
        #expect(delegate.currentSession?.directory == "/Users/developer/Projects/OpenLens")
        #expect(delegate.currentSession?.parentID == "parent-session")
        #expect(delegate.currentSession?.version == "v1")
        #expect(delegate.currentSession?.time == OCSessionTime(created: 100, updated: 200))
    }

    @MainActor
    @Test func sessionUpdatedAppliesIncomingMetadataWithoutDroppingAbsentFields() {
        let delegate = SSEDelegateSpy()
        delegate.currentSession = OCSession(
            id: "session-1",
            projectID: "project-old",
            directory: "/Users/developer/Projects/OpenLens",
            parentID: "parent-old",
            title: "Original title",
            version: "v1",
            time: OCSessionTime(created: 100, updated: 200),
            share: OCShareInfo(url: "https://share.example/old")
        )
        let handler = makeHandler(delegate: delegate)

        handler.handleEvent(
            OCEvent(
                type: "session.updated",
                properties: AnyCodable([
                    "info": [
                        "id": "session-1",
                        "projectID": "project-new",
                        "directory": "/Users/developer/Projects/OpenLensNext",
                        "title": "Renamed session",
                        "version": "v2",
                        "time": ["created": 100, "updated": 300],
                        "share": ["url": "https://share.example/new"]
                    ]
                ])
            )
        )

        #expect(delegate.currentSession?.projectID == "project-new")
        #expect(delegate.currentSession?.directory == "/Users/developer/Projects/OpenLensNext")
        #expect(delegate.currentSession?.parentID == "parent-old")
        #expect(delegate.currentSession?.title == "Renamed session")
        #expect(delegate.currentSession?.version == "v2")
        #expect(delegate.currentSession?.time == OCSessionTime(created: 100, updated: 300))
        #expect(delegate.currentSession?.share?.url == "https://share.example/new")
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

        await waitForMainQueue(milliseconds: 1_550)
        for _ in 0..<10 where client.responseState != .idle {
            // The state-clear task and this test continuation both resume on
            // MainActor. Polling avoids making their relative scheduler order
            // part of the behavioral assertion.
            await waitForMainQueue(milliseconds: 50)
        }

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
    @Test func chatScrollPolicyTracksSettledBottomAndButtonVisibility() {
        let normalMetrics = ChatScrollPolicy.bottomMetrics(
            contentHeight: 700,
            containerHeight: 100,
            contentOffsetY: 540,
            topInset: 0,
            bottomInset: 0
        )
        #expect(normalMetrics.distance == 60)
        #expect(normalMetrics.overscroll == 0)

        let shortContentMetrics = ChatScrollPolicy.bottomMetrics(
            contentHeight: 500,
            containerHeight: 600,
            contentOffsetY: 0,
            topInset: 0,
            bottomInset: 0
        )
        #expect(shortContentMetrics.distance == 0)
        #expect(shortContentMetrics.overscroll == 0)

        let overscrolledMetrics = ChatScrollPolicy.bottomMetrics(
            contentHeight: 700,
            containerHeight: 100,
            contentOffsetY: 660,
            topInset: 0,
            bottomInset: 0
        )
        #expect(overscrolledMetrics.distance == 0)
        #expect(overscrolledMetrics.overscroll == 60)

        #expect(ChatScrollPolicy.isAtBottom(
            bottomDistance: 8,
            bottomOverscroll: 0,
            tolerance: 8
        ))
        #expect(!ChatScrollPolicy.isAtBottom(
            bottomDistance: 9,
            bottomOverscroll: 0,
            tolerance: 8
        ))
        #expect(!ChatScrollPolicy.isAtBottom(
            bottomDistance: 0,
            bottomOverscroll: 9,
            tolerance: 8
        ))

        #expect(ChatScrollPolicy.state(
            contentHeight: 700,
            containerHeight: 100,
            contentOffsetY: 540,
            topInset: 0,
            bottomInset: 0,
            settledBottomTolerance: 8,
            visibilityThreshold: 56
        ) == ChatScrollState(
            bottomDistance: 60,
            bottomOverscroll: 0,
            isAtBottom: false,
            isPastVisibilityThreshold: true
        ))

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
    @Test func manualScrollUpDisablesFollowUntilUserReturnsToBottom() {
        #expect(ChatScrollPolicy.interaction(for: .tracking) == .userControlled)
        #expect(ChatScrollPolicy.interaction(for: .interacting) == .userControlled)
        #expect(ChatScrollPolicy.interaction(for: .decelerating) == .userControlled)
        #expect(ChatScrollPolicy.interaction(for: .animating) == .programmatic)
        #expect(ChatScrollPolicy.interaction(for: .idle) == .idle)

        let afterDrag = ChatScrollPolicy.updatedFollowLatest(
            currentValue: true,
            interaction: .userControlled,
            isAtBottom: true
        )
        #expect(!afterDrag)
        #expect(!ChatScrollPolicy.updatedFollowLatest(
            currentValue: afterDrag,
            interaction: .idle,
            isAtBottom: false
        ))
        #expect(ChatScrollPolicy.updatedFollowLatest(
            currentValue: afterDrag,
            interaction: .idle,
            isAtBottom: true
        ))
        #expect(!ChatScrollPolicy.shouldPerformProgrammaticScroll(
            interaction: .userControlled
        ))
        #expect(!ChatScrollPolicy.shouldPerformProgrammaticScroll(
            interaction: .programmatic
        ))
        #expect(ChatScrollPolicy.shouldPerformProgrammaticScroll(
            interaction: .idle
        ))
    }

    @MainActor
    @Test func chatScrollPolicyAllowsOnlyOneIdleAutoFollowPerNewDataBatch() {
        let now = Date()

        #expect(ChatScrollPolicy.shouldAutoFollow(
            isLoading: true,
            followLatest: true,
            interaction: .idle,
            bottomDistance: 40,
            bottomOverscroll: 0,
            settledBottomTolerance: 8,
            contentVersion: 11,
            lastHandledContentVersion: 10,
            now: now,
            lastAutoScrollDate: now.addingTimeInterval(-0.3),
            minimumInterval: 0.18
        ))
        #expect(!ChatScrollPolicy.shouldAutoFollow(
            isLoading: true,
            followLatest: false,
            interaction: .idle,
            bottomDistance: 40,
            bottomOverscroll: 0,
            settledBottomTolerance: 8,
            contentVersion: 11,
            lastHandledContentVersion: 10,
            now: now,
            lastAutoScrollDate: now.addingTimeInterval(-0.3),
            minimumInterval: 0.18
        ))
        #expect(!ChatScrollPolicy.shouldAutoFollow(
            isLoading: false,
            followLatest: true,
            interaction: .idle,
            bottomDistance: 40,
            bottomOverscroll: 0,
            settledBottomTolerance: 8,
            contentVersion: 11,
            lastHandledContentVersion: 10,
            now: now,
            lastAutoScrollDate: now.addingTimeInterval(-0.3),
            minimumInterval: 0.18
        ))
        #expect(!ChatScrollPolicy.shouldAutoFollow(
            isLoading: true,
            followLatest: true,
            interaction: .idle,
            bottomDistance: 40,
            bottomOverscroll: 0,
            settledBottomTolerance: 8,
            contentVersion: 11,
            lastHandledContentVersion: 10,
            now: now,
            lastAutoScrollDate: now.addingTimeInterval(-0.05),
            minimumInterval: 0.18
        ))

        // Re-evaluating the same content batch cannot emit another scroll.
        #expect(!ChatScrollPolicy.shouldAutoFollow(
            isLoading: true,
            followLatest: true,
            interaction: .idle,
            bottomDistance: 40,
            bottomOverscroll: 0,
            settledBottomTolerance: 8,
            contentVersion: 11,
            lastHandledContentVersion: 11,
            now: now,
            lastAutoScrollDate: now.addingTimeInterval(-0.3),
            minimumInterval: 0.18
        ))

        // If content shrinks while following (for example at the streaming
        // Markdown handoff), clamp a viewport stranded beyond the new end.
        #expect(ChatScrollPolicy.shouldAutoFollow(
            isLoading: true,
            followLatest: true,
            interaction: .idle,
            bottomDistance: 0,
            bottomOverscroll: 40,
            settledBottomTolerance: 8,
            contentVersion: 11,
            lastHandledContentVersion: 10,
            now: now,
            lastAutoScrollDate: now.addingTimeInterval(-0.3),
            minimumInterval: 0.18
        ))
    }

    @MainActor
    @Test func chatScrollPolicyNeverAutoFollowsAtBottomOrDuringUserMotion() {
        let now = Date()

        for interaction in [
            ChatScrollInteraction.userControlled,
            ChatScrollInteraction.programmatic
        ] {
            #expect(!ChatScrollPolicy.shouldAutoFollow(
                isLoading: true,
                followLatest: true,
                interaction: interaction,
                bottomDistance: 40,
                bottomOverscroll: 0,
                settledBottomTolerance: 8,
                contentVersion: 11,
                lastHandledContentVersion: 10,
                now: now,
                lastAutoScrollDate: now.addingTimeInterval(-0.3),
                minimumInterval: 0.18
            ))
        }

        // This is the former infinite-bounce case: new stream data that does
        // not move the bottom beyond the tolerance must not call scrollTo.
        #expect(!ChatScrollPolicy.shouldAutoFollow(
            isLoading: true,
            followLatest: true,
            interaction: .idle,
            bottomDistance: 0,
            bottomOverscroll: 0,
            settledBottomTolerance: 8,
            contentVersion: 11,
            lastHandledContentVersion: 10,
            now: now,
            lastAutoScrollDate: now.addingTimeInterval(-0.3),
            minimumInterval: 0.18
        ))
    }

    @MainActor
    @Test func earlierMessageLoadingIsGatedUntilAnchorRestorationCompletes() {
        #expect(ChatScrollPolicy.shouldLoadEarlierMessages(
            hasEarlierMessages: true,
            interaction: .idle,
            hasPendingRestoration: false
        ))
        #expect(!ChatScrollPolicy.shouldLoadEarlierMessages(
            hasEarlierMessages: true,
            interaction: .idle,
            hasPendingRestoration: true
        ))
        #expect(!ChatScrollPolicy.shouldLoadEarlierMessages(
            hasEarlierMessages: true,
            interaction: .userControlled,
            hasPendingRestoration: false
        ))
        #expect(!ChatScrollPolicy.shouldLoadEarlierMessages(
            hasEarlierMessages: false,
            interaction: .idle,
            hasPendingRestoration: false
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
        // Tool references are not needed to answer this prompt and are
        // intentionally discarded before untrusted permission data reaches UI state.
        #expect(delegate.pendingPermission?.toolRef == nil)
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
    func partUpdatedRetainsOnlyPotentiallyVisibleParts(_ rawType: String) {
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

        let isPotentiallyVisible = rawType == "agent" || rawType == "subtask"
        #expect(delegate.pendingAssistantMessage?.parts.count == (isPotentiallyVisible ? 1 : 0))
        if isPotentiallyVisible {
            #expect(delegate.pendingAssistantMessage?.parts.first?.type == OCPartType(rawValue: rawType))
            #expect(delegate.layoutChangeCount == 1)
            #expect(delegate.contentChangeCount == 0)
        } else {
            #expect(delegate.layoutChangeCount == 0)
            #expect(delegate.contentChangeCount == 1)
        }
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

        guard let segment = delegate.pendingAssistantMessage?.assistantSegments.first,
              case .reasoning = segment.kind,
              let projection = segment.streamingText else {
            Issue.record("Expected reasoning delta to update a reasoning segment")
            return
        }

        #expect(projection.copyText() == "Inspecting stream state")
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
        #expect(step.isActive)
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
        #expect(!step.isActive)
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
        #expect(step.isActive)
    }

    @MainActor
    @Test func largeToolOutputIsPrecomputedAsABoundedTranscriptPreview() {
        let messageID = "assistant-message"
        let output = " \n\nfirst line\n\n\nsecond line " + String(repeating: "x", count: 100_000)
        let message = ChatMessage(
            id: messageID,
            role: .assistant,
            content: "",
            parts: [
                OCPart(
                    id: "bash-part",
                    sessionID: "session-1",
                    messageID: messageID,
                    type: .tool,
                    tool: "bash",
                    state: OCToolState(status: .completed, output: output)
                )
            ],
            isStreaming: true
        )

        guard case .tool(let step) = message.assistantSegments.first?.kind,
              let preview = step.outputPreview else {
            Issue.record("Expected a bounded tool transcript preview")
            return
        }

        #expect(preview.hasPrefix("first line\nsecond line"))
        #expect(preview.hasSuffix("..."))
        #expect(preview.count <= 143)
    }

    @MainActor
    @Test func toolLabelsAndActivityDetailsBoundLargeInputs() {
        let command = "echo " + String(repeating: "x", count: 100_000)
        let bashState = OCToolState(
            status: .running,
            input: AnyCodable(["command": command])
        )
        let bashLabel = ToolLabelFormatter.label(toolName: "bash", state: bashState)

        #expect(bashLabel.hasPrefix("Bash echo "))
        #expect(bashLabel.hasSuffix("..."))
        #expect(bashLabel.count <= 60)

        let path = "/tmp/" + String(repeating: "nested/", count: 20_000)
        let pathState = OCToolState(
            status: .running,
            input: AnyCodable(["path": path])
        )
        let detail = ToolLabelFormatter.detail(state: pathState)

        #expect(detail.hasSuffix("..."))
        #expect(detail.count <= 183)
    }

    @MainActor
    @Test func completedAndErroredToolActivityLabelsBoundLargeServerValues() {
        let messageID = "assistant-message"
        let rawToolName = "tool-" + String(repeating: "n", count: 100_000)
        let completedTitle = "Completed result: " + String(repeating: "c", count: 100_000)
        let errorTitle = "Failed result: " + String(repeating: "e", count: 100_000)
        let delegate = SSEDelegateSpy()
        delegate.pendingAssistantMessage = ChatMessage(
            id: messageID,
            role: .assistant,
            content: "",
            isStreaming: true
        )
        delegate.currentActivity = AgentActivity()
        let handler = makeHandler(delegate: delegate)
        let rawEvent = OCEvent(type: "message.part.updated", properties: nil)

        handler.handleInboundEvent(
            .partUpdated(
                part: OCPart(
                    id: "tool-part",
                    sessionID: "session-1",
                    messageID: messageID,
                    type: .tool,
                    tool: rawToolName,
                    state: OCToolState(status: .completed, title: completedTitle)
                ),
                textChunks: nil,
                questionPayload: nil,
                rawEvent: rawEvent
            )
        )

        guard let completedLabel = delegate.currentActivity?.steps.last?.label else {
            Issue.record("Expected a completed tool activity step")
            return
        }

        #expect(completedLabel.hasPrefix("Completed result:"))
        #expect(completedLabel.hasSuffix("..."))
        #expect(completedLabel.count <= 83)

        handler.handleInboundEvent(
            .partUpdated(
                part: OCPart(
                    id: "tool-part",
                    sessionID: "session-1",
                    messageID: messageID,
                    type: .tool,
                    tool: rawToolName,
                    state: OCToolState(status: .error, title: errorTitle)
                ),
                textChunks: nil,
                questionPayload: nil,
                rawEvent: rawEvent
            )
        )

        let errorLabel = delegate.currentActivity?.currentLabel ?? ""
        #expect(errorLabel.hasPrefix("Error: Failed result:"))
        #expect(errorLabel.hasSuffix("..."))
        #expect(errorLabel.count <= 90)
    }

    @MainActor
    @Test func subagentAndToolDisplayValuesBoundLargeServerStrings() {
        let largeAgentName = "  explore-" + String(repeating: "a", count: 100_000)
        let largeDetail = "  Inspect this workspace: " + String(repeating: "d", count: 100_000)
        let largePrompt = "  Run focused checks: " + String(repeating: "p", count: 100_000)
        let largeToolName = "bash-" + String(repeating: "b", count: 100_000)

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
                    tool: "task",
                    state: OCToolState(
                        status: .running,
                        input: AnyCodable(["subagent_type": largeAgentName]),
                        title: largeDetail,
                        error: largeDetail
                    ),
                    prompt: largePrompt,
                    partDescription: largeDetail
                ),
                OCPart(
                    id: "large-tool-part",
                    sessionID: "session-1",
                    messageID: "assistant-message",
                    type: .tool,
                    tool: largeToolName,
                    state: OCToolState(status: .running)
                )
            ],
            isStreaming: true
        )

        #expect(message.assistantSegments.map(\.id) == ["task-part", "large-tool-part"])

        guard case .subagent(let subagent) = message.assistantSegments[0].kind else {
            Issue.record("Expected the task part to stay a subagent row")
            return
        }
        guard case .tool(let tool) = message.assistantSegments[1].kind else {
            Issue.record("Expected the generic tool part to stay a tool row")
            return
        }

        #expect(subagent.agentName?.hasPrefix("explore-") == true)
        #expect(subagent.agentName?.hasSuffix("...") == true)
        #expect(subagent.agentName?.count ?? 0 <= 99)
        #expect(subagent.title.count <= 99)
        #expect(subagent.detail.hasPrefix("Inspect this workspace:"))
        #expect(subagent.detail.hasSuffix("..."))
        #expect(subagent.detail.count <= 483)
        #expect(subagent.prompt?.hasPrefix("Run focused checks:") == true)
        #expect(subagent.prompt?.hasSuffix("...") == true)
        #expect(subagent.prompt?.count ?? 0 <= 483)

        #expect(tool.toolName.hasPrefix("bash-"))
        #expect(tool.toolName.hasSuffix("..."))
        #expect(tool.toolName.count <= 99)
        #expect(tool.toolCategory == .bash)
    }

    @MainActor
    @Test func timelinePreservesServerPartOrderAcrossTextAndTaskRows() {
        let assistantID = "assistant-message"
        let message = ChatMessage(
            id: assistantID,
            role: .assistant,
            content: "",
            parts: [
                OCPart(
                    id: "text-before",
                    sessionID: "session-1",
                    messageID: assistantID,
                    type: .text,
                    text: "Before task"
                ),
                OCPart(
                    id: "task-part",
                    sessionID: "session-1",
                    messageID: assistantID,
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
                ),
                OCPart(
                    id: "text-after",
                    sessionID: "session-1",
                    messageID: assistantID,
                    type: .text,
                    text: "After task"
                )
            ],
            isStreaming: true
        )

        let items = ChatTimeline.items(from: [message], showsThinking: true)

        #expect(items.map(\.id) == [
            "message-\(assistantID)-part-text-before",
            "message-\(assistantID)-part-task-part",
            "message-\(assistantID)-part-text-after"
        ])

        guard case .assistantSegment(_, let segment) = items[1].content,
              case .subagent(let step) = segment.kind else {
            Issue.record("Expected the middle server part to stay a task row")
            return
        }

        #expect(step.isActive)
    }

    @MainActor
    @Test func timelineKeepsTaskIdentityWhenServerUpdatesItsState() {
        let message = ChatMessage(
            id: "assistant-message",
            role: .assistant,
            content: "",
            parts: [
                taskPart(status: .running)
            ],
            isStreaming: true
        )

        let runningItems = ChatTimeline.items(from: [message], showsThinking: true)
        message.parts = [taskPart(status: .completed)]
        let completedItems = ChatTimeline.items(from: [message], showsThinking: true)

        #expect(runningItems.map(\.id) == completedItems.map(\.id))
        #expect(completedItems.count == 1)

        guard case .assistantSegment(_, let segment) = completedItems[0].content,
              case .subagent(let step) = segment.kind else {
            Issue.record("Expected the updated task to remain a subagent row")
            return
        }

        #expect(!step.isActive)
        #expect(step.isCompleted)
    }

    @MainActor
    @Test func timelineReplacesStreamingThinkingWithTaskRow() {
        let message = ChatMessage(
            id: "assistant-message",
            role: .assistant,
            content: "",
            isStreaming: true
        )

        let thinkingItems = ChatTimeline.items(from: [message], showsThinking: true)
        #expect(thinkingItems.map(\.id) == ["message-assistant-message-part-streaming-thinking-assistant-message"])

        message.parts = [taskPart(status: .running)]
        let taskItems = ChatTimeline.items(from: [message], showsThinking: true)

        #expect(taskItems.map(\.id) == ["message-assistant-message-part-task-part"])
    }

    @MainActor
    @Test func timelineKeepsStreamingTextIdentityThroughCompletion() {
        let message = ChatMessage(
            id: "assistant-message",
            role: .assistant,
            content: "Streaming answer",
            isStreaming: true
        )

        let streamingItems = ChatTimeline.items(from: [message], showsThinking: false)
        message.isStreaming = false
        let completedItems = ChatTimeline.items(from: [message], showsThinking: false)

        #expect(streamingItems.map(\.id) == completedItems.map(\.id))
        #expect(streamingItems.map(\.id) == ["message-assistant-message-part-content-text-assistant-message"])
    }

    @MainActor
    @Test func timelinePaginatesParentsBeforeFlatteningParts() {
        let client = ChatClient(demoMode: true)
        let older = ChatMessage(
            id: "older",
            role: .assistant,
            content: "",
            parts: [
                OCPart(id: "older-text", sessionID: "session-1", messageID: "older", type: .text, text: "Older")
            ]
        )
        let latest = ChatMessage(
            id: "latest",
            role: .assistant,
            content: "",
            parts: [
                OCPart(id: "latest-first", sessionID: "session-1", messageID: "latest", type: .text, text: "First"),
                taskPart(status: .running, messageID: "latest"),
                OCPart(id: "latest-last", sessionID: "session-1", messageID: "latest", type: .text, text: "Last")
            ],
            isStreaming: true
        )

        client.messages = [older, latest]
        client.displayLimit = 1

        let items = ChatTimeline.items(from: client.displayedMessages, showsThinking: true)

        #expect(items.map(\.id) == [
            "message-latest-part-latest-first",
            "message-latest-part-task-part",
            "message-latest-part-latest-last"
        ])
    }

    @MainActor
    @Test func loadingEarlierMessagesPrependsExactlyOnePage() {
        let client = ChatClient(demoMode: true)
        client.messages = (0..<40).map { index in
            ChatMessage(
                id: "message-\(index)",
                role: index.isMultiple(of: 2) ? .user : .assistant,
                content: "Message \(index)"
            )
        }

        #expect(client.displayedMessages.count == 15)
        #expect(client.displayedMessages.first?.id == "message-25")

        client.loadEarlierMessages()

        #expect(client.displayedMessages.count == 30)
        #expect(client.displayedMessages.first?.id == "message-10")
        #expect(client.displayedMessages[15].id == "message-25")
    }

    @MainActor
    @Test func taskPartUpdatePublishesLayoutChangeForSmoothAutoFollow() {
        let client = ChatClient(demoMode: true)
        let sessionID = "session-1"
        let messageID = "assistant-message"
        client.currentSession = OCSession(
            id: sessionID,
            title: "Test",
            time: OCSessionTime(created: 0, updated: 0)
        )
        client.pendingAssistantMessage = ChatMessage(
            id: messageID,
            role: .assistant,
            content: "",
            isStreaming: true
        )
        let handler = makeHandler(delegate: client)
        let previousVersion = client.contentVersion

        handler.handleEvent(
            OCEvent(
                type: "message.part.updated",
                properties: AnyCodable([
                    "part": [
                        "id": "task-part",
                        "sessionID": sessionID,
                        "messageID": messageID,
                        "type": "tool",
                        "tool": "task",
                        "callID": "task-call",
                        "state": [
                            "status": "running",
                            "input": [
                                "subagent_type": "explore",
                                "description": "Inspect the workspace"
                            ]
                        ]
                    ]
                ])
            )
        )

        #expect(client.contentVersion == previousVersion + 1)
        #expect(client.pendingAssistantMessage?.assistantSegments.count == 1)
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
    @Test func manyActivityPartsStayBoundedAndStatusUpdatesKeepTheirStableRow() {
        let message = ChatMessage(
            id: "assistant-message",
            role: .assistant,
            content: "",
            isStreaming: true
        )

        for index in 0..<80 {
            let part = OCPart(
                id: "task-\(index)",
                sessionID: "session-1",
                messageID: "assistant-message",
                type: .tool,
                callID: "call-\(index)",
                tool: "task",
                state: OCToolState(
                    status: .running,
                    input: AnyCodable([
                        "subagent_type": "explore",
                        "description": "Inspect item \(index)"
                    ])
                )
            )
            _ = message.applyPartUpdate(part)
        }

        let retainedActivityParts = message.parts.filter { $0.type == .tool }
        #expect(retainedActivityParts.count <= 48)
        #expect(message.assistantSegments.count <= 49)
        #expect(message.assistantSegments.contains(where: { $0.id == "activity-summary-assistant-message" }))

        let latestPart = OCPart(
            id: "task-79",
            sessionID: "session-1",
            messageID: "assistant-message",
            type: .tool,
            callID: "call-79",
            tool: "task",
            state: OCToolState(
                status: .completed,
                input: AnyCodable([
                    "subagent_type": "explore",
                    "description": "Inspect item 79"
                ])
            )
        )

        // A completion replaces the existing stable row. The timeline does not
        // need a full rebuild; `AssistantSegmentTimelineRow` observes it live.
        #expect(!message.applyPartUpdate(latestPart))
        guard let segment = message.assistantSegment(withID: "task-79"),
              case .subagent(let step) = segment.kind else {
            Issue.record("Expected the latest task to remain a visible subagent row")
            return
        }
        #expect(step.isCompleted)

        let timeline = ChatTimeline.items(from: [message], showsThinking: true)
        #expect(timeline.count <= 49)
    }

    @MainActor
    @Test func streamingDropsPermanentlyNonRenderablePartsBeforeTheyGrowTheIndex() {
        let message = ChatMessage(
            id: "assistant-message",
            role: .assistant,
            content: "",
            isStreaming: true
        )

        for index in 0..<200 {
            let changed = message.applyPartUpdate(
                OCPart(
                    id: "snapshot-\(index)",
                    sessionID: "session-1",
                    messageID: "assistant-message",
                    type: .snapshot
                )
            )
            #expect(!changed)
        }

        #expect(message.parts.isEmpty)
        #expect(message.assistantSegments.map(\.id) == ["streaming-thinking-assistant-message"])
    }

    @MainActor
    @Test func reasoningPartsAreBoundedWithASummaryAtTheirOriginalPosition() {
        let message = ChatMessage(
            id: "assistant-message",
            role: .assistant,
            content: "",
            isStreaming: true
        )

        _ = message.applyPartUpdate(
            OCPart(
                id: "reasoning-0",
                sessionID: "session-1",
                messageID: "assistant-message",
                type: .reasoning,
                text: "First reasoning update"
            )
        )
        _ = message.applyPartUpdate(
            OCPart(
                id: "tool-between-reasoning",
                sessionID: "session-1",
                messageID: "assistant-message",
                type: .tool,
                tool: "bash",
                state: OCToolState(status: .running)
            )
        )

        for index in 1...26 {
            _ = message.applyPartUpdate(
                OCPart(
                    id: "reasoning-\(index)",
                    sessionID: "session-1",
                    messageID: "assistant-message",
                    type: .reasoning,
                    text: "Reasoning update \(index)"
                )
            )
        }

        #expect(message.parts.filter { $0.type == .reasoning }.count <= 24)
        #expect(Array(message.assistantSegments.map(\.id).prefix(4)) == [
            "reasoning-summary-assistant-message-before-tool-between-reasoning",
            "tool-between-reasoning",
            "reasoning-summary-assistant-message-before-reasoning-3",
            "reasoning-3",
        ])
        #expect(!message.assistantSegments.contains(where: { $0.id == "reasoning-0" }))
        #expect(!message.assistantSegments.contains(where: { $0.id == "reasoning-2" }))
        #expect(message.assistantSegments.contains(where: { $0.id == "reasoning-26" }))
    }

    @MainActor
    @Test func pendingToolPromotionKeepsItsServerPartOrder() {
        let message = ChatMessage(
            id: "assistant-message",
            role: .assistant,
            content: "",
            isStreaming: true
        )
        let pendingTool = OCPart(
            id: "tool-first",
            sessionID: "session-1",
            messageID: "assistant-message",
            type: .tool,
            tool: "bash",
            state: OCToolState(status: .pending)
        )
        let reasoning = OCPart(
            id: "reasoning-second",
            sessionID: "session-1",
            messageID: "assistant-message",
            type: .reasoning,
            text: "Reasoning after the pending tool"
        )
        let runningTool = OCPart(
            id: "tool-first",
            sessionID: "session-1",
            messageID: "assistant-message",
            type: .tool,
            tool: "bash",
            state: OCToolState(status: .running)
        )

        _ = message.applyPartUpdate(pendingTool)
        _ = message.applyPartUpdate(reasoning)
        #expect(message.assistantSegments.map(\.id) == ["reasoning-second"])

        #expect(message.applyPartUpdate(runningTool))
        #expect(message.assistantSegments.map(\.id) == [
            "tool-first",
            "reasoning-second",
        ])
    }

    @MainActor
    @Test func stableSubagentUpdateUsesContentRefreshInsteadOfTimelineRebuild() {
        let messageID = "assistant-message"
        let delegate = SSEDelegateSpy()
        delegate.pendingAssistantMessage = ChatMessage(
            id: messageID,
            role: .assistant,
            content: "",
            isStreaming: true
        )
        let handler = makeHandler(delegate: delegate)
        let running = OCPart(
            id: "subagent-part",
            sessionID: "session-1",
            messageID: messageID,
            type: .subtask,
            partDescription: "Inspect the workspace",
            agent: AnyCodable(["id": "explore"])
        )
        let completed = OCPart(
            id: "subagent-part",
            sessionID: "session-1",
            messageID: messageID,
            type: .subtask,
            cost: 0.01,
            partDescription: "Inspect the workspace",
            agent: AnyCodable(["id": "explore"])
        )

        handler.handleInboundEvent(
            .partUpdated(part: running, textChunks: nil, questionPayload: nil, rawEvent: nil)
        )
        handler.handleInboundEvent(
            .partUpdated(part: completed, textChunks: nil, questionPayload: nil, rawEvent: nil)
        )

        #expect(delegate.layoutChangeCount == 1)
        #expect(delegate.contentChangeCount == 1)
    }

    @MainActor
    @Test func timelineAnimatesOnlyTheNewestActiveSubagent() {
        let earlier = ChatMessage(
            id: "earlier-message",
            role: .assistant,
            content: "",
            parts: [
                OCPart(
                    id: "earlier-subagent",
                    sessionID: "session-1",
                    messageID: "earlier-message",
                    type: .subtask,
                    partDescription: "Inspect the first task",
                    agent: AnyCodable(["id": "explore"])
                )
            ],
            isStreaming: true
        )
        let latest = ChatMessage(
            id: "latest-message",
            role: .assistant,
            content: "",
            parts: [
                OCPart(
                    id: "latest-subagent",
                    sessionID: "session-1",
                    messageID: "latest-message",
                    type: .subtask,
                    partDescription: "Inspect the latest task",
                    agent: AnyCodable(["id": "explore"])
                )
            ],
            isStreaming: true
        )

        let animatedIDs = ChatTimeline.items(
            from: [earlier, latest],
            showsThinking: true
        ).compactMap { item -> String? in
            guard item.animatesSubagentStatus,
                  case .assistantSegment(_, let segment) = item.content else {
                return nil
            }
            return segment.id
        }

        #expect(animatedIDs == ["latest-subagent"])
    }

    @MainActor
    @Test func boundedRenderMailboxReleasesChunksBeforeFinalization() async {
        let client = ChatClient(demoMode: true)
        let message = ChatMessage(
            id: "assistant-message",
            role: .assistant,
            content: "",
            isStreaming: true
        )
        client.pendingAssistantMessage = message

        let chunks = (0..<200).map { "chunk-\($0) " }
        client.appendStreamingText(
            messageID: message.id,
            text: "",
            chunks: chunks
        )

        #expect(client.bufferedStreamingMetricsForTesting.records == 1)
        #expect(client.bufferedStreamingMetricsForTesting.chunks == 200)
        #expect(client.bufferedStreamingMetricsForTesting.isBackpressured)

        await waitForMainQueue(milliseconds: 80)
        #expect(client.bufferedStreamingMetricsForTesting.records == 1)
        #expect(client.bufferedStreamingMetricsForTesting.chunks < 200)

        client.finishLoading()
        #expect(client.bufferedStreamingMetricsForTesting.records == 0)
        #expect(client.bufferedStreamingMetricsForTesting.chunks == 0)
        #expect(!client.bufferedStreamingMetricsForTesting.isBackpressured)

        await waitForMainQueue(milliseconds: 120)
        #expect(client.messages.last?.content == chunks.joined())
    }

    @MainActor
    @Test func finishKeepsDrainingASecondaryStreamingMailbox() async {
        let client = ChatClient(demoMode: true)
        let olderMessage = makeSecondaryStreamingMessage(id: "older-assistant")
        let pendingMessage = ChatMessage(
            id: "current-assistant",
            role: .assistant,
            content: "",
            isStreaming: true
        )
        client.messages = [olderMessage]
        client.pendingAssistantMessage = pendingMessage

        let chunks = enqueueSecondaryReasoningBurst(on: client, message: olderMessage)
        #expect(client.bufferedStreamingMetricsForTesting.isBackpressured)

        client.finishLoading()
        await waitForRenderMailboxToDrain(client)

        #expect(client.bufferedStreamingMetricsForTesting.records == 0)
        #expect(client.bufferedStreamingMetricsForTesting.chunks == 0)
        #expect(!client.bufferedStreamingMetricsForTesting.isBackpressured)
        #expect(olderMessage.assistantSegment(withID: "older-reasoning")?.streamingText?.copyText() == chunks.joined())
    }

    @MainActor
    @Test func localStopKeepsDrainingASecondaryStreamingMailbox() async {
        let client = ChatClient(demoMode: true)
        client.responseState = .generating
        client.isLoading = true
        let olderMessage = makeSecondaryStreamingMessage(id: "older-assistant")
        let pendingMessage = ChatMessage(
            id: "current-assistant",
            role: .assistant,
            content: "",
            isStreaming: true
        )
        client.messages = [olderMessage]
        client.pendingAssistantMessage = pendingMessage

        let chunks = enqueueSecondaryReasoningBurst(on: client, message: olderMessage)
        #expect(client.bufferedStreamingMetricsForTesting.isBackpressured)

        client.abort()
        await waitForRenderMailboxToDrain(client)

        #expect(client.bufferedStreamingMetricsForTesting.records == 0)
        #expect(client.bufferedStreamingMetricsForTesting.chunks == 0)
        #expect(!client.bufferedStreamingMetricsForTesting.isBackpressured)
        #expect(olderMessage.assistantSegment(withID: "older-reasoning")?.streamingText?.copyText() == chunks.joined())
    }

    @MainActor
    private func makeSecondaryStreamingMessage(id: String) -> ChatMessage {
        ChatMessage(
            id: id,
            role: .assistant,
            content: "",
            parts: [
                OCPart(
                    id: "older-reasoning",
                    sessionID: "session-1",
                    messageID: id,
                    type: .reasoning,
                    text: ""
                )
            ],
            isStreaming: true
        )
    }

    @MainActor
    private func enqueueSecondaryReasoningBurst(on client: ChatClient, message: ChatMessage) -> [String] {
        let chunks = (0..<48).map { "secondary-\($0) " }
        for chunk in chunks {
            client.appendStreamingReasoning(
                messageID: message.id,
                partID: "older-reasoning",
                text: chunk,
                chunks: [chunk]
            )
        }
        return chunks
    }

    @MainActor
    private func waitForRenderMailboxToDrain(_ client: ChatClient) async {
        for _ in 0..<40 where client.bufferedStreamingMetricsForTesting.records > 0 {
            await waitForMainQueue(milliseconds: 20)
        }
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

    private func taskPart(
        status: OCToolStatus,
        messageID: String = "assistant-message"
    ) -> OCPart {
        OCPart(
            id: "task-part",
            sessionID: "session-1",
            messageID: messageID,
            type: .tool,
            callID: "task-call",
            tool: "task",
            state: OCToolState(
                status: status,
                input: AnyCodable([
                    "subagent_type": "explore",
                    "description": "Inspect the workspace"
                ])
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
    var hiddenTodoCount: Int = 0
    var appendedStreamingTexts: [String] = []
    var clearedStreamingBuffers: [String] = []
    var layoutChangeCount = 0
    var contentChangeCount = 0

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

    func appendStreamingText(messageID: String, text: String, chunks: [String]) {
        appendedStreamingTexts.append(text)
    }

    func appendStreamingReasoning(messageID: String, partID: String, text: String, chunks: [String]) {
        guard let message = pendingAssistantMessage, message.id == messageID else { return }
        message.appendStreamingReasoning(partID: partID, text: text, chunks: chunks)
    }

    func clearStreamingBuffer(messageID: String) {
        clearedStreamingBuffers.append(messageID)
    }

    func messageLayoutDidChange() {
        layoutChangeCount += 1
    }

    func streamingContentDidChange() {
        contentChangeCount += 1
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
