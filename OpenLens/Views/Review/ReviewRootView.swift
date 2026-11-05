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
            AppText.reviewFileCount(files.count)
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
        case session
        case update

        var id: Self { self }

        var title: String {
            switch self {
            case .session: AppText.reviewScopeSession
            case .update: AppText.reviewScopeUpdate
            }
        }
    }

    @Bindable var chatClient: ChatClient

    @Environment(\.inboxService) private var inboxService
    @Environment(\.reviewService) private var reviewService
    @Environment(\.sessionsService) private var sessionsService
    @Environment(\.serverRegistry) private var registry
    @Environment(AppRouter.self) private var router: AppRouter?

    @State private var viewState: ViewState = .idle
    @State private var reviewSnapshot: SessionReviewSnapshot?
    @State private var changeSetToRevert: ReviewChangeSet?
    @State private var selectedScopeID = reviewSessionScopeID
    /// The update last inspected, restored when switching back from the whole session.
    @State private var lastUpdateScopeID: String?
    @State private var selectedFile: ReviewFileChange?
    @State private var availableSessions: [OCSession] = []
    /// The other connected servers' first pages, for the picker.
    @State private var otherServerSessions: [ServerSessionsResult] = []
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
        .background(Color.appBackground)
        .toolbarTitleDisplayMode(.inline)
        .task {
            await refreshInboxBadgeCount()
            if ScreenshotFixtures.opensInbox {
                isInboxPresented = true
            }
            if ScreenshotFixtures.opensReviewSessionPicker {
                try? await Task.sleep(for: .seconds(2))
                isSessionPickerPresented = true
            }
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
            AppText.reviewRevertDialogTitle,
            isPresented: Binding(
                get: { changeSetToRevert != nil },
                set: { if !$0 { changeSetToRevert = nil } }
            ),
            presenting: changeSetToRevert
        ) { changeSet in
            Button(AppText.reviewRevertDialogAction(changeSet.title), role: .destructive) {
                Task {
                    await revert(changeSet)
                }
            }
            Button(AppText.cancel, role: .cancel) {
                changeSetToRevert = nil
            }
        } message: { _ in
            Text(AppText.reviewRevertDialogMessage)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewState {
        case .idle where availableSessions.isEmpty && chatClient.currentSession == nil:
            ContentUnavailableView(
                AppText.reviewEmptyTitle,
                systemImage: "doc.text.magnifyingglass",
                description: Text(AppText.reviewEmptyDescription)
            )
        case .idle, .loading where reviewSnapshot == nil:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .error(let message) where reviewSnapshot == nil:
            ContentUnavailableView {
                Label(AppText.reviewUnavailableTitle, systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button(AppText.tryAgain) {
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
                if let reviewSnapshot, selectedScopeID != reviewSessionScopeID {
                    updateSection(reviewSnapshot)
                }

                filesSection
            }
        }
        .scrollContentBackground(.hidden)
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        .safeAreaBar(edge: .top, spacing: 8) {
            if !isReviewReloading, let reviewSnapshot, !reviewSnapshot.changeSets.isEmpty {
                scopeBar(reviewSnapshot)
            }
        }
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
                        options: sessionPickerOptions,
                        selectedOptionID: selectedReviewSessionID.map { "\(registry.activeContext.id)|\($0)" },
                        hasMore: nextSessionsCursor != nil,
                        pagingState: sessionsPagingState,
                        onSelect: { option in
                            isSessionPickerPresented = false
                            selectPickerOption(option)
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
                Label(AppText.inbox, systemImage: inboxBadgeCount > 0 ? "bell.badge" : "bell")
            }
            .accessibilityLabel(inboxAccessibilityLabel)
        }
    }

    /// Segmented switch between the whole session and a single agent update.
    /// It is pinned under the navigation bar instead of living in the form, so
    /// it stays visible while scrolling and adds no gap above the first section.
    private func scopeBar(_ snapshot: SessionReviewSnapshot) -> some View {
        Picker(AppText.reviewScopeAccessibility, selection: scopeModeBinding(for: snapshot)) {
            ForEach(ScopeMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    /// Chooses which agent update to inspect, and offers the revert for the
    /// selected update in the same section so the action lives with its data.
    private func updateSection(_ snapshot: SessionReviewSnapshot) -> some View {
        Section {
            Picker(AppText.reviewUpdatePickerLabel, selection: $selectedScopeID) {
                ForEach(snapshot.changeSets) { changeSet in
                    Label {
                        Text(changeSet.title)
                        Text(AppText.reviewUpdateLabel(
                            isLatest: changeSet.id == snapshot.latestChangeSet?.id,
                            date: shortDate(changeSet.createdAt)
                        ))
                    } icon: {
                        Image(systemName: changeSet.id == snapshot.latestChangeSet?.id ? "sparkles" : "clock.arrow.circlepath")
                    }
                    .tag(changeSet.id)
                }
            }
            .pickerStyle(.navigationLink)

            if let selectedChangeSet = selectedScopeState.changeSet {
                Button(role: .destructive) {
                    changeSetToRevert = selectedChangeSet
                } label: {
                    Label(AppText.reviewRevertUpdate, systemImage: "arrow.uturn.backward")
                }
            }
        } footer: {
            Text(AppText.reviewUpdateFooter)
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

    /// File count, plus how many agent updates the session spans so the
    /// single-update option is discoverable from the whole-session view.
    private var filesFooter: String {
        let fileCount = selectedScopeState.fileCountLabel
        guard let reviewSnapshot, !reviewSnapshot.changeSets.isEmpty else { return fileCount }

        if selectedScopeID == reviewSessionScopeID {
            return AppText.reviewFilesFooterSession(
                files: fileCount,
                updates: AppText.reviewUpdateCount(reviewSnapshot.changeSets.count)
            )
        }
        return AppText.reviewFilesFooterUpdate(files: fileCount)
    }

    private var filesSection: some View {
        Section {
            if selectedScopeState.files.isEmpty {
                Text(AppText.reviewNoFileChanges)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(selectedScopeState.files, id: \.id) { file in
                    Button {
                        selectedFile = file
                    } label: {
                        FileChangeRow(file: file)
                    }
                    .tint(.primary)
                }
            }
        } header: {
            Text(selectedScopeID == reviewSessionScopeID ? AppText.reviewFilesHeaderSession : AppText.reviewFilesHeaderUpdate)
        } footer: {
            Text(filesFooter)
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

    private var sessionPickerOptions: [ReviewPickerOption] {
        reviewPickerOptions(
            activeServerID: registry.activeContext.id,
            activeSessions: sessionPickerSessions,
            otherServers: otherServerSessions,
            tags: registry.serverTags(),
            showsServerTags: isMultiServerUIEnabled(savedServerCount: registry.savedServerContexts.count)
        )
    }

    /// A session on another server makes that server the active one first, as the Sessions list
    /// does. That rebuilds this view, so the choice is handed over through the router.
    private func selectPickerOption(_ option: ReviewPickerOption) {
        guard option.serverID != registry.activeContext.id else {
            selectedReviewSession = option.session
            return
        }
        router?.pendingReviewSession = option.session
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            guard registry.activate(id: option.serverID) else {
                router?.pendingReviewSession = nil
                return
            }
            router?.activate(serverID: option.serverID)
        }
    }

    private func refreshOtherServerSessions() async {
        let activeID = registry.activeContext.id
        let others = registry.savedServerContexts.filter { $0.id != activeID && $0.connection.isConnected }
        var results: [ServerSessionsResult] = []
        for context in others {
            do {
                let page = try await context.sessionsService.listSessionsPage()
                results.append(ServerSessionsResult(serverID: context.id, sessions: page.sessions))
            } catch {
                results.append(ServerSessionsResult(serverID: context.id, sessions: [], failureMessage: error.localizedDescription))
            }
        }
        otherServerSessions = results
    }

    private var isReviewReloading: Bool {
        if case .loading = viewState {
            return reviewSnapshot != nil
        }
        return false
    }

    private var inboxAccessibilityLabel: String {
        inboxBadgeCount == 0 ? AppText.inboxOpen : AppText.inboxOpenPending(inboxBadgeCount)
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
            await refreshOtherServerSessions()

            if let pending = router?.pendingReviewSession {
                router?.pendingReviewSession = nil
                selectedReviewSession = pending
                return
            }

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
            let snapshot = try await registry.loadAggregatedInbox(activeInbox: inboxService)
            inboxBadgeCount = snapshot.pendingRequestCount
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
        viewState = .error(AppText.reviewRevertRefreshFailed)
    }
}
