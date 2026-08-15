import Testing
@testable import OpenLens

struct StreamToolPartSafetyTests {

    @Test func boundsGenericToolPayloadBeforeItCanReachChatState() {
        let oversized = String(repeating: "payload ", count: 1_000)
        let part = OCPart(
            id: "tool-part",
            sessionID: "session",
            messageID: "message",
            type: .tool,
            metadata: ["unrelated": AnyCodable(oversized)],
            time: AnyCodable(["untrusted": oversized]),
            callID: oversized,
            tool: oversized,
            state: OCToolState(
                status: .running,
                input: AnyCodable([
                    "path": oversized,
                    "command": oversized,
                    "nested": ["untrusted": oversized]
                ]),
                output: oversized,
                title: oversized,
                error: oversized,
                metadata: [
                    "sessionID": AnyCodable("child-session"),
                    "unrelated": AnyCodable(oversized)
                ],
                attachments: [AnyCodable(oversized)]
            ),
            source: AnyCodable(oversized),
            files: [AnyCodable(oversized)],
            name: oversized,
            prompt: oversized,
            partDescription: oversized,
            agent: AnyCodable(["name": oversized, "unrelated": oversized]),
            retryError: oversized
        )

        let safe = StreamToolPartSafety.sanitize(part)

        #expect(safe.callID == nil)
        #expect(safe.metadata == nil)
        #expect(safe.time == nil)
        #expect(safe.source == nil)
        #expect(safe.files == nil)
        #expect(safe.retryError == nil)
        #expect(safe.state?.attachments == nil)
        #expect(safe.state?.output?.utf8.count ?? 0 <= StreamToolPartSafety.maximumOutputBytes + 3)
        #expect(safe.state?.title?.utf8.count ?? 0 <= StreamToolPartSafety.maximumTitleBytes + 3)
        #expect((safe.state?.input?.value as? [String: Any])?["nested"] == nil)
        #expect((safe.state?.metadata?["unrelated"]?.value) == nil)
        #expect((safe.state?.metadata?["sessionID"]?.value as? String) == "child-session")
    }

    @Test func boundsAgentAndSubtaskPayloadBeforeMainDelivery() {
        let oversized = String(repeating: "subagent payload ", count: 1_000)

        for type in ["agent", "subtask"] {
            let event = OCEvent(
                type: "message.part.updated",
                properties: AnyCodable([
                    "part": [
                        "id": "\(type)-part",
                        "sessionID": "session",
                        "messageID": "message",
                        "type": type,
                        "metadata": ["untrusted": oversized],
                        "time": ["end": 1, "untrusted": oversized],
                        "source": oversized,
                        "snapshot": ["untrusted": oversized],
                        "files": [oversized],
                        "name": oversized,
                        "prompt": oversized,
                        "description": oversized,
                        "agent": ["name": oversized, "untrusted": oversized],
                        "error": oversized,
                        "state": [
                            "status": "running",
                            "input": ["description": oversized, "untrusted": oversized],
                            "output": oversized,
                            "attachments": [oversized]
                        ]
                    ]
                ])
            )

            guard case let .partUpdated(safe, _, _, _) = SSEInboundEvent.prepare(
                event,
                retainingRawEvent: false
            ) else {
                Issue.record("Expected prepared \(type) part")
                return
            }

            #expect(safe.type.rawValue == type)
            #expect(safe.metadata == nil)
            #expect(safe.snapshot == nil)
            #expect(safe.files == nil)
            #expect(safe.retryError == nil)
            #expect(safe.state?.attachments == nil)
            let completionTime = safe.time?.value as? [String: Any]
            #expect(completionTime?["end"] as? Bool == true)
            #expect(completionTime?["untrusted"] == nil)
            let source = safe.source?.value as? String
            #expect(source != oversized)
            #expect((source?.utf8.count ?? 0) <= StreamToolPartSafety.maximumDetailBytes + 3)
            #expect((safe.agent?.value as? [String: Any])?["untrusted"] == nil)
            #expect((safe.state?.input?.value as? [String: Any])?["untrusted"] == nil)
        }
    }
}
