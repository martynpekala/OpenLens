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
        } message: { session in
            Text(AppText.deleteSessionMessage)
        }
        .task {
            await loadSessions()
        }
    }

    // MARK: - Session List

    private var sessionList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
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
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .refreshable {
            await loadSessions()
        }
    }

    private func sessionRow(_ session: OCSession) -> some View {
        let isBusy = sessionStatuses[session.id]?.type == .busy

        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title.isEmpty ? AppText.titleUntitled : session.title)
                    .font(.system(size: 18, weight: .regular, design: .rounded))
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
                        .font(.system(size: 16, design: .rounded))
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
}
