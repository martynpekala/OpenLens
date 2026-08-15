import Foundation

/// Admission limits for server-driven interactive questions. The option labels
/// are reply tokens, so oversized prompts are rejected rather than silently
/// truncated before presentation.
nonisolated enum InteractiveQuestionSafety {
    static let maximumIdentifierBytes = 256
    static let maximumQuestionCount = 12
    static let maximumOptionsPerQuestion = 12
    static let maximumHeaderBytes = 320
    static let maximumQuestionBytes = 2_400
    static let maximumOptionLabelBytes = 600
    static let maximumOptionDescriptionBytes = 1_200

    static func accepts(_ request: OCQuestionRequest) -> Bool {
        guard fitsIdentifier(request.id),
              fitsIdentifier(request.sessionID),
              (1...maximumQuestionCount).contains(request.questions.count)
        else {
            return false
        }

        if let tool = request.tool,
           !fitsIdentifier(tool.messageID) || !fitsIdentifier(tool.callID) {
            return false
        }

        for question in request.questions {
            guard fits(question.header, maximumBytes: maximumHeaderBytes),
                  fits(question.question, maximumBytes: maximumQuestionBytes),
                  question.options.count <= maximumOptionsPerQuestion
            else {
                return false
            }

            for option in question.options {
                guard fits(option.label, maximumBytes: maximumOptionLabelBytes),
                      fits(option.description, maximumBytes: maximumOptionDescriptionBytes)
                else {
                    return false
                }
            }
        }

        return true
    }

    static func fitsIdentifier(_ value: String) -> Bool {
        fits(value, maximumBytes: maximumIdentifierBytes)
    }

    private static func fits(_ value: String, maximumBytes: Int) -> Bool {
        value.utf8.count <= maximumBytes
    }
}
