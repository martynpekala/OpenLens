import SwiftUI

struct WorkspaceFolderBrowser: View {
    private enum LoadState {
        case loading
        case loaded(WorkspaceFolderSnapshot)
        case error(String)
    }

    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.workspaceService) private var workspaceService

    @State private var directory: String
    @State private var loadState: LoadState = .loading
    @State private var reloadID = UUID()

    init(initialDirectory: String, onSelect: @escaping (String) -> Void) {
        _directory = State(initialValue: WorkspaceSelectionBuilder.normalizedDirectory(initialDirectory) ?? "/")
        self.onSelect = onSelect
    }

    private var loadedDirectory: String? {
        guard case .loaded(let snapshot) = loadState, snapshot.directory == directory else { return nil }
        return snapshot.directory
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                locationHeader
                folderContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color.appBackground)
            .navigationTitle(AppText.folderBrowserTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppText.cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppText.useThisFolder) {
                        guard let loadedDirectory else { return }
                        onSelect(loadedDirectory)
                        dismiss()
                    }
                    .disabled(loadedDirectory == nil)
                    .accessibilityIdentifier("folderBrowser.useFolder")
                }
            }
            .task(id: reloadID) {
                await loadFolders()
            }
        }
    }

    private var locationHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(AppText.folderBrowserNote)
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(Color.appSecondary)

            Text(directory)
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(Color.appPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityIdentifier("folderBrowser.currentPath")

            Button {
                navigate(to: URL(fileURLWithPath: directory).deletingLastPathComponent().path)
            } label: {
                Label(AppText.parentFolder, systemImage: "arrow.up")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
            }
            .disabled(directory == "/")
            .accessibilityLabel("Go to parent folder")
            .accessibilityIdentifier("folderBrowser.up")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color.appSurface)
    }

    @ViewBuilder
    private var folderContent: some View {
        switch loadState {
        case .loading:
            ProgressView()
                .tint(Color.appAccent)
        case .loaded(let snapshot):
            if snapshot.folders.isEmpty {
                ContentUnavailableView(
                    AppText.noSubfolders,
                    systemImage: "folder",
                    description: Text(AppText.noSubfoldersMessage)
                )
            } else {
                List(snapshot.folders) { folder in
                    Button {
                        navigate(to: folder.path)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "folder")
                                .foregroundStyle(Color.appAccent)
                            Text(folder.name)
                                .foregroundStyle(Color.appPrimary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.appSecondary)
                        }
                        .font(.system(size: 16, design: .rounded))
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .listRowBackground(Color.appSurface)
                    .accessibilityIdentifier("folderBrowser.folder.\(folder.name)")
                }
                .scrollContentBackground(.hidden)
            }
        case .error(let message):
            ContentUnavailableView {
                Label(AppText.folderLoadError, systemImage: "folder.badge.questionmark")
            } description: {
                Text(message)
            } actions: {
                Button(AppText.tryAgain) {
                    navigate(to: directory)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func navigate(to directory: String) {
        self.directory = directory
        loadState = .loading
        reloadID = UUID()
    }

    private func loadFolders() async {
        let requestedDirectory = directory
        do {
            let snapshot = try await workspaceService.loadFolders(in: requestedDirectory)
            try Task.checkCancellation()
            guard directory == requestedDirectory else { return }
            loadState = .loaded(snapshot)
        } catch {
            guard !Task.isCancelled, directory == requestedDirectory else { return }
            loadState = .error(error.localizedDescription)
        }
    }
}
