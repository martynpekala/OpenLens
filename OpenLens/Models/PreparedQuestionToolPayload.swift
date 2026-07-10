import Foundation

/// A bounded, sendable projection of a `question` tool part.
///
/// The server's tool state is dynamic JSON. Parsing it in `ChatMessage` used
/// to make a streamed part update recursively copy that JSON and run a JSON
/// decoder on MainActor. This projection is built by the SSE/replay worker
/// instead. It intentionally keeps only the portion the transcript can show,
/// so the UI actor never needs to traverse arbitrary input or answer trees.
nonisolated struct PreparedQuestionToolPayload: Sendable {
    // Keep these aligned with the transcript's visible capacity. Byte limits
    // accommodate multi-byte scalars while still keeping the handoff small.
    static let maximumQuestionCount = 24
    static let maximumOptionCount = 12
    static let maximumAnswerRowCount = 24
    static let maximumAnswersPerRow = 12
    static let maximumHeaderBytes = 480
    static let maximumQuestionBytes = 1_440
    static let maximumOptionLabelBytes = 480
    static let maximumOptionDescriptionBytes = 720
    static let maximumAnswerBytes = 720
    static let maximumToolTitleBytes = 512

    let questions: [OCQuestionInfo]
    let answers: [[String]]

    /// Returns `nil` for every non-question part. A question part always gets
    /// a payload, including an empty one for a malformed/missing state, so the
    /// receiving `ChatMessage` never falls back to parsing its raw state.
    static func prepare(from part: OCPart) -> PreparedQuestionToolPayload? {
        guard isQuestionTool(part) else { return nil }

        return PreparedQuestionToolPayload(
            questions: questionInfos(from: part.state?.input),
            answers: questionAnswers(from: part.state?.metadata?["answers"])
        )
    }

    /// Drops the raw dynamic state after `prepare(from:)` has captured the
    /// bounded transcript projection. A `question` part has no other UI
    /// consumer for `input`, `metadata`, attachments, output, or error; keeping
    /// them in `ChatMessage.parts` would otherwise retain a multi-megabyte JSON
    /// tree for the lifetime of the transcript.
    static func sanitizedPart(from part: OCPart) -> OCPart {
        let sanitizedState = part.state.map { state in
            OCToolState(
                status: state.status,
                title: StreamDisplayValue.preview(
                    state.title,
                    maximumBytes: maximumToolTitleBytes
                )
            )
        }

        return OCPart(
            id: part.id,
            sessionID: part.sessionID,
            messageID: part.messageID,
            type: .tool,
            tool: "question",
            state: sanitizedState
        )
    }

    private static func isQuestionTool(_ part: OCPart) -> Bool {
        guard part.type == .tool,
              let tool = part.tool else { return false }

        // Do not lowercase an attacker-controlled megabyte-long tool name just
        // to decide whether this projection applies. We only need the literal
        // tool identifier and reject an overlong candidate after a tiny prefix.
        var candidate = String.UnicodeScalarView()
        var scalarCount = 0
        for scalar in tool.unicodeScalars {
            guard scalarCount < 32 else { return false }
            candidate.append(scalar)
            scalarCount += 1
        }

        return String(candidate)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("question") == .orderedSame
    }

    private static func questionInfos(from input: AnyCodable?) -> [OCQuestionInfo] {
        let rawInput = unwrap(input?.value)
        let rawQuestions = value(forKey: "questions", in: rawInput) ?? rawInput
        let rawQuestionItems = arrayPrefix(rawQuestions, limit: maximumQuestionCount)

        var questions: [OCQuestionInfo] = []
        questions.reserveCapacity(rawQuestionItems.count)

        for rawQuestion in rawQuestionItems {
            guard let question = dictionary(from: rawQuestion) else { continue }

            let options = optionInfos(from: value(forKey: "options", in: question))
            questions.append(
                OCQuestionInfo(
                    question: displayString(
                        value(forKey: "question", in: question),
                        maximumBytes: maximumQuestionBytes
                    ),
                    header: displayString(
                        value(forKey: "header", in: question),
                        maximumBytes: maximumHeaderBytes
                    ),
                    options: options,
                    multiple: boolValue(forKey: "multiple", in: question) ?? false,
                    custom: boolValue(forKey: "custom", in: question) ?? true
                )
            )
        }

        return questions
    }

    private static func optionInfos(from rawValue: Any?) -> [OCQuestionOption] {
        let rawOptions = arrayPrefix(rawValue, limit: maximumOptionCount)
        var options: [OCQuestionOption] = []
        options.reserveCapacity(rawOptions.count)

        for rawOption in rawOptions {
            guard let option = dictionary(from: rawOption) else { continue }
            options.append(
                OCQuestionOption(
                    label: displayString(
                        value(forKey: "label", in: option),
                        maximumBytes: maximumOptionLabelBytes
                    ),
                    description: displayString(
                        value(forKey: "description", in: option),
                        maximumBytes: maximumOptionDescriptionBytes
                    )
                )
            )
        }

        return options
    }

    private static func questionAnswers(from answers: AnyCodable?) -> [[String]] {
        let rawAnswers = unwrap(answers?.value)
        let values = arrayPrefix(rawAnswers, limit: maximumAnswerRowCount)

        if !values.isEmpty {
            let containsNestedRows = values.contains { !arrayPrefix($0, limit: 1).isEmpty }
            if containsNestedRows {
                return values
                    .map(answerStrings)
                    .filter { !$0.isEmpty }
            }

            let answers = answerStrings(values)
            return answers.isEmpty ? [] : [answers]
        }

        if let answer = answerString(rawAnswers) {
            return [[answer]]
        }

        return []
    }

    private static func answerStrings(_ value: Any) -> [String] {
        let values = arrayPrefix(value, limit: maximumAnswersPerRow)
        if !values.isEmpty {
            return values.compactMap(answerString)
        }

        return answerString(value).map { [$0] } ?? []
    }

    private static func answerString(_ value: Any?) -> String? {
        let bounded = displayString(value, maximumBytes: maximumAnswerBytes)
        let trimmed = bounded.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func displayString(_ value: Any?, maximumBytes: Int) -> String {
        guard let string = unwrap(value) as? String else { return "" }
        return StreamDisplayValue.preview(string, maximumBytes: maximumBytes)
    }

    private static func boolValue(forKey key: String, in dictionary: [String: Any]) -> Bool? {
        unwrap(dictionary[key]) as? Bool
    }

    private static func value(forKey key: String, in value: Any?) -> Any? {
        dictionary(from: value)?[key]
    }

    private static func dictionary(from value: Any?) -> [String: Any]? {
        unwrap(value) as? [String: Any]
    }

    private static func arrayPrefix(_ value: Any?, limit: Int) -> [Any] {
        guard limit > 0,
              let values = unwrap(value) as? [Any] else {
            return []
        }
        return Array(values.prefix(limit))
    }

    /// `AnyCodable` values decoded from the wire already use Foundation
    /// collections. This small unwrapping loop also supports test fixtures and
    /// legacy callers that hand us nested `AnyCodable` boxes, without allowing
    /// a malformed wrapper chain to recurse indefinitely.
    private static func unwrap(_ value: Any?) -> Any? {
        var current = value
        for _ in 0..<8 {
            guard let wrapped = current as? AnyCodable else { return current }
            current = wrapped.value
        }
        return nil
    }
}
