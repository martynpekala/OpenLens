import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class OpenLensQRMenuStore {
    private(set) var selectedWorkspace: WorkspaceBookmarkModel?
    private(set) var lastGeneratedQRPayload: OpenLensQRPayloadModel?
    private(set) var packagePath: String?
    private(set) var statusMessage: String?
    private(set) var errorMessage: String?

    @ObservationIgnored private let bookmarkClient: WorkspaceBookmarkClient
    @ObservationIgnored private let launchClient: OpenLensQRLaunchClient
    @ObservationIgnored private let qrPayloadClient: OpenLensQRPayloadClient

    init(
        bookmarkClient: WorkspaceBookmarkClient = WorkspaceBookmarkClient(),
        launchClient: OpenLensQRLaunchClient = OpenLensQRLaunchClient(),
        qrPayloadClient: OpenLensQRPayloadClient = OpenLensQRPayloadClient()
    ) {
        self.bookmarkClient = bookmarkClient
        self.launchClient = launchClient
        self.qrPayloadClient = qrPayloadClient
        self.selectedWorkspace = bookmarkClient.load()
        self.lastGeneratedQRPayload = qrPayloadClient.load()
        self.packagePath = try? launchClient.packageURL().path
        self.statusMessage = selectedWorkspace == nil
            ? "Choose a workspace folder. The app will remember the last one you pick."
            : "Ready to launch openlens-qr in \(selectedWorkspace?.displayName ?? "your workspace")."
    }

    var selectedDirectoryName: String {
        selectedWorkspace?.displayName ?? "No folder selected"
    }

    var selectedDirectoryPath: String {
        selectedWorkspace?.path ?? "Choose the folder where openlens-qr should start OpenCode."
    }

    var canLaunch: Bool {
        selectedWorkspace != nil && packagePath != nil
    }

    var canClearSelection: Bool {
        selectedWorkspace != nil
    }

    var hasLastGeneratedQRCode: Bool {
        lastGeneratedQRPayload != nil
    }

    var footerMessage: String {
        if let errorMessage {
            return errorMessage
        }

        if packagePath == nil {
            return OpenLensQRLaunchClientError.packageNotFound.errorDescription ?? "Could not locate Tools/openlens-qr."
        }

        return statusMessage ?? "Builds openlens-qr if needed, then opens your default terminal app in the selected folder."
    }

    var isShowingError: Bool {
        errorMessage != nil
    }

    func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.prompt = "Use Folder"
        panel.message = "Choose the folder where openlens-qr should run."

        if let selectedWorkspace,
           let directoryURL = try? bookmarkClient.resolve(selectedWorkspace) {
            panel.directoryURL = directoryURL
        }

        NSApplication.shared.activate(ignoringOtherApps: true)

        guard panel.runModal() == .OK, let selectedURL = panel.urls.first else {
            return
        }

        do {
            let workspace = try bookmarkClient.save(url: selectedURL)
            selectedWorkspace = workspace
            errorMessage = nil
            statusMessage = "Saved \(workspace.displayName)."
        } catch {
            applyError(error)
        }
    }

    func launchOpenLensQR() {
        guard let selectedWorkspace else {
            chooseDirectory()
            return
        }

        do {
            let workspaceURL = try bookmarkClient.resolve(selectedWorkspace)
            let packageURL = try launchClient.packageURL()

            try launchClient.launch(packageURL: packageURL, workingDirectory: workspaceURL)

            let refreshedWorkspace: WorkspaceBookmarkModel
            if let savedWorkspace = bookmarkClient.load() {
                refreshedWorkspace = savedWorkspace
            } else {
                refreshedWorkspace = WorkspaceBookmarkModel(
                    path: workspaceURL.path,
                    bookmarkData: try workspaceURL.bookmarkData()
                )
            }

            self.selectedWorkspace = refreshedWorkspace
            self.packagePath = packageURL.path
            self.lastGeneratedQRPayload = try? qrPayloadClient.generateAndSave()
            self.errorMessage = nil
            self.statusMessage = nil
        } catch {
            if case WorkspaceBookmarkClientError.directoryMissing = error {
                bookmarkClient.clear()
                self.selectedWorkspace = nil
            }

            self.packagePath = try? launchClient.packageURL().path
            applyError(error)
        }
    }

    func refreshQRCode() {
        guard hasLastGeneratedQRCode else {
            return
        }

        do {
            lastGeneratedQRPayload = try qrPayloadClient.generateAndSave()
            errorMessage = nil
            statusMessage = "QR code refreshed. The latest QR code is available in the dropdown menu."
        } catch {
            applyError(error)
        }
    }

    func clearSelection() {
        bookmarkClient.clear()
        selectedWorkspace = nil
        errorMessage = nil
        statusMessage = "Cleared the saved folder."
    }

    private func applyError(_ error: Error) {
        errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
