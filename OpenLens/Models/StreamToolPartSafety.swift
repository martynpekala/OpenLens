import Foundation

/// Converts a streamed activity part into the small subset the chat UI actually
/// needs. The raw event remains available only to explicit recording; normal
/// UI state must not retain arbitrary tool input, attachments, or multi-megabyte
/// payloads for every tool or subagent in a long agent run.
nonisolated enum StreamToolPartSafety {
    static let maximumToolNameBytes = 96
    static let maximumTitleBytes = 512
    static let maximumOutputBytes = 720
    static let maximumDetailBytes = 640
    static let maximumIdentifierBytes = 256

    private static let inputFieldLimits: [(String, Int)] = [
        ("filePath", 360),
        ("path", 360),
        ("pattern", 160),
        ("query", 160),
        ("command", 320),
        ("subagent_type", 128),
        ("agent", 128),
        ("agentID", 256),
        ("name", 128),
        ("description", maximumDetailBytes),
        ("task", maximumDetailBytes),
        ("prompt", maximumDetailBytes),
        ("message", maximumDetailBytes),
    ]

    static func sanitize(_ part: OCPart) -> OCPart {
        guard isActivityPart(part.type) else { return part }

        let state = part.state.map(sanitizedState)
        return OCPart(
            id: part.id,
            sessionID: part.sessionID,
            messageID: part.messageID,
            type: part.type,
            time: sanitizedCompletionTime(part.time),
            callID: part.type == .tool ? safeIdentifier(part.callID) : nil,
            tool: part.type == .tool
                ? StreamDisplayValue.preview(part.tool, maximumBytes: maximumToolNameBytes)
                : nil,
            state: state,
            // Generic tool rows never render `source`; subagent rows use it
            // only as a bounded fallback detail.
            source: part.type == .tool ? nil : sanitizedSource(part.source),
            name: StreamDisplayValue.preview(part.name, maximumBytes: 160),
            cost: part.cost,
            tokens: part.tokens,
            prompt: StreamDisplayValue.preview(part.prompt, maximumBytes: maximumDetailBytes),
            partDescription: StreamDisplayValue.preview(part.partDescription, maximumBytes: maximumDetailBytes),
            agent: sanitizedAgent(part.agent),
            attempt: part.attempt
        )
    }

    private static func isActivityPart(_ type: OCPartType) -> Bool {
        switch type {
        case .tool, .agent, .subtask:
            true
        case .text,
             .reasoning,
             .file,
             .stepStart,
             .stepFinish,
             .snapshot,
             .patch,
             .retry,
             .compaction,
             .unknown:
            false
        }
    }

    private static func sanitizedState(_ state: OCToolState) -> OCToolState {
        OCToolState(
            status: state.status,
            input: sanitizedInput(state.input),
            output: StreamDisplayValue.preview(state.output, maximumBytes: maximumOutputBytes),
            title: StreamDisplayValue.preview(state.title, maximumBytes: maximumTitleBytes),
            error: StreamDisplayValue.preview(state.error, maximumBytes: maximumOutputBytes),
            metadata: sanitizedMetadata(state.metadata),
            time: state.time
        )
    }

    private static func sanitizedInput(_ input: AnyCodable?) -> AnyCodable? {
        guard let dictionary = dictionary(from: input?.value) else { return nil }
        var result: [String: Any] = [:]
        result.reserveCapacity(inputFieldLimits.count)

        for (key, limit) in inputFieldLimits {
            guard let value = displayString(dictionary[key], maximumBytes: limit) else { continue }
            result[key] = value
        }

        return result.isEmpty ? nil : AnyCodable(result)
    }

    private static func sanitizedMetadata(_ metadata: [String: AnyCodable]?) -> [String: AnyCodable]? {
        guard let metadata else { return nil }
        var result: [String: AnyCodable] = [:]

        for key in ["sessionId", "sessionID", "session_id"] {
            guard let value = metadata[key]?.value as? String,
                  let identifier = safeIdentifier(value) else { continue }
            result[key] = AnyCodable(identifier)
        }

        return result.isEmpty ? nil : result
    }

    private static func sanitizedAgent(_ agent: AnyCodable?) -> AnyCodable? {
        guard let raw = agent?.value else { return nil }

        if let value = displayString(raw, maximumBytes: 160) {
            return AnyCodable(value)
        }

        guard let dictionary = dictionary(from: raw) else { return nil }
        var result: [String: Any] = [:]
        for key in ["name", "id", "title"] {
            if let value = displayString(dictionary[key], maximumBytes: 160) {
                result[key] = value
            }
        }
        return result.isEmpty ? nil : AnyCodable(result)
    }

    private static func sanitizedSource(_ source: AnyCodable?) -> AnyCodable? {
        guard let source,
              let value = displayString(source, maximumBytes: maximumDetailBytes)
        else {
            return nil
        }
        return AnyCodable(value)
    }

    /// Agent/subtask completion only needs to know that a completion marker
    /// exists. Keep that bit without retaining an arbitrary dynamic time map.
    private static func sanitizedCompletionTime(_ time: AnyCodable?) -> AnyCodable? {
        guard let dictionary = dictionary(from: time?.value) else { return nil }

        if dictionary["end"] != nil {
            return AnyCodable(["end": true])
        }
        if dictionary["completed"] != nil {
            return AnyCodable(["completed": true])
        }
        return nil
    }

    private static func safeIdentifier(_ value: String?) -> String? {
        guard let value, value.utf8.count <= maximumIdentifierBytes else { return nil }
        return value
    }

    private static func displayString(_ value: Any?, maximumBytes: Int) -> String? {
        guard let string = unwrap(value) as? String else { return nil }
        return StreamDisplayValue.preview(Optional(string), maximumBytes: maximumBytes)
    }

    private static func dictionary(from value: Any?) -> [String: Any]? {
        unwrap(value) as? [String: Any]
    }

    private static func unwrap(_ value: Any?) -> Any? {
        var current = value
        for _ in 0..<8 {
            guard let wrapped = current as? AnyCodable else { return current }
            current = wrapped.value
        }
        return nil
    }
}
