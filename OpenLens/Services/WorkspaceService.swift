import Foundation
import os

struct WorkspaceCommandItem: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let description: String
    let prompt: String
}

struct WorkspaceAgentItem: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let description: String
    let prompt: String
}

struct WorkspaceSkillItem: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let description: String

    /// The token typed in the composer, matching the TUI's `@skill` list.
    var mention: String { "@\(id)" }
}

struct WorkspaceSlashActionItem: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case command
        case agent
    }

    let kind: Kind
    let token: String
    let title: String
    let description: String
    let prompt: String

    var id: String { "\(kind.rawValue):\(token)" }
}

struct WorkspaceFileItem: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case directory
        case file
        case unknown
    }

    let path: String
    let name: String
    let absolutePath: String?
    let kind: Kind

    var id: String { path }
}

enum WorkspaceWorkingTreeSource: Sendable {
    case gitStatus
    case sessionDiffFallback
    case unavailable
}

struct WorkspaceSnapshot: Sendable {
    let currentProject: OCProject?
    let projects: [OCProject]
    let pathInfo: OCPathInfo?
    let vcsInfo: OCVCSInfo?
    let commands: [WorkspaceCommandItem]
    let fileItems: [WorkspaceFileItem]
    let currentPath: String?
    let workingTree: [ReviewFileChange]
    let workingTreeSource: WorkspaceWorkingTreeSource
}

/// A file or folder inside a session's folder; `path` is relative to it.
struct RepositoryEntry: Identifiable, Hashable, Sendable {
    let path: String
    let name: String
    let isDirectory: Bool

    var id: String { path }
}

struct WorkspaceFolderSnapshot: Sendable {
    let directory: String
    let folders: [WorkspaceFileItem]
}

final class WorkspaceService {

    private struct WorkingTreeSnapshot: Sendable {
        let files: [ReviewFileChange]
        let source: WorkspaceWorkingTreeSource
    }

    private let connection: ConnectionManager

    init(connection: ConnectionManager) {
        self.connection = connection
    }

    func loadWorkspace(path: String? = nil, sessionID: String? = nil) async throws -> WorkspaceSnapshot {
        if ScreenshotFixtures.isEnabled {
            return ScreenshotFixtures.workspaceSnapshot(path: path)
        }

        guard let client = connection.client else {
            throw OpenCodeError.notConnected
        }

        let pathInfo = await tryPathInfo(client)
        async let currentProjectTask = tryCurrentProject(client)
        async let projectsTask = tryProjects(client)
        async let vcsTask = tryVCS(client)
        async let commandsTask = tryCommands(client)
        async let filesTask = tryFiles(client, path: path)
        async let workingTreeTask = tryWorkingTree(client, sessionID: sessionID)

        let currentProject = await currentProjectTask
        let projects = await projectsTask
        let vcsInfo = await vcsTask
        let commands = await commandsTask
        let fileItems = await filesTask
        let workingTreeSnapshot = await workingTreeTask

        return WorkspaceSnapshot(
            currentProject: currentProject,
            projects: projects,
            pathInfo: pathInfo,
            vcsInfo: vcsInfo,
            commands: commands,
            fileItems: fileItems,
            currentPath: normalizedCurrentPath(path, pathInfo: pathInfo),
            workingTree: workingTreeSnapshot.files,
            workingTreeSource: workingTreeSnapshot.source
        )
    }

    /// Loads what the server reports about its workspaces. `rememberedDirectories`
    /// are folders chosen earlier; those the server did not report itself are
    /// checked by asking it to open them, because the project list only names
    /// project roots and says nothing about other folders it can open.
    func loadWorkspaceSelection(verifying rememberedDirectories: [String] = []) async throws -> WorkspaceSelectionSnapshot {
        if ScreenshotFixtures.isEnabled {
            let snapshot = ScreenshotFixtures.workspaceSnapshot(path: nil)
            return WorkspaceSelectionSnapshot(
                currentProject: snapshot.currentProject,
                projects: snapshot.projects,
                pathInfo: snapshot.pathInfo
            )
        }

        guard let client = connection.client else {
            throw OpenCodeError.notConnected
        }

        let pathInfo = await tryPathInfo(client)
        async let currentProjectTask = tryCurrentProject(client)
        async let projectsTask = tryProjects(client)

        let currentProject = await currentProjectTask
        let projects = await projectsTask

        var snapshot = WorkspaceSelectionSnapshot(
            currentProject: currentProject,
            projects: projects,
            pathInfo: pathInfo
        )
        let unreported = WorkspaceSelectionBuilder.directoriesNeedingVerification(rememberedDirectories, in: snapshot)
        snapshot.inaccessibleDirectories = await refusedDirectories(among: unreported, client: client)
        return snapshot
    }

