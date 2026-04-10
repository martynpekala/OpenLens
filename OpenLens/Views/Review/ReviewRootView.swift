import SwiftUI

private let reviewSessionScopeID = "__session__"

private enum ReviewLayout {
    static let screenInset: CGFloat = 20
    static let screenVerticalPadding: CGFloat = 24
    static let sectionGap: CGFloat = 28
    static let groupGap: CGFloat = 16
    static let compactGap: CGFloat = 8
    static let chipGap: CGFloat = 12
    static let rowPaddingHorizontal: CGFloat = 16
    static let rowPaddingVertical: CGFloat = 14
}

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

    enum ViewState {
        case idle
        case loading
        case loaded
        case error(String)
    }

    @Bindable var chatClient: ChatClient

    @Environment(\.inboxService) private var inboxService
    @Environment(\.reviewService) private var reviewService
    @Environment(\.sessionsService) private var sessionsService

    @State private var viewState: ViewState = .idle
    @State private var reviewSnapshot: SessionReviewSnapshot?
    @State private var changeSetToRevert: ReviewChangeSet?
    @State private var selectedScopeID = reviewSessionScopeID
    @State private var selectedFile: ReviewFileChange?
    @State private var availableSessions: [OCSession] = []
    @State private var selectedReviewSessionID: String?
    @State private var inboxBadgeCount = 0
    @State private var isInboxPresented = false
    @State private var selectedScopeState = SelectedScopeState.empty

    var body: some View {
        Group {
            content
        }
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await refreshAvailableSessions(preferActiveSession: true)
            await refreshInboxBadgeCount()
        }
        .task(id: chatClient.currentSession?.id) {
            await refreshAvailableSessions(preferActiveSession: true)
        }
        .task(id: selectedReviewSessionID) {
            await loadReview(resetScope: true)
        }
        .onChange(of: selectedScopeID) { _, _ in
            refreshSelectedScopeState()
        }
        .refreshable {
            await refreshAvailableSessions(preferActiveSession: false)
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
            ToolbarItem(placement: .topBarTrailing) {
                inboxToolbarButton
            }
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
            FeaturePlaceholderView(
                title: "Review",
                subtitle: "No sessions available yet. Start a chat or pick a session once one exists.",
                symbol: "doc.text.magnifyingglass",
                highlights: [
                    "Review can inspect any existing session",
                    "The active chat session is selected by default",
                    "If there is no active chat, the most recent session is used"
                ]
            )
        case .idle:
            ProgressView()
                .tint(Color.appSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.appBackground)
        case .loading where reviewSnapshot == nil:
            ProgressView()
                .tint(Color.appSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.appBackground)
        case .error(let message) where reviewSnapshot == nil:
            FeaturePlaceholderView(
                title: "Review",
                subtitle: message,
                symbol: "exclamationmark.triangle",
                highlights: [
                    "Pull to refresh and retry",
                    "Changes are loaded from the active session only",
                    "Chat stays available while Review reloads"
                ]
            )
        default:
            reviewScrollView
        }
    }

    private var reviewScrollView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ReviewLayout.sectionGap) {
                sessionPickerCard

                if let reviewSnapshot, !reviewSnapshot.changeSets.isEmpty {
                    scopePickerSection(reviewSnapshot.changeSets)
                }
                
                filesSection                
            }
            .padding(.horizontal, ReviewLayout.screenInset)
            .padding(.bottom, ReviewLayout.screenVerticalPadding)
        }
        .background(Color.appBackground)
    }

    private var inboxToolbarButton: some View {
        Button {
            isInboxPresented = true
        } label: {
            Image(systemName: inboxBadgeCount > 0 ? "bell.badge" : "bell")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.appPrimary)
                .frame(width: 28, height: 28)
                .overlay(alignment: .topTrailing) {
                    if inboxBadgeCount > 0 {
                        Text(inboxBadgeLabel)
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.red, in: Capsule())
                            .fixedSize()
                            .offset(x: 8, y: -6)
                    }
                }
                .frame(width: 38, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(inboxAccessibilityLabel)
    }

    private var sessionPickerCard: some View {
        HStack(alignment: .firstTextBaseline, spacing: ReviewLayout.groupGap) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Reviewing session")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.appSecondary)
                    .textCase(.uppercase)

                Text(selectedReviewSession?.title.nilIfBlank ?? AppText.titleUntitled)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.appPrimary)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 12) {
                    Text("+\(selectedScopeState.totals.additions)")
                        .foregroundStyle(.green)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.appSurface, in: Capsule())
                        .overlay(
                            Capsule()
                                .stroke(Color.green.opacity(0.3), lineWidth: 1)
                        )
                    Text("-\(selectedScopeState.totals.deletions)")
                        .foregroundStyle(.red)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.appSurface, in: Capsule())
                        .overlay(
                            Capsule()
                                .stroke(Color.red.opacity(0.3), lineWidth: 1)
                        )
                }
                .font(.system(size: 12, weight: .medium, design: .rounded))
            }

            Spacer(minLength: 12)

            Menu {
                ForEach(availableSessions) { session in
                    Button {
                        selectedReviewSessionID = session.id
                    } label: {
                        if session.id == selectedReviewSessionID {
                            Label(session.title.nilIfBlank ?? AppText.titleUntitled, systemImage: "checkmark")
                        } else {
                            Text(session.title.nilIfBlank ?? AppText.titleUntitled)
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text("Change")
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                }
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.appPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.appSurface, in: Capsule())
                .overlay(
                    Capsule()
                        .stroke(Color.appSeparator, lineWidth: 1)
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.appTertiary)
        )
    }

    private func scopePickerSection(_ changeSets: [ReviewChangeSet]) -> some View {
        VStack(alignment: .leading, spacing: 12) {

            Text("Choose a single agent update or inspect the full working session.")
                .font(.system(size: 13))
                .foregroundStyle(Color.appSecondary)
            

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: ReviewLayout.chipGap) {
                    scopeChip(
                        title: "Latest",
                        subtitle: reviewSnapshot?.latestChangeSet.map { shortDate($0.createdAt) } ?? "Agent changes",
                        isSelected: selectedScopeID == (reviewSnapshot?.latestChangeSet?.id ?? reviewSessionScopeID)
                    ) {
                        selectedScopeID = reviewSnapshot?.latestChangeSet?.id ?? reviewSessionScopeID
                    }

                    scopeChip(
                        title: "Session",
                        subtitle: "All current changes",
                        isSelected: selectedScopeID == reviewSessionScopeID
                    ) {
                        selectedScopeID = reviewSessionScopeID
                    }

                    ForEach(changeSets) { changeSet in
                        scopeChip(
                            title: truncatedScopeTitle(changeSet.title),
                            subtitle: shortDate(changeSet.createdAt),
                            isSelected: selectedScopeID == changeSet.id
                        ) {
                            selectedScopeID = changeSet.id
                        }
                    }
                }
                .padding(.horizontal, 1)
                .padding(.vertical, 2)
            }
        }
    }

    private var filesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(selectedScopeID == reviewSessionScopeID ? "SESSION FILES" : "FILTERED FILES")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.appSecondary)
                    .kerning(0.5)

                Spacer(minLength: 8)

                Text(selectedScopeState.fileCountLabel)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.appSecondary)
            }

            SurfaceCard(padding: 0) {
                if selectedScopeState.files.isEmpty {
                    emptyStateRow
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(selectedScopeState.files.enumerated()), id: \.element.id) { index, file in
                            Button {
                                selectedFile = file
                            } label: {
                                fileRow(file)
                                    .padding(.horizontal, ReviewLayout.rowPaddingHorizontal)
                                    .padding(.vertical, ReviewLayout.rowPaddingVertical)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            if index < selectedScopeState.files.count - 1 {
                                SurfaceDivider()
                            }
                        }
                    }
                }
            }

            if let selectedChangeSet = selectedScopeState.changeSet {
                revertChangeSetCard(selectedChangeSet)
                    .padding(.top, 16)
            }
        }
    }

    private func revertChangeSetCard(_ changeSet: ReviewChangeSet) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.red)

                Text("Danger Zone")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.red)
                    .textCase(.uppercase)
                    .kerning(0.6)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.08))

            SurfaceDivider()

            VStack(alignment: .leading, spacing: 14) {
                Text("Revert this update")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.appPrimary)

                Text("Undo only the changes introduced by \"\(truncatedScopeTitle(changeSet.title))\" in this session.")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.appPrimary)

                Text("This action creates a rollback for the selected agent update. It does not delete the whole session, but it will remove the code changes from this update after confirmation.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.appSecondary)

                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Selected update")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.appSecondary)

                        Text(changeSet.title)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.appPrimary)
                            .lineLimit(2)
                    }

                    Spacer(minLength: 12)

                    Button("Revert update", role: .destructive) {
                        changeSetToRevert = changeSet
                    }
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.appSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.red.opacity(0.35), lineWidth: 1)
        )
    }

    private var emptyStateRow: some View {
        HStack {
            Text("No file changes available for this selection.")
                .font(.system(size: 14))
                .foregroundStyle(Color.appSecondary)
            Spacer()
        }
        .padding(.horizontal, ReviewLayout.rowPaddingHorizontal)
        .padding(.vertical, ReviewLayout.rowPaddingVertical)
    }

    private func fileRow(_ file: ReviewFileChange) -> some View {
        FileChangeRow(file: file)
    }

    private func scopeChip(title: String, subtitle: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11, design: .rounded))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? Color.appSurface : Color.appPrimary)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(minWidth: 148, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isSelected ? Color.appPrimary : Color.appSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isSelected ? Color.clear : Color.appSeparator, lineWidth: 1)
            )
            .surfaceShadow()
        }
        .buttonStyle(.plain)
    }

    private func overviewPill(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(Color.appSecondary)
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(Color.appPrimary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.appTertiary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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

    private var selectedReviewSession: OCSession? {
        guard let selectedReviewSessionID else { return nil }
        return availableSessions.first(where: { $0.id == selectedReviewSessionID })
    }

    private var errorMessage: String? {
        if case .error(let message) = viewState {
            return message
        }
        return nil
    }

    private var inboxBadgeLabel: String {
        inboxBadgeCount > 99 ? "99+" : "\(inboxBadgeCount)"
    }

    private var inboxAccessibilityLabel: String {
        if inboxBadgeCount == 0 {
            return "Open inbox"
        }

        let itemLabel = inboxBadgeCount == 1 ? "item" : "items"
        return "Open inbox, \(inboxBadgeCount) pending \(itemLabel)"
    }

    private func truncatedScopeTitle(_ title: String) -> String {
        guard title.count > 25 else { return title }
        return String(title.prefix(24)) + "…"
    }

    private func shortDate(_ date: Date?) -> String {
        guard let date else { return "No timestamp" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func refreshAvailableSessions(preferActiveSession: Bool) async {
        do {
            let sessions = try await sessionsService.listSessions()
            availableSessions = sessions

            let activeSessionID = chatClient.currentSession?.id
            let activeSessionIsAvailable = activeSessionID.flatMap { sessionID in
                sessions.contains(where: { $0.id == sessionID }) ? sessionID : nil
            }

            if preferActiveSession, let activeSessionIsAvailable {
                selectedReviewSessionID = activeSessionIsAvailable
            } else if let selectedReviewSessionID,
                      sessions.contains(where: { $0.id == selectedReviewSessionID }) {
                self.selectedReviewSessionID = selectedReviewSessionID
            } else if let activeSessionIsAvailable {
                selectedReviewSessionID = activeSessionIsAvailable
            } else {
                selectedReviewSessionID = sessions.first?.id
            }
        } catch {
            if availableSessions.isEmpty {
                viewState = .error(error.localizedDescription)
            }
        }
    }

    private func loadReview(force: Bool = false, resetScope: Bool = false) async {
        guard let sessionID = selectedReviewSessionID else {
            reviewSnapshot = nil
            selectedScopeID = reviewSessionScopeID
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

        if resetScope || !validScopeIDs.contains(selectedScopeID) {
            selectedScopeID = snapshot.latestChangeSet?.id ?? reviewSessionScopeID
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
            if chatClient.currentSession?.id == sessionID {
                await chatClient.loadMessages()
            }
            await loadReview(force: true)
        } catch {
            viewState = .error(error.localizedDescription)
        }
    }
}
