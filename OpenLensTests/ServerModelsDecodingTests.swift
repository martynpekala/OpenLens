import Foundation
import Testing
@testable import OpenLens

struct ServerModelsDecodingTests {

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
}