import SwiftUI

private let reviewSessionScopeID = "__session__"

struct ReviewRootView: View {
    private struct SelectedScopeState {
        struct Totals {
            let additions: Int
            let deletions: Int

            static let zero = Totals(additions: 0, deletions: 0)
        }

        let changeSet: ReviewChangeSet?
        let files: [ReviewFileChange]
        let totals: Totals

        static let empty = SelectedScopeState(
            changeSet: nil,
            files: [],
            totals: .zero
        )

        var fileCountLabel: String {
            let count = files.count
            return count == 1 ? "1 file" : "\(count) files"
        }
    }

    enum ViewState: Equatable {
        case idle
        case loading
        case loaded
        case error(String)
    }

    /// Whether the review shows everything the session changed or one agent update.
    private enum ScopeMode: String, CaseIterable, Identifiable {
        case session = "Whole session"
        case update = "Single update"

        var id: Self { self }
    }

    @Bindable var chatClient: ChatClient

    @Environment(\.inboxService) private var inboxService
    @Environment(\.reviewService) private var reviewService
    @Environment(\.sessionsService) private var sessionsService

    @State private var viewState: ViewState = .idle
    @State private var reviewSnapshot: SessionReviewSnapshot?
    @State private var changeSetToRevert: ReviewChangeSet?
    @State private var selectedScopeID = reviewSessionScopeID
    /// The update last inspected, restored when switching back from the whole session.
    @State private var lastUpdateScopeID: String?
    @State private var selectedFile: ReviewFileChange?
    @State private var availableSessions: [OCSession] = []
    @State private var nextSessionsCursor: String?
    @State private var sessionsPagingState: ReviewSessionPickerList.PagingState = .idle
    @State private var selectedReviewSession: OCSession?
    @State private var isSessionPickerPresented = false
    @State private var inboxBadgeCount = 0
    @State private var isInboxPresented = false
    @State private var selectedScopeState = SelectedScopeState.empty

    var body: some View {
        Group {
            content
        }
        .task {
            await refreshInboxBadgeCount()
        }
        .task(id: chatClient.currentSession?.id) {
            await refreshAvailableSessions()
        }
        .task(id: selectedReviewSessionID) {
            await loadReview(resetScope: true)
        }
        .onChange(of: selectedScopeID) { _, newScopeID in
            if newScopeID != reviewSessionScopeID {
                lastUpdateScopeID = newScopeID
            }
            refreshSelectedScopeState()
        }
        .refreshable {
            await refreshAvailableSessions()
            await loadReview(force: true)
            await refreshInboxBadgeCount()
        }
        .sheet(item: $selectedFile) { file in
            FileDiffDetailView(file: file)
        }
        .sheet(isPresented: $isInboxPresented, onDismiss: {
            Task {
                await refreshInboxBadgeCount()
            }
        }) {
            NavigationStack {
                InboxRootView(chatClient: chatClient)
            }
        }
        .toolbar {
            sessionPickerToolbarItem
            inboxToolbarItem
        }
        .confirmationDialog(
            "Revert changes",
            isPresented: Binding(
                get: { changeSetToRevert != nil },
                set: { if !$0 { changeSetToRevert = nil } }
            ),
            presenting: changeSetToRevert
        ) { changeSet in
            Button("Revert \"\(changeSet.title)\"", role: .destructive) {
                Task {
                    await revert(changeSet)
                }
            }
            Button(AppText.cancel, role: .cancel) {
                changeSetToRevert = nil
            }
        } message: { _ in
            Text("This will revert the selected change set from the selected review session.")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewState {
        case .idle where availableSessions.isEmpty && chatClient.currentSession == nil:
            ContentUnavailableView(
                "No Sessions",
                systemImage: "doc.text.magnifyingglass",
                description: Text("Start a chat or pick a session once one exists.")
            )
        case .idle, .loading where reviewSnapshot == nil:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .error(let message) where reviewSnapshot == nil:
            ContentUnavailableView {
                Label("Review Unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Retry") {
                    Task {
                        await refreshAvailableSessions()
                        await loadReview(force: true)
                    }
                }
            }
        default:
            reviewForm
        }
    }

    private var reviewForm: some View {
        Form {
            if !isReviewReloading {
                if let reviewSnapshot, !reviewSnapshot.changeSets.isEmpty {
                    scopeSection(reviewSnapshot)
                }

                filesSection

                if let selectedChangeSet = selectedScopeState.changeSet {
                    revertSection(selectedChangeSet)
                }
            }
        }
        .scrollEdgeEffectStyle(.soft, for: .bottom)
    }

    private var sessionPickerToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            if let reviewedSession = selectedReviewSession {
                ReviewSessionPickerCapsule(
                    title: reviewedSession.title.nilIfBlank ?? AppText.titleUntitled,
                    totals: toolbarChangeTotals,
                    isPresented: isSessionPickerPresented
                ) {
                    isSessionPickerPresented = true
                }
                .popover(isPresented: $isSessionPickerPresented, arrowEdge: .top) {
                    ReviewSessionPickerList(
                        sessions: sessionPickerSessions,
                        selectedSessionID: selectedReviewSessionID,
                        hasMore: nextSessionsCursor != nil,
                        pagingState: sessionsPagingState,
                        onSelect: { session in
                            selectedReviewSession = session
                            isSessionPickerPresented = false
                        },
                        onLoadMore: loadMoreSessions
                    )
                    .frame(width: 320, height: 420)
                    .presentationCompactAdaptation(.popover)
                }
            }
        }
        .sharedBackgroundVisibility(.hidden)
    }

    private var inboxToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                isInboxPresented = true
            } label: {
                Label("Inbox", systemImage: inboxBadgeCount > 0 ? "bell.badge" : "bell")
            }
            .accessibilityLabel(inboxAccessibilityLabel)
        }
