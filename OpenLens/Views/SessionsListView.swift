import SwiftUI

/// Pulsing green dot indicating an active/busy session.
private struct ActivityIndicatorDot: View {
    @State private var pulsing = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.green.opacity(0.3))
                .frame(width: 18, height: 18)
                .scaleEffect(pulsing ? 1.4 : 1.0)
                .opacity(pulsing ? 0 : 1)
            Circle()
                .fill(Color.green)
                .frame(width: 10, height: 10)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: false)) {
                pulsing = true
            }
        }
    }
}

/// Session list view with create, delete, and select.
/// Uses SessionsService directly with view-local state.
struct SessionsListView: View {
    private struct NewSessionRequest: Identifiable {
        let id = UUID()
    }

    private struct SessionProjectGroup: Identifiable {
        let id: String
        let title: String
        let subtitle: String?
        let sessions: [OCSession]

        var visibleSessions: [OCSession] {
            Array(sessions.prefix(Self.collapsedSessionLimit))
        }

        var hiddenSessionCount: Int {
            max(sessions.count - Self.collapsedSessionLimit, 0)
        }

        static let collapsedSessionLimit = 4
    }

    private static let sessionExpansionAnimation: Animation = .spring(response: 0.28, dampingFraction: 0.9)

    // MARK: - View State

    enum InitialState {
        case loaded([OCSession])
        case error(String)
    }

    enum ViewState {
        case idle
        case loading
        case loaded
        case error(String)
    }

    @State private var viewState: ViewState
    @State private var sessions: [OCSession]
    @State private var sessionStatuses: [String: OCSessionStatus]

    @State private var newSessionRequest: NewSessionRequest?
    @State private var sessionToDelete: OCSession?
    @State private var showDeleteConfirmation = false
    @State private var expandedProjectIDs = Set<String>()

    var onSelect: (OCSession) -> Void

    @Environment(\.sessionsService) private var sessionsService

    init(
        initialState: InitialState,
        onSelect: @escaping (OCSession) -> Void
    ) {
        self.onSelect = onSelect

        switch initialState {
        case .loaded(let sessions):
            self._viewState = State(initialValue: .loaded)
            self._sessions = State(initialValue: sessions)
        case .error(let message):
            self._viewState = State(initialValue: .error(message))
            self._sessions = State(initialValue: [])
        }

        self._sessionStatuses = State(initialValue: [:])
    }

    // MARK: - Convenience

    private var isLoading: Bool {
        if case .loading = viewState { return true }
        return false
    }

    private var errorMessage: String? {
        if case .error(let msg) = viewState { return msg }
        return nil
    }

    private var groupedSessions: [SessionProjectGroup] {
        var groupedByID: [String: [OCSession]] = [:]
        var groupOrder: [String] = []
        var titles: [String: String] = [:]
        var subtitles: [String: String?] = [:]

        for session in sessions {
            let groupID = projectGroupID(for: session)
            if groupedByID[groupID] == nil {
                groupOrder.append(groupID)
            }
            groupedByID[groupID, default: []].append(session)
            titles[groupID] = projectTitle(for: session)
            subtitles[groupID] = projectSubtitle(for: session)
        }

        return groupOrder.compactMap { groupID in
            guard let groupedSessions = groupedByID[groupID] else { return nil }
            return SessionProjectGroup(
                id: groupID,
                title: titles[groupID] ?? AppText.projectFallback,
                subtitle: subtitles[groupID] ?? nil,
                sessions: groupedSessions
            )
        }
    }

    // MARK: - Body

