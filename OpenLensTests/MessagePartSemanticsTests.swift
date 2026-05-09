import Foundation
import Testing
@testable import OpenLens

struct MessagePartSemanticsTests {

    @Test func messagesServiceSkipsSyntheticAndIgnoredTextWhenBuildingContent() {
        let service = MessagesService(connection: ConnectionManager())
        let message = OCMessageWithParts(
            info: makeInfo(),
            parts: [
                OCPart(id: "synthetic", sessionID: "session", messageID: "message", type: .text, text: "hidden", synthetic: true),
                OCPart(id: "ignored", sessionID: "session", messageID: "message", type: .text, text: "ignored", ignored: true),
                OCPart(id: "visible", sessionID: "session", messageID: "message", type: .text, text: "shown")
            ]
        )

        let chatMessage = service.convertToChatMessage(message)

        #expect(chatMessage.content == "shown")
    }

    @Test func assistantSegmentsSkipSyntheticAndIgnoredText() {
        let message = ChatMessage(
            id: "message",
            role: .assistant,
            content: "",
            parts: [
                OCPart(id: "synthetic", sessionID: "session", messageID: "message", type: .text, text: "hidden", synthetic: true),
                OCPart(id: "ignored", sessionID: "session", messageID: "message", type: .text, text: "ignored", ignored: true),
                OCPart(id: "visible", sessionID: "session", messageID: "message", type: .text, text: "shown")
            ],
            isStreaming: false
        )

        #expect(message.hasRenderableTextPart)
        #expect(message.assistantSegments.count == 1)

        let segment = try? #require(message.assistantSegments.first)
        switch segment?.kind {
        case .text(let text):
            #expect(text == "shown")
        default:
            Issue.record("Expected a single visible text segment")
        }
    }

    @Test func hiddenTextPartsDoNotTriggerFallbackTextSegment() {
        let message = ChatMessage(
            id: "message",
            role: .assistant,
            content: "",
            parts: [
                OCPart(id: "synthetic", sessionID: "session", messageID: "message", type: .text, text: "hidden", synthetic: true),
                OCPart(id: "ignored", sessionID: "session", messageID: "message", type: .text, text: "ignored", ignored: true)
            ],
            isStreaming: false
        )

        #expect(!message.hasRenderableTextPart)
        #expect(message.assistantSegments.isEmpty)
    }

    private func makeInfo() -> OCMessage {
        try! JSONDecoder().decode(
            OCMessage.self,
            from: Data(
                #"""
                {
                  "id": "message",
                  "sessionID": "session",
                  "role": "assistant",
                  "time": {
                    "created": 0
                  }
                }
                """#.utf8
            )
        )
    }
}
