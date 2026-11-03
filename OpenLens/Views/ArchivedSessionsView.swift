import SwiftUI

/// Lists archived conversations with restore and delete actions.
/// Pushed on the Sessions screen and presented modally from the sidebar layout.
struct ArchivedSessionsView: View {
    /// Presents a Done button when shown modally; pushed views use the back button.
    var dismissable = false

    enum ViewState {
        case idle
        case loading
        case loaded
        case error(String)
    }

    @State private var viewState: ViewState = .idle
    @State private var sessions: [OCSession] = []
    @State private var sessionToDelete: OCSession?
    @State private var showDeleteConfirmation = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.sessionsService) private var sessionsService

    var body: some View {
        stateContent
            .navigationTitle(AppText.archivedSessions)
            .navigationBarTitleDisplayMode(.inline)
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .background(Color.appBackground)
            .toolbar {
                if dismissable {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(AppText.done) {
                            dismiss()
                        }
                    }
                }
            }
            .confirmationDialog(
                AppText.deleteSession,
                isPresented: $showDeleteConfirmation,
                presenting: sessionToDelete
            ) { session in
                Button("\(AppText.delete) \"\(session.title)\"", role: .destructive) {
                    delete(session)
                }
                Button(AppText.cancel, role: .cancel) {}
            } message: { _ in
                Text(AppText.deleteSessionMessage)
            }
            .task {
                await loadSessions()
            }
    }

    // MARK: - Content

    private var isLoading: Bool {
        if case .loading = viewState { return true }
        return false
    }

    private var errorMessage: String? {
        if case .error(let message) = viewState { return message }
        return nil
    }

    @ViewBuilder
    private var stateContent: some View {
        if isLoading, sessions.isEmpty {
            ProgressView()
                .tint(Color.appSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage, sessions.isEmpty {
            ContentUnavailableView {
                Label(AppText.sessionsLoadErrorTitle, systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            } actions: {
                Button(AppText.tryAgain) {
                    Task {
                        await loadSessions()
                    }
                }
                .primaryCTAStyle()
            }
        } else if sessions.isEmpty {
            ContentUnavailableView {
                Label(AppText.archivedSessionsEmptyTitle, systemImage: "archivebox")
            } description: {
                Text(AppText.archivedSessionsEmptyMessage)
            }
        } else {
            sessionList
        }
    }

    private var sessionList: some View {
        List {
            ForEach(sessions) { session in
                sessionRow(session)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 12, leading: 24, bottom: 12, trailing: 24))
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button {
                            unarchive(session)
                        } label: {
                            Label(AppText.unarchive, systemImage: "tray.and.arrow.up")
                        }
                        .tint(Color.appAccent)

                        Button(role: .destructive) {
                            sessionToDelete = session
                            showDeleteConfirmation = true
                        } label: {
                            Label(AppText.delete, systemImage: "trash")
                        }
                    }
                    .contextMenu {
                        Button {
                            unarchive(session)
                        } label: {
                            Label(AppText.unarchive, systemImage: "tray.and.arrow.up")
                        }

                        Button(role: .destructive) {
                            sessionToDelete = session
                            showDeleteConfirmation = true
                        } label: {
                            Label(AppText.delete, systemImage: "trash")
                        }
                    }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 16, for: .scrollContent)
        .contentMargins(.bottom, 16, for: .scrollContent)
    }

    private func sessionRow(_ session: OCSession) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                SessionWorkingTitle(
                    title: session.title.isEmpty ? AppText.titleUntitled : session.title,
                    isWorking: false
                )

                Text(archivedDateText(for: session))
                    .font(.system(size: 14, design: .rounded))
                    .foregroundStyle(Color.appSecondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(Color.appSecondary.opacity(0.7))
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    // MARK: - Side Effects (Service calls)

    private func loadSessions() async {
        guard !Task.isCancelled, !isLoading else { return }
        viewState = .loading
        do {
            let archived = try await sessionsService.listArchivedSessions()
            guard !Task.isCancelled else { return }
            sessions = archived
            viewState = .loaded
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            viewState = .error(error.localizedDescription)
        }
    }

    private func unarchive(_ session: OCSession) {
        Task {
            do {
                _ = try await sessionsService.unarchiveSession(session)
                sessions.removeAll { $0.id == session.id }
            } catch {
                viewState = .error(error.localizedDescription)
            }
        }
    }

    private func delete(_ session: OCSession) {
        Task {
            do {
                try await sessionsService.deleteSession(session)
                sessions.removeAll { $0.id == session.id }
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

    /// Prefers the archive timestamp; sessions archived by older servers fall
    /// back to their last update.
    private func archivedDateText(for session: OCSession) -> String {
        let archivedAt = session.time.archived.map { $0 / 1000 }
        let reference = Date(timeIntervalSince1970: archivedAt ?? session.updatedAt)
        return Self.relativeDateFormatter.localizedString(for: reference, relativeTo: Date())
    }
}

#Preview {
    NavigationStack {
        ArchivedSessionsView()
    }
}
