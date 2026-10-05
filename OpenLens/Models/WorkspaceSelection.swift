import Foundation

struct WorkspaceSelectionSnapshot {
    let currentProject: OCProject?
    let projects: [OCProject]
    let pathInfo: OCPathInfo?
    /// Remembered folders the server explicitly refused to open. Absence from
    /// `projects` proves nothing: that list only names project roots, so
    /// non-git folders, subfolders and differently spelled paths never appear.
    var inaccessibleDirectories: Set<String> = []
}

struct WorkspaceSelectionOption: Identifiable, Hashable {
    enum Availability: Hashable {
        case available
        case unavailable
        case serverDefault
    }

    let id: String
    let directory: String?
    let projectID: String?
    let title: String
    let subtitle: String?
    let availability: Availability
    let isCurrent: Bool
    let isRecent: Bool

    var canCreateSession: Bool {
        availability != .unavailable
    }

    var clearsWorkspaceContext: Bool {
        availability == .serverDefault
    }
}

struct WorkspaceSelectionResult: Hashable {
    let options: [WorkspaceSelectionOption]
    let defaultOptionID: WorkspaceSelectionOption.ID?
    let unavailablePreferredDirectory: String?
}

enum WorkspaceSelectionBuilder {
    private struct Candidate {
        let directory: String
        let projectID: String?
    }

    static func makeOptions(
        snapshot: WorkspaceSelectionSnapshot,
        recentDirectories: [String],
        preferredDirectory: String?
    ) -> WorkspaceSelectionResult {
        var candidatesByDirectory: [String: Candidate] = [:]
        var candidateOrder: [String] = []
        var currentDirectories = Set<String>()

        func rememberCandidate(directory rawDirectory: String?, projectID: String?) {
            guard let directory = normalizedDirectory(rawDirectory) else { return }
            if candidatesByDirectory[directory] == nil {
                candidateOrder.append(directory)
                candidatesByDirectory[directory] = Candidate(directory: directory, projectID: projectID)
            }
        }

        func rememberCurrentDirectory(_ rawDirectory: String?) {
            guard let directory = normalizedDirectory(rawDirectory) else { return }
            currentDirectories.insert(directory)
        }

        for reported in reportedDirectories(in: snapshot) {
            // Folders outside a git repository belong to the server's `global`
            // project, rooted at `/`. That is a placeholder, not a workspace to
            // open; the folder browser refuses `/` for the same reason.
            guard normalizedDirectory(reported.directory) != "/" else { continue }
            rememberCandidate(directory: reported.directory, projectID: reported.projectID)
        }

        rememberCurrentDirectory(snapshot.currentProject?.worktree)
        rememberCurrentDirectory(snapshot.pathInfo?.worktree)
        rememberCurrentDirectory(snapshot.pathInfo?.directory)

        let inaccessibleDirectories = Set(snapshot.inaccessibleDirectories.compactMap(normalizedDirectory))
        let normalizedPreferred = normalizedDirectory(preferredDirectory)
        let normalizedRecents = uniqueDirectories([normalizedPreferred].compactMap { $0 } + recentDirectories)
        let recentSet = Set(normalizedRecents)

        let orderedDirectories = uniqueDirectories(normalizedRecents + candidateOrder)
        var options = orderedDirectories.map { directory in
            if let candidate = candidatesByDirectory[directory] {
                return WorkspaceSelectionOption(
                    id: optionID(for: directory),
                    directory: candidate.directory,
                    projectID: candidate.projectID,
                    title: displayName(for: candidate.directory),
                    subtitle: candidate.directory,
                    availability: .available,
                    isCurrent: currentDirectories.contains(directory),
                    isRecent: recentSet.contains(directory)
                )
            }

            // Remembered but not reported by the server. It stays usable unless
            // the server refused to open it.
            return WorkspaceSelectionOption(
                id: optionID(for: directory),
                directory: directory,
                projectID: nil,
                title: displayName(for: directory),
                subtitle: directory,
                availability: inaccessibleDirectories.contains(directory) ? .unavailable : .available,
                isCurrent: false,
                isRecent: true
            )
        }

        if !options.contains(where: \.canCreateSession) {
            options.append(serverDefaultOption())
        }

        let preferredOption = normalizedPreferred.flatMap { preferred in
            options.first { $0.directory == preferred && $0.canCreateSession }
        }
        let defaultOptionID = preferredOption?.id ?? options.first(where: \.canCreateSession)?.id

        let unavailablePreferredDirectory = options
            .first { $0.directory == normalizedPreferred && $0.availability == .unavailable }?
            .directory

        return WorkspaceSelectionResult(
            options: options,
            defaultOptionID: defaultOptionID,
            unavailablePreferredDirectory: unavailablePreferredDirectory
        )
    }

    /// Remembered folders the server did not report itself. Only the server can
    /// say whether it can still open them, so callers ask it directly.
    static func directoriesNeedingVerification(
        _ directories: [String],
        in snapshot: WorkspaceSelectionSnapshot
    ) -> [String] {
        let reported = Set(reportedDirectories(in: snapshot).compactMap { normalizedDirectory($0.directory) })
        return uniqueDirectories(directories).filter { !reported.contains($0) }
    }

    /// Every directory the server named itself: the active location and each project root.
    private static func reportedDirectories(
        in snapshot: WorkspaceSelectionSnapshot
    ) -> [(directory: String?, projectID: String?)] {
        let currentProjectID = snapshot.currentProject?.id
        return [
            (snapshot.currentProject?.worktree, currentProjectID),
            (snapshot.pathInfo?.worktree, currentProjectID),
            (snapshot.pathInfo?.directory, currentProjectID),
        ] + snapshot.projects.map { ($0.worktree, $0.id) }
    }

    nonisolated static func normalizedDirectory(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }

        return URL(fileURLWithPath: trimmed).standardizedFileURL.path
    }

    nonisolated static func displayName(for directory: String) -> String {
        let lastComponent = URL(fileURLWithPath: directory).lastPathComponent
        let trimmed = lastComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? directory : trimmed
    }

    private static func optionID(for directory: String) -> String {
        "directory:\(directory)"
    }

    private static func uniqueDirectories(_ directories: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for rawDirectory in directories {
            guard let directory = normalizedDirectory(rawDirectory), seen.insert(directory).inserted else {
                continue
            }
            result.append(directory)
        }

        return result
    }

    private static func serverDefaultOption() -> WorkspaceSelectionOption {
        WorkspaceSelectionOption(
            id: "server-default",
            directory: nil,
            projectID: nil,
            title: AppText.workspaceServerDefault,
            subtitle: AppText.workspaceServerDefaultSubtitle,
            availability: .serverDefault,
            isCurrent: false,
            isRecent: false
        )
    }
}

extension OCSession {
    var workspaceDirectory: String? {
        WorkspaceSelectionBuilder.normalizedDirectory(directory)
    }

    var workspaceDisplayName: String? {
        workspaceDirectory.map(WorkspaceSelectionBuilder.displayName(for:))
    }
}
