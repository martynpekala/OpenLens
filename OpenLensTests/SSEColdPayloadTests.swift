import Testing
@testable import OpenLens

struct SSEColdPayloadTests {

    @Test func preparesBoundedQuestionForMainDelivery() {
        let event = OCEvent(
            type: "question.asked",
            properties: AnyCodable([
                "id": "question-request",
                "sessionID": "session",
                "questions": [
                    [
                        "header": "Confirmation",
                        "question": "Continue?",
                        "options": [["label": "Yes", "description": "Proceed"]],
                    ],
                ],
            ])
        )

        guard case .cold(.questionAsked(let prepared), _) = SSEInboundEvent.prepare(event),
              let prepared
        else {
            Issue.record("Expected prepared cold question")
            return
        }

        #expect(prepared.request?.id == "question-request")
        #expect(prepared.rejectedRequestID == nil)
    }

    @Test func turnsOversizedQuestionIntoAControlledRejection() {
        let options = (0..<(InteractiveQuestionSafety.maximumOptionsPerQuestion + 1)).map {
            ["label": "option-\($0)", "description": ""]
        }
        let event = OCEvent(
            type: "question.asked",
            properties: AnyCodable([
                "id": "question-request",
                "sessionID": "session",
                "questions": [[
                    "header": "Confirmation",
                    "question": "Continue?",
                    "options": options,
                ]],
            ])
        )

        guard case .cold(.questionAsked(let prepared), _) = SSEInboundEvent.prepare(event),
              let prepared
        else {
            Issue.record("Expected prepared cold question")
            return
        }

        #expect(prepared.request == nil)
        #expect(prepared.rejectedRequestID == "question-request")
    }

    @Test func boundsPermissionPayloadBeforeMainDelivery() {
        let oversized = String(repeating: "untrusted scope ", count: 200)
        let event = OCEvent(
            type: "permission.asked",
            properties: AnyCodable([
                "id": "permission-request",
                "sessionID": "session",
                "permission": oversized,
                "patterns": (0...PermissionRequestDisplaySafety.maximumScopeEntryCount).map {
                    "rule-\($0) \(oversized)"
                },
                "metadata": ["raw": oversized],
                "input": ["raw": oversized],
            ])
        )

        guard case .cold(.permissionAsked(let prepared), _) = SSEInboundEvent.prepare(event),
              let permission = prepared?.request
        else {
            Issue.record("Expected prepared cold permission")
            return
        }

        #expect(permission.patterns.count == PermissionRequestDisplaySafety.maximumScopeEntryCount)
        #expect(permission.displayScopeWasTruncated)
        #expect(permission.metadata == nil)
        #expect(permission.input == nil)
    }

    @Test func boundsSessionTitleAndStatusMessageBeforeMainDelivery() {
        let oversized = String(repeating: "x", count: 10_000)
        let sessionEvent = OCEvent(
            type: "session.updated",
            properties: AnyCodable([
                "info": [
                    "id": "session",
                    "title": oversized,
                ],
            ])
        )
        let statusEvent = OCEvent(
            type: "session.status",
            properties: AnyCodable([
                "sessionID": "session",
                "status": ["type": "busy", "message": oversized],
            ])
        )

        guard case .cold(.sessionUpdated(let sessionUpdate), _) = SSEInboundEvent.prepare(sessionEvent),
              let sessionUpdate,
              case .cold(.sessionStatus(let statusUpdate), _) = SSEInboundEvent.prepare(statusEvent),
              let statusUpdate
        else {
            Issue.record("Expected bounded cold session payloads")
            return
        }

        #expect(sessionUpdate.title?.utf8.count ?? 0 <= 512)
        #expect(sessionUpdate.update?.title.utf8.count ?? 0 <= 512)
        #expect(statusUpdate.status.message?.utf8.count ?? 0 <= 512)
    }

    @Test func boundsTodoPayloadBeforeMainDelivery() {
        let todos = (0..<(TodoDisplaySafety.maximumTodoCount + 3)).map { index in
            [
                "content": "task-\(index)-" + String(repeating: "x", count: 1_000),
                "status": "in_progress",
            ]
        }
        let event = OCEvent(
            type: "todo.updated",
            properties: AnyCodable([
                "sessionID": "session",
                "todos": todos,
            ])
        )

        guard case .cold(.todoUpdated(let prepared), _) = SSEInboundEvent.prepare(event),
              let prepared,
              let visibleTodos = prepared.todos
        else {
            Issue.record("Expected prepared cold todos")
            return
        }

        #expect(visibleTodos.count == TodoDisplaySafety.maximumTodoCount)
        #expect(prepared.hiddenTodoCount == 3)
        #expect(visibleTodos.allSatisfy {
            $0.content.utf8.count <= TodoDisplaySafety.maximumContentBytes
        })
    }
}