//        .badge(inboxBadgeCount)
    }

    /// Segmented switch between the whole session and a single agent update.
    /// The update picker only shows once "Single update" is chosen.
    private func scopeSection(_ snapshot: SessionReviewSnapshot) -> some View {
        Section {
            Picker("Review scope", selection: scopeModeBinding(for: snapshot)) {
                ForEach(ScopeMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())

            if selectedScopeID != reviewSessionScopeID {
                Picker("Update", selection: $selectedScopeID) {
                    ForEach(snapshot.changeSets) { changeSet in
                        Label {
                            Text(changeSet.title)
                            Text(changeSet.id == snapshot.latestChangeSet?.id
                                ? "Latest · \(shortDate(changeSet.createdAt))"
                                : shortDate(changeSet.createdAt))
                        } icon: {
                            Image(systemName: changeSet.id == snapshot.latestChangeSet?.id ? "sparkles" : "clock.arrow.circlepath")
                        }
                        .tag(changeSet.id)
                    }
                }
                .pickerStyle(.navigationLink)
            }
        } footer: {
            Text(scopeFooter(for: snapshot))
        }
    }

    private func scopeModeBinding(for snapshot: SessionReviewSnapshot) -> Binding<ScopeMode> {
        Binding(
            get: { selectedScopeID == reviewSessionScopeID ? .session : .update },
            set: { mode in
                switch mode {
                case .session:
                    selectedScopeID = reviewSessionScopeID
                case .update:
                    let rememberedID = lastUpdateScopeID.flatMap { id in
                        snapshot.changeSets.contains(where: { $0.id == id }) ? id : nil
                    }
                    selectedScopeID = rememberedID ?? snapshot.latestChangeSet?.id ?? reviewSessionScopeID
                }
            }
        )
    }

    private func scopeFooter(for snapshot: SessionReviewSnapshot) -> String {
        if selectedScopeID == reviewSessionScopeID {
            let count = snapshot.changeSets.count
            let updates = count == 1 ? "1 agent update" : "\(count) agent updates"
            return "Everything changed in this session, across \(updates). Switch to Single update to review one at a time."
        }
        return "Only the changes from the selected agent update. Switch to Whole session to see everything."
    }

    private var filesSection: some View {
        Section {
            if selectedScopeState.files.isEmpty {
                Text("No file changes available for this selection.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(selectedScopeState.files, id: \.id) { file in
                    Button {
                        selectedFile = file
                    } label: {
                        fileRow(file)
                    }
                    .tint(.primary)
                }
            }
        } header: {
            Text(selectedScopeID == reviewSessionScopeID ? "Session changes" : "Update changes")
        } footer: {
            Text(selectedScopeState.fileCountLabel)
        }
    }

    private func fileRow(_ file: ReviewFileChange) -> some View {
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
            Text(fileStatusLabel(file.status))
        }
    }

    private func revertSection(_ changeSet: ReviewChangeSet) -> some View {
        Section {
            LabeledContent("Selected update") {
                Text(changeSet.title)
                    .lineLimit(2)
            }
            Button(role: .destructive) {
                changeSetToRevert = changeSet
            } label: {
                Label("Revert update", systemImage: "arrow.uturn.backward")
            }
        } header: {
            Text("Danger Zone")
        } footer: {
            Text("Undo only the changes introduced by this update. The session itself is kept, but the code changes from this update are removed after confirmation.")
        }
    }

    private var selectedReviewSessionID: String? {
        selectedReviewSession?.id
    }

    /// Change totals for the toolbar capsule. The capsule stays mounted while a
    /// snapshot is loading, showing zeros that count up once it arrives.
    private var toolbarChangeTotals: ReviewSessionPickerCapsule.ChangeTotals {
        guard reviewSnapshot != nil, !isReviewReloading else { return .zero }
        return ReviewSessionPickerCapsule.ChangeTotals(
            additions: selectedScopeState.totals.additions,
            deletions: selectedScopeState.totals.deletions
        )
    }

    /// Loaded pages, with the selected session pinned on top when it has not
    /// been paged in yet (for example an older active chat session).
    private var sessionPickerSessions: [OCSession] {
        guard let selectedReviewSession,
              !availableSessions.contains(where: { $0.id == selectedReviewSession.id }) else {
            return availableSessions
        }
        return [selectedReviewSession] + availableSessions
    }

    private var isReviewReloading: Bool {
        if case .loading = viewState {
            return reviewSnapshot != nil
        }
        return false
    }

    private var inboxAccessibilityLabel: String {
        if inboxBadgeCount == 0 {
            return "Open inbox"
        }

        let itemLabel = inboxBadgeCount == 1 ? "item" : "items"
        return "Open inbox, \(inboxBadgeCount) pending \(itemLabel)"
    }

    private func fileStatusLabel(_ status: String) -> String {
        switch status.uppercased() {
        case "A": "Added"
        case "D": "Deleted"
        case "R": "Renamed"
        default: "Modified"
        }
    }

    private func shortDate(_ date: Date?) -> String {
        guard let date else { return "No timestamp" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    /// Reloads the first page of sessions and keeps a valid selection.
    private func refreshAvailableSessions() async {
        do {
            let page = try await sessionsService.listSessionsPage()
            availableSessions = page.sessions
            nextSessionsCursor = page.nextCursor
            sessionsPagingState = .idle

            let activeSession = chatClient.currentSession.flatMap { session in
                session.parentID?.nilIfBlank == nil ? session : nil
            }

            if let selectedReviewSession,
               let refreshed = page.sessions.first(where: { $0.id == selectedReviewSession.id }) {
                self.selectedReviewSession = refreshed
            } else if let selectedReviewSession,
                      page.nextCursor != nil || selectedReviewSession.id == activeSession?.id {
                // The selection may live on a page that is not loaded yet.
                self.selectedReviewSession = selectedReviewSession
            } else {
                selectedReviewSession = activeSession ?? page.sessions.first
            }
        } catch {
            if availableSessions.isEmpty {
                viewState = .error(error.localizedDescription)
            }
        }
    }

    private func loadMoreSessions() async {
        guard let cursor = nextSessionsCursor, sessionsPagingState != .loading else { return }

        sessionsPagingState = .loading
        do {
            let page = try await sessionsService.listSessionsPage(cursor: cursor)
            // Ignore a stale page if the list was refreshed meanwhile.
            guard nextSessionsCursor == cursor else { return }
            let knownIDs = Set(availableSessions.map(\.id))
            availableSessions += page.sessions.filter { !knownIDs.contains($0.id) }
            nextSessionsCursor = page.nextCursor
            sessionsPagingState = .idle
        } catch {
            guard nextSessionsCursor == cursor else { return }
            sessionsPagingState = .error(error.localizedDescription)
        }
    }

    private func loadReview(force: Bool = false, resetScope: Bool = false) async {
        guard let sessionID = selectedReviewSessionID else {
            reviewSnapshot = nil
            selectedScopeID = reviewSessionScopeID
            lastUpdateScopeID = nil
            selectedScopeState = .empty
            viewState = .idle
            return
        }

        if !force, reviewSnapshot?.sessionID == sessionID, case .loaded = viewState {
            return
        }

        viewState = .loading
        do {
            let snapshot = try await reviewService.loadReview(sessionID: sessionID)
            reviewSnapshot = snapshot
            syncSelectedScope(using: snapshot, resetScope: resetScope)
            refreshSelectedScopeState(using: snapshot)
            viewState = .loaded
        } catch {
            viewState = .error(error.localizedDescription)
        }
    }

    private func refreshInboxBadgeCount() async {
        do {
            let snapshot = try await inboxService.loadInbox()
            inboxBadgeCount = snapshot.permissions.count + snapshot.questions.count
        } catch {
            inboxBadgeCount = 0
        }
    }

    private func syncSelectedScope(using snapshot: SessionReviewSnapshot, resetScope: Bool) {
        let validScopeIDs = Set(snapshot.changeSets.map(\.id)).union([reviewSessionScopeID])

        if resetScope {
            lastUpdateScopeID = nil
        }

        // Review the whole session by default; a single update is opt-in.
        if resetScope || !validScopeIDs.contains(selectedScopeID) {
            selectedScopeID = reviewSessionScopeID
        }
    }

    private func refreshSelectedScopeState() {
        guard let reviewSnapshot else {
            selectedScopeState = .empty
            return
        }

        refreshSelectedScopeState(using: reviewSnapshot)
    }

    private func refreshSelectedScopeState(using snapshot: SessionReviewSnapshot) {
        let changeSet = snapshot.changeSets.first(where: { $0.id == selectedScopeID })
        let files = changeSet?.files ?? snapshot.workingTree
        let totals = files.reduce(into: SelectedScopeState.Totals.zero) { totals, file in
            totals = SelectedScopeState.Totals(
                additions: totals.additions + file.additions,
                deletions: totals.deletions + file.deletions
            )
        }

        selectedScopeState = SelectedScopeState(
            changeSet: changeSet,
            files: files,
            totals: totals
        )
    }

    private func revert(_ changeSet: ReviewChangeSet) async {
        guard let sessionID = selectedReviewSessionID else { return }

        do {
            try await reviewService.revertChangeSet(sessionID: sessionID, messageID: changeSet.id)
            changeSetToRevert = nil
            guard await refreshAfterRevertAttempt(sessionID: sessionID) else {
                showRevertRefreshFailure()
                return
            }
        } catch {
            // A staged revert can fail after the server changed its preview.
            // Always replace the displayed review snapshot before reporting the
            // failure so the user can safely retry once the session is idle.
            guard await refreshAfterRevertAttempt(sessionID: sessionID) else {
                showRevertRefreshFailure()
                return
            }
        }
    }

    private func refreshAfterRevertAttempt(sessionID: String) async -> Bool {
        let refreshedChat = if chatClient.currentSession?.id == sessionID {
            await chatClient.refreshCurrentSessionFromServer()
        } else {
            true
        }
        await refreshAvailableSessions()
        await loadReview(force: true)
        return refreshedChat && viewState == .loaded
    }

    private func showRevertRefreshFailure() {
        // Do not continue showing a stale diff after an incomplete server
        // mutation. The explicit error state leaves pull-to-refresh available
        // for a safe recovery.
        reviewSnapshot = nil
        selectedScopeState = .empty
        viewState = .error("The revert state could not be refreshed. Pull to refresh and retry once the session is idle.")
    }
}
