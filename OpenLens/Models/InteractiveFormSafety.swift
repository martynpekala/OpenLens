import Foundation

/// Admission limits for server-driven v2 forms. Reply identifiers and option
/// values stay intact because changing either would submit a different answer.
/// New field types are deliberately retained as an explicit unsupported UI
/// state rather than rejected as though the whole server response were invalid.
nonisolated enum InteractiveFormSafety {
    static let maximumIdentifierBytes = InteractiveQuestionSafety.maximumIdentifierBytes
    static let maximumFieldCount = InteractiveQuestionSafety.maximumQuestionCount
    static let maximumTitleBytes = InteractiveQuestionSafety.maximumHeaderBytes
    static let maximumDescriptionBytes = InteractiveQuestionSafety.maximumQuestionBytes
    static let maximumOptionCount = InteractiveQuestionSafety.maximumOptionsPerQuestion
    static let maximumOptionValueBytes = InteractiveQuestionSafety.maximumOptionLabelBytes
    static let maximumOptionLabelBytes = InteractiveQuestionSafety.maximumOptionLabelBytes
    static let maximumOptionDescriptionBytes = InteractiveQuestionSafety.maximumOptionDescriptionBytes
    static let maximumURLBytes = 2_048
    static let maximumPatternBytes = 1_024

    static func fitsGlobalDirectory(_ directory: String) -> Bool {
        ServerPath.isAbsolute(directory) && directory.utf8.count <= 4_096 && !directory.contains("\0")
    }

    static func sanitize(_ request: OCFormRequest) -> OCFormRequest? {
        guard fitsIdentifier(request.id),
              fitsIdentifier(request.sessionID),
              fits(request.title, maximumBytes: maximumTitleBytes),
              (1...maximumFieldCount).contains(request.fields.count),
              request.state == .pending
        else {
            return nil
        }

        var keys = Set<String>()
        for field in request.fields {
            guard fitsIdentifier(field.key),
                  keys.insert(field.key).inserted,
                  fitsOptional(field.title, maximumBytes: maximumTitleBytes),
                  fitsOptional(field.description, maximumBytes: maximumDescriptionBytes),
                  fitsOptional(field.placeholder, maximumBytes: maximumTitleBytes),
                  fits(field.rawType, maximumBytes: 80),
                   field.options.count <= maximumOptionCount,
                   validCountBounds(minimum: field.stringMinimum, maximum: field.stringMaximum),
                   validCountBounds(minimum: field.multiselectMinimum, maximum: field.multiselectMaximum),
                   validBounds(minimum: field.numberMinimum, maximum: field.numberMaximum),
                   field.stringPattern.map({ fits($0, maximumBytes: maximumPatternBytes) }) ?? true,
                   fitsOptional(field.stringDefault, maximumBytes: maximumDescriptionBytes),
                   field.multiselectDefault.allSatisfy({ fits($0, maximumBytes: maximumOptionValueBytes) }),
                   field.externalURLString.map({ fits($0, maximumBytes: maximumURLBytes) }) ?? true,
                   validPattern(field.stringPattern)
            else {
                return nil
            }

            if let conditions = field.conditions {
                guard conditions.count <= maximumFieldCount,
                      conditions.allSatisfy({ condition in
                          fitsIdentifier(condition.key) && fits(condition.op, maximumBytes: 80)
                              && conditionValueFits(condition.value)
                      }) else { return nil }
            }

            var optionValues = Set<String>()
            for option in field.options {
                guard fits(option.value, maximumBytes: maximumOptionValueBytes),
                      !option.value.isEmpty,
                      optionValues.insert(option.value).inserted,
                      fits(option.label, maximumBytes: maximumOptionLabelBytes),
                      fitsOptional(option.description, maximumBytes: maximumOptionDescriptionBytes)
                else {
                    return nil
                }
            }

            guard validDefault(for: field) else { return nil }
        }

        return request
    }

    /// Validate the dependency graph without inferring unknown visibility semantics.
    static func supportsConditions(in request: OCFormRequest) -> Bool {
        var earlier: [String: OCFormField] = [:]
        for field in request.fields {
            guard let conditions = field.conditions else { return false }
            for condition in conditions {
                guard ["eq", "neq"].contains(condition.op),
                      let target = earlier[condition.key], target.isSupported,
                      !target.hidden,
                      target.kind != .external else { return false }
                switch (target.kind, condition.value) {
                case (.boolean, .boolean), (.number, .number), (.integer, .number):
                    break
                case (.string, .string(let value)), (.multiselect, .string(let value)):
                    if !target.custom && (target.kind == .multiselect || target.hasDeclaredOptions),
                       !target.options.contains(where: { $0.value == value }) { return false }
                default:
                    return false
                }
            }
            earlier[field.key] = field
        }
        return true
    }

    /// Only active earlier answers participate, so a hidden branch cannot keep
    /// its descendants active through stale draft values.
    static func activeFields(for request: OCFormRequest, answer: [String: OCFormValue]) -> [OCFormField] {
        guard !request.hasUnsupportedFields else { return request.fields.filter { !$0.hidden } }
        var active: [OCFormField] = []
        var earlierAnswers: [String: OCFormValue] = [:]
        for field in request.fields where !field.hidden {
            guard field.conditions?.allSatisfy({ $0.matches(earlierAnswers[$0.key]) }) == true else { continue }
            active.append(field)
            earlierAnswers[field.key] = answer[field.key]
        }
        return active
    }

    /// Services drop only known inactive fields. Unknown keys and unsupported
    /// forms still fail rather than becoming a guessed, superficially valid reply.
    static func submissionAnswer(_ answer: [String: OCFormValue], for request: OCFormRequest) -> [String: OCFormValue]? {
        guard sanitize(request) != nil, !request.hasUnsupportedFields,
              answer.keys.allSatisfy({ key in request.fields.contains { $0.key == key } }) else { return nil }
        let activeKeys = Set(activeFields(for: request, answer: answer).map(\.key))
        let reply = answer.filter { activeKeys.contains($0.key) }
        return accepts(answer: reply, for: request) ? reply : nil
    }

    private static func conditionValueFits(_ value: OCFormValue) -> Bool {
        switch value {
        case .string(let text): return fits(text, maximumBytes: maximumDescriptionBytes)
        case .number(let number): return number.isFinite
        case .boolean: return true
        case .strings: return false
        }
    }

    static func accepts(answer: [String: OCFormValue], for request: OCFormRequest) -> Bool {
        guard sanitize(request) != nil,
              request.state == .pending,
              fitsIdentifier(request.id),
              fitsIdentifier(request.sessionID),
              !request.hasUnsupportedFields
        else { return false }

        let visibleFields = activeFields(for: request, answer: answer)
        let fieldsByKey = Dictionary(uniqueKeysWithValues: visibleFields.map { ($0.key, $0) })
        guard answer.keys.allSatisfy({ fieldsByKey[$0] != nil }) else { return false }

        for field in visibleFields {
            if field.kind == .external {
                // The v2 server treats external actions as acknowledgements.
                // Displaying a link is not enough to submit one safely.
                guard answer[field.key] == .boolean(true) else { return false }
                continue
            }

            let value = answer[field.key]
            if field.required, value == nil {
                return false
            }
            guard let value else { continue }
            guard accepts(value, for: field) else { return false }
        }
        return true
    }

    static func fitsIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty,
              value != ".",
              value != "..",
              fits(value, maximumBytes: maximumIdentifierBytes)
        else {
            return false
        }

        return value.unicodeScalars.allSatisfy {
            $0.value < 128
                && (CharacterSet.alphanumerics.contains($0) || "-._~".unicodeScalars.contains($0))
        }
    }

    private static func accepts(_ value: OCFormValue, for field: OCFormField) -> Bool {
        switch (field.kind, value) {
        case (.string, .string(let text)):
            let count = text.count
            guard fits(text, maximumBytes: maximumDescriptionBytes),
                  !text.isEmpty,
                  field.stringMinimum.map({ count >= $0 }) ?? true,
                  field.stringMaximum.map({ count <= $0 }) ?? true,
                  matchesStringConstraints(text, field: field)
            else {
                return false
            }
            return field.options.isEmpty || field.custom || field.options.contains(where: { $0.value == text })

        case (.number, .number(let number)):
            return number.isFinite
                && (field.numberMinimum.map({ number >= $0 }) ?? true)
                && (field.numberMaximum.map({ number <= $0 }) ?? true)

        case (.integer, .number(let number)):
            return number.isFinite
                && number.rounded() == number
                && (field.numberMinimum.map({ number >= $0 }) ?? true)
                && (field.numberMaximum.map({ number <= $0 }) ?? true)

        case (.boolean, .boolean):
            return true

        case (.multiselect, .strings(let values)):
            guard !values.isEmpty,
                  values.count == Set(values).count,
                  values.count <= maximumOptionCount,
                  field.multiselectMinimum.map({ values.count >= $0 }) ?? true,
                  field.multiselectMaximum.map({ values.count <= $0 }) ?? true,
                  values.allSatisfy({ fits($0, maximumBytes: maximumOptionValueBytes) })
            else {
                return false
            }
            return values.allSatisfy { value in
                field.custom || field.options.contains(where: { $0.value == value })
            }

        default:
            return false
        }
    }

    private static func validBounds<T: Comparable>(minimum: T?, maximum: T?) -> Bool {
        guard let minimum, let maximum else { return true }
        return minimum <= maximum
    }

    private static func validCountBounds<T: Comparable & Numeric>(minimum: T?, maximum: T?) -> Bool {
        guard validBounds(minimum: minimum, maximum: maximum) else { return false }
        return (minimum.map { $0 >= 0 } ?? true)
            && (maximum.map { $0 >= 0 } ?? true)
    }

    private static func validPattern(_ pattern: String?) -> Bool {
        guard let pattern else { return true }
        return (try? NSRegularExpression(pattern: pattern)) != nil
    }

    private static func matchesStringConstraints(_ value: String, field: OCFormField) -> Bool {
        if let pattern = field.stringPattern,
           let expression = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            guard expression.firstMatch(in: value, range: range) != nil else { return false }
        }

        guard let format = field.stringFormat else { return true }
        switch format {
        case "email":
            return value.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil
        case "uri":
            return URL(string: value)?.scheme != nil
        case "date":
            guard value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
                  let date = ISO8601DateFormatter().date(from: "\(value)T00:00:00Z")
            else { return false }
            return ISO8601DateFormatter().string(from: date).hasPrefix(value)
        case "date-time":
            return ISO8601DateFormatter().date(from: value) != nil
        default:
            return false
        }
    }

    private static func validDefault(for field: OCFormField) -> Bool {
        guard field.isSupported else { return true }

        switch field.kind {
        case .string:
            guard let value = field.stringDefault else { return true }
            guard !value.isEmpty else { return true }
            return accepts(.string(value), for: field)
        case .number, .integer:
            guard let value = field.numberDefault else { return true }
            return accepts(.number(value), for: field)
        case .boolean:
            return true
        case .multiselect:
            // A required field does not need a server-provided default. The
            // user can complete it in the renderer; an empty default is not a
            // malformed form.
            guard !field.multiselectDefault.isEmpty else { return true }
            return accepts(.strings(field.multiselectDefault), for: field)
        case .external, .unsupported:
            return true
        }
    }

    private static func fitsOptional(_ value: String?, maximumBytes: Int) -> Bool {
        value.map { fits($0, maximumBytes: maximumBytes) } ?? true
    }

    private static func fits(_ value: String, maximumBytes: Int) -> Bool {
        value.utf8.count <= maximumBytes
    }
}
