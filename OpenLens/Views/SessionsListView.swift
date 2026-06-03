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

    enum ViewState {
        case idle
        case loading
        case loaded
        case error(String)
    }

    @State private var viewState: ViewState = .idle
    @State private var sessions: [OCSession] = []
    @State private var sessionStatuses: [String: OCSessionStatus] = [:]

    @State private var showNewSessionAlert = false
    @State private var newSessionTitle = ""
    @State private var sessionToDelete: OCSession?
    @State private var showDeleteConfirmation = false
    @State private var expandedProjectIDs = Set<String>()

    var onSelect: (OCSession) -> Void

    @Environment(\.sessionsService) private var sessionsService

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
                    showNewSessionAlert = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 16))
                        .foregroundStyle(Color.appPrimary)
                }
            }
        }
        .alert(AppText.newSession, isPresented: $showNewSessionAlert) {
            TextField(AppText.newSessionPlaceholder, text: $newSessionTitle)
            Button(AppText.create) {
                createSession()
            }
            Button(AppText.cancel, role: .cancel) {
                newSessionTitle = ""
            }
        } message: {
            Text(AppText.newSessionMessage)
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
            await loadSessions()
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
                showNewSessionAlert = true
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

    private func createSession() {
        let title = newSessionTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        newSessionTitle = ""

        Task {
            do {
                let session = try await sessionsService.createSession(title: title.isEmpty ? nil : title)
                sessions.insert(session, at: 0)
                pruneExpandedProjects(using: sessions)
                onSelect(session)
            } catch {
                viewState = .error(error.localizedDescription)
            }
        }
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
