import Testing
@testable import OpenLens

struct PreparedQuestionToolPayloadTests {
    @Test func preparesAndBoundsNestedQuestionToolStateBeforeMainDelivery() {
        let oversized = String(repeating: "nested server payload ", count: 350)
        let options: [[String: Any]] = (0..<(
            PreparedQuestionToolPayload.maximumOptionCount + 6
        )).map { index in
            [
                "label": "Option \(index): \(oversized)",
                "description": oversized,
            ]
        }
        let questions: [[String: Any]] = (0..<(
            PreparedQuestionToolPayload.maximumQuestionCount + 5
        )).map { index in
            [
                "header": "Header \(index): \(oversized)",
                "question": "Question \(index): \(oversized)",
                "options": options,
                "multiple": index.isMultiple(of: 2),
                "custom": true,
            ]
        }
        let answers: [[String]] = (0..<(
            PreparedQuestionToolPayload.maximumAnswerRowCount + 5
        )).map { row in
            (0..<(PreparedQuestionToolPayload.maximumAnswersPerRow + 6)).map { column in
                "Answer \(row)-\(column): \(oversized)"
            }
        }

        // This branch should never be walked by the projection; it verifies
        // that irrelevant nesting cannot increase its traversal budget.
        let ignoredNestedValue: Any = (0..<64).reduce(["leaf": oversized] as [String: Any]) {
            value, _ in ["nested": value]
        }
        let part: [String: Any] = [
            "id": "question-tool-part",
            "sessionID": "session-1",
            "messageID": "message-1",
            "type": "tool",
            "tool": "question",
            "metadata": ["retained": oversized],
            "state": [
                "status": "completed",
                "title": "Question title",
                "output": oversized,
                "error": oversized,
                "attachments": [["raw": oversized]],
                "input": [
                    "questions": questions,
                    "irrelevant": ignoredNestedValue,
                ],
                "metadata": [
                    "answers": answers,
                    "irrelevant": ignoredNestedValue,
                ],
            ],
        ]
        let event = OCEvent(
            type: "message.part.updated",
            properties: AnyCodable(["part": part])
        )

        guard case .partUpdated(let projectedPart, _, let payload, _) = SSEInboundEvent.prepare(event),
              let payload
        else {
            Issue.record("Expected worker-prepared question tool payload")
            return
        }

        #expect(projectedPart.id == "question-tool-part")
        #expect(projectedPart.tool == "question")
        #expect(projectedPart.state?.status == .completed)
        #expect(projectedPart.state?.title == "Question title")
        #expect(projectedPart.state?.input == nil)
        #expect(projectedPart.state?.metadata == nil)
        #expect(projectedPart.state?.output == nil)
        #expect(projectedPart.state?.error == nil)
        #expect(projectedPart.state?.attachments == nil)
        #expect(projectedPart.metadata == nil)
        #expect(payload.questions.count == PreparedQuestionToolPayload.maximumQuestionCount)
        #expect(payload.answers.count == PreparedQuestionToolPayload.maximumAnswerRowCount)
        #expect(payload.questions.allSatisfy {
            $0.header.utf8.count <= PreparedQuestionToolPayload.maximumHeaderBytes
                && $0.question.utf8.count <= PreparedQuestionToolPayload.maximumQuestionBytes
                && $0.options.count == PreparedQuestionToolPayload.maximumOptionCount
                && $0.options.allSatisfy {
                    $0.label.utf8.count <= PreparedQuestionToolPayload.maximumOptionLabelBytes
                        && $0.description.utf8.count <= PreparedQuestionToolPayload.maximumOptionDescriptionBytes
                }
        })
        #expect(payload.answers.allSatisfy {
            $0.count == PreparedQuestionToolPayload.maximumAnswersPerRow
                && $0.allSatisfy {
                    $0.utf8.count <= PreparedQuestionToolPayload.maximumAnswerBytes
                }
        })
    }

    @MainActor
    @Test func retainsWorkerPreparedQuestionPayloadThroughFinalTranscriptRebuild() {
        let rawQuestionCount = PreparedQuestionToolPayload.maximumQuestionCount + 3
        let rawQuestions: [[String: Any]] = (0..<rawQuestionCount).map { index in
            [
                "header": "Header \(index)",
                "question": "Question \(index)",
                "options": [["label": "Option \(index)", "description": "Detail \(index)"]],
            ]
        }
        let part = OCPart(
            id: "question-part",
            sessionID: "session-1",
            messageID: "message-1",
            type: .tool,
            tool: "question",
            state: OCToolState(
                status: .completed,
                input: AnyCodable(["questions": rawQuestions]),
                metadata: ["answers": AnyCodable([["Option 0"]])]
            )
        )
        guard let payload = PreparedQuestionToolPayload.prepare(from: part) else {
            Issue.record("Expected a question payload")
            return
        }
        let message = ChatMessage(
            id: "message-1",
            role: .assistant,
            content: "",
            isStreaming: true
        )

        _ = message.applyPartUpdate(part, questionPayload: payload)

        guard case .question(let streamingStep)? = message.assistantSegments.first?.kind else {
            Issue.record("Expected the prepared question transcript")
            return
        }
        #expect(streamingStep.questions.count == PreparedQuestionToolPayload.maximumQuestionCount)
        #expect(streamingStep.questions.first?.question == "Question 0")
        #expect(streamingStep.answers == [["Option 0"]])

        message.isStreaming = false

        guard case .question(let finalStep)? = message.assistantSegments.first?.kind else {
            Issue.record("Expected the prepared transcript after completion")
            return
        }
        // A fallback parse of the raw input would restore all rawQuestionCount
        // rows. Keeping this bounded result proves completion uses the worker
        // projection instead of reparsing dynamic JSON on MainActor.
        #expect(finalStep.questions.count == PreparedQuestionToolPayload.maximumQuestionCount)
        #expect(finalStep.questions.first?.question == "Question 0")
        #expect(finalStep.answers == [["Option 0"]])
    }
}
