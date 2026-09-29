import SwiftUI

struct WorkspaceRootView: View {
    private struct WorkingTreeSummary {
        let fileCount: Int
        let additions: Int
        let deletions: Int

        static let empty = WorkingTreeSummary(fileCount: 0, additions: 0, deletions: 0)
    }

    enum ViewState {
        case idle
        case loading
        case loaded
        case error(String)
    }

    enum PendingWorkspaceAction: String, Identifiable {
        case push
        case pullRequest

        var id: String { rawValue }
    }

    enum WorkspaceActionNotice: Identifiable {
        case info(String)
        case error(String)

        var id: String { message }

        var message: String {
            switch self {
            case .info(let message), .error(let message):
                message
            }
        }

        var icon: String {
            switch self {
            case .info:
                "paperplane"
            case .error:
                "exclamationmark.triangle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .info:
                .secondary
            case .error:
                .orange
            }
        }
    }

    @Bindable var chatClient: ChatClient

    @Environment(AppRouter.self) private var router
    @Environment(\.connection) private var connection
    @Environment(\.workspaceService) private var workspaceService

    @State private var viewState: ViewState = .idle
    @State private var snapshot = WorkspaceSnapshot(
        currentProject: nil,
        projects: [],
        pathInfo: nil,
        vcsInfo: nil,
        commands: [],
        fileItems: [],
        currentPath: nil,
        workingTree: [],
        workingTreeSource: .unavailable
    )
    @State private var browserPath: String?
    @State private var commandSearch = ""
    @State private var switchingProjectID: String?
    @State private var showsFiles = false
    @State private var showsCommands = false
    @State private var activityRefreshToken = 0
    @State private var selectedDiffFile: ReviewFileChange?
    @State private var pendingWorkspaceAction: PendingWorkspaceAction?
    @State private var showsBranchPrompt = false
    @State private var branchNameDraft = ""
    @State private var actionNotice: WorkspaceActionNotice?
    @State private var isInboxPresented = false
    @State private var filteredCommands: [WorkspaceCommandItem] = []
    @State private var displayedProjects: [OCProject] = []
    @State private var workingTreeSummary = WorkingTreeSummary.empty

