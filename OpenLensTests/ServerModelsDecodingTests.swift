import Foundation
import Testing
@testable import OpenLens

struct ServerModelsDecodingTests {

    @Test func ocPartTypeRemainsAlignedWithKnownUpstreamCases() {
        #expect(OCPartType(rawValue: "text") == .text)
        #expect(OCPartType(rawValue: "reasoning") == .reasoning)
        #expect(OCPartType(rawValue: "tool") == .tool)
        #expect(OCPartType(rawValue: "file") == .file)
        #expect(OCPartType(rawValue: "step-start") == .stepStart)
        #expect(OCPartType(rawValue: "step-finish") == .stepFinish)
        #expect(OCPartType(rawValue: "snapshot") == .snapshot)
        #expect(OCPartType(rawValue: "patch") == .patch)
        #expect(OCPartType(rawValue: "retry") == .retry)
        #expect(OCPartType(rawValue: "compaction") == .compaction)
        #expect(OCPartType(rawValue: "agent") == .agent)
        #expect(OCPartType(rawValue: "subtask") == .subtask)
        #expect(OCPartType(rawValue: "missing-case") == nil)
    }

    @Test func decodesProviderModelCapabilitiesFromNestedOpenCodePayload() throws {
        let data = Data(
            #"""
            {
              "id": "claude-sonnet-4.6",
              "name": "Claude Sonnet 4.6",
              "capabilities": {
                "temperature": true,
                "reasoning": true,
                "attachment": true,
                "toolcall": true
              },
              "variants": {
                "high": {
                  "reasoningEffort": "high"
                }
              }
            }
            """#.utf8
        )

        let model = try JSONDecoder().decode(OCProviderModel.self, from: data)

        #expect(model.id == "claude-sonnet-4.6")
        #expect(model.temperature == true)
        #expect(model.reasoning == true)
        #expect(model.attachment == true)
        #expect(model.toolCall == true)
        #expect(model.variants?["high"]?.reasoningEffort == "high")
    }

    @Test func providerModelTopLevelCapabilitiesOverrideNestedFallbacks() throws {
        let data = Data(
            #"""
            {
              "id": "gpt-4.1",
              "name": "GPT-4.1",
              "attachment": false,
              "reasoning": false,
              "tool_call": false,
              "capabilities": {
                "attachment": true,
                "reasoning": true,
                "toolcall": true
              }
            }
            """#.utf8
        )

        let model = try JSONDecoder().decode(OCProviderModel.self, from: data)

        #expect(model.attachment == false)
        #expect(model.reasoning == false)
        #expect(model.toolCall == false)
    }

    @Test func decodesCurrentPermissionPayload() throws {
        let data = Data(
            #"""
            {
              "id": "permission_123",
              "sessionID": "session_456",
              "permission": "bash",
              "patterns": ["ls", "pwd"],
              "metadata": {
                "cmd": "ls",
                "cwd": "/workspace"
              },
              "always": ["ls *"],
              "tool": {
                "messageID": "message_1",
                "callID": "call_1"
              }
            }
            """#.utf8
        )

        let permission = try JSONDecoder().decode(OCPermissionRequest.self, from: data)

        #expect(permission.id == "permission_123")
        #expect(permission.sessionID == "session_456")
        #expect(permission.permission == "bash")
        #expect(permission.patterns == ["ls", "pwd"])
        #expect(permission.always == ["ls *"])
        #expect(permission.toolRef?.messageID == "message_1")
        #expect(permission.toolRef?.callID == "call_1")
        #expect(permission.toolDisplayName == "bash")
        #expect(permission.description == "ls")
        #expect(permission.metadata?["cmd"]?.value as? String == "ls")
        #expect(permission.metadata?["cwd"]?.value as? String == "/workspace")
    }

    @Test func decodesCurrentQuestionPayload() throws {
        let data = Data(
            #"""
            {
              "id": "question_123",
              "sessionID": "session_456",
              "questions": [
                {
                  "question": "What would you like to do?",
                  "header": "Action",
                  "options": [
                    {
                      "label": "Option 1",
                      "description": "First option"
                    },
                    {
                      "label": "Option 2",
                      "description": "Second option"
                    }
                  ]
                }
              ],
              "tool": {
                "messageID": "message_1",
                "callID": "call_1"
              }
            }
            """#.utf8
        )

        let request = try JSONDecoder().decode(OCQuestionRequest.self, from: data)

        #expect(request.id == "question_123")
        #expect(request.sessionID == "session_456")
        #expect(request.tool?.messageID == "message_1")
        #expect(request.tool?.callID == "call_1")
        #expect(request.questions.count == 1)

        let question = try #require(request.questions.first)
        #expect(question.header == "Action")
        #expect(question.question == "What would you like to do?")
        #expect(question.multiple == false)
        #expect(question.custom == true)
        #expect(question.options.count == 2)
        #expect(question.options[0].label == "Option 1")
        #expect(question.options[0].description == "First option")
    }

    @Test func extractsReplaySessionIDsFromNestedEventPayloads() {
        let messageUpdated = OCEvent(
            type: "message.updated",
            properties: AnyCodable([
                "info": [
                    "id": "message_1",
                    "role": "assistant",
                    "sessionID": "session_456"
                ]
            ])
        )
        let partUpdated = OCEvent(
            type: "message.part.updated",
            properties: AnyCodable([
                "part": [
                    "id": "part_1",
                    "messageID": "message_1",
                    "sessionID": "session_789",
                    "type": "text",
                    "text": "Hello"
                ]
            ])
        )
        let sessionUpdated = OCEvent(
            type: "session.updated",
            properties: AnyCodable([
                "info": [
                    "id": "session_999",
                    "title": "Updated Session"
                ]
            ])
        )

        #expect(messageUpdated.sessionID == "session_456")
        #expect(partUpdated.sessionID == "session_789")
        #expect(sessionUpdated.sessionID == "session_999")
    }

    @Test func flagsReplayNoiseEventsAndDecodesSessionStatusType() {
        let heartbeat = OCEvent(
            type: "server.heartbeat",
            properties: AnyCodable(["sessionID": "session_456"])
        )
        let sessionStatus = OCEvent(
            type: "session.status",
            properties: AnyCodable([
                "sessionID": "session_456",
                "status": ["type": "busy"]
            ])
        )

        #expect(!heartbeat.isReplayRecordable)
        #expect(sessionStatus.isReplayRecordable)
        #expect(sessionStatus.sessionStatusType == .busy)
    }

    @Test func decodesExtendedTextPartFields() throws {
        let part = try decodePart(
            #"""
            {
              "id": "part_text",
              "sessionID": "session_1",
              "messageID": "message_1",
              "type": "text",
              "text": "hello",
              "synthetic": true,
              "ignored": false,
              "metadata": {
                "lang": "md"
              },
              "time": {
                "start": 1,
                "end": 2
              }
            }
            """#
        )

        #expect(part.type == .text)
        #expect(part.text == "hello")
        #expect(part.synthetic == true)
        #expect(part.ignored == false)
        #expect(part.metadata?["lang"]?.value as? String == "md")
        #expect((part.time?.value as? [String: Any])?["start"] as? Int == 1)
        #expect(part.renderableText == nil)
    }

    @Test func decodesReasoningPartMetadataAndTime() throws {
        let part = try decodePart(
            #"""
            {
              "id": "part_reasoning",
              "sessionID": "session_1",
              "messageID": "message_1",
              "type": "reasoning",
              "text": "thinking",
              "metadata": {
                "effort": "high"
              },
              "time": 123
            }
            """#
        )

        #expect(part.type == .reasoning)
        #expect(part.text == "thinking")
        #expect(part.metadata?["effort"]?.value as? String == "high")
        #expect(part.time?.value as? Int == 123)
    }

    @Test func decodesFilePartSource() throws {
        let part = try decodePart(
            #"""
            {
              "id": "part_file",
              "sessionID": "session_1",
              "messageID": "message_1",
              "type": "file",
              "mime": "text/plain",
              "filename": "README.md",
              "url": "https://example.test/readme",
              "source": {
                "path": "README.md"
              }
            }
            """#
        )

        #expect(part.type == .file)
        #expect(part.filename == "README.md")
        #expect((part.source?.value as? [String: Any])?["path"] as? String == "README.md")
    }

    @Test func decodesToolPartAttachments() throws {
        let part = try decodePart(
            #"""
            {
              "id": "part_tool",
              "sessionID": "session_1",
              "messageID": "message_1",
              "type": "tool",
              "callID": "call_1",
              "tool": "bash",
              "state": {
                "status": "completed",
                "title": "Ran ls",
                "output": "ok",
                "attachments": [
                  {
                    "name": "out.txt"
                  }
                ]
              }
            }
            """#
        )

        #expect(part.type == .tool)
        #expect(part.tool == "bash")
        #expect(part.state?.status == .completed)
        #expect(part.state?.attachments?.count == 1)
        #expect((part.state?.attachments?.first?.value as? [String: Any])?["name"] as? String == "out.txt")
    }

    @Test func decodesStepStartSnapshot() throws {
        let part = try decodePart(
            #"""
            {
              "id": "part_step_start",
              "sessionID": "session_1",
              "messageID": "message_1",
              "type": "step-start",
              "snapshot": {
                "cwd": "/tmp/project"
              }
            }
            """#
        )

        #expect(part.type == .stepStart)
        #expect((part.snapshot?.value as? [String: Any])?["cwd"] as? String == "/tmp/project")
    }

    @Test func decodesStepFinishSnapshot() throws {
        let part = try decodePart(
            #"""
            {
              "id": "part_step_finish",
              "sessionID": "session_1",
              "messageID": "message_1",
              "type": "step-finish",
              "snapshot": {
                "status": "done"
              }
            }
            """#
        )

        #expect(part.type == .stepFinish)
        #expect((part.snapshot?.value as? [String: Any])?["status"] as? String == "done")
    }

    @Test func decodesSnapshotPartSnapshotPayload() throws {
        let part = try decodePart(
            #"""
            {
              "id": "part_snapshot",
              "sessionID": "session_1",
              "messageID": "message_1",
              "type": "snapshot",
              "snapshot": {
                "files": 3
              }
            }
            """#
        )

        #expect(part.type == .snapshot)
        #expect((part.snapshot?.value as? [String: Any])?["files"] as? Int == 3)
    }

    @Test func decodesPatchPartFields() throws {
        let part = try decodePart(
            #"""
            {
              "id": "part_patch",
              "sessionID": "session_1",
              "messageID": "message_1",
              "type": "patch",
              "hash": "abc123",
              "files": [
                {
                  "path": "Sources/App.swift"
                }
              ]
            }
            """#
        )

        #expect(part.type == .patch)
        #expect(part.hash == "abc123")
        #expect(part.files?.count == 1)
        #expect((part.files?.first?.value as? [String: Any])?["path"] as? String == "Sources/App.swift")
    }

    @Test func decodesAgentPartFields() throws {
        let part = try decodePart(
            #"""
            {
              "id": "part_agent",
              "sessionID": "session_1",
              "messageID": "message_1",
              "type": "agent",
              "name": "reviewer",
              "source": "planner"
            }
            """#
        )

        #expect(part.type == .agent)
        #expect(part.name == "reviewer")
        #expect(part.source?.value as? String == "planner")
    }

    @Test func decodesSubtaskPartFields() throws {
        let part = try decodePart(
            #"""
            {
              "id": "part_subtask",
              "sessionID": "session_1",
              "messageID": "message_1",
              "type": "subtask",
              "prompt": "Check tests",
              "description": "Run the failing suite",
              "agent": {
                "id": "tester"
              }
            }
            """#
        )

        #expect(part.type == .subtask)
        #expect(part.prompt == "Check tests")
        #expect(part.partDescription == "Run the failing suite")
        #expect((part.agent?.value as? [String: Any])?["id"] as? String == "tester")
    }

    @Test func decodesRetryPartFields() throws {
        let part = try decodePart(
            #"""
            {
              "id": "part_retry",
              "sessionID": "session_1",
              "messageID": "message_1",
              "type": "retry",
              "attempt": 2,
              "error": "rate limited",
              "time": {
                "next": 123
              }
            }
            """#
        )

        #expect(part.type == .retry)
        #expect(part.attempt == 2)
        #expect(part.retryError == "rate limited")
        #expect((part.time?.value as? [String: Any])?["next"] as? Int == 123)
    }

    @Test func decodesCompactionPartFields() throws {
        let part = try decodePart(
            #"""
            {
              "id": "part_compaction",
              "sessionID": "session_1",
              "messageID": "message_1",
              "type": "compaction",
              "auto": true
            }
            """#
        )

        #expect(part.type == .compaction)
        #expect(part.auto == true)
    }

    @Test func decodesUnknownPartTypeAsUnknown() throws {
        let part = try decodePart(
            #"""
            {
              "id": "part_unknown",
              "sessionID": "session_1",
              "messageID": "message_1",
              "type": "future-type"
            }
            """#
        )

        #expect(part.type == .unknown)
    }

    private func decodePart(_ json: String) throws -> OCPart {
        try JSONDecoder().decode(OCPart.self, from: Data(json.utf8))
    }
}
