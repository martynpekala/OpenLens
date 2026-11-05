import SwiftUI

/// Adds a server, or renames one. Adding saves it and hands the profile back so the list can
/// connect it and report a refusal; this sheet never connects.
struct ServerEditSheet: View {
    enum Mode {
        case add
        case rename(SavedConnection)
    }

    let mode: Mode
    let onSaved: (SavedConnection) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.serverRegistry) private var registry
    @Environment(\.openLensTheme) private var theme

    @State private var serverURL = ""
    @State private var username = AppText.serversUsernameDefault
    @State private var password = ""
    @State private var nickname = ""
    @State private var didSeedFields = false

    private var isRename: Bool {
        if case .rename = mode { true } else { false }
    }

    private var canSave: Bool {
        isRename || connectionServerDisplayName(serverURL) != nil
    }

    private var isAtConnectionLimit: Bool {
        registry.liveConnectionCount >= ServerRegistry.maximumConcurrentConnections
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if case .rename(let profile) = mode {
                        renameHeader(profile)
                    } else {
                        addFields
                    }

                    field(AppText.serversNickname) {
                        TextField(AppText.serversNicknamePlaceholder, text: $nickname)
                            .textInputAutocapitalization(.words)
                            .font(theme.typography.rowTitle)
                    }

                    if !isRename, isAtConnectionLimit {
                        noticeRow(
                            icon: "exclamationmark.triangle.fill",
                            message: AppText.serversAtLimitNotice,
                            tint: Color.appWarning
                        )
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 28)
            }
            .background(Color.appBackground)
            .navigationTitle(isRename ? AppText.serversRenameTitle : AppText.serversAdd)
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
                    Button(action: save) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .accessibilityLabel(AppText.serversSave)
                    .disabled(!canSave)
                }
            }
            .onAppear(perform: seedFields)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.appBackground)
    }

    // MARK: - Sections

    private var addFields: some View {
        VStack(alignment: .leading, spacing: 22) {
            field(AppText.serversServerURL) {
                TextField(AppText.serversServerURLPlaceholder, text: $serverURL)
                    .font(.system(size: 15, design: .monospaced))
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            field(AppText.serversUsername) {
                TextField(AppText.serversUsernameDefault, text: $username)
                    .font(.system(size: 15, design: .monospaced))
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            field(AppText.password) {
                SecureField(AppText.serversPasswordPlaceholder, text: $password)
                    .font(.system(size: 15, design: .monospaced))
                    .textContentType(.password)
            }
        }
    }

    private func renameHeader(_ profile: SavedConnection) -> some View {
        Text(connectionServerDisplayName(profile.serverURL) ?? profile.serverURL)
            .font(.system(size: 15, design: .monospaced))
            .foregroundStyle(Color.appSecondary)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(theme.typography.sectionLabel)
                .foregroundStyle(Color.appSecondary)

            content()
                .foregroundStyle(Color.appPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    Color.appSurface,
                    in: RoundedRectangle(cornerRadius: theme.radius.control, style: .continuous)
                )
        }
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

    // MARK: - Actions

    private func seedFields() {
        guard !didSeedFields else { return }
        didSeedFields = true
        if case .rename(let profile) = mode {
            nickname = profile.nickname ?? ""
        }
    }

    private func save() {
        let trimmedNickname = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        switch mode {
        case .add:
            let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
            let profile = registry.add(
                serverURL: serverURL.trimmingCharacters(in: .whitespacesAndNewlines),
                username: trimmedUsername.isEmpty ? AppText.serversUsernameDefault : trimmedUsername,
                password: password,
                nickname: trimmedNickname.isEmpty ? nil : trimmedNickname
            )
            onSaved(profile)
        case .rename(let profile):
            registry.update(id: profile.id, nickname: trimmedNickname.isEmpty ? nil : trimmedNickname)
            onSaved(profile)
        }
        dismiss()
    }
}
