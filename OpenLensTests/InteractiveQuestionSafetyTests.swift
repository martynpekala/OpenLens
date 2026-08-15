import Testing
@testable import OpenLens

struct InteractiveQuestionSafetyTests {

    @Test func acceptsACompactQuestionWithoutChangingReplyTokens() {
        let request = OCQuestionRequest(
            id: "request",
            sessionID: "session",
            questions: [
                OCQuestionInfo(
                    question: "Proceed?",
                    header: "Confirmation",
                    options: [
                        OCQuestionOption(label: "Ship the release", description: "Deploy the current build"),
                    ]
                ),
            ]
        )

        #expect(InteractiveQuestionSafety.accepts(request))
        #expect(request.questions[0].options[0].label == "Ship the release")
    }

    @Test func rejectsQuestionWithTooManyOptionsInsteadOfTruncatingReplyTokens() {
        let request = OCQuestionRequest(
            id: "request",
            sessionID: "session",
            questions: [
                OCQuestionInfo(
                    question: "Choose one",
                    header: "Question",
                    options: (0..<(InteractiveQuestionSafety.maximumOptionsPerQuestion + 1)).map {
                        OCQuestionOption(label: "option-\($0)", description: "")
                    }
                ),
            ]
        )

        #expect(!InteractiveQuestionSafety.accepts(request))
    }

    @Test func rejectsLargeDisplayTextBeforeTheSheetCanBuildIt() {
        let request = OCQuestionRequest(
            id: "request",
            sessionID: "session",
            questions: [
                OCQuestionInfo(
                    question: String(repeating: "x", count: InteractiveQuestionSafety.maximumQuestionBytes + 1),
                    header: "Question",
                    options: []
                ),
            ]
        )

        #expect(!InteractiveQuestionSafety.accepts(request))
    }
}
