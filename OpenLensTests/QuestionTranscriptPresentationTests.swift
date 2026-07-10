import Testing
@testable import OpenLens

struct QuestionTranscriptPresentationTests {

    @Test func boundsNestedQuestionPayloadBeforeItReachesTheView() {
        let oversized = String(
            repeating: "untrusted question payload ",
            count: QuestionTranscriptPresentation.maximumQuestionLength
        )
        let options = (0..<(QuestionTranscriptPresentation.maximumOptionCount + 8)).map { index in
            OCQuestionOption(
                label: "Option \(index) \(oversized)",
                description: oversized
            )
        }
        let questions = (0..<(QuestionTranscriptPresentation.maximumQuestionCount + 6)).map { index in
            OCQuestionInfo(
                question: "Question \(index) \(oversized)",
                header: oversized,
                options: options
            )
        }
        let answers = questions.indices.map { _ in
            (0..<(QuestionTranscriptPresentation.maximumAnswerCount + 5)).map { index in
                "Custom answer \(index) \(oversized)"
            }
        }

        let prepared = QuestionTranscriptPresentation.prepare(
            QuestionTranscriptSource(
                id: "question-tool",
                status: .running,
                isError: false,
                questions: questions,
                answers: answers
            )
        )

        #expect(prepared.questions.count == QuestionTranscriptPresentation.maximumQuestionCount)
        #expect(prepared.hiddenQuestionCount == 6)
        #expect(prepared.hasAnswers)

        guard let first = prepared.questions.first else {
            Issue.record("Expected a bounded question preview")
            return
        }

        #expect(first.header?.count ?? 0 <= QuestionTranscriptPresentation.maximumHeaderLength + 1)
        #expect(first.text?.count ?? 0 <= QuestionTranscriptPresentation.maximumQuestionLength + 1)
        #expect(first.options.count == QuestionTranscriptPresentation.maximumOptionCount)
        #expect(first.customAnswers.count == QuestionTranscriptPresentation.maximumAnswerCount)
        #expect(first.hiddenOptionCount == 8)
        #expect(first.hiddenAnswerCount == 5)
        #expect(first.options.allSatisfy {
            $0.label.count <= QuestionTranscriptPresentation.maximumOptionLabelLength + 1
                && ($0.detail?.count ?? 0) <= QuestionTranscriptPresentation.maximumOptionDetailLength + 1
        })
        #expect(first.customAnswers.allSatisfy {
            $0.text.count <= QuestionTranscriptPresentation.maximumAnswerLength + 1
        })
    }

    @Test func marksSelectedOptionsAndKeepsOnlyCustomAnswerPreviews() {
        let source = QuestionTranscriptSource(
            id: "question-tool",
            status: .completed,
            isError: false,
            questions: [
                OCQuestionInfo(
                    question: "Which option?",
                    header: "Question",
                    options: [
                        OCQuestionOption(label: "Ship it", description: "Deploy now"),
                        OCQuestionOption(label: "Wait", description: "Review later"),
                    ]
                ),
            ],
            answers: [["Ship it", "Add a rollback note"]]
        )

        let prepared = QuestionTranscriptPresentation.prepare(source)

        guard let question = prepared.questions.first else {
            Issue.record("Expected a question preview")
            return
        }

        #expect(question.options.first?.isSelected == true)
        #expect(question.options.last?.isSelected == false)
        #expect(question.customAnswers.map(\.text) == ["Add a rollback note"])
    }
}