    /// Asks the server to open each folder the way the folder browser does, in a
    /// per-request context that leaves the active project untouched. Only an
    /// explicit refusal counts; a dropped connection says nothing about the folder.
    private func refusedDirectories(among directories: [String], client: OpenCodeClient) async -> Set<String> {
        await withTaskGroup(of: String?.self) { group in
            for directory in directories {
                group.addTask {
                    do {
                        _ = try await client.listFiles(path: ".", directory: directory)
                        return nil
                    } catch {
                        return Self.isFolderRefusal(error) ? directory : nil
                    }
                }
            }

            var refused = Set<String>()
            for await directory in group {
                if let directory { refused.insert(directory) }
            }
            return refused
        }
    }

    /// The server answered about the folder itself, not about authentication,
    /// rate limits or its own health.
    nonisolated static func isFolderRefusal(_ error: Error) -> Bool {
        let statusCode: Int
        switch error as? OpenCodeError {
        case .httpError(let code):
            statusCode = code
        case .apiError(let code, _):
            statusCode = code
        default:
            return false
        }
        return (400..<500).contains(statusCode) && ![401, 407, 408, 429].contains(statusCode)
    }

    func loadFolders(in directory: String) async throws -> WorkspaceFolderSnapshot {
        guard directory.hasPrefix("/"),
              let directory = WorkspaceSelectionBuilder.normalizedDirectory(directory) else {
            throw OpenCodeError.invalidPayload("Choose an absolute folder path on the connected computer.")
        }

        if ScreenshotFixtures.isEnabled {
            return ScreenshotFixtures.folderSnapshot(directory: directory)
        }

        guard let client = connection.client else {
            throw OpenCodeError.notConnected
        }

        // Listing "." in a per-request context also supports servers that
        // only accept workspace-relative file paths.
        let entries = try await client.listFiles(path: ".", directory: directory)
        return WorkspaceFolderSnapshot(
            directory: directory,
            folders: Self.folderItems(from: entries, directory: directory)
        )
    }

