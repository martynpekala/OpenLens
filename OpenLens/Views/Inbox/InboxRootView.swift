import SwiftUI

private enum InboxLayout {
    static let screenInset: CGFloat = 20
    static let screenVerticalPadding: CGFloat = 24
    static let sectionGap: CGFloat = 28
    static let rowPaddingHorizontal: CGFloat = 16
    static let rowPaddingVertical: CGFloat = 14
}

struct InboxRootView: View {
    enum ViewState {
        case idle
        case loading
        case loaded
        case error(String)
    }

    @Bindable var chatClient: ChatClient

    @Environment(\.inboxService) private var inboxService

    @State private var viewState: ViewState = .idle
    @State private var snapshot = InboxSnapshot(permissions: [], questions: [])
    @State private var activeQuestion: OCQuestionRequest?

    var body: some View {
        Group {
            if isInitialLoading {
                ProgressView()
                    .tint(Color.appSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.appBackground)
            } else {
                content
            }
        }
        .navigationTitle("Inbox")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadInbox()
        }
        .refreshable {
            await loadInbox(force: true)
        }
        .sheet(item: $activeQuestion) { question in
            QuestionView(
                request: question,
                onSubmit: { answers in
                    Task {
                        await submitQuestion(question, answers: answers)
                    }
                },
                onDismiss: {
                    Task {
                        await rejectQuestion(question)
                    }
                }
            )
        }
    }

    @ViewBuilder
    private var content: some View {
        if let errorMessage, snapshot.permissions.isEmpty, snapshot.questions.isEmpty {
            FeaturePlaceholderView(
                title: "Inbox",
                subtitle: errorMessage,
                symbol: "exclamationmark.triangle",
                highlights: [
                    "Pull to refresh and retry",
                    "Inbox reads pending permissions and questions",
                    "Chat keeps working while inbox reloads"
                ]
            )
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: InboxLayout.sectionGap) {
                    if let errorMessage {
                        errorCard(errorMessage)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        sectionHeader(title: "Permissions", count: snapshot.permissions.count)
                        permissionsCard
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        sectionHeader(title: "Questions", count: snapshot.questions.count)
                        questionsCard
                    }
                }
                .padding(.horizontal, InboxLayout.screenInset)
                .padding(.bottom, InboxLayout.screenVerticalPadding)
            }
            .background(Color.appBackground)
        }
    }

    private func sectionHeader(title: String, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title.uppercased())
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.appSecondary)
                .kerning(0.5)

            Spacer(minLength: 8)

            Text(count == 1 ? "1 item" : "\(count) items")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Color.appSecondary)
        }
    }

    private var permissionsCard: some View {
        SurfaceCard(padding: 0) {
            if snapshot.permissions.isEmpty {
                emptyRow(symbol: "checkmark.circle", text: "No pending permission requests.")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(snapshot.permissions.enumerated()), id: \.element.id) { index, permission in
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(alignment: .top, spacing: 12) {
                                itemBadge(title: "Permission", tint: .orange)

                                VStack(alignment: .leading, spacing: 6) {
                                    Text(permission.title?.nilIfBlank ?? "Permission request")
                                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                                        .foregroundStyle(Color.appPrimary)

                                    if let description = permission.description?.nilIfBlank {
                                        Text(description)
                                            .font(.system(size: 13))
                                            .foregroundStyle(Color.appSecondary)
                                    }

                                    if let tool = permission.toolDisplayName?.nilIfBlank {
                                        metadataChip(text: tool, monospaced: true)
                                    }
                                }
                            }

                            HStack(spacing: 10) {
                                actionButton(title: AppText.deny, fill: Color.appTertiary, foreground: Color.appPrimary) {
                                    Task {
                                        await respondToPermission(permission, reply: .reject)
                                    }
                                }
                                actionButton(title: AppText.allowOnce, fill: Color.appAccent, foreground: Color.appOnAccent) {
                                    Task {
                                        await respondToPermission(permission, reply: .once)
                                    }
                                }
                                actionButton(title: AppText.allowAll, fill: Color.appWarning.opacity(0.14), foreground: Color.appWarning) {
                                    Task {
                                        await respondToPermission(permission, reply: .always)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, InboxLayout.rowPaddingHorizontal)
                        .padding(.vertical, InboxLayout.rowPaddingVertical)

                        if index < snapshot.permissions.count - 1 {
                            SurfaceDivider()
                        }
                    }
                }
            }
        }
    }

    private var questionsCard: some View {
        SurfaceCard(padding: 0) {
            if snapshot.questions.isEmpty {
                emptyRow(symbol: "checkmark.circle", text: "No pending questions from the agent.")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(snapshot.questions.enumerated()), id: \.element.id) { index, question in
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(alignment: .top, spacing: 12) {
                                itemBadge(title: "Question", tint: Color.appPrimary)

                                VStack(alignment: .leading, spacing: 6) {
                                    Text(question.questions.first?.header.nilIfBlank ?? "Agent question")
                                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                                        .foregroundStyle(Color.appPrimary)

                                    Text(question.questions.first?.question.nilIfBlank ?? "Open the sheet to answer this question.")
                                        .font(.system(size: 13))
                                        .foregroundStyle(Color.appSecondary)
                                        .lineLimit(3)

                                    metadataChip(
                                        text: "\(question.questions.count) prompt\(question.questions.count == 1 ? "" : "s")",
                                        monospaced: false
                                    )
                                }
                            }

                            HStack(spacing: 10) {
                                actionButton(title: "Answer", fill: Color.appAccent, foreground: Color.appOnAccent) {
                                    activeQuestion = question
                                }
                                actionButton(title: "Dismiss", fill: Color.appTertiary, foreground: Color.appPrimary) {
                                    Task {
                                        await rejectQuestion(question)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, InboxLayout.rowPaddingHorizontal)
                        .padding(.vertical, InboxLayout.rowPaddingVertical)

                        if index < snapshot.questions.count - 1 {
                            SurfaceDivider()
                        }
                    }
                }
            }
        }
    }

    private func actionButton(title: String, fill: Color, foreground: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(foreground)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(fill, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func itemBadge(title: String, tint: Color) -> some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.appSurface, in: Capsule())
            .overlay(
                Capsule()
                    .stroke(tint.opacity(0.3), lineWidth: 1)
            )
    }

    private func metadataChip(text: String, monospaced: Bool) -> some View {
        Text(text)
            .font(monospaced ? .system(size: 12, weight: .medium, design: .monospaced) : .system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(Color.appSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.appTertiary, in: Capsule())
    }

    private func emptyRow(symbol: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.appSecondary)

            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(Color.appSecondary)

            Spacer()
        }
        .padding(.horizontal, InboxLayout.rowPaddingHorizontal)
        .padding(.vertical, InboxLayout.rowPaddingVertical)
    }

    private func errorCard(_ message: String) -> some View {
        SurfaceCard {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.appSecondary)
                Spacer()
            }
        }
    }

    private var isInitialLoading: Bool {
        if case .loading = viewState {
            return snapshot.permissions.isEmpty && snapshot.questions.isEmpty
        }
        return false
    }

    private var errorMessage: String? {
        if case .error(let message) = viewState {
            return message
        }
        return nil
    }

    private func loadInbox(force: Bool = false) async {
        if !force, case .loaded = viewState {
            return
        }

        viewState = .loading
        do {
            snapshot = try await inboxService.loadInbox()
            viewState = .loaded
        } catch {
            viewState = .error(error.localizedDescription)
        }
    }

    private func respondToPermission(_ permission: OCPermissionRequest, reply: OCPermissionReply) async {
        do {
            try await inboxService.respondToPermission(requestID: permission.id, reply: reply)
            if chatClient.pendingPermission?.id == permission.id {
                chatClient.pendingPermission = nil
                chatClient.showPermissionAlert = false
            }
            await loadInbox(force: true)
        } catch {
            viewState = .error(error.localizedDescription)
        }
    }

    private func submitQuestion(_ question: OCQuestionRequest, answers: [[String]]) async {
        do {
            try await inboxService.respondToQuestion(requestID: question.id, answers: answers)
            if chatClient.pendingQuestion?.id == question.id {
                chatClient.pendingQuestion = nil
                chatClient.showQuestionSheet = false
            }
            activeQuestion = nil
            await loadInbox(force: true)
        } catch {
            viewState = .error(error.localizedDescription)
        }
    }

    private func rejectQuestion(_ question: OCQuestionRequest) async {
        do {
            try await inboxService.rejectQuestion(requestID: question.id)
            if chatClient.pendingQuestion?.id == question.id {
                chatClient.pendingQuestion = nil
                chatClient.showQuestionSheet = false
            }
            activeQuestion = nil
            await loadInbox(force: true)
        } catch {
            viewState = .error(error.localizedDescription)
        }
    }
}