    var body: some View {
        Group {
            if isInitialLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                content
            }
        }
        .navigationTitle("Workspace")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: browserPath) {
            await loadWorkspace()
        }
        .task(id: chatClient.currentSession?.id) {
            guard chatClient.currentSession != nil else { return }
            await refreshWorkspace()
        }
        .refreshable {
            await refreshWorkspace()
        }
        .onChange(of: chatClient.isLoading) { wasLoading, isLoading in
            guard wasLoading, !isLoading else { return }
            Task {
                await refreshWorkspace()
            }
        }
        .onChange(of: commandSearch) { _, newValue in
            filteredCommands = makeFilteredCommands(
                from: snapshot.commands,
                query: newValue
            )
        }
        .sheet(item: $selectedDiffFile) { file in
            WorkspaceFileDiffSheet(summaryFile: file)
        }
        .sheet(isPresented: $isInboxPresented) {
            NavigationStack {
                InboxRootView(chatClient: chatClient)
            }
        }
        .alert("Change branch", isPresented: $showsBranchPrompt) {
            TextField("feature/my-branch", text: $branchNameDraft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            Button("Switch") {
                Task {
                    await requestBranchSwitch()
                }
            }

            Button(AppText.cancel, role: .cancel) {
                branchNameDraft = ""
            }
        } message: {
            Text("Send a branch switch request through the active session. The agent will ask before doing anything risky.")
        }
        .confirmationDialog(
            workspaceActionDialogTitle,
            isPresented: Binding(
                get: { pendingWorkspaceAction != nil },
                set: { if !$0 { pendingWorkspaceAction = nil } }
            ),
            presenting: pendingWorkspaceAction
        ) { action in
            Button(workspaceActionButtonTitle(for: action)) {
                Task {
                    await performWorkspaceAction(action)
                }
            }
            Button(AppText.cancel, role: .cancel) {
                pendingWorkspaceAction = nil
            }
        } message: { action in
            Text(workspaceActionDialogMessage(for: action))
        }
    }

    private var content: some View {
        Form {
            if let errorMessage {
                Section {
                    Label {
                        Text(errorMessage)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }

            projectSection
            sourceControlSection
            actionsSection
            changedFilesSection
            activitySection
            insightsSection
            filesSection
            commandsSection
        }
        .scrollEdgeEffectStyle(.soft, for: .bottom)
    }

    // MARK: - Project

    private var projectSection: some View {
        Section("Project") {
            LabeledContent("Name", value: currentProjectName)

            if let path = projectLocation {
                pathRow("Location", value: path)
            }

            if let worktree = activeWorktree {
                LabeledContent("Working Directory", value: worktree)
            }

            if let config = snapshot.pathInfo?.config?.nilIfBlank {
                pathRow("Config", value: config)
            }

            if displayedProjects.count > 1 {
                Picker(selection: projectSelection) {
                    ForEach(displayedProjects) { project in
                        Text(project.displayName ?? project.worktree ?? project.id)
                            .tag(project.id)
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text("Recent Projects")
                        if switchingProjectID != nil {
                            ProgressView()
                        }
                    }
                }
                .disabled(switchingProjectID != nil)
            }
        }
    }

    private var projectSelection: Binding<String> {
        Binding(
            get: { displayedProjects.first(where: isCurrentProject)?.id ?? "" },
            set: { projectID in
                guard let project = displayedProjects.first(where: { $0.id == projectID }),
                      !isCurrentProject(project) else { return }
                Task { await switchProject(to: project) }
            }
        )
    }

    // MARK: - Source Control

    private var sourceControlSection: some View {
        Section {
            LabeledContent("Branch") {
                Text(currentBranch)
                    .font(.body.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            LabeledContent("Files", value: "\(workingTreeSummary.fileCount)")
            LabeledContent("Added") {
                Text("+\(workingTreeSummary.additions)")
                    .foregroundStyle(.green)
            }
            LabeledContent("Removed") {
                Text("-\(workingTreeSummary.deletions)")
                    .foregroundStyle(.red)
            }

            if let workingTreeStatusNotice {
                noticeRow(.error(workingTreeStatusNotice))
            }
        } header: {
            Text("Source Control")
        } footer: {
            Text(sourceControlDescription)
        }
        .monospacedDigit()
    }

    private var actionsSection: some View {
        Section {
            Button {
                showsBranchPrompt = true
            } label: {
                Label("Change Branch", systemImage: "arrow.triangle.branch")
            }
            .disabled(!canStartWorkspaceAction)

            Button {
                pendingWorkspaceAction = .push
            } label: {
                Label("Push Current Branch", systemImage: "arrow.up.circle")
            }
            .disabled(!canStartWorkspaceAction)

            Button {
                pendingWorkspaceAction = .pullRequest
            } label: {
                Label("Create Pull Request", systemImage: "arrow.up.right.square")
            }
            .disabled(!canStartWorkspaceAction)

            Button {
                isInboxPresented = true
            } label: {
                Label("Open Inbox", systemImage: "bell")
            }

            if let blockedReason = workspaceActionBlockedReason {
                noticeRow(.error(blockedReason))
            } else if let actionNotice {
                noticeRow(actionNotice)
            }
        } header: {
            Text("Actions")
        } footer: {
            Text("Actions are sent as requests to the active session, so the agent can ask for permission when needed.")
        }
    }

    private var changedFilesSection: some View {
        Section {
            if snapshot.workingTree.isEmpty {
                Text(workingTreeEmptyStateText)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(snapshot.workingTree) { file in
                    Button {
                        selectedDiffFile = file
                    } label: {
                        changedFileRow(file)
                    }
                    .tint(.primary)
                }
            }
        } header: {
            Text("Changed Files")
        } footer: {
            if !snapshot.workingTree.isEmpty {
                Text("\(workingTreeFileCountLabel). Open any file to inspect its full diff.")
            }
        }
    }

    private func changedFileRow(_ file: ReviewFileChange) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                Text("+\(file.additions)")
                    .foregroundStyle(.green)
                Text("-\(file.deletions)")
                    .foregroundStyle(.red)
            }
            .monospacedDigit()
        } label: {
            Text(file.path)
                .font(.body.monospaced())
                .lineLimit(2)
                .truncationMode(.middle)
            Text(file.statusLabel.capitalized)
        }
    }

    // MARK: - Activity & Insights

    private var activitySection: some View {
        Section {
            WorkspaceActivityHeatmap(
                projectID: snapshot.currentProject?.id,
                projectDirectory: snapshot.currentProject?.worktree ?? connection.selectedProjectDirectory,
                projectName: currentProjectName,
                refreshToken: activityRefreshToken
            )
            .padding(.vertical, 4)
        } header: {
            Text("Activity")
        } footer: {
            Text("Last 12 weeks")
        }
    }

    private var insightsSection: some View {
        Section {
            Button {
                openInsights()
            } label: {
                Label("Session Insights", systemImage: "chart.bar.xaxis")
            }
        } header: {
            Text("Insights")
        } footer: {
            Text(insightsFooter)
        }
    }

    private var insightsFooter: String {
        let scope = chatClient.currentSession == nil ? "any session" : "the active session"
        return "Local breakdown of cost, token usage, models, and recent assistant responses for \(scope)."
    }

    private func openInsights() {
        router.navigate(to: .sessionInsights(sessionID: chatClient.currentSession?.id), in: .workspace)
    }

    // MARK: - Files

    private var filesSection: some View {
        Section {
            DisclosureGroup(isExpanded: $showsFiles) {
                if let browserPath {
                    Button {
                        goUpDirectory()
                    } label: {
                        LabeledContent {
                            Text(browserPath)
                                .font(.footnote.monospaced())
                                .lineLimit(1)
                                .truncationMode(.head)
                        } label: {
                            Label("Up", systemImage: "arrow.up.backward")
                        }
                    }
                    .disabled(browserPath == ".")
                }

                if snapshot.fileItems.isEmpty {
                    Text("No file entries returned for this path.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(snapshot.fileItems) { item in
                        fileRow(item)
                    }
                }
            } label: {
                LabeledContent("Files", value: fileCountLabel)
            }
        } footer: {
            Text("Browse the current working directory and send paths back into chat as context.")
        }
    }

    @ViewBuilder
    private func fileRow(_ item: WorkspaceFileItem) -> some View {
        if item.kind == .directory {
            Button {
                browserPath = item.path
            } label: {
                HStack {
                    Label(item.name, systemImage: "folder")
                        .font(.body.monospaced())
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .tint(.primary)
        } else {
            LabeledContent {
                Button("Insert") {
                    insertIntoChat("Inspect file: \(item.absolutePath ?? item.path)")
                }
                .buttonStyle(.borderless)
            } label: {
                Label {
                    Text(item.name)
                        .font(.body.monospaced())
                    Text(item.absolutePath ?? item.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } icon: {
                    Image(systemName: "doc.text")
                }
            }
        }
    }

    // MARK: - Commands

    @ViewBuilder
    private var commandsSection: some View {
        if hasCommands {
            Section {
                DisclosureGroup(isExpanded: $showsCommands) {
                    TextField("Search commands", text: $commandSearch)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    if filteredCommands.isEmpty {
                        Text("No commands available.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(filteredCommands.prefix(6)) { command in
                            commandRow(command)
                        }
                    }
                } label: {
                    LabeledContent("Commands", value: commandCountLabel)
                }
            } footer: {
                Text("Drop a workspace command straight into chat without leaving this tab.")
            }
        }
    }

    private func commandRow(_ command: WorkspaceCommandItem) -> some View {
        LabeledContent {
            Button("Insert") {
                insertIntoChat(command.prompt)
            }
            .buttonStyle(.borderless)
        } label: {
            Text(command.title)
                .font(.body.monospaced())
            if !command.description.isEmpty {
                Text(command.description)
            }
        }
    }

    // MARK: - Rows

    private func pathRow(_ title: String, value: String) -> some View {
        LabeledContent(title) {
            Text(value)
                .font(.footnote.monospaced())
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    private func noticeRow(_ notice: WorkspaceActionNotice) -> some View {
        Label {
            Text(notice.message)
                .font(.footnote)
                .foregroundStyle(.secondary)
        } icon: {
            Image(systemName: notice.icon)
                .foregroundStyle(notice.tint)
        }
    }

    // MARK: - Computed Properties

    private var isInitialLoading: Bool {
        if case .loading = viewState {
            return snapshot.commands.isEmpty && snapshot.fileItems.isEmpty && snapshot.projects.isEmpty
        }
        return false
    }

    private var errorMessage: String? {
        if case .error(let message) = viewState {
            return message
        }
        return nil
    }

    private var hasCommands: Bool {
        !snapshot.commands.isEmpty || !commandSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var commandCountLabel: String {
        let count = min(filteredCommands.count, 6)
        return count == 1 ? "1 result" : "\(count) results"
    }

    private var fileCountLabel: String {
        let count = snapshot.fileItems.count
        return count == 1 ? "1 item" : "\(count) items"
    }

    private var workingTreeCount: Int {
        workingTreeSummary.fileCount
    }

    private var workingTreeFileCountLabel: String {
        let count = workingTreeCount
        return count == 1 ? "1 file" : "\(count) files"
    }

    private var sourceControlDescription: String {
        switch snapshot.workingTreeSource {
        case .gitStatus:
            "Inspect the current uncommitted working-tree diff and run branch, push, or PR actions through the active session."
        case .sessionDiffFallback:
            "Inspect the current workspace changes. This server fell back to session-tracked diffs because repo-wide git status was unavailable."
        case .unavailable:
            "Inspect the current workspace context and run branch, push, or PR actions through the active session."
        }
    }

    private var workingTreeStatusNotice: String? {
        switch snapshot.workingTreeSource {
        case .gitStatus:
            nil
        case .sessionDiffFallback:
            "Repo-wide git status was unavailable from this OpenCode server, so Workspace is showing changes tracked in the active session instead."
        case .unavailable:
            "This OpenCode server did not return working-tree status. Update the server to see repository changes in Workspace."
        }
    }

    private var workingTreeEmptyStateText: String {
        switch snapshot.workingTreeSource {
        case .gitStatus:
            "No uncommitted changes in the active working directory."
        case .sessionDiffFallback:
            "No session-tracked changes were available. Update OpenCode to expose repo-wide git status in Workspace."
        case .unavailable:
            "Working-tree status is unavailable from this OpenCode server."
        }
    }

    private var currentProjectName: String {
        snapshot.currentProject?.displayName
            ?? connection.projectName
            ?? snapshot.pathInfo?.directory
            ?? "No project context"
    }

    private var projectLocation: String? {
        snapshot.currentProject?.worktree?.nilIfBlank
            ?? snapshot.pathInfo?.worktree?.nilIfBlank
            ?? snapshot.pathInfo?.directory?.nilIfBlank
    }

    private var currentBranch: String {
        snapshot.vcsInfo?.branch?.nilIfBlank ?? connection.branch ?? "n/a"
    }

    private var activeWorktree: String? {
        guard let worktree = snapshot.pathInfo?.worktree?.nilIfBlank else { return nil }
        let dir = snapshot.pathInfo?.directory?.nilIfBlank
        guard worktree != dir else { return nil }
        return (worktree as NSString).lastPathComponent
    }

    private var currentWorktreePath: String? {
        snapshot.currentProject?.worktree?.nilIfBlank
            ?? snapshot.pathInfo?.worktree?.nilIfBlank
            ?? projectLocation
    }

    private var workspaceActionBlockedReason: String? {
        if switchingProjectID != nil {
            return "Wait for the current working directory change to finish before starting another workspace action."
        }

        if chatClient.pendingQuestion != nil {
            return "Answer the current question in Chat or Inbox before starting another workspace action."
        }

        if chatClient.pendingPermission != nil {
            return "Resolve the pending permission request in Chat or Inbox before starting another workspace action."
        }

        if chatClient.isLoading {
            return "The active session is busy. Wait for the current task to finish."
        }

        return nil
    }

    private var canStartWorkspaceAction: Bool {
        workspaceActionBlockedReason == nil
    }

    private var workspaceActionDialogTitle: String {
        switch pendingWorkspaceAction {
        case .push:
            "Push current branch?"
        case .pullRequest:
            "Create pull request?"
        case .none:
            "Workspace action"
        }
    }

    // MARK: - Network

    private func workspaceActionButtonTitle(for action: PendingWorkspaceAction) -> String {
        switch action {
        case .push:
            "Push via active session"
        case .pullRequest:
            "Create PR via active session"
        }
    }

    private func workspaceActionDialogMessage(for action: PendingWorkspaceAction) -> String {
        switch action {
        case .push:
            "This sends a push request through the active session so the agent can ask for permission if needed."
        case .pullRequest:
            "This asks the active session to create a pull request for the current branch and surface any follow-up questions through Chat or Inbox."
        }
    }

    private func requestBranchSwitch() async {
        let branchName = branchNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branchName.isEmpty else {
            actionNotice = .error("Enter a branch name before sending the switch request.")
            return
        }

        await submitWorkspacePrompt(
            branchSwitchPrompt(for: branchName),
            successMessage: "Sent a branch switch request to the active session. Check Chat or Inbox for follow-up questions."
        )
        branchNameDraft = ""
    }

    private func performWorkspaceAction(_ action: PendingWorkspaceAction) async {
        pendingWorkspaceAction = nil

        switch action {
        case .push:
            await submitWorkspacePrompt(
                pushPrompt(),
                successMessage: "Sent a push request to the active session. Check Chat or Inbox for permission prompts."
            )
        case .pullRequest:
            await submitWorkspacePrompt(
                pullRequestPrompt(),
                successMessage: "Sent a pull request request to the active session. Check Chat or Inbox for follow-up questions."
            )
        }
    }

    private func submitWorkspacePrompt(_ prompt: String, successMessage: String) async {
        let submitted = await chatClient.submitWorkspaceRequest(prompt)
        if submitted {
            actionNotice = .info(successMessage)
            await refreshWorkspace()
        } else {
            actionNotice = .error(chatClient.errorMessage ?? "Unable to send the workspace action right now.")
        }
    }

    private func branchSwitchPrompt(for branchName: String) -> String {
        var lines = [
            "Switch the active repository to branch `\(branchName)`."
        ]

        if let currentWorktreePath {
            lines.append("Working directory: `\(currentWorktreePath)`.")
        }

        if currentBranch != "n/a" {
            lines.append("Current branch: `\(currentBranch)`.")
        }

        lines.append("If uncommitted changes make checkout unsafe, or if the target branch needs remote tracking setup, stop and ask before proceeding.")
        lines.append("After the checkout attempt, summarize the result.")
        return lines.joined(separator: "\n")
    }

    private func pushPrompt() -> String {
        var lines = [
            "Push the active branch to its configured remote."
        ]

        if let currentWorktreePath {
            lines.append("Working directory: `\(currentWorktreePath)`.")
        }

        if currentBranch != "n/a" {
            lines.append("Branch: `\(currentBranch)`.")
        }

        lines.append("If the upstream remote or target branch is missing or ambiguous, ask me before pushing.")
        lines.append("Summarize the push result when done.")
        return lines.joined(separator: "\n")
    }

    private func pullRequestPrompt() -> String {
        var lines = [
            "Create a pull request for the active branch using the current working directory diff and recent session context."
        ]

        if let currentWorktreePath {
            lines.append("Working directory: `\(currentWorktreePath)`.")
        }

        if currentBranch != "n/a" {
            lines.append("Branch: `\(currentBranch)`.")
        }

        lines.append("Infer the default base branch if possible, but ask me first if the base branch, remote, or PR metadata is ambiguous.")
        lines.append("Share the created pull request link when done.")
        return lines.joined(separator: "\n")
    }

    private func loadWorkspace() async {
        viewState = .loading
        do {
            let loadedSnapshot = try await workspaceService.loadWorkspace(
                path: browserPath,
                sessionID: chatClient.currentSession?.id
            )
            applySnapshot(loadedSnapshot)
            if browserPath == nil {
                browserPath = loadedSnapshot.currentPath
            }
            activityRefreshToken += 1
            viewState = .loaded
        } catch {
            viewState = .error(error.localizedDescription)
        }
    }

    private func refreshWorkspace() async {
        do {
            let loadedSnapshot = try await workspaceService.loadWorkspace(
                path: browserPath,
                sessionID: chatClient.currentSession?.id
            )
            applySnapshot(loadedSnapshot)
            if browserPath == nil {
                browserPath = loadedSnapshot.currentPath
            }
            activityRefreshToken += 1
            viewState = .loaded
        } catch {
            viewState = .error(error.localizedDescription)
        }
    }

    private func goUpDirectory() {
        guard let browserPath = browserPath?.nilIfBlank else { return }
        if browserPath == "." {
            return
        }
        let path = browserPath.hasSuffix("/") ? String(browserPath.dropLast()) : browserPath
        let parent = (path as NSString).deletingLastPathComponent
        self.browserPath = parent.nilIfBlank ?? "."
    }

    private func insertIntoChat(_ text: String) {
        let trimmed = chatClient.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            chatClient.inputText = text
        } else {
            chatClient.inputText += "\n\(text)"
        }
        router.selectedTab = .chat
    }

    private func applySnapshot(_ loadedSnapshot: WorkspaceSnapshot) {
        snapshot = loadedSnapshot
        displayedProjects = makeDisplayedProjects(from: loadedSnapshot)
        filteredCommands = makeFilteredCommands(
            from: loadedSnapshot.commands,
            query: commandSearch
        )
        workingTreeSummary = summarizeWorkingTree(loadedSnapshot.workingTree)
    }

    private func makeFilteredCommands(
        from commands: [WorkspaceCommandItem],
        query: String
    ) -> [WorkspaceCommandItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return commands }
        return commands.filter {
            $0.title.localizedCaseInsensitiveContains(trimmed) ||
            $0.description.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private func makeDisplayedProjects(from snapshot: WorkspaceSnapshot) -> [OCProject] {
        var seenProjectIDs = Set<String>()
        var seenWorktrees = Set<String>()
        var result: [OCProject] = []

        for project in [snapshot.currentProject].compactMap({ $0 }) + snapshot.projects {
            if !seenProjectIDs.insert(project.id).inserted {
                continue
            }

            if let worktree = project.worktree, !worktree.isEmpty {
                if !seenWorktrees.insert(worktree).inserted {
                    continue
                }
            }

            result.append(project)
        }

        return result
    }

    private func summarizeWorkingTree(_ files: [ReviewFileChange]) -> WorkingTreeSummary {
        files.reduce(into: .empty) { summary, file in
            summary = WorkingTreeSummary(
                fileCount: summary.fileCount + 1,
                additions: summary.additions + file.additions,
                deletions: summary.deletions + file.deletions
            )
        }
    }

    private func isCurrentProject(_ project: OCProject) -> Bool {
        if let currentID = snapshot.currentProject?.id, currentID == project.id {
            return true
        }
        return snapshot.currentProject?.worktree == project.worktree
    }

    private func switchProject(to project: OCProject) async {
        guard switchingProjectID == nil else { return }

        switchingProjectID = project.id
        defer { switchingProjectID = nil }

        await connection.setProjectContext(directory: project.worktree)
        browserPath = "."
        await chatClient.reloadForProjectContextChange()
        await refreshWorkspace()
    }
}

private struct WorkspaceFileDiffSheet: View {
    let summaryFile: ReviewFileChange

    @Environment(\.workspaceService) private var workspaceService

    @State private var file: ReviewFileChange
    @State private var isLoading = false

    init(summaryFile: ReviewFileChange) {
        self.summaryFile = summaryFile
        _file = State(initialValue: summaryFile)
    }

    var body: some View {
        FileDiffDetailView(file: file)
            .overlay(alignment: .top) {
                if isLoading {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading file diff…")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.appSecondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.appSurface, in: Capsule())
                    .padding(.top, 12)
                }
            }
            .task(id: summaryFile.id) {
                await loadDetail()
            }
    }

    private func loadDetail() async {
        guard !summaryFile.hasReadableDiff else { return }
        isLoading = true
        file = await workspaceService.loadWorkingTreeFile(summary: summaryFile)
        isLoading = false
    }
}

// MARK: - Activity Heatmap

/// Siatka aktywności projektu — 12 tygodni × 7 dni.
private struct WorkspaceActivityHeatmap: View {

    private struct TaskKey: Hashable {
        let projectID: String?
        let projectDirectory: String?
        let projectName: String
        let refreshToken: Int
    }

    @Environment(\.sessionsService) private var sessionsService

    let projectID: String?
    let projectDirectory: String?
    let projectName: String
    let refreshToken: Int

    private let weekCount = 12
    private let columnSpacing: CGFloat = 3
    private let rowSpacing: CGFloat = 2
    private let cellHeightRatio: CGFloat = 0.58
    @State private var cells = Self.emptyCells(weekCount: 12)
    @State private var hasLoaded = false
    @State private var availableWidth: CGFloat = 0

    private var taskKey: TaskKey {
        TaskKey(
            projectID: projectID,
            projectDirectory: projectDirectory,
            projectName: projectName,
            refreshToken: refreshToken
        )
    }

    private var activeDayCount: Int {
        cells.flatMap { $0 }.filter { $0 > 0 }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { proxy in
                let cellWidth = cellSize(for: proxy.size.width)
                let cellHeight = heatmapCellHeight(for: cellWidth)

                HStack(alignment: .top, spacing: columnSpacing) {
                    ForEach(0..<weekCount, id: \.self) { weekIndex in
                        VStack(spacing: rowSpacing) {
                            ForEach(0..<7, id: \.self) { dayIndex in
                                RoundedRectangle(cornerRadius: max(2, cellHeight * 0.24), style: .continuous)
                                    .fill(cellColor(level: cells[weekIndex][dayIndex]))
                                    .frame(width: cellWidth, height: cellHeight)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
            .frame(height: heatmapHeight(for: availableWidth))
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear {
                            updateAvailableWidth(proxy.size.width)
                        }
                        .onChange(of: proxy.size.width) { _, newWidth in
                            updateAvailableWidth(newWidth)
                        }
                }
            }

            HStack {
                Text("Less")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                HStack(spacing: 3) {
                    ForEach(0..<4, id: \.self) { level in
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(cellColor(level: level))
                            .frame(width: 10, height: 10)
                    }
                }
                Text("More")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            if hasLoaded && activeDayCount == 0 {
                Text("No message activity yet for this project.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: taskKey) {
            await loadActivity()
        }
    }

    private func cellColor(level: Int) -> Color {
        switch level {
        case 0: return Color.appTertiary
        case 1: return Color.appPrimary.opacity(0.18)
        case 2: return Color.appPrimary.opacity(0.42)
        default: return Color.appPrimary.opacity(0.72)
        }
    }

    private func cellSize(for availableWidth: CGFloat) -> CGFloat {
        let totalSpacing = CGFloat(weekCount - 1) * columnSpacing
        let width = max(availableWidth - totalSpacing, 0)
        return width / CGFloat(weekCount)
    }

    private func heatmapCellHeight(for cellWidth: CGFloat) -> CGFloat {
        cellWidth * cellHeightRatio
    }

    private func heatmapHeight(for availableWidth: CGFloat) -> CGFloat {
        let cellWidth = cellSize(for: availableWidth)
        let cellHeight = heatmapCellHeight(for: cellWidth)
        return (cellHeight * 7) + (rowSpacing * 6)
    }

    private func updateAvailableWidth(_ width: CGFloat) {
        guard width > 0 else { return }
        availableWidth = width
    }

    private func loadActivity() async {
        let calendar = Calendar.current
        let startDate = firstWeekStart(calendar: calendar)

        do {
            let activityDays = try await sessionsService.loadActivityDays(
                projectID: projectID,
                directory: projectDirectory,
                since: startDate,
                calendar: calendar
            )
            cells = makeCells(from: activityDays, calendar: calendar)
            hasLoaded = true
        } catch {
            cells = Self.emptyCells(weekCount: weekCount)
            hasLoaded = true
        }
    }

    private func makeCells(from activityDays: [WorkspaceActivityDay], calendar: Calendar) -> [[Int]] {
        let firstWeekStart = firstWeekStart(calendar: calendar)
        let countsByDate = Dictionary(uniqueKeysWithValues: activityDays.map {
            (calendar.startOfDay(for: $0.date), $0.turnCount)
        })
        let maxCount = countsByDate.values.max() ?? 0

        return (0..<weekCount).map { weekIndex in
            (0..<7).map { dayIndex in
                guard let date = calendar.date(byAdding: .day, value: (weekIndex * 7) + dayIndex, to: firstWeekStart) else {
                    return 0
                }
                let count = countsByDate[calendar.startOfDay(for: date)] ?? 0
                return level(for: count, maxCount: maxCount)
            }
        }
    }

    private func firstWeekStart(calendar: Calendar) -> Date {
        let today = Date()
        let startOfCurrentWeek = calendar.dateInterval(of: .weekOfYear, for: today)?.start
            ?? calendar.startOfDay(for: today)
        return calendar.date(byAdding: .weekOfYear, value: -(weekCount - 1), to: startOfCurrentWeek)
            ?? startOfCurrentWeek
    }

    private func level(for count: Int, maxCount: Int) -> Int {
        guard count > 0 else { return 0 }
        guard maxCount > 1 else { return 1 }

        let ratio = Double(count) / Double(maxCount)
        switch ratio {
        case 0.75...:
            return 3
        case 0.4...:
            return 2
        default:
            return 1
        }
    }

    private static func emptyCells(weekCount: Int) -> [[Int]] {
        Array(repeating: Array(repeating: 0, count: 7), count: weekCount)
    }
}