    static func folderItems(from entries: [OCWorkspaceFileEntry], directory: String) -> [WorkspaceFileItem] {
        var seen = Set<String>()
        return entries.compactMap { entry in
            guard entry.type?.lowercased() == "directory" else { return nil }
            let rawPath: String
            if let absolute = entry.absolute, absolute.hasPrefix("/") {
                rawPath = absolute
            } else {
                rawPath = entry.path
            }
            let absolutePath = rawPath.hasPrefix("/")
                ? rawPath
                : URL(fileURLWithPath: directory).appendingPathComponent(rawPath).path
            guard let path = WorkspaceSelectionBuilder.normalizedDirectory(absolutePath),
                  path != directory,
                  !WorkspaceSelectionBuilder.displayName(for: path).hasPrefix("."),
                  seen.insert(path).inserted else { return nil }
            return WorkspaceFileItem(
                path: path,
                name: WorkspaceSelectionBuilder.displayName(for: path),
                absolutePath: path,
                kind: .directory
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Files and folders at `relativePath` inside a session's folder, for
    /// choosing a file to reference in a prompt.
    func loadRepositoryEntries(at relativePath: String, in directory: String) async throws -> [RepositoryEntry] {
        if ScreenshotFixtures.isEnabled {
            return ScreenshotFixtures.repositoryEntries(at: relativePath)
        }
        guard let client = connection.client else { throw OpenCodeError.notConnected }
        let entries = try await client.listFiles(path: relativePath.isEmpty ? "." : relativePath, directory: directory)
        return Self.repositoryEntries(from: entries, directory: directory)
    }

    func readRepositoryFile(at relativePath: String, in directory: String) async throws -> String {
        if ScreenshotFixtures.isEnabled {
            return ScreenshotFixtures.repositoryFileContent
        }
        guard let client = connection.client else { throw OpenCodeError.notConnected }
        let content = try await client.readFileContent(path: relativePath, directory: directory)
        guard content.type != "binary", let text = content.content else {
            throw OpenCodeError.invalidPayload(AppText.repositoryFileNotText)
        }
        return text
    }

    /// Opens a file a tool returned. Inline content is decoded off the main
    /// actor; server files must be inside the session's folder.
    func loadToolResultFile(_ file: ToolResultFile, sessionDirectory: String?) async throws -> ToolResultFileContent {
        if let error = file.unavailableError { throw error }
        let kind = file.kind
        switch file.source {
        case .tooLarge, .unavailable:
            throw ToolResultFileError.unavailable
        case let .dataURI(uri):
            return try await Task.detached(priority: .userInitiated) {
                try ToolResultFileContent.make(kind: kind, data: ToolResultFileContent.data(fromDataURI: uri))
            }.value
        case let .serverPath(path):
            guard let sessionDirectory,
                  let reference = try? ServerFileReference(path: path, sessionDirectory: sessionDirectory),
                  let relativePath = reference.relativePath(in: sessionDirectory)
            else {
                throw ToolResultFileError.outsideSession
            }
            guard let client = connection.client else { throw OpenCodeError.notConnected }
            let data = try await client.readFileData(path: relativePath, directory: sessionDirectory)
            guard data.count <= ToolResultFileContent.maximumServerFileBytes else { throw ToolResultFileError.tooLarge }
            return try await Task.detached(priority: .userInitiated) {
                try ToolResultFileContent.make(kind: kind, data: data)
            }.value
        }
    }

    static func repositoryEntries(from entries: [OCWorkspaceFileEntry], directory: String) -> [RepositoryEntry] {
        let root = directory.hasSuffix("/") ? String(directory.dropLast()) : directory
        var seen = Set<String>()
        return entries.compactMap { entry in
            var path = entry.absolute.flatMap { $0.hasPrefix(root + "/") ? String($0.dropFirst(root.count + 1)) : nil }
                ?? entry.path
            let isDirectory = entry.type?.lowercased() == "directory" || path.hasSuffix("/")
            while path.hasSuffix("/") { path.removeLast() }
            let name = (path as NSString).lastPathComponent
            guard !path.isEmpty, !path.hasPrefix("/"), path != ".", !name.hasPrefix("."),
                  seen.insert(path).inserted else { return nil }
            return RepositoryEntry(path: path, name: name, isDirectory: isDirectory)
        }
        .sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func loadCommands() async -> [WorkspaceCommandItem] {
        if ScreenshotFixtures.isEnabled {
            return ScreenshotFixtures.workspaceSnapshot(path: nil).commands
        }

        guard let client = connection.client else { return [] }
        return await tryCommands(client)
    }

    func loadWorkingTreeFile(summary: ReviewFileChange) async -> ReviewFileChange {
        if ScreenshotFixtures.isEnabled {
            return summary
        }

        guard !summary.hasReadableDiff, let client = connection.client else {
            return summary
        }

        let contextDirectory = await client.currentContextDirectory() ?? "nil"
        do {
            let diffs = (try? await client.getWorkingTreeDiff()) ?? []
            let matchingDiff = diffs.first(where: { $0.resolvedPath == summary.path })
                .map(ReviewFileChange.init(diff:))
            if let matchingDiff, matchingDiff.hasReadableDiff {
                return matchingDiff
            }
            let content = try await client.readFileContent(path: summary.path)
            return (matchingDiff ?? summary).applying(content: content)
        } catch {
            Logger.api.warning("WorkspaceService failed to load file diff detail for \(summary.path, privacy: .public) in context directory \(contextDirectory, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return summary
        }
    }

    func loadSlashActions() async -> [WorkspaceSlashActionItem] {
        if ScreenshotFixtures.isEnabled {
            return ScreenshotFixtures.workspaceSnapshot(path: nil).commands.map {
                WorkspaceSlashActionItem(
                    kind: .command,
                    token: $0.id,
                    title: $0.title,
                    description: $0.description,
                    prompt: $0.prompt
                )
            }
        }

        guard let client = connection.client else { return [] }

        async let commandsTask = tryCommands(client)
        async let agentsTask = tryAgents(client)

        let commands = await commandsTask.map { command in
            WorkspaceSlashActionItem(
                kind: .command,
                token: command.id,
                title: command.title,
                description: command.description,
                prompt: command.prompt
            )
        }

        let agents = await agentsTask.map { agent in
            WorkspaceSlashActionItem(
                kind: .agent,
                token: agent.id,
                title: agent.title,
                description: agent.description,
                prompt: agent.prompt
            )
        }

        return (commands + agents)
            .sorted { lhs, rhs in
                if lhs.kind != rhs.kind {
                    return lhs.kind == .command
                }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
    }

    func loadSkills() async -> [WorkspaceSkillItem] {
        if ScreenshotFixtures.isEnabled {
            return []
        }

        guard let client = connection.client else { return [] }

        let contextDirectory = await client.currentContextDirectory() ?? "nil"
        do {
            return try await client.listSkills()
                .map { skill in
                    WorkspaceSkillItem(
                        id: skill.id,
                        name: skill.name.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank ?? skill.id,
                        description: skill.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    )
                }
                .sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
        } catch {
            Logger.api.error("WorkspaceService failed to load skills for context directory \(contextDirectory, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private func tryCurrentProject(_ client: OpenCodeClient) async -> OCProject? {
        try? await client.getCurrentProject()
    }

    private func tryProjects(_ client: OpenCodeClient) async -> [OCProject] {
        (try? await client.listProjects()) ?? []
    }

    private func tryPathInfo(_ client: OpenCodeClient) async -> OCPathInfo? {
        try? await client.getPath()
    }

    private func tryVCS(_ client: OpenCodeClient) async -> OCVCSInfo? {
        try? await client.getVCS()
    }

    private func tryCommands(_ client: OpenCodeClient) async -> [WorkspaceCommandItem] {
        let contextDirectory = await client.currentContextDirectory() ?? "nil"
        do {
            let commands = try await client.listCommands()
            if commands.isEmpty {
                Logger.api.debug("Server returned zero slash commands for context directory \(contextDirectory, privacy: .public).")
            }
            return commands
            .map { command in
                let title = command.name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
                    ?? "/\(command.id)"
                let prompt = title.hasPrefix("/") ? title : "/\(command.id)"
                return WorkspaceCommandItem(
                    id: command.id,
                    title: title,
                    description: command.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                    prompt: prompt
                )
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        } catch {
            Logger.api.error("WorkspaceService failed to load slash commands for context directory \(contextDirectory, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private func tryAgents(_ client: OpenCodeClient) async -> [WorkspaceAgentItem] {
        let contextDirectory = await client.currentContextDirectory() ?? "nil"
        do {
            let agents = try await client.listAgents()
            return agents
                .map { agent in
                    let title = agent.name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
                        ?? agent.id
                    return WorkspaceAgentItem(
                        id: agent.id,
                        title: title,
                        description: agent.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                        prompt: "/\(agent.id)"
                    )
                }
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        } catch {
            Logger.api.error("WorkspaceService failed to load agents for context directory \(contextDirectory, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private func tryFiles(_ client: OpenCodeClient, path: String?) async -> [WorkspaceFileItem] {
        guard let result = try? await client.listFiles(path: normalizedRequestPath(path)) else { return [] }
        return mapFileItems(result)
    }

    private func tryWorkingTree(_ client: OpenCodeClient, sessionID: String?) async -> WorkingTreeSnapshot {
        let contextDirectory = await client.currentContextDirectory() ?? "nil"

        do {
            let files = try await client.listFileStatus()
                .map(ReviewFileChange.init(fileStatus:))
                .sorted { lhs, rhs in
                    lhs.path.localizedCaseInsensitiveCompare(rhs.path) == .orderedAscending
                }
            return WorkingTreeSnapshot(files: files, source: .gitStatus)
        } catch {
            Logger.api.warning("WorkspaceService failed to load git working tree status in context directory \(contextDirectory, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        guard let sessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank else {
            return WorkingTreeSnapshot(files: [], source: .unavailable)
        }

        do {
            let files = try await client.getSessionDiff(sessionID: sessionID)
                .map(ReviewFileChange.init(diff:))
                .sorted { lhs, rhs in
                    lhs.path.localizedCaseInsensitiveCompare(rhs.path) == .orderedAscending
                }
            return WorkingTreeSnapshot(files: files, source: .sessionDiffFallback)
        } catch {
            Logger.api.error("WorkspaceService failed to load session diff fallback for session \(sessionID, privacy: .public) in context directory \(contextDirectory, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return WorkingTreeSnapshot(files: [], source: .unavailable)
        }
    }

    private func normalizedCurrentPath(_ path: String?, pathInfo: OCPathInfo?) -> String? {
        path?.nilIfBlank ?? "."
    }

    private func normalizedRequestPath(_ path: String?) -> String {
        path?.nilIfBlank ?? "."
    }

    private func mapFileItems(_ payload: [OCWorkspaceFileEntry]) -> [WorkspaceFileItem] {
        payload
            .filter { !($0.ignored ?? false) }
            .map(mapFileItem)
            .sorted { lhs, rhs in
                if lhs.kind != rhs.kind {
                    return lhs.kind == .directory
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    private func mapFileItem(_ entry: OCWorkspaceFileEntry) -> WorkspaceFileItem {
        WorkspaceFileItem(
            path: entry.path,
            name: entry.name,
            absolutePath: entry.absolute,
            kind: kind(for: entry.type)
        )
    }

    private func kind(for type: String?) -> WorkspaceFileItem.Kind {
        switch type?.lowercased() {
        case "directory": .directory
        case "file": .file
        default: .unknown
        }
    }
}
