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

        async let currentProjectTask = tryCurrentProject(client)
        async let projectsTask = tryProjects(client)
        async let pathInfoTask = tryPathInfo(client)
        async let vcsTask = tryVCS(client)
        async let commandsTask = tryCommands(client)
        async let filesTask = tryFiles(client, path: path)
        async let workingTreeTask = tryWorkingTree(client, sessionID: sessionID)

        let currentProject = await currentProjectTask
        let projects = await projectsTask
        let pathInfo = await pathInfoTask
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

    func loadWorkspaceSelection() async throws -> WorkspaceSelectionSnapshot {
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

        async let currentProjectTask = tryCurrentProject(client)
        async let projectsTask = tryProjects(client)
        async let pathInfoTask = tryPathInfo(client)

        let currentProject = await currentProjectTask
        let projects = await projectsTask
        let pathInfo = await pathInfoTask

        return WorkspaceSelectionSnapshot(
            currentProject: currentProject,
            projects: projects,
            pathInfo: pathInfo
        )
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
            let content = try await client.readFileContent(path: summary.path)
            return summary.applying(content: content)
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
