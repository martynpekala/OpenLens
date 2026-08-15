import Foundation

struct WorkspaceSelectionSnapshot {
    let currentProject: OCProject?
    let projects: [OCProject]
    let pathInfo: OCPathInfo?
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

        rememberCandidate(directory: snapshot.currentProject?.worktree, projectID: snapshot.currentProject?.id)
        rememberCandidate(directory: snapshot.pathInfo?.worktree, projectID: snapshot.currentProject?.id)
        rememberCandidate(directory: snapshot.pathInfo?.directory, projectID: snapshot.currentProject?.id)

        rememberCurrentDirectory(snapshot.currentProject?.worktree)
        rememberCurrentDirectory(snapshot.pathInfo?.worktree)
        rememberCurrentDirectory(snapshot.pathInfo?.directory)

        for project in snapshot.projects {
            rememberCandidate(directory: project.worktree, projectID: project.id)
        }

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

            return WorkspaceSelectionOption(
                id: optionID(for: directory),
                directory: directory,
                projectID: nil,
                title: displayName(for: directory),
                subtitle: directory,
                availability: .unavailable,
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

        let unavailablePreferredDirectory = normalizedPreferred.flatMap { preferred in
            candidatesByDirectory[preferred] == nil ? preferred : nil
        }

        return WorkspaceSelectionResult(
            options: options,
            defaultOptionID: defaultOptionID,
            unavailablePreferredDirectory: unavailablePreferredDirectory
        )
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
