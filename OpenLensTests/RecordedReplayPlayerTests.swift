import Foundation
import Testing
@testable import OpenLens

struct RecordedReplayPlayerTests {

    @MainActor
    @Test func recordedReplayPreviewRebuildsTheFinalAssistantMessage() async {
        let replay = RecordedChatReplay(
            sessionID: "session-preview-test",
            sessionTitle: "Recorded Preview",
            projectName: "OpenLens",
            branch: "main",
            createdAt: Date(timeIntervalSince1970: 1_730_200_000),
            events: [
                .init(id: 0, offset: 0, event: sessionStatusEvent(sessionID: "session-preview-test", status: .busy)),
                .init(id: 1, offset: 0, event: messageUpdatedEvent(sessionID: "session-preview-test", messageID: "assistant-message")),
                .init(id: 2, offset: 0, event: textPartUpdatedEvent(sessionID: "session-preview-test", messageID: "assistant-message", text: "Hello from replay")),
                .init(id: 3, offset: 0, event: sessionStatusEvent(sessionID: "session-preview-test", status: .idle))
            ]
        )

        let client = ChatClient(recordedReplay: replay, playbackMode: .fast)

        await client.ensureSession()
        await waitForMainQueue(milliseconds: 80)

        #expect(client.currentSession?.title == "Recorded Preview")
        #expect(client.messages.count == 1)
        #expect(client.messages.first?.role == .assistant)
        #expect(client.messages.first?.content == "Hello from replay")
        #expect(client.pendingAssistantMessage == nil)
        #expect(client.isLoading == false)
    }

    private func sessionStatusEvent(sessionID: String, status: OCSessionStatusType) -> OCEvent {
        OCEvent(
            type: "session.status",
            properties: AnyCodable([
                "sessionID": sessionID,
                "status": ["type": status.rawValue]
            ])
        )
    }

    private func messageUpdatedEvent(sessionID: String, messageID: String) -> OCEvent {
        OCEvent(
            type: "message.updated",
            properties: AnyCodable([
                "info": [
                    "id": messageID,
                    "role": "assistant",
                    "sessionID": sessionID
                ]
            ])
        )
    }

    private func textPartUpdatedEvent(sessionID: String, messageID: String, text: String) -> OCEvent {
        OCEvent(
            type: "message.part.updated",
            properties: AnyCodable([
                "part": [
                    "id": "part-\(messageID)",
                    "sessionID": sessionID,
                    "messageID": messageID,
                    "type": "text",
                    "text": text
                ]
            ])
        )
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
