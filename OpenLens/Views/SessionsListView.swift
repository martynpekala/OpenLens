import SwiftUI

/// Session list view with create, delete, and select.
/// Uses SessionsService directly with view-local state.
struct SessionsListView: View {
    enum PresentationStyle: Equatable {
        case navigation
        case sidebar
    }

    private struct NewSessionRequest: Identifiable {
        let id = UUID()
        let targetServerID: String
    }

    /// A session waiting on the delete confirmation, with the server that owns it.
    private struct PendingDeletion {
        let session: OCSession
        let serverID: String
    }

    /// One server this list can load from. The active server uses the environment's service and
    /// connection, which the composition root keeps equal to the active context's own.
    private struct Source {
        let id: String
        let sessionsService: SessionsService
        let connection: ConnectionManager
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
    /// What each server last returned, by server id. A server with no entry has not been loaded;
    /// the seed stands in for it until then (see `sessions(for:)`).
    @State private var sessionsByServer: [String: [OCSession]] = ScreenshotFixtures.isEnabled
        ? ScreenshotFixtures.sessionsByServerID : [:]
    @State private var failureByServer: [String: String] = ScreenshotFixtures.isEnabled
        ? ScreenshotFixtures.sessionFailuresByServerID : [:]
    @State private var statusesByServer: [String: [String: OCSessionStatus]] = [:]
    @State private var failedOutcomeIDsByServer: [String: Set<String>] = [:]
    /// Sessions the list opened with, before any refresh of its own.
    @State private var seedSessions: [OCSession]
    /// Which server the list shows; nil is every server.
    @State private var serverFilterID: String?
    @State private var openedSessionIDs: Set<String> = []
    @State private var outcomeRefreshGeneration = 0

    @State private var newSessionRequest: NewSessionRequest?
    @State private var sessionToDelete: PendingDeletion?
    @State private var showDeleteConfirmation = false
    @State private var expandedProjectIDs = Set<String>()
    @State private var showArchivedSessions = false

    /// Chooses which swipe action a full swipe triggers on a conversation row.
    @AppStorage(AppPreferenceKeys.fullSwipeAction) private var fullSwipeAction = SessionFullSwipeAction.archive

    let presentationStyle: PresentationStyle
    let selectedSessionID: String?
    /// The server `initialState`'s sessions came from. Nil means the active server.
    let initialServerID: String?
    var onSelect: (OCSession) -> Void
    /// Makes a server the active one. Called before `onSelect` for a session on another server.
    var onActivateServer: (String) -> Void
    var onDelete: (OCSession) -> Void
    var onArchive: (OCSession) -> Void
    /// Resolves the model a new session starts with; nil uses the server default.
    var newSessionModel: @MainActor () async -> OCV2ModelRef?

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.sessionsService) private var sessionsService
    @Environment(\.connection) private var connection
    @Environment(\.serverRegistry) private var registry
    @Environment(\.workspaceNames) private var workspaceNames
    @Environment(\.openLensTheme) private var theme

