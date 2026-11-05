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
    @State private var isScannerPresented = false
    @State private var pairing: PairingState = .idle

    private enum PairingState: Equatable {
        case idle
        case exchanging
        case failed(String)
    }

    private var isRename: Bool {
        if case .rename = mode { true } else { false }
    }

    private var canSave: Bool {
        guard pairing != .exchanging else { return false }
        return isRename || connectionServerDisplayName(serverURL) != nil
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

                        nicknameField
                    } else {
                        scanSection

                        nicknameField

                        addFields
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
            .fullScreenCover(isPresented: $isScannerPresented) {
                QRScannerView(
                    onScanned: handleScannedCode,
                    onDismiss: { isScannerPresented = false }
                )
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.appBackground)
    }

    // MARK: - Sections

    private var nicknameField: some View {
        field(AppText.serversNickname) {
            TextField(AppText.serversNicknamePlaceholder, text: $nickname)
                .textInputAutocapitalization(.words)
                .font(theme.typography.rowTitle)
        }
    }

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

    /// Pairing by QR is how most people add their first server, so it leads rather than sitting
    /// under the manual fields -- the same order the connect screen offers.
    @ViewBuilder
    private var scanSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                isScannerPresented = true
            } label: {
                Label(AppText.serversScanQRCode, systemImage: "qrcode.viewfinder")
            }
            .primaryCTAStyle()
            .disabled(pairing == .exchanging)

            if pairing == .exchanging {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(AppText.serversPairing)
                        .font(.system(size: 13, design: .rounded))
                        .foregroundStyle(Color.appSecondary)
                }
            } else if case .failed(let reason) = pairing {
                noticeRow(
                    icon: "exclamationmark.triangle.fill",
                    message: AppText.serversPairingFailed(reason),
                    tint: Color.appDanger
                )
            } else {
                // The command is set in monospace rather than wrapped in backticks: this is a
                // rendered label, not Markdown, and a literal backtick reads as leaked markup.
                (
                    Text(AppText.serversScanQRCodeHintPrefix)
                        .font(.system(size: 13, design: .rounded))
                        + Text(AppText.serversScanQRCodeCommand)
                        .font(.system(size: 13, design: .monospaced))
                        + Text(AppText.serversScanQRCodeHintSuffix)
                        .font(.system(size: 13, design: .rounded))
                )
                .foregroundStyle(Color.appSecondary)
                .fixedSize(horizontal: false, vertical: true)
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

    private func handleScannedCode(_ code: ScannedOpenLensCode) {
        isScannerPresented = false
        switch code {
        case .direct(let link):
            // Carries its own credentials, so there is nothing to exchange: fill the fields and
            // let the user confirm, as typing them would.
            serverURL = link.serverURL
            username = link.username
            password = link.password
            pairing = .idle
        case .openCodePairing(let link):
            exchangePairingCode(link)
        }
    }

    /// Resolves a pairing code and saves the result immediately, rather than filling the fields
    /// and waiting for the user to confirm. The exchange consumes a single-use code that expires
    /// in five minutes, so a server left unsaved here could not be added by scanning again --
    /// the connect screen persists before connecting for the same reason.
    private func exchangePairingCode(_ link: OpenCodePairingLink) {
        pairing = .exchanging
        serverURL = link.serverURL.absoluteString
        Task {
            do {
                let credential = try await OpenCodePairingClient().pair(using: link)
                let trimmedNickname = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
                let profile = registry.add(
                    serverURL: credential.serverURL,
                    username: credential.username,
                    password: credential.password,
                    nickname: trimmedNickname.isEmpty ? nil : trimmedNickname
                )
                pairing = .idle
                onSaved(profile)
                dismiss()
            } catch {
                pairing = .failed(
                    (error as? OpenCodePairingError)?.localizedDescription ?? error.localizedDescription
                )
            }
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
