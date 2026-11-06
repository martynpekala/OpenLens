import SwiftUI

/// Everything the Sessions filter shows and does, so the toolbar capsule and the iPad sidebar
/// header present the same popover from one value.
struct SessionFilterModel {
    struct ServerOption: Identifiable {
        let id: String
        let tag: ServerTag
        let status: ServerRowStatus
        /// Nil renders an em dash: the server has no count, which is not the same as none.
        let count: Int?
    }

    struct WorkspaceOption: Identifiable {
        let id: String
        let text: String
        /// The server in front of the workspace while the list spans several; nil once one is chosen.
        let server: ServerTag?
        let count: Int?
    }

    let title: String
    /// Empty while a single server is saved: the section would be a group of one.
    let servers: [ServerOption]
    let allServersCount: Int
    let workspaces: [WorkspaceOption]
    let allWorkspacesCount: Int
    let serverSelection: Binding<String>
    let workspaceSelection: Binding<String>
    let isFiltered: Bool
    let onClear: () -> Void

    static let allID = ""
}

/// The popover behind the Sessions capsule: Servers, then Workspaces, each opening with an "All"
/// row. Follows `ReviewSessionPickerList`: a plain `List`, an accent checkmark on the selection.
struct SessionFilterPopover: View {
    let model: SessionFilterModel
    let onDone: () -> Void

    @Environment(\.openLensTheme) private var theme

    private static let width: CGFloat = 340
    private static let rowHeight: CGFloat = 44

    var body: some View {
        List {
            if !model.servers.isEmpty {
                Section {
                    serverRow(
                        id: SessionFilterModel.allID,
                        status: nil,
                        name: Text(AppText.sessionsAllServers).font(theme.typography.rowTitle),
                        count: model.allServersCount
                    )
                    ForEach(model.servers) { server in
                        serverRow(id: server.id, status: server.status, name: name(for: server.tag), count: server.count)
                    }
                } header: {
                    groupLabel(AppText.servers)
                }
            }

            Section {
                workspaceRow(
                    id: SessionFilterModel.allID,
                    name: Text(AppText.sessionsAllWorkspaces).font(theme.typography.rowTitle),
                    count: model.allWorkspacesCount
                )
                ForEach(model.workspaces) { workspace in
                    workspaceRow(
                        id: workspace.id,
                        name: workspaceName(workspace),
                        server: workspaceServer(workspace),
                        count: workspace.count
                    )
                }
            } header: {
                groupLabel(AppText.workspaces)
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, Self.rowHeight)
        .listSectionSpacing(0)
        .scrollContentBackground(.hidden)
        .background(Color.appSurface)
        .overlay {
            if model.workspaces.isEmpty, model.servers.isEmpty {
                ContentUnavailableView(AppText.sessionsAllWorkspaces, systemImage: "folder")
            }
        }
        .frame(width: Self.width, height: preferredHeight)
        .presentationCompactAdaptation(.popover)
        .presentationBackground(Color.appSurface)
        .presentationCornerRadius(theme.radius.listGroup)
    }

    /// Fits the rows up to a ceiling, then scrolls: a popover sized by a `List` alone collapses.
    private var preferredHeight: CGFloat {
        let rows = (model.servers.isEmpty ? 0 : model.servers.count + 1) + model.workspaces.count + 1
        let headers = model.servers.isEmpty ? 1 : 2
        return min(CGFloat(rows) * Self.rowHeight + CGFloat(headers) * 32 + 28, 520)
    }

    private func groupLabel(_ text: String) -> some View {
        Text(text)
            .font(theme.typography.sectionLabel)
            .foregroundStyle(Color.appSecondary)
            .textCase(nil)
            .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 4, trailing: 20))
    }

    /// The server in the rounded face (a name) or monospaced (a host), the workspace monospaced.
    private func workspaceName(_ workspace: SessionFilterModel.WorkspaceOption) -> Text {
        Text(workspace.text).font(.system(size: 15, weight: .medium, design: .monospaced))
    }

    /// The server a workspace belongs to, when the list spans several -- two servers can hold a
    /// folder of the same name, which is the whole reason this qualifier exists.
    private func workspaceServer(_ workspace: SessionFilterModel.WorkspaceOption) -> Text? {
        guard let server = workspace.server else { return nil }
        return Text(server.text)
            .font(server.kind == .nickname
                ? .system(size: 12, design: .rounded)
                : .system(size: 12, design: .monospaced))
    }

    private func name(for tag: ServerTag) -> Text {
        switch tag.kind {
        case .nickname: Text(tag.text).font(theme.typography.rowTitle)
        case .host: Text(tag.text).font(.system(size: 14, weight: .medium, design: .monospaced))
        }
    }

    private func serverRow(id: String, status: ServerRowStatus?, name: Text, count: Int?) -> some View {
        let isSelected = model.serverSelection.wrappedValue == id
        return row(isSelected: isSelected, status: status, name: name, count: count) {
            model.serverSelection.wrappedValue = id
            onDone()
        }
    }

    private func workspaceRow(id: String, name: Text, server: Text? = nil, count: Int?) -> some View {
        let isSelected = model.workspaceSelection.wrappedValue == id
        return row(isSelected: isSelected, status: nil, name: name, subtitle: server, count: count) {
            model.workspaceSelection.wrappedValue = id
            onDone()
        }
    }

    private func row(
        isSelected: Bool,
        status: ServerRowStatus?,
        name: Text,
        subtitle: Text? = nil,
        count: Int?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                // Keeps the names of the "All" row and the server rows on one leading edge.
                Circle()
                    .fill(status?.dotColor ?? Color.clear)
                    .frame(width: 7, height: 7)
                    .opacity(status == nil ? 0 : 1)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    name
                        .foregroundStyle(Color.appPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    // The server qualifying a workspace goes underneath rather than in front:
                    // inline, a truncated host ran into the folder name and swallowed the
                    // separator, and two type sizes collided on one line.
                    if let subtitle {
                        subtitle
                            .foregroundStyle(Color.appSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
                Text(count.map(String.init) ?? "\u{2014}")
                    .font(theme.typography.captionRounded)
                    .foregroundStyle(Color.appSecondary)
                    .monospacedDigit()
                // Reserved even when unselected, so counts stay aligned on one trailing edge.
                Image(systemName: "checkmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.appAccent)
                    .opacity(isSelected ? 1 : 0)
                    .frame(width: 14)
            }
            .frame(minHeight: Self.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
        .listRowBackground(
            RoundedRectangle(cornerRadius: theme.radius.rowHighlight, style: .continuous)
                .fill(isSelected ? Color.appTertiary : Color.clear)
                .padding(.horizontal, 8)
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
