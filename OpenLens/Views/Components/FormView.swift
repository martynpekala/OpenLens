import Foundation
import SwiftUI

/// Safety-bounded renderer for the documented v2 form field types. It never
/// invents answers for a field introduced by a newer OpenCode server.
struct FormView: View {
    let form: OCFormRequest
    let onSubmit: ([String: OCFormValue]) -> Void
    let onCancel: () -> Void
    let isSubmitting: Bool

    @State private var strings: [String: String] = [:]
    @State private var numbers: [String: String] = [:]
    @State private var booleans: [String: Bool] = [:]
    @State private var selections: [String: Set<String>] = [:]
    @State private var customSelections: [String: String] = [:]
    @State private var externalAcknowledgements: [String: Bool] = [:]

    private var visibleFields: [OCFormField] {
        form.fields.filter { !$0.hidden }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(form.title)
                        .font(.title3.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)

                    if form.hasUnsupportedFields {
                        unsupportedNotice
                    }

                    ForEach(visibleFields) { field in
                        fieldView(field)
                    }
                }
                .padding(20)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Agent Form")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                    }
                    .disabled(isSubmitting)
                    .accessibilityHint("Cancels this form without submitting it")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppText.submit) {
                        submit()
                    }
                    .disabled(!canSubmit || isSubmitting)
                }
            }
        }
        .onAppear(perform: populateDefaults)
    }

    private var unsupportedNotice: some View {
        Label {
            Text("This form contains a field OpenLens cannot safely render. Open the form in OpenCode to complete it.")
                .font(.subheadline)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .foregroundStyle(.orange)
        .padding(14)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func fieldView(_ field: OCFormField) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(field.displayTitle)
                    .font(.headline)
                if let description = field.description?.nilIfBlank {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if !field.isSupported {
                Label("This field has rules OpenLens cannot safely render. Open the form in OpenCode.", systemImage: "questionmark.app")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            } else {
                switch field.kind {
                case .string:
                    stringField(field)
                case .number, .integer:
                    numericField(field)
                case .boolean:
                    Toggle(field.displayTitle, isOn: booleanBinding(for: field.key))
                        .labelsHidden()
                case .multiselect:
                    multiselectField(field)
                case .external:
                    externalField(field)
                case .unsupported:
                    EmptyView()
                }
            }

            if field.required && field.kind != .external && field.kind != .unsupported {
                Text("Required")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private func stringField(_ field: OCFormField) -> some View {
        if !field.options.isEmpty {
            Picker(field.displayTitle, selection: stringBinding(for: field.key)) {
                Text("Choose an option").tag("")
                ForEach(field.options) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .pickerStyle(.menu)
        }

        if field.options.isEmpty || field.custom {
            TextField(
                field.placeholder ?? field.displayTitle,
                text: field.options.isEmpty
                    ? stringBinding(for: field.key)
                    : customStringBinding(for: field.key)
            )
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.sentences)
        }
    }

    @ViewBuilder
    private func numericField(_ field: OCFormField) -> some View {
        TextField(field.placeholder ?? field.displayTitle, text: numberBinding(for: field.key))
            .keyboardType(field.kind == .integer ? .numberPad : .decimalPad)
            .textFieldStyle(.roundedBorder)

        if let minimum = field.numberMinimum, let maximum = field.numberMaximum {
            Text("Between \(minimum.formatted()) and \(maximum.formatted())")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func multiselectField(_ field: OCFormField) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(field.options) { option in
                Toggle(isOn: multiselectBinding(for: field.key, value: option.value)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(option.label.nilIfBlank ?? option.value)
                        if let description = option.description?.nilIfBlank {
                            Text(description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if field.custom {
                TextField("Custom selection", text: customSelectionBinding(for: field.key))
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    @ViewBuilder
    private func externalField(_ field: OCFormField) -> some View {
        if let url = field.externalURL {
            Link(destination: url) {
                Label("Open in browser", systemImage: "safari")
            }
            .buttonStyle(.bordered)

            Toggle(
                "I completed this external action",
                isOn: externalAcknowledgementBinding(for: field.key)
            )
            .font(.subheadline)
        } else {
            Label("This link is unavailable. Open the form in OpenCode.", systemImage: "exclamationmark.triangle")
                .font(.subheadline)
                .foregroundStyle(.orange)
        }
    }

    private var canSubmit: Bool {
        InteractiveFormSafety.accepts(answer: formAnswer, for: form)
    }

    private func submit() {
        guard canSubmit else { return }
        onSubmit(formAnswer)
    }

    private var formAnswer: [String: OCFormValue] {
        var answer: [String: OCFormValue] = [:]

        for field in visibleFields {
            switch field.kind {
            case .string:
                if let value = selectedString(for: field), !value.isEmpty {
                    answer[field.key] = .string(value)
                }
            case .number, .integer:
                if let value = numericValue(for: field) {
                    answer[field.key] = .number(value)
                }
            case .boolean:
                if let value = booleans[field.key] {
                    answer[field.key] = .boolean(value)
                }
            case .multiselect:
                let values = multiselectValues(for: field)
                if !values.isEmpty {
                    answer[field.key] = .strings(values)
                }
            case .external:
                if externalAcknowledgements[field.key] == true {
                    answer[field.key] = .boolean(true)
                }
            case .unsupported:
                break
            }
        }

        return answer
    }

    private func populateDefaults() {
        for field in form.fields {
            switch field.kind {
            case .string:
                strings[field.key] = field.stringDefault ?? ""
            case .number, .integer:
                numbers[field.key] = field.numberDefault.map { value in
                    field.kind == .integer && value.rounded() == value
                        ? String(format: "%.0f", value)
                        : String(describing: value)
                } ?? ""
            case .boolean:
                booleans[field.key] = field.booleanDefault ?? (field.required ? false : nil)
            case .multiselect:
                selections[field.key] = Set(field.multiselectDefault)
            case .external, .unsupported:
                break
            }
        }
    }

    private func selectedString(for field: OCFormField) -> String? {
        let custom = customSelections[field.key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !custom.isEmpty {
            return custom
        }
        let value = strings[field.key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    private func numericValue(for field: OCFormField) -> Double? {
        let raw = numbers[field.key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let value = Double(raw), value.isFinite,
              field.kind != .integer || value.rounded() == value,
              field.numberMinimum.map({ value >= $0 }) ?? true,
              field.numberMaximum.map({ value <= $0 }) ?? true
        else {
            return nil
        }
        return value
    }

    private func multiselectValues(for field: OCFormField) -> [String] {
        var values = selections[field.key, default: []].sorted()
        let custom = customSelections[field.key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !custom.isEmpty, !values.contains(custom) {
            values.append(custom)
        }
        return values
    }

    private func stringBinding(for key: String) -> Binding<String> {
        Binding(get: { strings[key, default: ""] }, set: { strings[key] = $0 })
    }

    private func customStringBinding(for key: String) -> Binding<String> {
        Binding(get: { customSelections[key, default: ""] }, set: { customSelections[key] = $0 })
    }

    private func numberBinding(for key: String) -> Binding<String> {
        Binding(get: { numbers[key, default: ""] }, set: { numbers[key] = $0 })
    }

    private func booleanBinding(for key: String) -> Binding<Bool> {
        Binding(get: { booleans[key, default: false] }, set: { booleans[key] = $0 })
    }

    private func multiselectBinding(for key: String, value: String) -> Binding<Bool> {
        Binding(
            get: { selections[key, default: []].contains(value) },
            set: { enabled in
                if enabled {
                    selections[key, default: []].insert(value)
                } else {
                    selections[key, default: []].remove(value)
                }
            }
        )
    }

    private func customSelectionBinding(for key: String) -> Binding<String> {
        Binding(get: { customSelections[key, default: ""] }, set: { customSelections[key] = $0 })
    }

    private func externalAcknowledgementBinding(for key: String) -> Binding<Bool> {
        Binding(
            get: { externalAcknowledgements[key, default: false] },
            set: { externalAcknowledgements[key] = $0 }
        )
    }
}
