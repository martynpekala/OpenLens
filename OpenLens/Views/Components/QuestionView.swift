import SwiftUI

/// Interactive view that presents questions from the AI agent with selectable options.
/// Supports single-select, multi-select, custom text answers, and multiple questions.
struct QuestionView: View {
    let request: OCQuestionRequest
    let onSubmit: ([[String]]) -> Void
    let onDismiss: () -> Void

    /// Tracks selected option labels per question index.
    @State private var selections: [[String]] = []
    /// Tracks custom text input per question index.
    @State private var customTexts: [String] = []
    /// Whether the user is typing a custom answer per question index.
    @State private var showingCustomInput: [Bool] = []
    /// Current question index when there are multiple questions.
    @State private var currentQuestionIndex: Int = 0
    /// Controls the entrance animation.
    @State private var hasAppeared: Bool = false

    @FocusState private var isCustomInputFocused: Bool

    private var questions: [OCQuestionInfo] {
        request.questions
    }

    private var currentQuestionID: String? {
        guard questions.indices.contains(currentQuestionIndex) else { return nil }
        return questions[currentQuestionIndex].id
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if questions.count > 1 {
                    questionTabs
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                if questions.indices.contains(currentQuestionIndex) {
                    questionContent(questions[currentQuestionIndex], index: currentQuestionIndex)
                        .id(currentQuestionID)
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)
                        ))
                }

                Spacer()

                submitBar
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Agent Question")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppText.dismiss) {
                        onDismiss()
                    }
                    .accessibilityLabel("Dismiss question")
                    .accessibilityHint("Rejects the question without answering")
                }
                ToolbarItem(placement: .keyboard) {
                    HStack {
                        Spacer()
                        Button(AppText.done) {
                            isCustomInputFocused = false
                        }
                        .font(.system(size: 15, weight: .medium))
                    }
                }
            }
        }
        .onAppear {
            initializeState()
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                hasAppeared = true
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agent question with \(questions.count) \(questions.count == 1 ? "question" : "questions")")
    }

    // MARK: - Question Tabs

    private var questionTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(questions.enumerated()), id: \.element.id) { index, q in
                    Button {
                        selectQuestion(at: index)
                    } label: {
                        HStack(spacing: 4) {
                            if hasAnswer(at: index) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.green)
                                    .transition(.scale.combined(with: .opacity))
                            }
                            Text(q.header.isEmpty ? "Q\(index + 1)" : q.header)
                                .font(.system(size: 13, weight: currentQuestionIndex == index ? .semibold : .regular))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(currentQuestionIndex == index ? Color.blue.opacity(0.15) : Color(.systemGray5))
                        .foregroundStyle(currentQuestionIndex == index ? .blue : .primary)
                        .clipShape(Capsule())
                    }
                    .accessibilityLabel("\(q.header.isEmpty ? "Question \(index + 1)" : q.header)\(hasAnswer(at: index) ? ", answered" : "")")
                    .accessibilityAddTraits(currentQuestionIndex == index ? .isSelected : [])
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(Color(.systemBackground))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Question tabs")
    }

    // MARK: - Question Content

    private func questionContent(_ question: OCQuestionInfo, index: Int) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !question.header.isEmpty {
                    Text(question.header)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityAddTraits(.isHeader)
                }

                Text(question.question)
                    .font(.system(size: 16))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(question.question)

                if question.multiple {
                    Label(AppText.multipleSelection, systemImage: "checkmark.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Multiple selection allowed")
                }

                VStack(spacing: 8) {
                    ForEach(Array(question.options.enumerated()), id: \.element.id) { optionIndex, option in
                        optionButton(option, questionIndex: index, isMultiple: question.multiple)
                            .opacity(hasAppeared ? 1 : 0)
                            .offset(y: hasAppeared ? 0 : 10)
                            .animation(
                                .spring(response: 0.4, dampingFraction: 0.8)
                                    .delay(Double(optionIndex) * 0.05),
                                value: hasAppeared
                            )
                    }

                    if question.custom {
                        customAnswerSection(questionIndex: index)
                            .opacity(hasAppeared ? 1 : 0)
                            .offset(y: hasAppeared ? 0 : 10)
                            .animation(
                                .spring(response: 0.4, dampingFraction: 0.8)
                                    .delay(Double(question.options.count) * 0.05),
                                value: hasAppeared
                            )
                    }
                }
            }
            .padding(16)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: - Option Button

    private func optionButton(_ option: OCQuestionOption, questionIndex: Int, isMultiple: Bool) -> some View {
        let isSelected = selections.indices.contains(questionIndex) && selections[questionIndex].contains(option.label)

        return Button {
            selectOption(option, questionIndex: questionIndex, isMultiple: isMultiple)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                // Selection indicator
                Image(systemName: isMultiple
                    ? (isSelected ? "checkmark.square.fill" : "square")
                    : (isSelected ? "largecircle.fill.circle" : "circle"))
                    .font(.system(size: 20))
                    .foregroundStyle(isSelected ? .blue : Color(.systemGray3))
                    .contentTransition(.symbolEffect(.replace))

                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)

                    if !option.description.isEmpty {
                        Text(option.description)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                }

                Spacer()
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color.blue.opacity(0.08) : Color(.systemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.blue.opacity(0.3) : Color(.systemGray4), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(option.label). \(option.description)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(isMultiple
            ? (isSelected ? "Double-tap to deselect" : "Double-tap to select")
            : (isSelected ? "Currently selected" : "Double-tap to select"))
    }

    // MARK: - Custom Answer

    private func customAnswerSection(questionIndex: Int) -> some View {
        let isActive = showingCustomInput.indices.contains(questionIndex) && showingCustomInput[questionIndex]

        return VStack(spacing: 8) {
            Button {
                toggleCustomInput(questionIndex: questionIndex)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: isActive ? "pencil.circle.fill" : "pencil.circle")
                        .font(.system(size: 20))
                        .foregroundStyle(isActive ? .blue : Color(.systemGray3))
                        .contentTransition(.symbolEffect(.replace))

                    Text(AppText.customAnswer)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.primary)
                    Spacer()
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isActive ? Color.blue.opacity(0.08) : Color(.systemBackground))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(isActive ? Color.blue.opacity(0.3) : Color(.systemGray4), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(AppText.customAnswer)
            .accessibilityAddTraits(isActive ? .isSelected : [])
            .accessibilityHint(isActive ? "Double-tap to close custom input" : "Double-tap to type a custom answer")

            if isActive {
                TextField(AppText.customPlaceholder, text: customTextBinding(for: questionIndex), axis: .vertical)
                    .focused($isCustomInputFocused)
                    .lineLimit(1...4)
                    .submitLabel(.done)
                    .onSubmit {
                        isCustomInputFocused = false
                    }
                    .padding(12)
                    .background(Color(.systemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.blue.opacity(0.3), lineWidth: 1)
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)).combined(with: .scale(scale: 0.95, anchor: .top)))
                    .accessibilityLabel("Custom answer text field")
                    .accessibilityHint("Type your custom answer here")
            }
        }
    }

    // MARK: - Submit Bar

    private var submitBar: some View {
        VStack(spacing: 0) {
            Divider()

            HStack(spacing: 12) {
                if questions.count > 1 {
                    let answered = (0..<questions.count).filter { hasAnswer(at: $0) }.count
                    Text("\(answered)/\(questions.count) answered")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                        .animation(.easeInOut(duration: 0.2), value: answeredCount)
                        .accessibilityLabel("\(answered) of \(questions.count) questions answered")
                }

                Spacer()

                Button {
                    submitAnswers()
                } label: {
                    Text(AppText.submit)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 10)
                        .background(canSubmit ? Color.blue : Color(.systemGray4))
                        .clipShape(Capsule())
                        .animation(.easeInOut(duration: 0.2), value: canSubmit)
                }
                .disabled(!canSubmit)
                .accessibilityLabel("Submit answers")
                .accessibilityHint(canSubmit ? "Double-tap to submit your answers" : "Select at least one answer to enable submission")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(.systemBackground))
        }
    }

    // MARK: - Logic

    private func initializeState() {
        selections = questions.map { _ in [] }
        customTexts = questions.map { _ in "" }
        showingCustomInput = questions.map { _ in false }
    }

    private func selectQuestion(at index: Int) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            currentQuestionIndex = index
        }
        isCustomInputFocused = false
    }

    private func selectOption(
        _ option: OCQuestionOption,
        questionIndex: Int,
        isMultiple: Bool
    ) {
        guard selections.indices.contains(questionIndex) else { return }

        isCustomInputFocused = false

        if isMultiple {
            if selections[questionIndex].contains(option.label) {
                selections[questionIndex].removeAll { $0 == option.label }
            } else {
                selections[questionIndex].append(option.label)
            }
            return
        }

        selections[questionIndex] = [option.label]
        if showingCustomInput.indices.contains(questionIndex) {
            showingCustomInput[questionIndex] = false
            customTexts[questionIndex] = ""
        }
    }

    private func toggleCustomInput(questionIndex: Int) {
        guard showingCustomInput.indices.contains(questionIndex) else { return }

        let shouldShow = !showingCustomInput[questionIndex]
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            showingCustomInput[questionIndex] = shouldShow
        }

        if shouldShow {
            if !questions[questionIndex].multiple {
                selections[questionIndex] = []
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                isCustomInputFocused = true
            }
        } else {
            isCustomInputFocused = false
        }
    }

    private func hasAnswer(at index: Int) -> Bool {
        guard selections.indices.contains(index),
              customTexts.indices.contains(index),
              showingCustomInput.indices.contains(index) else { return false }

        if !selections[index].isEmpty { return true }
        if showingCustomInput[index] && !customTexts[index].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return false
    }

    private var canSubmit: Bool {
        // At least one question must have an answer
        for i in questions.indices {
            if hasAnswer(at: i) { return true }
        }
        return false
    }

    /// Count of answered questions (for animation).
    private var answeredCount: Int {
        (0..<questions.count).filter { hasAnswer(at: $0) }.count
    }

    private func submitAnswers() {
        var answers: [[String]] = []
        for i in questions.indices {
            var answer: [String] = []
            if selections.indices.contains(i) {
                answer.append(contentsOf: selections[i])
            }
            if showingCustomInput.indices.contains(i) && showingCustomInput[i],
               customTexts.indices.contains(i) {
                let custom = customTexts[i].trimmingCharacters(in: .whitespacesAndNewlines)
                if !custom.isEmpty {
                    answer.append(custom)
                }
            }
            answers.append(answer)
        }
        onSubmit(answers)
    }

    private func customTextBinding(for index: Int) -> Binding<String> {
        Binding(
            get: { customTexts.indices.contains(index) ? customTexts[index] : "" },
            set: { newValue in
                if customTexts.indices.contains(index) {
                    customTexts[index] = newValue
                }
            }
        )
    }
}
