import SwiftUI

private enum WorkspaceLayout {
    static let screenInset: CGFloat = 20
    static let screenVerticalPadding: CGFloat = 24
    static let sectionGap: CGFloat = 28
    static let groupGap: CGFloat = 16
    static let compactGap: CGFloat = 8
    static let chipGap: CGFloat = 12
    static let rowPaddingHorizontal: CGFloat = 16
    static let rowPaddingVertical: CGFloat = 14
}

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
                Color.appPrimary
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
    @State private var showsProjectDetails = false
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
                    .tint(Color.appSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.appBackground)
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
        ScrollView {
            VStack(alignment: .leading, spacing: WorkspaceLayout.sectionGap) {
                projectHeaderCard

                sourceControlSection

                activitySection

                insightsSection

                if let errorMessage {
                    errorCard(errorMessage)
                }

                detailsSection
                filesSection
                commandsSection
            }
            .padding(.horizontal, WorkspaceLayout.screenInset)
            .padding(.bottom, WorkspaceLayout.screenVerticalPadding)
        }
        .background(Color.appBackground)
    }

    // MARK: - Project Header

    private var projectHeaderCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(currentProjectName)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.appPrimary)
                    .lineLimit(2)

                Spacer(minLength: 12)
            }

            if let path = projectLocation {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "folder")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.appSecondary)
                        .frame(width: 16)

                    Text(path)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.appSecondary)
                        .lineLimit(2)
                }
            }

            if hasBranchOrWorktree {
                HStack(alignment: .top, spacing: 18) {
                    headerMetaBlock(title: "Branch", value: currentBranch)

                    if let worktree = activeWorktree {
                        Rectangle()
                            .fill(Color.appSeparator)
                            .frame(width: 1, height: 28)

                        headerMetaBlock(title: "Working Directory", value: worktree)
                    }

                    Spacer(minLength: 0)
                }
            }

            Rectangle()
                .fill(Color.appSeparator)
                .frame(height: 1)
                .opacity(0.9)
        }
    }

    private var projectPickerMenu: some View {
        Menu {
            ForEach(displayedProjects) { project in
                if isCurrentProject(project) {
                    Label(project.displayName ?? project.worktree ?? project.id, systemImage: "checkmark")
                        .font(.system(size: 15, design: .rounded))
                } else {
                    Button {
                        Task { await switchProject(to: project) }
                    } label: {
                        Text(project.displayName ?? project.worktree ?? project.id)
                    }
                }
            }
        } label: {
            Group {
                if switchingProjectID != nil {
                    ProgressView()
                        .tint(Color.appAccent)
                        .frame(width: 14, height: 14)
                } else {
                    HStack(spacing: 6) {
                        Text("Recently opened projects")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))

                        Image(systemName: "arrow.left.arrow.right")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(Color.appPrimary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.appSurface, in: Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.appSeparator, lineWidth: 1)
            )
        }
        .menuStyle(.automatic)
        .disabled(switchingProjectID != nil)
    }

    private func headerMetaBlock(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.appSecondary)
                .textCase(.uppercase)
                .kerning(0.4)

            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.appPrimary)
                .lineLimit(1)
        }
    }

    // MARK: - Activity Heatmap

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "ACTIVITY", detail: "last 12 weeks")

            SurfaceCard {
                WorkspaceActivityHeatmap(
                    projectID: snapshot.currentProject?.id,
                    projectDirectory: snapshot.currentProject?.worktree ?? connection.selectedProjectDirectory,
                    projectName: currentProjectName,
                    refreshToken: activityRefreshToken
                )
            }
        }
    }

    private var insightsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "INSIGHTS", detail: insightsDetail)

            SurfaceCard {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Session insights")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.appPrimary)

                        Text("Open a local breakdown of cost, token usage, models, and recent assistant responses for the active session.")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.appSecondary)
                    }

                    Spacer(minLength: 12)

                    Button("Open") {
                        openInsights()
                    }
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.appPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.appSurface, in: Capsule())
                    .overlay(
                        Capsule()
                            .stroke(Color.appSeparator, lineWidth: 1)
                    )
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Source Control

    private var sourceControlSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "SOURCE CONTROL", detail: sourceControlDetail)

            SurfaceCard {
                VStack(alignment: .leading, spacing: WorkspaceLayout.groupGap) {
                    Text(sourceControlDescription)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.appSecondary)

                    if let workingTreeStatusNotice {
                        sourceControlInlineNotice(.error(workingTreeStatusNotice))
                    }

                    HStack(spacing: 10) {
                        sourceControlSummaryMetric(title: "Files", value: "\(workingTreeCount)", tint: Color.appPrimary)
                        sourceControlSummaryMetric(title: "Added", value: "+\(workingTreeAdditions)", tint: .green)
                        sourceControlSummaryMetric(title: "Removed", value: "-\(workingTreeDeletions)", tint: .red)
                    }

                    HStack(spacing: 10) {
                        sourceControlContextPill(title: "Branch", value: currentBranch)
                        sourceControlContextPill(title: "Working Directory", value: sourceControlWorktreeLabel)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        if displayedProjects.count > 1 {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Recently opened projects")
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .foregroundStyle(Color.appPrimary)

                                Text("Switch to another project previously opened by this OpenCode server.")
                                    .font(.system(size: 12, design: .rounded))
                                    .foregroundStyle(Color.appSecondary)

                                projectPickerMenu
                            }
                        }

                        Button {
                            showsBranchPrompt = true
                        } label: {
                            Label("Change branch", systemImage: "arrow.triangle.branch")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.appPrimary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color.appSurface, in: Capsule())
                                .overlay(
                                    Capsule()
                                        .stroke(Color.appSeparator, lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(!canStartWorkspaceAction)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        sourceControlActionButton(
                            title: "Push current branch",
                            systemImage: "arrow.up.circle",
                            fill: Color.appSurface,
                            foreground: Color.appPrimary,
                            showsBorder: true
                        ) {
                            pendingWorkspaceAction = .push
                        }
                        .disabled(!canStartWorkspaceAction)

                        sourceControlActionButton(
                            title: "Create pull request",
                            systemImage: "arrow.up.right.square",
                            fill: Color.appAccent,
                            foreground: Color.appOnAccent,
                            showsBorder: false
                        ) {
                            pendingWorkspaceAction = .pullRequest
                        }
                        .disabled(!canStartWorkspaceAction)

                        sourceControlActionButton(
                            title: "Open Inbox",
                            systemImage: "bell",
                            fill: Color.appSurface,
                            foreground: Color.appPrimary,
                            showsBorder: true
                        ) {
                            isInboxPresented = true
                        }
                    }

                    if let blockedReason = workspaceActionBlockedReason {
                        sourceControlInlineNotice(.error(blockedReason))
                    } else if let actionNotice {
                        sourceControlInlineNotice(actionNotice)
                    }
                }
            }

            sourceControlChangedFilesCard
        }
    }

    private var insightsDetail: String {
        chatClient.currentSession == nil ? "open any session" : "active session"
    }

    private func openInsights() {
        router.navigate(to: .sessionInsights(sessionID: chatClient.currentSession?.id), in: .workspace)
    }

    // MARK: - Collapsible Sections

    private var detailsSection: some View {
        collapsibleSection(
            title: "Project details",
            detail: "Branch and paths",
            isExpanded: $showsProjectDetails
        ) {
            SurfaceCard(padding: 0) {
                VStack(spacing: 0) {
                    infoRow(title: "Branch", value: snapshot.vcsInfo?.branch ?? connection.branch ?? "Unknown")
                    SurfaceDivider()
                    infoRow(title: "Current path", value: snapshot.currentPath ?? ".")
                    SurfaceDivider()
                    infoRow(title: "Working Directory", value: snapshot.pathInfo?.worktree ?? "Unknown")
                    SurfaceDivider()
                    infoRow(title: "Config", value: snapshot.pathInfo?.config ?? "Unknown")
                }
            }
        }
    }

    @ViewBuilder
    private var commandsSection: some View {
        if hasCommands {
            collapsibleSection(
                title: "Commands",
                detail: commandCountLabel,
                isExpanded: $showsCommands
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Drop a workspace command straight into chat without leaving this tab.")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.appSecondary)

                    SurfaceCard {
                        VStack(alignment: .leading, spacing: WorkspaceLayout.groupGap) {
                            TextField("Search commands", text: $commandSearch)
                                .textFieldStyle(.plain)
                                .font(.system(size: 15))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(Color.appTertiary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                            if filteredCommands.isEmpty {
                                Text("No commands available.")
                                    .font(.system(size: 14))
                                    .foregroundStyle(Color.appSecondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                VStack(spacing: 0) {
                                    ForEach(Array(filteredCommands.prefix(6).enumerated()), id: \.element.id) { index, command in
                                        commandRow(command)

                                        if index < min(filteredCommands.count, 6) - 1 {
                                            SurfaceDivider()
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var filesSection: some View {
        collapsibleSection(
            title: "Files",
            detail: fileCountLabel,
            isExpanded: $showsFiles
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Browse the current working directory and send paths back into chat as context.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.appSecondary)

                SurfaceCard(padding: 0) {
                    VStack(spacing: 0) {
                        if let browserPath {
                            HStack(spacing: 10) {
                                Button {
                                    goUpDirectory()
                                } label: {
                                    Label("Up", systemImage: "arrow.up.backward")
                                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                                        .foregroundStyle(Color.appPrimary)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                        .background(Color.appSurface, in: Capsule())
                                        .overlay(
                                            Capsule()
                                                .stroke(Color.appSeparator, lineWidth: 1)
                                        )
                                }
                                .buttonStyle(.plain)

                                Text(browserPath)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(Color.appSecondary)
                                    .lineLimit(1)

                                Spacer()
                            }
                            .padding(.horizontal, WorkspaceLayout.rowPaddingHorizontal)
                            .padding(.vertical, WorkspaceLayout.rowPaddingVertical)
                            .background(Color.appTertiary)

                            if !snapshot.fileItems.isEmpty {
                                SurfaceDivider()
                            }
                        }

                        if snapshot.fileItems.isEmpty {
                            emptyRow("No file entries returned for this path.")
                        } else {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(snapshot.fileItems.enumerated()), id: \.element.id) { index, item in
                                    fileRow(item)

                                    if index < snapshot.fileItems.count - 1 {
                                        SurfaceDivider()
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Rows

    private func commandRow(_ command: WorkspaceCommandItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(command.title)
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.appPrimary)
                if !command.description.isEmpty {
                    Text(command.description)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.appSecondary)
                }
            }

            Spacer()

            Button("Insert") {
                insertIntoChat(command.prompt)
            }
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.appPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.appSurface, in: Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.appSeparator, lineWidth: 1)
            )
            .buttonStyle(.plain)
        }
        .padding(.horizontal, WorkspaceLayout.rowPaddingHorizontal)
        .padding(.vertical, 12)
    }

    private func fileRow(_ item: WorkspaceFileItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.kind == .directory ? "folder.fill" : "doc.text")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(item.kind == .directory ? Color.appPrimary : Color.appSecondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.appPrimary)
                Text(item.absolutePath ?? item.path)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.appSecondary)
                    .lineLimit(1)
            }

            Spacer()

            if item.kind == .directory {
                Button("Open") {
                    browserPath = item.path
                }
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.appPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.appSurface, in: Capsule())
                .overlay(
                    Capsule()
                        .stroke(Color.appSeparator, lineWidth: 1)
                )
                .buttonStyle(.plain)
            } else {
                Button("Insert") {
                    insertIntoChat("Inspect file: \(item.absolutePath ?? item.path)")
                }
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.appPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.appSurface, in: Capsule())
                .overlay(
                    Capsule()
                        .stroke(Color.appSeparator, lineWidth: 1)
                )
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, WorkspaceLayout.rowPaddingHorizontal)
        .padding(.vertical, WorkspaceLayout.rowPaddingVertical)
    }

    private func infoRow(title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.appPrimary)
                Text(value)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.appSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer()
        }
        .padding(.horizontal, WorkspaceLayout.rowPaddingHorizontal)
        .padding(.vertical, WorkspaceLayout.rowPaddingVertical)
    }

    private func emptyRow(_ text: String) -> some View {
        HStack {
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(Color.appSecondary)
            Spacer()
        }
        .padding(.horizontal, WorkspaceLayout.rowPaddingHorizontal)
        .padding(.vertical, WorkspaceLayout.rowPaddingVertical)
    }

    private var sourceControlChangedFilesCard: some View {
        SurfaceCard(padding: 0) {
            if snapshot.workingTree.isEmpty {
                emptyRow(workingTreeEmptyStateText)
            } else {
                LazyVStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text("Changed files")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.appPrimary)

                            Spacer(minLength: 8)

                            Text(workingTreeFileCountLabel)
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(Color.appSecondary)
                        }

                        Text("Open any file to inspect the full diff for the current working directory.")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.appSecondary)
                    }
                    .padding(.horizontal, WorkspaceLayout.rowPaddingHorizontal)
                    .padding(.vertical, WorkspaceLayout.rowPaddingVertical)
                    .background(Color.appTertiary)

                    SurfaceDivider()

                    ForEach(Array(snapshot.workingTree.enumerated()), id: \.element.id) { index, file in
                        Button {
                            selectedDiffFile = file
                        } label: {
                            FileChangeRow(file: file)
                                .padding(.horizontal, WorkspaceLayout.rowPaddingHorizontal)
                                .padding(.vertical, WorkspaceLayout.rowPaddingVertical)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if index < snapshot.workingTree.count - 1 {
                            SurfaceDivider()
                        }
                    }
                }
            }
        }
    }

    private func sourceControlSummaryMetric(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(Color.appSecondary)
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.appTertiary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func sourceControlContextPill(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.appSecondary)
                .textCase(.uppercase)
                .kerning(0.4)

            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.appPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.appTertiary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func sourceControlActionButton(
        title: String,
        systemImage: String,
        fill: Color,
        foreground: Color,
        showsBorder: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(foreground)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(fill, in: Capsule())
                .overlay(
                    Capsule()
                        .stroke(showsBorder ? Color.appSeparator : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func sourceControlInlineNotice(_ notice: WorkspaceActionNotice) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: notice.icon)
                .foregroundStyle(notice.tint)
            Text(notice.message)
                .font(.system(size: 13))
                .foregroundStyle(Color.appSecondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(Color.appTertiary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Layout Helpers

    private func collapsibleSection<Content: View>(
        title: String,
        detail: String,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) {
                    isExpanded.wrappedValue.toggle()
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(title.uppercased())
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.appSecondary)
                        .kerning(0.5)

                    Spacer(minLength: 8)

                    Text(detail)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.appSecondary)

                    Image(systemName: isExpanded.wrappedValue ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.appSecondary)
                }
            }
            .buttonStyle(.plain)

            if isExpanded.wrappedValue {
                content()
            }
        }
    }

    private func sectionHeader(title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.appSecondary)
                .kerning(0.5)

            Spacer(minLength: 8)

            Text(detail)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Color.appSecondary)
        }
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

    private var sourceControlDetail: String {
        switch snapshot.workingTreeSource {
        case .gitStatus:
            workingTreeCount == 0 ? "clean working tree" : workingTreeFileCountLabel
        case .sessionDiffFallback:
            workingTreeCount == 0 ? "session fallback" : workingTreeFileCountLabel
        case .unavailable:
            "status unavailable"
        }
    }

    private var workingTreeCount: Int {
        workingTreeSummary.fileCount
    }

    private var workingTreeAdditions: Int {
        workingTreeSummary.additions
    }

    private var workingTreeDeletions: Int {
        workingTreeSummary.deletions
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

    private var hasBranchOrWorktree: Bool {
        let branch = snapshot.vcsInfo?.branch?.nilIfBlank ?? connection.branch
        return branch != nil || activeWorktree != nil
    }

    private var sourceControlWorktreeLabel: String {
        activeWorktree
            ?? snapshot.currentProject?.displayName
            ?? currentProjectName
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
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.appSecondary)
                HStack(spacing: 3) {
                    ForEach(0..<4, id: \.self) { level in
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(cellColor(level: level))
                            .frame(width: 10, height: 10)
                    }
                }
                Text("More")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.appSecondary)
                Spacer()
            }

            if hasLoaded && activeDayCount == 0 {
                Text("No message activity yet for this project.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.appSecondary)
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
