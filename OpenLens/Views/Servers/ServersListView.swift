import SwiftUI

/// Adds, names, inspects and forgets servers. Pushed from Settings; with one saved server it is
/// the only multi-server surface there is, and the way to add a second.
struct ServersListView: View {
    private enum SheetRequest: Identifiable {
        case add
        case rename(SavedConnection)

        var id: String {
            switch self {
            case .add: "add"
            case .rename(let profile): "rename-\(profile.id)"
            }
        }
    }

    @Environment(\.serverRegistry) private var registry
    @Environment(\.openLensTheme) private var theme

    @State private var sheetRequest: SheetRequest? = ScreenshotFixtures.opensServerSheet ? .add : nil
    @State private var serverToForget: ServerContext?
    @State private var noticeMessage: String?

    private var contexts: [ServerContext] {
        registry.savedServerContexts
    }

    var body: some View {
        content
            .navigationTitle(AppText.servers)
            .navigationBarTitleDisplayMode(.inline)
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .background(Color.appBackground)
            .sheet(item: $sheetRequest) { request in
                switch request {
                case .add:
                    ServerEditSheet(mode: .add) { profile in
                        Task { await connectAfterAdding(profile) }
                    }
                case .rename(let profile):
                    ServerEditSheet(mode: .rename(profile)) { _ in }
                }
            }
            .confirmationDialog(
                AppText.serversForgetTitle,
                isPresented: Binding(
                    get: { serverToForget != nil },
                    set: { if !$0 { serverToForget = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button(AppText.forget, role: .destructive) {
                    if let serverToForget { registry.remove(id: serverToForget.id) }
                    serverToForget = nil
                }
                Button(AppText.cancel, role: .cancel) {
                    serverToForget = nil
                }
            } message: {
                Text(AppText.serversForgetMessage)
            }
    }

    @ViewBuilder
    private var content: some View {
        if contexts.isEmpty {
            ContentUnavailableView {
                Label(AppText.serversEmptyTitle, systemImage: "server.rack")
            } description: {
                Text(AppText.serversEmptyMessage)
            } actions: {
                Button(AppText.serversAdd) {
                    sheetRequest = .add
                }
                .primaryCTAStyle()
            }
        } else {
            serverList
        }
    }

    private var serverList: some View {
        List {
            if let noticeMessage {
                noticeRow(message: noticeMessage)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 24, bottom: 4, trailing: 24))
            }

            ForEach(contexts) { context in
                if let profile = registry.profile(for: context) {
                    let status = serverRowStatus(
                        connectionState: context.connection.state,
                        isActive: context.id == registry.activeServerID
                    )
                    HStack(spacing: 4) {
                        Button {
                            Task { await open(context, profile: profile) }
                        } label: {
                            serverRow(profile: profile, status: status)
                        }
                        .buttonStyle(.plain)

                        rowActionsMenu(context, profile: profile)
                    }
                    .listRowBackground(activeHighlight(status == .active))
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 12, leading: 24, bottom: 12, trailing: 24))
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        forgetButton(context)
                        if registry.isLive(context) {
                            disconnectButton(context)
                        }
                        renameButton(profile)
                    }
                    .contextMenu {
                        renameButton(profile)
                        if registry.isLive(context) {
                            disconnectButton(context)
                        }
                        forgetButton(context)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 16, for: .scrollContent)
        .contentMargins(.bottom, 16, for: .scrollContent)
        .safeAreaInset(edge: .bottom, alignment: .trailing, spacing: 0) {
            addServerButton
                .padding(.trailing, 24)
                .padding(.top, 12)
                .padding(.bottom, 32)
        }
    }

    // MARK: - Row

    private func serverRow(profile: SavedConnection, status: ServerRowStatus) -> some View {
        let host = connectionServerDisplayName(profile.serverURL) ?? profile.serverURL
        let nickname = profile.nickname?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank

        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                // Same 7pt dot as the host capsule, so the two read as one language.
                Circle()
                    .fill(status.dotColor)
                    .frame(width: 7, height: 7)
                    .alignmentGuide(.firstTextBaseline) { _ in 8 }

                VStack(alignment: .leading, spacing: 2) {
                    if let nickname {
                        Text(nickname)
                            .font(theme.typography.rowTitle)
                            .foregroundStyle(Color.appPrimary)
                            .lineLimit(1)
                        Text(host)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(Color.appSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text(host)
                            .font(.system(size: 15, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.appPrimary)
                            .lineLimit(1)
                            // Tail, not middle: when the row is tight it is the hostname that
                            // tells two machines apart, and middle truncation spends it to keep
                            // a port they usually share.
                            .truncationMode(.tail)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(status.label)
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(Color.appSecondary)
                .lineLimit(1)
                .fixedSize()

        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(status == .active ? [.isSelected] : [])
    }

    /// Marks the active row the way the sidebar marks its selected tab: `appTertiary` at the
    /// `rowHighlight` radius, inset so the row's 24pt text margin sits inside the fill.
    @ViewBuilder
    private func activeHighlight(_ isActive: Bool) -> some View {
        if isActive {
            RoundedRectangle(cornerRadius: theme.radius.rowHighlight, style: .continuous)
                .fill(Color.appTertiary)
                .padding(.horizontal, 12)
        } else {
            Color.clear
        }
    }

    private func noticeRow(message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.appWarning)
                .padding(.top, 2)

            Text(message)
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(Color.appSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(
            Color.appWarning.opacity(0.08),
            in: RoundedRectangle(cornerRadius: theme.radius.rowHighlight, style: .continuous)
        )
    }

    // MARK: - Actions

    private var addServerButton: some View {
        Button {
            sheetRequest = .add
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(Color.appOnNeutralAction)
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .tint(Color.appNeutralAction)
        .accessibilityLabel(AppText.serversAdd)
    }

    /// The row's actions need somewhere visible to live. Tapping a row picks a server rather
    /// than pushing a screen, so there is no chevron to hint at more; a checkmark used to sit
    /// here, but the tinted row and the "Active" label already say which server is active, so it
    /// was the one trailing slot carrying no information. Swipe and long-press still work --
    /// this just stops rename being reachable only by gestures nothing advertises.
    private func rowActionsMenu(_ context: ServerContext, profile: SavedConnection) -> some View {
        Menu {
            renameButton(profile)
            if registry.isLive(context) {
                disconnectButton(context)
            }
            forgetButton(context)
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 17))
                .foregroundStyle(Color.appSecondary)
                // 44pt is the minimum comfortable touch target.
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(AppText.serversRowActionsAccessibility(profile.displayName))
    }

    private func renameButton(_ profile: SavedConnection) -> some View {
        Button {
            sheetRequest = .rename(profile)
        } label: {
            Label(AppText.serversRename, systemImage: "pencil")
        }
        .tint(Color.appAccent)
    }

    private func disconnectButton(_ context: ServerContext) -> some View {
        Button {
            context.connection.manualDisconnect()
        } label: {
            Label(AppText.disconnect, systemImage: "bolt.slash")
        }
        .tint(Color.appSecondary)
    }

    private func forgetButton(_ context: ServerContext) -> some View {
        Button(role: .destructive) {
            serverToForget = context
        } label: {
            Label(AppText.forget, systemImage: "trash")
        }
    }

    /// Tap: bring an idle server up, then make it the one the app shows. A refusal by the
    /// connection cap surfaces here as a notice; a failed connect shows on the row itself.
    private func open(_ context: ServerContext, profile: SavedConnection) async {
        noticeMessage = nil
        if !registry.isLive(context) {
            do {
                try await registry.connect(profile: profile)
            } catch {
                noticeMessage = error.localizedDescription
                return
            }
        }
        guard context.connection.isConnected else { return }
        registry.activate(id: context.id)
    }

    private func connectAfterAdding(_ profile: SavedConnection) async {
        noticeMessage = nil
        do {
            try await registry.connect(profile: profile)
        } catch {
            noticeMessage = error.localizedDescription
        }
    }
}
