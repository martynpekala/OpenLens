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
    @Environment(\.serverRegistry) private var registry

    @State private var viewState: ViewState = .idle
    @State private var snapshot = AggregatedInbox()
    @State private var activeQuestion: ServerScoped<OCQuestionRequest>?
    @State private var activeForm: ServerScoped<OCFormRequest>?
    @State private var isResolvingForm = false

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
            if ScreenshotFixtures.opensGlobalFormSheet {
                activeForm = snapshot.globalForms.first
            }
        }
        .refreshable {
            await loadInbox(force: true)
        }
        .sheet(item: $activeQuestion) { question in
            QuestionView(
                request: question.item,
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
        .sheet(item: $activeForm) { form in
            FormView(
                form: form.item,
                onSubmit: { answer in
                    Task {
                        await submitForm(form, answer: answer)
                    }
                },
                onCancel: {
                    Task {
                        await cancelForm(form)
                    }
                },
                isSubmitting: isResolvingForm
            )
            .interactiveDismissDisabled(isResolvingForm)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let errorMessage,
           snapshot.permissions.isEmpty,
           snapshot.questions.isEmpty,
           snapshot.forms.isEmpty {
            FeaturePlaceholderView(
                title: "Inbox",
                subtitle: errorMessage,
                symbol: "exclamationmark.triangle",
                highlights: [
                    "Pull to refresh and retry",
                    "Inbox reads pending permissions, questions, and forms",
                    "Chat keeps working while inbox reloads"
                ]
            )
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: InboxLayout.sectionGap) {
                    if let errorMessage {
                        errorCard(errorMessage)
                    }
                    if let warning = snapshot.warning {
                        errorCard(warning)
                    }

                    if !snapshot.globalForms.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            sectionHeader(title: "Global MCP forms", count: snapshot.globalForms.count)
                            formsCard(snapshot.globalForms)
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        sectionHeader(title: "Permissions", count: snapshot.permissions.count)
                        permissionsCard
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        sectionHeader(title: "Questions", count: snapshot.questions.count)
                        questionsCard
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        sectionHeader(title: "Forms", count: snapshot.sessionForms.count)
                        formsCard(snapshot.sessionForms)
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
                    ForEach(Array(snapshot.permissions.enumerated()), id: \.element.id) { index, scopedPermission in
                        let permission = scopedPermission.item
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(alignment: .top, spacing: 12) {
                                itemBadge(title: "Permission", tint: .orange)

                                VStack(alignment: .leading, spacing: 6) {
                                    serverLine(scopedPermission.tag)
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
                                        await respondToPermission(scopedPermission, reply: .reject)
                                    }
                                }
                                actionButton(title: AppText.allowOnce, fill: Color.appAccent, foreground: Color.appOnAccent) {
                                    Task {
                                        await respondToPermission(scopedPermission, reply: .once)
                                    }
                                }
                                actionButton(title: AppText.allowAll, fill: Color.appWarning.opacity(0.14), foreground: Color.appWarning) {
                                    Task {
                                        await respondToPermission(scopedPermission, reply: .always)
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
                    ForEach(Array(snapshot.questions.enumerated()), id: \.element.id) { index, scopedQuestion in
                        let question = scopedQuestion.item
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(alignment: .top, spacing: 12) {
                                itemBadge(title: "Question", tint: Color.appPrimary)

                                VStack(alignment: .leading, spacing: 6) {
                                    serverLine(scopedQuestion.tag)
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
                                    activeQuestion = scopedQuestion
                                }
                                actionButton(title: "Dismiss", fill: Color.appTertiary, foreground: Color.appPrimary) {
                                    Task {
                                        await rejectQuestion(scopedQuestion)
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

    private func formsCard(_ forms: [ServerScoped<OCFormRequest>]) -> some View {
        SurfaceCard(padding: 0) {
            if forms.isEmpty {
                emptyRow(symbol: "checkmark.circle", text: "No pending forms from the agent.")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(forms.enumerated()), id: \.element.id) { index, scopedForm in
                        let form = scopedForm.item
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(alignment: .top, spacing: 12) {
                                itemBadge(title: form.isGlobal ? "MCP" : "Form", tint: Color.appPrimary)

                                VStack(alignment: .leading, spacing: 6) {
                                    serverLine(scopedForm.tag)
                                    Text(form.title.nilIfBlank ?? "Agent form")
                                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                                        .foregroundStyle(Color.appPrimary)

                                    Text(form.hasUnsupportedFields
                                        ? "Open this form to see fields OpenLens cannot safely submit."
                                        : "\(form.fields.count) field\(form.fields.count == 1 ? "" : "s") ready for review.")
                                        .font(.system(size: 13))
                                        .foregroundStyle(Color.appSecondary)
                                        .lineLimit(3)

                                    if form.isGlobal {
                                        Text("Workspace interaction · no chat owner")
                                            .font(.system(size: 12))
                                            .foregroundStyle(Color.appSecondary)
                                        if let directory = form.globalDirectory {
                                            Text(directory)
                                                .font(.system(size: 12, design: .monospaced))
                                                .foregroundStyle(Color.appSecondary)
                                                .lineLimit(2)
                                        }
                                    }
                                }
                            }

                            HStack(spacing: 10) {
                                actionButton(title: "Open", fill: Color.appAccent, foreground: Color.appOnAccent) {
                                    activeForm = scopedForm
                                }
                                actionButton(title: "Cancel", fill: Color.appTertiary, foreground: Color.appPrimary) {
                                    Task {
                                        await cancelForm(scopedForm)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, InboxLayout.rowPaddingHorizontal)
                        .padding(.vertical, InboxLayout.rowPaddingVertical)

                        if index < forms.count - 1 {
                            SurfaceDivider()
                        }
                    }
                }
            }
        }
    }

    /// Which server a pending item belongs to; nothing at one saved server.
    @ViewBuilder
    private func serverLine(_ tag: ServerTag?) -> some View {
        if let tag {
            ServerBadge(tag: tag)
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
            return snapshot.isEmpty
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
            snapshot = try await registry.loadAggregatedInbox(activeInbox: inboxService)
            viewState = .loaded
        } catch {
            viewState = .error(error.localizedDescription)
        }
    }

    /// Replies go to the server that owns the item, never to whichever one is active.
    private func service(for serverID: String) -> InboxService {
        serverID == registry.activeContext.id
            ? inboxService
            : (registry.context(id: serverID)?.inboxService ?? inboxService)
    }

    private func isActive(_ serverID: String) -> Bool {
        serverID == registry.activeContext.id
    }

    private func respondToPermission(_ scoped: ServerScoped<OCPermissionRequest>, reply: OCPermissionReply) async {
        let permission = scoped.item
        do {
            try await service(for: scoped.serverID).respondToPermission(permission, reply: reply)
            if isActive(scoped.serverID), chatClient.pendingPermission?.id == permission.id {
                chatClient.pendingPermission = nil
                chatClient.showPermissionAlert = false
            }
            await loadInbox(force: true)
        } catch {
            viewState = .error(error.localizedDescription)
        }
    }

    private func submitQuestion(_ scoped: ServerScoped<OCQuestionRequest>, answers: [[String]]) async {
        let question = scoped.item
        do {
            try await service(for: scoped.serverID).respondToQuestion(requestID: question.id, answers: answers)
            if isActive(scoped.serverID), chatClient.pendingQuestion?.id == question.id {
                chatClient.pendingQuestion = nil
                chatClient.showQuestionSheet = false
            }
            activeQuestion = nil
            await loadInbox(force: true)
        } catch {
            viewState = .error(error.localizedDescription)
        }
    }

    private func rejectQuestion(_ scoped: ServerScoped<OCQuestionRequest>) async {
        let question = scoped.item
        do {
            try await service(for: scoped.serverID).rejectQuestion(requestID: question.id)
            if isActive(scoped.serverID), chatClient.pendingQuestion?.id == question.id {
                chatClient.pendingQuestion = nil
                chatClient.showQuestionSheet = false
            }
            activeQuestion = nil
            await loadInbox(force: true)
        } catch {
            viewState = .error(error.localizedDescription)
        }
    }

    private func submitForm(_ scoped: ServerScoped<OCFormRequest>, answer: [String: OCFormValue]) async {
        guard !isResolvingForm else { return }
        isResolvingForm = true
        defer { isResolvingForm = false }
        let form = scoped.item

        do {
            try await service(for: scoped.serverID).respondToForm(form, answer: answer)
            if isActive(scoped.serverID), chatClient.pendingForm?.id == form.id, chatClient.pendingForm?.owner == form.owner {
                chatClient.pendingForm = nil
                chatClient.showFormSheet = false
            }
            activeForm = nil
            await loadInbox(force: true)
        } catch {
            viewState = .error(error.localizedDescription)
        }
    }

    private func cancelForm(_ scoped: ServerScoped<OCFormRequest>) async {
        guard !isResolvingForm else { return }
        isResolvingForm = true
        defer { isResolvingForm = false }
        let form = scoped.item

        do {
            try await service(for: scoped.serverID).cancelForm(form)
            if isActive(scoped.serverID), chatClient.pendingForm?.id == form.id, chatClient.pendingForm?.owner == form.owner {
                chatClient.pendingForm = nil
                chatClient.showFormSheet = false
            }
            activeForm = nil
            await loadInbox(force: true)
        } catch {
            viewState = .error(error.localizedDescription)
        }
    }
}