    var body: some View {
        Group {
            if isLoading && sessions.isEmpty {
                ProgressView()
                    .tint(Color.appSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage, sessions.isEmpty {
                SessionsLoadErrorView(
                    message: errorMessage,
                    retry: retryLoadingSessions
                )
            } else if sessions.isEmpty {
                emptyState
            } else {
                sessionList
            }
        }
        .background(Color.appBackground)
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle(AppText.sessions)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    presentNewSessionSheet()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 16))
                        .foregroundStyle(Color.appPrimary)
                }
            }
        }
        .sheet(item: $newSessionRequest) { _ in
            NewSessionSheet { session in
                handleCreatedSession(session)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackground(Color.appBackground)
        }
        .confirmationDialog(
            AppText.deleteSession,
            isPresented: $showDeleteConfirmation,
            presenting: sessionToDelete
        ) { session in
            Button("\(AppText.delete) \"\(session.title)\"", role: .destructive) {
                deleteSession(session)
            }
            Button(AppText.cancel, role: .cancel) {}
        } message: { _ in
            Text(AppText.deleteSessionMessage)
        }
        .task {
            await loadSessionStatuses()
        }
    }

    // MARK: - Session List

    private var sessionList: some View {
        ScrollView {
            LazyVStack(spacing: 18) {
                ForEach(groupedSessions) { group in
                    projectSection(group)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 16)
        }
        .refreshable {
            await loadSessions()
        }
    }

    private func projectSection(_ group: SessionProjectGroup) -> some View {
        let isExpanded = expandedProjectIDs.contains(group.id)
        let displayedSessions = isExpanded ? group.sessions : group.visibleSessions

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading) {
                    HStack(alignment: .center) {
                        Image(systemName: "folder")
                            .font(.system(size: 12, design: .rounded))
                            .foregroundStyle(Color.appSecondary)

                        Text(group.title)
                            .font(.system(size: 18, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.appPrimary)
                            .lineLimit(1)

                        Text("\u{00B7}")
                            .font(.system(size: 12, design: .rounded))
                            .foregroundStyle(Color.appSecondary)

                        Text(AppText.groupedProjectCount(group.sessions.count))
                            .font(.system(size: 12, design: .rounded))
                            .foregroundStyle(Color.appSecondary)
                    }
                }

                Spacer()

                if group.hiddenSessionCount > 0 {
                    Button {
                        toggleProjectExpansion(group.id)
                    } label: {
                        Text(isExpanded ? AppText.showFewerSessions : AppText.showMoreSessions(group.hiddenSessionCount))
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.appAccent)
                    }
                    .buttonStyle(.plain)
                }
            }

            VStack(spacing: 0) {
                ForEach(Array(displayedSessions.enumerated()), id: \.element.id) { index, session in
                    Button {
                        onSelect(session)
                    } label: {
                        sessionRow(session)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) {
                            sessionToDelete = session
                            showDeleteConfirmation = true
                        } label: {
                            Label(AppText.delete, systemImage: "trash")
                        }
                    }
                    .transition(.asymmetric(
                        insertion: .opacity
                            .combined(with: .move(edge: .top))
                            .combined(with: .scale(scale: 0.98, anchor: .top)),
                        removal: .opacity
                            .combined(with: .scale(scale: 0.98, anchor: .top))
                    ))
                }
            }
        }
    }

    private func sessionRow(_ session: OCSession) -> some View {
        let isBusy = sessionStatuses[session.id]?.type == .busy

        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title.isEmpty ? AppText.titleUntitled : session.title)
                    .font(.system(size: 16, weight: .regular, design: .rounded))
                    .foregroundStyle(Color.appPrimary)
                    .lineLimit(1)

                if isBusy {
                    HStack(spacing: 6) {
                        ActivityIndicatorDot()
                            .frame(width: 10, height: 10)
                        Text(AppText.working)
                    }
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.green)
                } else {
                    Text(formattedDate(session.updatedAt))
                        .font(.system(size: 14, design: .rounded))
                        .foregroundStyle(Color.appSecondary)
                }

                if let workspaceName = session.workspaceDisplayName {
                    HStack(spacing: 5) {
                        Image(systemName: "folder")
                            .font(.system(size: 10, weight: .medium))
                        Text(workspaceName)
                            .lineLimit(1)
                    }
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(Color.appSecondary.opacity(0.86))
                    .accessibilityLabel("\(AppText.workspace): \(workspaceName)")
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(Color.appSecondary.opacity(0.7))
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 20) {
            RoundedRectangle(cornerRadius: 20)
                .fill(Color.appTertiary)
                .frame(width: 72, height: 72)
                .overlay {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(Color.appSecondary)
                }

            VStack(spacing: 6) {
                Text(AppText.emptySessionsTitle)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.appPrimary)

                Text(AppText.emptySessionsSubtitle)
                    .font(.system(size: 14, design: .rounded))
                    .foregroundStyle(Color.appSecondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                presentNewSessionSheet()
            } label: {
                Text(AppText.newSession)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.appOnAccent)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 13)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color.appAccent)
                    )
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Side Effects (Service calls)

    private func loadSessions() async {
        guard !Task.isCancelled else { return }
        viewState = .loading
        do {
            async let sessionList = sessionsService.listSessions()
            async let statuses = (try? sessionsService.getSessionStatuses()) ?? [:]
            let (result, statusMap) = try await (sessionList, statuses)
            guard !Task.isCancelled else { return }
            sessions = result
            sessionStatuses = statusMap
            pruneExpandedProjects(using: result)
            viewState = .loaded
        } catch is CancellationError {
            debugPrint("loadSessions cancelled during view teardown")
            return
        } catch {
            guard !Task.isCancelled else { return }
            viewState = .error(error.localizedDescription)
        }
    }

    private func loadSessionStatuses() async {
        guard !sessions.isEmpty, !Task.isCancelled else { return }
        let statuses = (try? await sessionsService.getSessionStatuses()) ?? [:]
        guard !Task.isCancelled else { return }
        sessionStatuses = statuses
    }

    private func retryLoadingSessions() {
        Task {
            await loadSessions()
        }
    }

    private func presentNewSessionSheet() {
        newSessionRequest = NewSessionRequest()
    }

    private func handleCreatedSession(_ session: OCSession) {
        sessions.insert(session, at: 0)
        pruneExpandedProjects(using: sessions)
        onSelect(session)
    }

    private func deleteSession(_ session: OCSession) {
        Task {
            do {
                try await sessionsService.deleteSession(session)
                sessions.removeAll { $0.id == session.id }
                pruneExpandedProjects(using: sessions)
            } catch {
                viewState = .error(error.localizedDescription)
            }
        }
    }

    // MARK: - Helpers

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private func formattedDate(_ timestamp: Double) -> String {
        guard timestamp > 0 else { return "" }
        let date = Date(timeIntervalSince1970: timestamp)
        return Self.relativeDateFormatter.localizedString(for: date, relativeTo: Date())
    }

    private func toggleProjectExpansion(_ groupID: String) {
        withAnimation(Self.sessionExpansionAnimation) {
            if expandedProjectIDs.contains(groupID) {
                expandedProjectIDs.remove(groupID)
            } else {
                expandedProjectIDs.insert(groupID)
            }
        }
    }

    private func pruneExpandedProjects(using sessions: [OCSession]) {
        let validGroupIDs = Set(sessions.map(projectGroupID(for:)))
        expandedProjectIDs = expandedProjectIDs.intersection(validGroupIDs)
    }

    private func projectGroupID(for session: OCSession) -> String {
        if let directory = normalizedDirectory(for: session), !directory.isEmpty {
            return "directory:\(directory)"
        }

        if let projectID = session.projectID?.trimmingCharacters(in: .whitespacesAndNewlines), !projectID.isEmpty {
            return "projectID:\(projectID)"
        }

        return "unknown"
    }

    private func projectTitle(for session: OCSession) -> String {
        if let directory = normalizedDirectory(for: session) {
            let lastComponent = URL(fileURLWithPath: directory).lastPathComponent
            if !lastComponent.isEmpty {
                return lastComponent
            }
        }

        if let projectID = session.projectID?.trimmingCharacters(in: .whitespacesAndNewlines), !projectID.isEmpty {
            return projectID
        }

        return AppText.projectFallback
    }

    private func projectSubtitle(for session: OCSession) -> String? {
        guard let directory = normalizedDirectory(for: session) else { return nil }
        return directory
    }

    private func normalizedDirectory(for session: OCSession) -> String? {
        let trimmedDirectory = session.directory?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmedDirectory, !trimmedDirectory.isEmpty else { return nil }
        return trimmedDirectory
    }
}

