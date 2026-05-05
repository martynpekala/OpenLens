import Foundation

struct WorkspaceBookmarkModel: Equatable {
    let path: String
    let bookmarkData: Data

    var displayName: String {
        let name = fileURL.lastPathComponent
        return name.isEmpty ? path : name
    }

    var fileURL: URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }
}
