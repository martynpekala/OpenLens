import Foundation

enum WorkspaceBookmarkClientError: LocalizedError {
    case directoryMissing(String)
    case couldNotCreateBookmark

    var errorDescription: String? {
        switch self {
        case let .directoryMissing(path):
            return "The selected folder is no longer available: \(path)"
        case .couldNotCreateBookmark:
            return "The app could not save the selected folder."
        }
    }
}

struct WorkspaceBookmarkClient {
    private let defaults: UserDefaults
    private let fileManager: FileManager

    private let bookmarkKey = "OpenLensQRMenubar.workspaceBookmark"
    private let pathKey = "OpenLensQRMenubar.workspacePath"

    init(defaults: UserDefaults = .standard, fileManager: FileManager = .default) {
        self.defaults = defaults
        self.fileManager = fileManager
    }

    func load() -> WorkspaceBookmarkModel? {
        guard let bookmarkData = defaults.data(forKey: bookmarkKey),
              let path = defaults.string(forKey: pathKey) else {
            return nil
        }

        return WorkspaceBookmarkModel(path: path, bookmarkData: bookmarkData)
    }

    @discardableResult
    func save(url: URL) throws -> WorkspaceBookmarkModel {
        try validateDirectory(url)

        guard let bookmarkData = try? url.bookmarkData() else {
            throw WorkspaceBookmarkClientError.couldNotCreateBookmark
        }

        defaults.set(bookmarkData, forKey: bookmarkKey)
        defaults.set(url.path, forKey: pathKey)

        return WorkspaceBookmarkModel(path: url.path, bookmarkData: bookmarkData)
    }

    func resolve(_ workspace: WorkspaceBookmarkModel) throws -> URL {
        var isStale = false

        if let resolvedURL = try? URL(
            resolvingBookmarkData: workspace.bookmarkData,
            options: [.withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) {
            try validateDirectory(resolvedURL)

            if isStale {
                _ = try? save(url: resolvedURL)
            }

            return resolvedURL
        }

        let fallbackURL = workspace.fileURL
        try validateDirectory(fallbackURL)
        return fallbackURL
    }

    func clear() {
        defaults.removeObject(forKey: bookmarkKey)
        defaults.removeObject(forKey: pathKey)
    }

    private func validateDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw WorkspaceBookmarkClientError.directoryMissing(url.path)
        }
    }
}