private struct SessionsLoadErrorView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(AppText.sessionsLoadErrorTitle, systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button(AppText.tryAgain, action: retry)
                .buttonStyle(.borderedProminent)
        }
    }
}

private struct NewSessionSheet: View {
    enum WorkspaceLoadState {
        case idle
        case loading
        case loaded
        case error(String)
    }

    let onCreated: (OCSession) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.connection) private var connection
    @Environment(\.savedConnections) private var savedConnections
    @Environment(\.sessionsService) private var sessionsService
    @Environment(\.workspaceService) private var workspaceService

    @State private var title = ""
    @State private var workspaceState: WorkspaceLoadState = .idle
    @State private var workspaceOptions: [WorkspaceSelectionOption] = []
    @State private var selectedWorkspaceID: WorkspaceSelectionOption.ID?
    @State private var defaultWorkspaceID: WorkspaceSelectionOption.ID?
    @State private var unavailablePreferredDirectory: String?
    @State private var createErrorMessage: String?
    @State private var isCreating = false

    private var selectedWorkspace: WorkspaceSelectionOption? {
        workspaceOptions.first { $0.id == selectedWorkspaceID }
    }

    private var canCreate: Bool {
        selectedWorkspace?.canCreateSession == true && !isCreating && !isLoadingWorkspaces
    }

    private var isLoadingWorkspaces: Bool {
        if case .loading = workspaceState { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    titleSection
                    workspaceSection

                    if let createErrorMessage {
                        noticeRow(
                            icon: "exclamationmark.triangle.fill",
                            message: createErrorMessage,
                            tint: Color.appDanger
                        )
                    }

                    workspaceSourceNote
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 28)
            }
            .background(Color.appBackground)
            .navigationTitle(AppText.newSession)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppText.cancel) {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await createSession() }
                    } label: {
                        if isCreating {
                            ProgressView()
                                .tint(Color.appAccent)
                        } else {
                            Text(AppText.create)
                        }
                    }
                    .disabled(!canCreate)
                }
            }
            .task {
                await loadWorkspaceOptions()
            }
        }
    }

    private var workspaceSourceNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.appSecondary)
                .padding(.top, 2)

            Text(AppText.newSessionWorkspaceSourceNote)
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(Color.appSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 2)
        .accessibilityElement(children: .combine)
    }

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppText.newSessionPlaceholder)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.appSecondary)
                .textCase(.uppercase)

            TextField(AppText.newSessionPlaceholder, text: $title)
                .font(.system(size: 17, design: .rounded))
                .foregroundStyle(Color.appPrimary)
                .submitLabel(.done)
                .textInputAutocapitalization(.sentences)
                .autocorrectionDisabled(false)
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
                .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.appSeparator, lineWidth: 1)
                }
        }
    }

    private var workspaceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(AppText.workspace)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.appSecondary)
                    .textCase(.uppercase)

                Spacer()

                if isLoadingWorkspaces {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Color.appAccent)
                }
            }

            if let unavailablePreferredDirectory {
                noticeRow(
                    icon: "exclamationmark.triangle.fill",
                    message: "\(AppText.newSessionWorkspaceUnavailable) \(unavailablePreferredDirectory)",
                    tint: Color.appWarning
                )
            }

            switch workspaceState {
            case .idle, .loading:
                loadingRow
            case .loaded:
                workspaceOptionsList
            case .error(let message):
                VStack(alignment: .leading, spacing: 10) {
                    noticeRow(icon: "exclamationmark.triangle.fill", message: message, tint: Color.appDanger)

                    Button {
                        Task { await loadWorkspaceOptions() }
                    } label: {
                        Label(AppText.tryAgain, systemImage: "arrow.clockwise")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                    }
                    .buttonStyle(.bordered)
                    .tint(Color.appAccent)
                }
            }
        }
    }

    private var loadingRow: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(Color.appAccent)
            Text("Loading workspaces...")
                .font(.system(size: 14, design: .rounded))
                .foregroundStyle(Color.appSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var workspaceOptionsList: some View {
        VStack(spacing: 0) {
            ForEach(Array(workspaceOptions.enumerated()), id: \.element.id) { index, option in
                workspaceOptionRow(option)

                if index < workspaceOptions.count - 1 {
                    Rectangle()
                        .fill(Color.appSeparator)
                        .frame(height: 1)
                        .padding(.leading, 52)
                }
            }
        }
        .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.appSeparator, lineWidth: 1)
        }
    }

    private func workspaceOptionRow(_ option: WorkspaceSelectionOption) -> some View {
        Button {
            guard option.canCreateSession else { return }
            selectedWorkspaceID = option.id
            createErrorMessage = nil
        } label: {
            HStack(spacing: 12) {
                Image(systemName: iconName(for: option))
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(iconTint(for: option))
                    .frame(width: 28, height: 28)
                    .background(iconTint(for: option).opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(option.title)
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(option.canCreateSession ? Color.appPrimary : Color.appSecondary)
                            .lineLimit(1)

                        badges(for: option)
                    }

                    if let subtitle = option.subtitle {
                        Text(subtitle)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Color.appSecondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 10)

                Image(systemName: selectedWorkspaceID == option.id ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(selectedWorkspaceID == option.id ? Color.appAccent : Color.appSecondary.opacity(0.45))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
            .opacity(option.canCreateSession ? 1 : 0.62)
        }
        .buttonStyle(.plain)
        .disabled(!option.canCreateSession)
    }

    @ViewBuilder
    private func badges(for option: WorkspaceSelectionOption) -> some View {
        if option.id == defaultWorkspaceID, option.canCreateSession {
            badge(AppText.workspaceSuggested, tint: Color.appAccent)
        }

        if option.isCurrent {
            badge(AppText.workspaceCurrent, tint: Color.appSuccess)
        } else if option.isRecent {
            badge(AppText.workspaceRecent, tint: Color.appSecondary)
        }

        if option.availability == .unavailable {
            badge(AppText.workspaceUnavailable, tint: Color.appWarning)
        }
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(tint.opacity(0.10), in: Capsule())
    }

    private func noticeRow(icon: String, message: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.top, 2)

            Text(message)
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(Color.appSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func iconName(for option: WorkspaceSelectionOption) -> String {
        switch option.availability {
        case .available:
            "folder"
        case .unavailable:
            "folder.badge.questionmark"
        case .serverDefault:
            "server.rack"
        }
    }

    private func iconTint(for option: WorkspaceSelectionOption) -> Color {
        switch option.availability {
        case .available:
            option.isCurrent ? Color.appSuccess : Color.appAccent
        case .unavailable:
            Color.appWarning
        case .serverDefault:
            Color.appSecondary
        }
    }

    private func loadWorkspaceOptions() async {
        workspaceState = .loading
        createErrorMessage = nil

        do {
            let snapshot = try await workspaceService.loadWorkspaceSelection()
            let activeConnectionID = savedConnections.activeConnectionID
            let recentDirectories = activeConnectionID
                .map { savedConnections.recentProjectSelections(connectionID: $0) }
                ?? []
            let preferredDirectory = activeConnectionID
                .flatMap { savedConnections.savedProjectSelection(connectionID: $0) }
                ?? connection.selectedProjectDirectory

            let result = WorkspaceSelectionBuilder.makeOptions(
                snapshot: snapshot,
                recentDirectories: recentDirectories,
                preferredDirectory: preferredDirectory
            )

            workspaceOptions = result.options
            defaultWorkspaceID = result.defaultOptionID
            selectedWorkspaceID = result.defaultOptionID
            unavailablePreferredDirectory = result.unavailablePreferredDirectory
            workspaceState = .loaded
        } catch {
            workspaceOptions = []
            defaultWorkspaceID = nil
            selectedWorkspaceID = nil
            unavailablePreferredDirectory = nil
            workspaceState = .error(error.localizedDescription)
        }
    }

    private func createSession() async {
        guard let selectedWorkspace, selectedWorkspace.canCreateSession else { return }

        isCreating = true
        createErrorMessage = nil
        defer { isCreating = false }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            let session = try await sessionsService.createSession(
                title: trimmedTitle.isEmpty ? nil : trimmedTitle,
                workspaceDirectory: selectedWorkspace.directory,
                clearsWorkspaceContext: selectedWorkspace.clearsWorkspaceContext
            )
            onCreated(session)
            dismiss()
        } catch {
            createErrorMessage = error.localizedDescription
        }
    }
}
