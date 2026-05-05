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
        #expect(ChatScrollPolicy.isNearBottom(bottomMarkerMinY: 640, viewportHeight: 600, threshold: 48))
        #expect(!ChatScrollPolicy.isNearBottom(bottomMarkerMinY: 700, viewportHeight: 600, threshold: 48))

        #expect(ChatScrollPolicy.shouldShowScrollToLatest(
            followLatest: false,
            bottomMarkerMinY: 680,
            viewportHeight: 600,
            visibilityThreshold: 56
        ))
        #expect(!ChatScrollPolicy.shouldShowScrollToLatest(
            followLatest: true,
            bottomMarkerMinY: 680,
            viewportHeight: 600,
            visibilityThreshold: 56
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
    private func waitForMainQueue(milliseconds: Int) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(milliseconds)) {
                continuation.resume()
            }
        }
    }
}