    init(
        initialState: InitialState,
        presentationStyle: PresentationStyle = .navigation,
        selectedSessionID: String? = nil,
        initialServerID: String? = nil,
        onSelect: @escaping (OCSession) -> Void,
        onActivateServer: @escaping (String) -> Void = { _ in },
        onDelete: @escaping (OCSession) -> Void = { _ in },
        onArchive: @escaping (OCSession) -> Void = { _ in },
        newSessionModel: @escaping @MainActor () async -> OCV2ModelRef? = { nil }
    ) {
        self.presentationStyle = presentationStyle
        self.selectedSessionID = selectedSessionID
        self.initialServerID = initialServerID
        self.onSelect = onSelect
        self.onActivateServer = onActivateServer
        self.onDelete = onDelete
        self.onArchive = onArchive
        self.newSessionModel = newSessionModel

        switch initialState {
        case .loaded(let sessions):
            self._viewState = State(initialValue: .loaded)
            self._seedSessions = State(initialValue: sessions)
        case .error(let message):
            self._viewState = State(initialValue: .error(message))
            self._seedSessions = State(initialValue: [])
        }
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

    private var isSidebar: Bool {
        presentationStyle == .sidebar
    }

    /// Archiving needs the v2 session archive contract; v1 servers never
    /// support it, so their rows only offer deletion.
    private var supportsArchiving: Bool {
        connection.serverCapabilities?.protocolVersion == .v2 || ScreenshotFixtures.isEnabled
    }

    // MARK: - Servers

    /// Every saved server, in display order. With nothing saved (the connect screen's draft, or
    /// screenshot mode) the active context stands alone.
    private var sources: [Source] {
        let active = registry.activeContext
        var contexts = registry.savedServerContexts
        if contexts.isEmpty { contexts = [active] }
        return contexts.map { context in
            let isActive = context.id == active.id
            return Source(
                id: context.id,
                sessionsService: isActive ? sessionsService : context.sessionsService,
                connection: isActive ? connection : context.connection
            )
        }
    }

    private var activeServerID: String { registry.activeContext.id }

    /// The server `seedSessions` belongs to.
    private var seedServerID: String { initialServerID ?? activeServerID }

    /// One saved server means one list exactly as it always was: no tags, no switcher.
    private var showsServerTags: Bool {
        isMultiServerUIEnabled(savedServerCount: registry.savedServerContexts.count)
    }

    private var serverTags: [String: ServerTag] {
        var tags: [String: ServerTag] = [:]
        for context in registry.savedServerContexts {
            guard let profile = registry.profile(for: context) else { continue }
            tags[context.id] = ServerTag(nickname: profile.nickname, serverURL: profile.serverURL)
        }
        return tags
    }

    private var switchTargets: ServerSwitchTargets {
        let tags = serverTags
        return serverSwitchTargets(registry.savedServerContexts.compactMap { context in
            tags[context.id].map { (id: context.id, tag: $0) }
        })
    }

    /// The servers the list currently shows: all of them, or the one the filter names.
    private var shownSources: [Source] {
        guard let serverFilterID else { return sources }
        let filtered = sources.filter { $0.id == serverFilterID }
        return filtered.isEmpty ? sources : filtered
    }

    /// Sources that can answer now. The active server is always asked, so a failure there is
    /// reported as it always was; the others are asked only while connected, because a saved but
    /// idle server is not a failing one.
    private var loadableSources: [Source] {
        sources.filter { $0.id == activeServerID || $0.connection.isConnected }
    }

    private func sessions(for serverID: String) -> [OCSession] {
        if let loaded = sessionsByServer[serverID] { return loaded }
        return serverID == seedServerID ? seedSessions : []
    }

    private func results(for sources: [Source]) -> [ServerSessionsResult] {
        sources.map {
            ServerSessionsResult(serverID: $0.id, sessions: sessions(for: $0.id), failureMessage: failureByServer[$0.id])
        }
    }

    private var aggregation: SessionAggregation {
        SessionGrouping.aggregate(
            results: results(for: shownSources),
            tags: serverTags,
            showsServerTags: showsServerTags,
            customName: { workspaceNames.customName(forDirectory: $0) }
        )
    }

    private var allSessionsEmpty: Bool {
        sources.allSatisfy { sessions(for: $0.id).isEmpty }
    }

    private func showsExecutionOutcomes(on connection: ConnectionManager) -> Bool {
        connection.serverCapabilities?.protocolVersion == .v2 || ScreenshotFixtures.showsExecutionOutcomes
    }

    private func connection(for serverID: String) -> ConnectionManager {
        sources.first { $0.id == serverID }?.connection ?? connection
    }

    private func service(for serverID: String) -> SessionsService {
        sources.first { $0.id == serverID }?.sessionsService ?? sessionsService
    }

    // MARK: - Body

    var body: some View {
        presentationContent
            .scrollEdgeEffectStyle(.soft, for: .bottom)
        .background(isSidebar ? Color.clear : Color.appBackground)
        .sheet(item: $newSessionRequest) { request in
            NewSessionSheet(
                newSessionModel: newSessionModel,
                targets: switchTargets.targets,
                initialTargetID: request.targetServerID
            ) { session, serverID in
                handleCreatedSession(session, serverID: serverID)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackground(Color.appBackground)
        }
        .sheet(isPresented: $showArchivedSessions) {
            NavigationStack {
                ArchivedSessionsView(dismissable: true)
            }
            .presentationDragIndicator(.visible)
            .presentationBackground(Color.appBackground)
        }
        .confirmationDialog(
            AppText.deleteSession,
            isPresented: $showDeleteConfirmation,
            presenting: sessionToDelete
        ) { session in
            Button("\(AppText.delete) \"\(session.session.title)\"", role: .destructive) {
                deleteSession(session.session, serverID: session.serverID)
            }
            Button(AppText.cancel, role: .cancel) {}
        } message: { _ in
            Text(AppText.deleteSessionMessage)
        }
        .onChange(of: selectedSessionID, initial: true) { previousID, currentID in
            // Queue affected rows for the existing poll without restarting catalog recovery.
            openedSessionIDs.formUnion([previousID, currentID].compactMap { $0 })
        }
        .onChange(of: sessionsService.confirmedViewedMarkers, initial: true) { _, _ in
            let id = activeServerID
            sessionsByServer[id] = sessionsService.applyingConfirmedViewedMarkers(to: sessions(for: id))
        }
        .task {
            if ScreenshotFixtures.opensNewSessionSheet { presentNewSessionSheet() }
        }
        .task(id: loadableSources.map(\.id)) {
            // The first load seeds one server; the rest fill in as they are connected.
            let unloaded = Set(loadableSources.map(\.id).filter { sessionsByServer[$0] == nil && $0 != seedServerID })
            guard !unloaded.isEmpty else { return }
            await loadSessions(servers: unloaded)
        }
        .onChange(of: sessionsService.archiveMutationCount) {
            // Archive mutations can happen in the archived list while this view
            // is beneath it; reconcile the catalog when one is confirmed.
            Task { await loadSessions() }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await loadSessionStatuses(refreshInactive: true)
            guard loadableSources.contains(where: { $0.connection.serverCapabilities?.protocolVersion == .v2 })
                    || (ScreenshotFixtures.isEnabled && ScreenshotFixtures.showsExecutionOutcomes) else { return }
            var lastAttentionRefresh = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                // Desktop viewing can change idle rows without an active-entry
                // transition. Reconcile attention periodically while visible.
                let refreshAttention = Date().timeIntervalSince(lastAttentionRefresh) >= 30
                await loadSessionStatuses(refreshAttention: refreshAttention)
                if refreshAttention { lastAttentionRefresh = Date() }
            }
        }
    }

    @ViewBuilder
    private var presentationContent: some View {
        if isSidebar {
            VStack(spacing: 0) {
                SessionsSidebarHeader(
                    serverFilter: switchTargets.isInteractive
                        ? SessionsSidebarHeader.ServerFilter(
                            title: serverFilterTitle,
                            targets: switchTargets.targets,
                            selection: serverFilterSelection
                        )
                        : nil,
                    onCreate: presentNewSessionSheet,
                    onShowArchived: supportsArchiving ? { showArchivedSessions = true } : nil
                )
                sessionStateContent
            }
        } else {
            sessionStateContent
                .safeAreaInset(edge: .bottom, alignment: .trailing, spacing: 0) {
                    newSessionButton
                        .padding(.trailing, 24)
                        .padding(.top, 12)
                        .padding(.bottom, 32)
                }
                .navigationBarTitleDisplayMode(.inline)
                .navigationTitle(AppText.sessions)
                .toolbar {
                    if switchTargets.isInteractive {
                        ToolbarItem(placement: .principal) {
                            serverFilterMenu
                        }
                        .sharedBackgroundVisibility(.hidden)
                    } else if let host = connection.serverHostDisplay {
                        ToolbarItem(placement: .principal) {
                            ConnectedHostCapsule(host: host, isReconnecting: connection.isReconnecting)
                        }
                        .sharedBackgroundVisibility(.hidden)
                    }

                    if supportsArchiving {
                        ToolbarItem(placement: .topBarTrailing) {
                            NavigationLink(value: RouterDestination.archivedSessions) {
                                Image(systemName: "archivebox")
                            }
                            .accessibilityLabel(AppText.archivedSessions)
                        }
                    }
                }
        }
    }

    /// With several saved servers the capsule filters the list instead of naming one host.
    private var serverFilterMenu: some View {
        Menu {
            Picker(AppText.servers, selection: serverFilterSelection) {
                Text(AppText.sessionsAllServers)
                    .tag(Self.allServersSelection)
                ForEach(switchTargets.targets) { target in
                    Text(target.tag.text)
                        .tag(target.id)
                }
            }
        } label: {
            ServerFilterCapsule(title: serverFilterTitle)
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
    }

    private static let allServersSelection = ""

    private var serverFilterTitle: String {
        guard let serverFilterID,
              let target = switchTargets.targets.first(where: { $0.id == serverFilterID }) else {
            return AppText.sessionsAllServers
        }
        return target.tag.text
    }

    private var serverFilterSelection: Binding<String> {
        Binding(
            get: { serverFilterID ?? Self.allServersSelection },
            set: { id in
                let newFilter = id == Self.allServersSelection ? nil : id
                guard newFilter != serverFilterID,
                      newFilter == nil || switchTargets.targets.contains(where: { $0.id == newFilter }) else { return }
                serverFilterID = newFilter
            }
        )
    }

    private var newSessionButton: some View {
        Button(action: presentNewSessionSheet) {
            Image(systemName: "plus")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(Color.appOnNeutralAction)
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .tint(Color.appNeutralAction)
        .accessibilityLabel(AppText.newSession)
    }

    @ViewBuilder
    private var sessionStateContent: some View {
        if isLoading && allSessionsEmpty {
            ProgressView()
                .tint(Color.appSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage, allSessionsEmpty {
            SessionsLoadErrorView(
                message: errorMessage,
                retry: retryLoadingSessions
            )
        } else if allSessionsEmpty {
            emptyState
        } else {
            sessionList
        }
    }

    // MARK: - Session List

    /// Rows are hosted in a `List` so swipe actions behave natively. Insets and
    /// backgrounds are cleared to keep the custom layout: project groups render
    /// as a header row followed by its session rows.
    private var sessionList: some View {
        let current = aggregation

        return List {
            ForEach(current.groups) { group in
                projectSection(group)
            }
            ForEach(current.failures, id: \.serverID) { failure in
                serverFailureNotice(failure)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, isSidebar ? 10 : 16, for: .scrollContent)
        .contentMargins(.bottom, 16, for: .scrollContent)
        .refreshable {
            await loadSessions()
        }
    }

    @ViewBuilder
    private func projectSection(_ group: SessionGroup) -> some View {
        let isExpanded = expandedProjectIDs.contains(group.id)
        let displayedSessions = isExpanded ? group.sessions : group.visibleSessions
        let canArchive = supportsArchiving(on: group.serverID)

        projectHeader(group)

        ForEach(Array(displayedSessions.enumerated()), id: \.element.id) { index, session in
            sessionRowButton(session, serverID: group.serverID, supportsArchiving: canArchive)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(
                    top: 0,
                    leading: isSidebar ? 12.0 : 24.0,
                    bottom: 0,
                    trailing: isSidebar ? 12.0 : 24.0
                ))
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    // The first action is what a full swipe triggers; the
                    // Settings preference decides whether that archives or
                    // starts the delete confirmation.
                    if canArchive, fullSwipeAction == .delete {
                        deleteSwipeButton(session, serverID: group.serverID)
                        archiveSwipeButton(session, serverID: group.serverID)
                    } else {
                        if canArchive {
                            archiveSwipeButton(session, serverID: group.serverID)
                        }
                        deleteSwipeButton(session, serverID: group.serverID)
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

    /// The server leads, because two machines can share a project name: trailing the tag put the
    /// only thing telling two "Client work" sections apart at the far end of the line, after the
    /// eye had already anchored on the left edge -- and it lost a fight for space with Show More,
    /// truncating the host it exists to name.
    ///
    /// With one server there is no tag and this returns the title line *itself*, not a stack
    /// wrapping it: wrapping a single child still changes the layout, which measurably shifted
    /// every header and row below it against the single-server baseline.
    private func projectHeader(_ group: SessionGroup) -> some View {
        projectHeaderContent(group)
            .padding(.bottom, 6)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(
                top: isSidebar ? 12.0 : 12.0,
                leading: isSidebar ? 12.0 : 24.0,
                bottom: 0,
                trailing: isSidebar ? 12.0 : 24.0
            ))
            .accessibilityAddTraits(.isHeader)
    }

    /// The server leads, because two machines can share a project name: trailing the tag put the
    /// only thing telling two "Client work" sections apart at the far end of the line, after the
    /// eye had already anchored on the left edge -- and it lost a fight for space with Show More,
    /// truncating the host it exists to name.
    ///
    /// With one server there is no tag and this is the title line *itself*, not a stack wrapping
    /// it: wrapping a single child still changes layout, which measurably shifted every header
    /// and row below it against the single-server baseline. The row modifiers stay on the caller
    /// so they style the List row rather than whatever this returns -- nested inside the stack
    /// they silently stopped applying, costing the header its 24pt margin and themed background.
    @ViewBuilder
    private func projectHeaderContent(_ group: SessionGroup) -> some View {
        let isExpanded = expandedProjectIDs.contains(group.id)

        if let tag = group.tag {
            VStack(alignment: .leading, spacing: 2) {
                ServerBadge(tag: tag)
                projectHeaderTitleLine(group, isExpanded: isExpanded)
            }
        } else {
            projectHeaderTitleLine(group, isExpanded: isExpanded)
        }
    }

    private func projectHeaderTitleLine(_ group: SessionGroup, isExpanded: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(group.title)
                .font(.system(size: isSidebar ? 15 : 16, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.appPrimary)
                .lineLimit(1)

            Text("\u{00B7}")
                .font(theme.typography.captionRounded)
                .foregroundStyle(Color.appSecondary)

            Text(AppText.groupedProjectCount(group.sessions.count))
                .font(theme.typography.captionRounded)
                .foregroundStyle(Color.appSecondary)

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
    }

    /// One server's load failure, shown where its sections would be. The others still render.
    private func serverFailureNotice(_ failure: SessionServerFailure) -> some View {
        Text(AppText.sessionsServerUnavailable(failure.tag?.text))
            .font(theme.typography.captionRounded)
            .foregroundStyle(Color.appSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 6)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(
                top: 12,
                leading: isSidebar ? 12.0 : 24.0,
                bottom: 0,
                trailing: isSidebar ? 12.0 : 24.0
            ))
    }

    private func sessionRowButton(_ session: OCSession, serverID: String, supportsArchiving: Bool) -> some View {
        Button {
            openedSessionIDs.insert(session.id)
            selectSession(session, serverID: serverID)
        } label: {
            sessionRow(session, serverID: serverID)
        }
        .buttonStyle(.plain)
        .contextMenu {
            if supportsArchiving {
                Button {
                    archiveSession(session, serverID: serverID)
                } label: {
                    Label(AppText.archive, systemImage: "archivebox")
                }
            }

            Button(role: .destructive) {
                sessionToDelete = PendingDeletion(session: session, serverID: serverID)
                showDeleteConfirmation = true
            } label: {
                Label(AppText.delete, systemImage: "trash")
            }
        }
    }

    private func archiveSwipeButton(_ session: OCSession, serverID: String) -> some View {
        Button {
            archiveSession(session, serverID: serverID)
        } label: {
            Label(AppText.archive, systemImage: "archivebox")
        }
        .tint(Color.appAccent)
    }

    private func deleteSwipeButton(_ session: OCSession, serverID: String) -> some View {
        Button(role: .destructive) {
            sessionToDelete = PendingDeletion(session: session, serverID: serverID)
            showDeleteConfirmation = true
        } label: {
            Label(AppText.delete, systemImage: "trash")
        }
    }

    private func sessionRow(_ session: OCSession, serverID: String) -> some View {
        let status = statusesByServer[serverID]?[session.id]
        let isBusy = status?.type == .busy || status?.type == .retry
        let isSelected = isSidebar && selectedSessionID == session.id
        let showsListExecutionOutcomes = showsExecutionOutcomes(on: connection(for: serverID))

        let showsUnreadBadge = !isBusy && session.hasUnreadResult && showsListExecutionOutcomes

        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    SessionWorkingTitle(
                        title: session.title.isEmpty ? AppText.titleUntitled : session.title,
                        isWorking: isBusy
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if !isBusy, showsListExecutionOutcomes,
                              let outcome = session.executionOutcomeVisibleOnSessionList() {
                        ExecutionStatusView(state: outcome, idleTime: session.time.idle, isCompact: true)
                    } else if !isBusy, !showsListExecutionOutcomes {
                        Text(formattedDate(session.updatedAt))
                            .font(.system(size: 13, design: .rounded))
                            .foregroundStyle(Color.appSecondary)
                    }
                }

                // Unread results earn their own line: the badge gets breathing
                // room and the row itself stands taller than read rows.
                if showsUnreadBadge {
                    Text(AppText.unreadResult)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.appAccent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.appAccent.opacity(0.12), in: Capsule())
                        .accessibilityLabel(AppText.unreadResultAccessibility)
                        .accessibilityIdentifier("session.unreadResult.\(session.id)")
                }
            }

            if !isSidebar {
                Image(systemName: "chevron.right")
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(Color.appSecondary.opacity(0.7))
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, isSidebar ? 10 : 0)
        .background(
            isSelected ? Color.appTertiary : Color.clear,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .contentShape(Rectangle())
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 20) {
            RoundedRectangle(cornerRadius: theme.radius.card)
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

            Button(AppText.newSession) {
                presentNewSessionSheet()
            }
            .primaryCTAStyle()
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Side Effects (Service calls)

    /// Loads the given servers (every loadable one by default) side by side. Each server's
    /// sessions are applied as they arrive, and one failing leaves the others untouched.
    private func loadSessions(servers: Set<String>? = nil) async {
        guard !Task.isCancelled, !isLoading else { return }
        outcomeRefreshGeneration &+= 1
        let generation = outcomeRefreshGeneration
        viewState = .loading
        defer {
            if generation == outcomeRefreshGeneration, case .loading = viewState {
                viewState = .loaded
            }
        }
        let targets = loadableSources.filter { servers?.contains($0.id) ?? true }
        let failures = await withTaskGroup(of: String?.self) { group in
            for source in targets {
                group.addTask { @MainActor in
                    await loadSessions(from: source, generation: generation)
                }
            }
            var failures: [String] = []
            for await message in group {
                if let message { failures.append(message) }
            }
            return failures
        }
        guard !Task.isCancelled, generation == outcomeRefreshGeneration else { return }
        // Only a list with nothing to show and nowhere that answered becomes a full-screen error.
        if !targets.isEmpty, failures.count == targets.count, let first = failures.first {
            viewState = .error(first)
        } else {
            viewState = .loaded
        }
    }

    /// Returns the failure message when this server could not be loaded.
    private func loadSessions(from source: Source, generation: Int) async -> String? {
        do {
            let result = try await source.sessionsService.listAllSessions()
            guard !Task.isCancelled, generation == outcomeRefreshGeneration else { return nil }
            let requestedIDs = openedSessionIDs.union(failedOutcomeIDsByServer[source.id] ?? [])
            let snapshot = await source.sessionsService.refreshSessionOutcomes(
                in: result,
                previousStatuses: statusesByServer[source.id] ?? [:],
                openedSessionIDs: requestedIDs,
                refreshInactive: true
            )
            guard !Task.isCancelled, generation == outcomeRefreshGeneration else { return nil }
            failureByServer[source.id] = nil
            applyExecutionSnapshot(snapshot, requestedIDs: requestedIDs, serverID: source.id, service: source.sessionsService)
            return nil
        } catch is CancellationError {
            return nil
        } catch {
            guard !Task.isCancelled, generation == outcomeRefreshGeneration else { return nil }
            failureByServer[source.id] = error.localizedDescription
            return error.localizedDescription
        }
    }

    private func loadSessionStatuses(refreshInactive: Bool = false, refreshAttention: Bool = false) async {
        let targets = loadableSources.filter { !sessions(for: $0.id).isEmpty }
        guard !targets.isEmpty, !Task.isCancelled, !isLoading else { return }
        outcomeRefreshGeneration &+= 1
        let generation = outcomeRefreshGeneration
        await withTaskGroup(of: Void.self) { group in
            for source in targets {
                group.addTask { @MainActor in
                    await refreshStatuses(
                        from: source,
                        generation: generation,
                        refreshInactive: refreshInactive,
                        refreshAttention: refreshAttention
                    )
                }
            }
        }
    }

    private func refreshStatuses(
        from source: Source,
        generation: Int,
        refreshInactive: Bool,
        refreshAttention: Bool
    ) async {
        let current = sessions(for: source.id)
        let requestedIDs = openedSessionIDs.union(failedOutcomeIDsByServer[source.id] ?? [])
        let snapshot = await source.sessionsService.refreshSessionOutcomes(
            in: current,
            previousStatuses: statusesByServer[source.id] ?? [:],
            openedSessionIDs: requestedIDs,
            refreshInactive: refreshInactive
        )
        guard !Task.isCancelled, generation == outcomeRefreshGeneration else { return }
        applyExecutionSnapshot(snapshot, requestedIDs: requestedIDs, serverID: source.id, service: source.sessionsService)
        if refreshAttention {
            let refreshed = await source.sessionsService.refreshUnreadResults(
                in: sessions(for: source.id),
                statuses: statusesByServer[source.id] ?? [:]
            )
            guard !Task.isCancelled, generation == outcomeRefreshGeneration else { return }
            sessionsByServer[source.id] = source.sessionsService.applyingConfirmedViewedMarkers(to: refreshed)
        }
    }

    private func applyExecutionSnapshot(
        _ snapshot: SessionExecutionSnapshot,
        requestedIDs: Set<String>,
        serverID: String,
        service: SessionsService
    ) {
        sessionsByServer[serverID] = service.applyingConfirmedViewedMarkers(to: snapshot.sessions)
        statusesByServer[serverID] = snapshot.statuses
        failedOutcomeIDsByServer[serverID] = snapshot.failedOutcomeSessionIDs
        openedSessionIDs.subtract(requestedIDs)
        pruneExpandedProjects()
    }

    /// A session on another server makes that server the active one first, so the chat opens
    /// against the connection that owns the session.
    private func selectSession(_ session: OCSession, serverID: String) {
        if serverID != activeServerID {
            onActivateServer(serverID)
        }
        onSelect(session)
    }

    private func supportsArchiving(on serverID: String) -> Bool {
        connection(for: serverID).serverCapabilities?.protocolVersion == .v2 || ScreenshotFixtures.isEnabled
    }

    private func retryLoadingSessions() {
        Task {
            await loadSessions()
        }
    }

    private func presentNewSessionSheet() {
        // The server the user is looking at, so + after browsing B's sessions creates on B.
        let targetID = resolveNewSessionTarget(
            preferredServerID: serverFilterID,
            activeServerID: activeServerID,
            savedServerIDs: registry.savedServerContexts.map(\.id)
        )
        newSessionRequest = NewSessionRequest(targetServerID: targetID)
    }

    private func handleCreatedSession(_ session: OCSession, serverID id: String) {
        outcomeRefreshGeneration &+= 1
        openedSessionIDs.insert(session.id)
        viewState = .loaded
        sessionsByServer[id] = [session] + sessions(for: id)
        pruneExpandedProjects()
        selectSession(session, serverID: id)
    }

    private func deleteSession(_ session: OCSession, serverID: String) {
        Task {
            do {
                try await service(for: serverID).deleteSession(session)
                outcomeRefreshGeneration &+= 1
                if case .loading = viewState { viewState = .loaded }
                sessionsByServer[serverID] = sessions(for: serverID).filter { $0.id != session.id }
                pruneExpandedProjects()
                onDelete(session)
            } catch {
                viewState = .error(error.localizedDescription)
            }
        }
    }

    private func archiveSession(_ session: OCSession, serverID: String) {
        Task {
            do {
                try await service(for: serverID).archiveSession(session)
                outcomeRefreshGeneration &+= 1
                if case .loading = viewState { viewState = .loaded }
                sessionsByServer[serverID] = sessions(for: serverID).filter { $0.id != session.id }
                pruneExpandedProjects()
                onArchive(session)
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

    /// Forgets expansion for groups that no longer exist, on any server. Uses every server, not
    /// just the filtered ones, so switching the filter does not collapse what was opened.
    private func pruneExpandedProjects() {
        let validGroupIDs = Set(sources.flatMap { source in
            sessions(for: source.id).map { SessionGrouping.groupID(serverID: source.id, for: $0) }
        })
        expandedProjectIDs = expandedProjectIDs.intersection(validGroupIDs)
    }
}

private struct SessionsSidebarHeader: View {
    /// The sidebar's form of the toolbar capsule: present only while several servers are saved.
    struct ServerFilter {
        let title: String
        let targets: [ServerSwitchTargets.Target]
        let selection: Binding<String>
    }

    let serverFilter: ServerFilter?
    let onCreate: () -> Void
    var onShowArchived: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            if let serverFilter {
                filterMenu(serverFilter)
            } else {
                Text(AppText.sessions)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.appSecondary)
            }

            Spacer()

            if let onShowArchived {
                Button(action: onShowArchived) {
                    Image(systemName: "archivebox")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.appPrimary)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(AppText.archivedSessions)
            }

            Button(action: onCreate) {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.appPrimary)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(AppText.newSession)
        }
        .padding(.leading, 22)
        .padding(.trailing, 14)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }

    private func filterMenu(_ filter: ServerFilter) -> some View {
        Menu {
            Picker(AppText.servers, selection: filter.selection) {
                Text(AppText.sessionsAllServers)
                    .tag("")
                ForEach(filter.targets) { target in
                    Text(target.tag.text)
                        .tag(target.id)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(filter.title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.appSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.appSecondary)
            }
            .contentShape(Rectangle())
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .accessibilityLabel("\(AppText.sessions), \(filter.title)")
        .accessibilityHint(AppText.servers)
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
                .primaryCTAStyle()
        }
    }
}

private struct NewSessionSheet: View {
    private struct FolderBrowserRequest: Identifiable {
        let id = UUID()
        let directory: String
    }

    enum WorkspaceLoadState {
        case idle
        case loading
        case loaded
        case error(String)
    }

    /// Resolves the model for the *active* server; another server resolves its own.
    let newSessionModel: @MainActor () async -> OCV2ModelRef?
    /// Empty with one saved server, which is what keeps the sheet exactly as it was.
    let targets: [ServerSwitchTargets.Target]
    let onCreated: (OCSession, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.connection) private var activeConnection
    @Environment(\.savedConnections) private var savedConnections
    @Environment(\.sessionsService) private var activeSessionsService
    @Environment(\.workspaceService) private var activeWorkspaceService
    @Environment(\.serverRegistry) private var registry
    @Environment(\.openLensTheme) private var theme

    @State private var targetServerID: String?

    init(
        newSessionModel: @escaping @MainActor () async -> OCV2ModelRef?,
        targets: [ServerSwitchTargets.Target],
        initialTargetID: String,
        onCreated: @escaping (OCSession, String) -> Void
    ) {
        self.newSessionModel = newSessionModel
        self.targets = targets
        self.onCreated = onCreated
        self._targetServerID = State(initialValue: initialTargetID)
    }

    /// The target's context. The active server uses the environment's services, which the
    /// composition root keeps equal to the active context's own.
    private var targetContext: ServerContext {
        targetServerID.flatMap { registry.context(id: $0) } ?? registry.activeContext
    }

    private var isTargetActive: Bool { targetContext.id == registry.activeContext.id }
    private var connection: ConnectionManager { isTargetActive ? activeConnection : targetContext.connection }
    private var sessionsService: SessionsService { isTargetActive ? activeSessionsService : targetContext.sessionsService }
    private var workspaceService: WorkspaceService { isTargetActive ? activeWorkspaceService : targetContext.workspaceService }

    @State private var title = ""
    @State private var workspaceState: WorkspaceLoadState = .idle
    @State private var workspaceOptions: [WorkspaceSelectionOption] = []
    @State private var selectedWorkspaceID: WorkspaceSelectionOption.ID?
    @State private var defaultWorkspaceID: WorkspaceSelectionOption.ID?
    @State private var unavailablePreferredDirectory: String?
    @State private var createErrorMessage: String?
    @State private var isCreating = false
    @State private var folderBrowserRequest: FolderBrowserRequest?

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
                    if targets.count > 1 {
                        serverSection
                    }
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
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .accessibilityLabel(AppText.dismiss)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await createSession() }
                    } label: {
                        if isCreating {
                            ProgressView()
                                .tint(Color.appAccent)
                        } else {
                            Image(systemName: "plus")
                                .font(.system(size: 16, weight: .semibold))
                        }
                    }
                    .accessibilityLabel(AppText.create)
                    .disabled(!canCreate)
                }
            }
            .task(id: targetServerID) {
                await loadWorkspaceOptions()
            }
            .sheet(item: $folderBrowserRequest) { request in
                WorkspaceFolderBrowser(initialDirectory: request.directory, onSelect: selectBrowsedDirectory)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(Color.appBackground)
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
                .font(theme.typography.sectionLabel)
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
                .background(Color.appSurface, in: RoundedRectangle(cornerRadius: theme.radius.control, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: theme.radius.control, style: .continuous)
                        .stroke(Color.appSeparator, lineWidth: 1)
                }
        }
    }

    /// Which server the session is created on. Only offered with several saved servers.
    private var serverSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppText.server)
                .font(theme.typography.sectionLabel)
                .foregroundStyle(Color.appSecondary)
                .textCase(.uppercase)

            Menu {
                Picker(AppText.server, selection: Binding(
                    get: { targetServerID ?? "" },
                    set: { targetServerID = $0 }
                )) {
                    ForEach(targets) { target in
                        Text(target.tag.text).tag(target.id)
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    if let tag = targets.first(where: { $0.id == targetServerID })?.tag {
                        ServerBadge(tag: tag, color: Color.appPrimary, size: 15)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color.appSecondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
                .background(Color.appSurface, in: RoundedRectangle(cornerRadius: theme.radius.control, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: theme.radius.control, style: .continuous)
                        .stroke(Color.appSeparator, lineWidth: 1)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var workspaceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(AppText.workspace)
                    .font(theme.typography.sectionLabel)
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

            Button {
                folderBrowserRequest = FolderBrowserRequest(
                    directory: selectedWorkspace?.directory ?? connection.selectedProjectDirectory ?? "/"
                )
            } label: {
                Label(AppText.browseFolders, systemImage: "folder.badge.plus")
                    .font(theme.typography.rowTitleEmphasized)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Color.appSurface, in: RoundedRectangle(cornerRadius: theme.radius.control, style: .continuous))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.appAccent)
            .disabled(isCreating || isLoadingWorkspaces)
            .accessibilityIdentifier("newSession.browseFolders")
        }
    }

    private var loadingRow: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(Color.appAccent)
            Text(AppText.workspaceLoadingWorkspaces)
                .font(.system(size: 14, design: .rounded))
                .foregroundStyle(Color.appSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.appSurface, in: RoundedRectangle(cornerRadius: theme.radius.control, style: .continuous))
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
        .background(Color.appSurface, in: RoundedRectangle(cornerRadius: theme.radius.listGroup, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: theme.radius.listGroup, style: .continuous)
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
                    .background(iconTint(for: option).opacity(0.12), in: RoundedRectangle(cornerRadius: theme.radius.iconTile, style: .continuous))

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(option.title)
                            .font(theme.typography.rowTitleEmphasized)
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
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: theme.radius.rowHighlight, style: .continuous))
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

    private func selectBrowsedDirectory(_ directory: String) {
        let option = WorkspaceSelectionOption(
            id: "directory:\(directory)",
            directory: directory,
            projectID: nil,
            title: WorkspaceSelectionBuilder.displayName(for: directory),
            subtitle: directory,
            availability: .available,
            isCurrent: directory == connection.selectedProjectDirectory,
            isRecent: false
        )
        workspaceOptions.removeAll { $0.id == option.id }
        workspaceOptions.insert(option, at: 0)
        selectedWorkspaceID = option.id
        unavailablePreferredDirectory = nil
        createErrorMessage = nil
        workspaceState = .loaded
    }

    private func loadWorkspaceOptions() async {
        workspaceState = .loading
        createErrorMessage = nil

        let activeConnectionID = connection.connectionID
        let recentDirectories = activeConnectionID
            .map { savedConnections.recentProjectSelections(connectionID: $0) }
            ?? []
        let preferredDirectory = activeConnectionID
            .flatMap { savedConnections.savedProjectSelection(connectionID: $0) }
            ?? connection.selectedProjectDirectory

        do {
            let snapshot = try await workspaceService.loadWorkspaceSelection(
                verifying: recentDirectories + [preferredDirectory].compactMap { $0 }
            )

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
                clearsWorkspaceContext: selectedWorkspace.clearsWorkspaceContext,
                model: isTargetActive ? await newSessionModel() : await targetContext.chatClient.newSessionModelPreference()
            )
            onCreated(session, targetContext.id)
            dismiss()
        } catch {
            createErrorMessage = error.localizedDescription
        }
    }
}

// MARK: - Server Filter Capsule

/// The toolbar capsule while several servers are saved: it filters the list rather than naming
/// one host, so it carries no connection status.
private struct ServerFilterCapsule: View {
    let title: String

    var body: some View {
        GlassToolbarCapsule(isInteractive: true) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.appPrimary)
                .lineLimit(1)
                .truncationMode(.middle)

            Image(systemName: "chevron.down")
                .font(.caption2.weight(.bold))
                .foregroundStyle(Color.appSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(AppText.sessions), \(title)")
        .accessibilityHint(AppText.servers)
    }
}

// MARK: - Connected Host Capsule

private struct ConnectedHostCapsule: View {
    let host: String
    let isReconnecting: Bool

    var body: some View {
        GlassToolbarCapsule(isInteractive: false) {
            Circle()
                .fill(isReconnecting ? Color.appWarning : Color.appSuccess)
                .frame(width: 7, height: 7)
            Text(host)
                .font(.subheadline.weight(.medium).monospaced())
                .foregroundStyle(Color.appPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(AppText.sessions), \(host)")
    }
}

private extension SessionGroup {
    static let collapsedSessionLimit = 4

    var visibleSessions: [OCSession] {
        Array(sessions.prefix(Self.collapsedSessionLimit))
    }

    var hiddenSessionCount: Int {
        max(sessions.count - Self.collapsedSessionLimit, 0)
    }
}
