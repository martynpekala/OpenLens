import Foundation

enum ScreenshotFixtures {
    static let launchArgument = "SCREENSHOT_MODE"
    static let tabArgumentPrefix = "SCREENSHOT_TAB="
    static let chatSessionArgument = "SCREENSHOT_CHAT_SESSION"
    static let settingsSectionArgumentPrefix = "SCREENSHOT_SETTINGS_SECTION="
    static let environmentKey = "OPENLENS_SCREENSHOT_MODE"
    static let tabEnvironmentKey = "OPENLENS_SCREENSHOT_TAB"
    static let chatSessionEnvironmentKey = "OPENLENS_SCREENSHOT_CHAT_SESSION"
    static let settingsSectionEnvironmentKey = "OPENLENS_SCREENSHOT_SETTINGS_SECTION"

    static var isEnabled: Bool {
        let processInfo = ProcessInfo.processInfo
        return processInfo.arguments.contains(launchArgument) || processInfo.environment[environmentKey] == "1"
    }

    static var launchTab: AppTab? {
        let processInfo = ProcessInfo.processInfo

        if let rawValue = processInfo.environment[tabEnvironmentKey] {
            return AppTab(rawValue: rawValue.lowercased())
        }

        let rawValue = processInfo.arguments
            .first { $0.hasPrefix(tabArgumentPrefix) }?
            .dropFirst(tabArgumentPrefix.count)

        guard let rawValue else { return nil }
        return AppTab(rawValue: String(rawValue).lowercased())
    }

    static var opensDefaultChatSession: Bool {
        let processInfo = ProcessInfo.processInfo
        return processInfo.arguments.contains(chatSessionArgument) || processInfo.environment[chatSessionEnvironmentKey] == "1"
    }

    static var settingsSection: String? {
        let processInfo = ProcessInfo.processInfo

        if let rawValue = processInfo.environment[settingsSectionEnvironmentKey] {
            return rawValue.lowercased()
        }

        return processInfo.arguments
            .first { $0.hasPrefix(settingsSectionArgumentPrefix) }
            .map { String($0.dropFirst(settingsSectionArgumentPrefix.count)).lowercased() }
    }

    static let projectID = "proj_openlens_ios"
    static let projectName = "OpenLens"
    static let projectPath = "/workspace/OpenLens"
    static let branchName = "feature/app-store-assets"

    private static let nowMilliseconds = Date().timeIntervalSince1970 * 1000
    private static let hourMilliseconds = 60.0 * 60.0 * 1000.0
    private static let dayMilliseconds = 24.0 * hourMilliseconds

    static let defaultSessionID = "session-screenshot-1"

    static let sessions: [OCSession] = [
        OCSession(
            id: "session-screenshot-1",
            projectID: projectID,
            directory: projectPath,
            title: "Ship polished App Store screenshots",
            version: "v1",
            time: OCSessionTime(created: nowMilliseconds - (3 * hourMilliseconds), updated: nowMilliseconds - (8 * 60 * 1000))
        ),
        OCSession(
            id: "session-screenshot-2",
            projectID: projectID,
            directory: projectPath,
            title: "Tighten workspace information architecture",
            version: "v1",
            time: OCSessionTime(created: nowMilliseconds - (28 * hourMilliseconds), updated: nowMilliseconds - (3 * hourMilliseconds))
        ),
        OCSession(
            id: "session-screenshot-3",
            projectID: projectID,
            directory: projectPath,
            title: "Review onboarding copy for precision",
            version: "v1",
            time: OCSessionTime(created: nowMilliseconds - (4 * dayMilliseconds), updated: nowMilliseconds - (27 * hourMilliseconds))
        )
    ]

    static let sessionStatuses: [String: OCSessionStatus] = [
        "session-screenshot-1": OCSessionStatus(type: .busy, attempt: 1, message: "Generating screenshot-ready copy", next: nil),
        "session-screenshot-2": OCSessionStatus(type: .idle, attempt: nil, message: nil, next: nil),
        "session-screenshot-3": OCSessionStatus(type: .idle, attempt: nil, message: nil, next: nil)
    ]

    static let savedConnection = SavedConnection(
        id: "saved-screenshot-connection",
        serverURL: "demo.openlens.local:4096",
        username: "developer",
        password: "demo-token",
        selectedProviderID: "anthropic",
        selectedModelID: "claude-sonnet-4-20250514",
        selectedVariant: "high",
        selectedProjectDirectory: projectPath,
        lastConnectedAt: Date()
    )

    static let providersResult = ProvidersService.ProvidersResult(
        providers: [
            OCProvider(
                id: "anthropic",
                name: "Anthropic",
                models: [
                    "claude-sonnet-4-20250514": OCProviderModel(
                        id: "claude-sonnet-4-20250514",
                        name: "Claude Sonnet 4",
                        attachment: true,
                        reasoning: true,
                        toolCall: true,
                        limit: OCModelLimit(context: 200_000, output: 8_192),
                        variants: [
                            "minimal": OCProviderVariant(disabled: false, reasoningEffort: "minimal", effort: nil, budgetTokens: nil, maxReasoningEffort: nil, thinking: nil, thinkingConfig: nil, reasoning: nil, reasoningConfig: nil),
                            "high": OCProviderVariant(disabled: false, reasoningEffort: "high", effort: nil, budgetTokens: nil, maxReasoningEffort: nil, thinking: nil, thinkingConfig: nil, reasoning: nil, reasoningConfig: nil)
                        ]
                    )
                ]
            ),
            OCProvider(
                id: "openai",
                name: "OpenAI",
                models: [
                    "gpt-5.4": OCProviderModel(
                        id: "gpt-5.4",
                        name: "GPT-5.4",
                        attachment: true,
                        reasoning: true,
                        toolCall: true,
                        limit: OCModelLimit(context: 128_000, output: 16_384),
                        variants: nil
                    )
                ]
            )
        ],
        connectedProviderIDs: ["anthropic", "openai"],
        defaultProviderID: "anthropic",
        defaultModelID: "claude-sonnet-4-20250514"
    )

    static let configResult = ProvidersService.ConfigResult(
        defaultProviderID: "anthropic",
        defaultModelID: "claude-sonnet-4-20250514",
        enabledProviders: nil,
        disabledProviders: nil
    )

    static let inboxSnapshot = InboxSnapshot(
        permissions: [
            OCPermissionRequest(
                id: "perm-screenshot-1",
                sessionID: defaultSessionID,
                permission: "bash",
                patterns: ["git push origin feature/app-store-assets"],
                always: [],
                description: "Push the screenshot branch to origin.",
                title: "Permission required",
                toolName: "bash"
            )
        ],
        questions: [
            OCQuestionRequest(
                id: "question-screenshot-1",
                sessionID: defaultSessionID,
                questions: [
                    OCQuestionInfo(
                        question: "Which screenshot should become the first App Store card?",
                        header: "Choose hero screenshot",
                        options: [
                            OCQuestionOption(label: "Chat overview", description: "Lead with the agent conversation."),
                            OCQuestionOption(label: "Workspace overview", description: "Lead with repo-level context and changes."),
                            OCQuestionOption(label: "Review flow", description: "Lead with code review and diffs.")
                        ],
                        multiple: false,
                        custom: false
                    )
                ]
            )
        ]
    )

    static func session(withID id: String) -> OCSession? {
        sessions.first { $0.id == id }
    }

    static var defaultSession: OCSession {
        session(withID: defaultSessionID) ?? sessions[0]
    }

    static func reviewSnapshot(sessionID: String) -> SessionReviewSnapshot {
        SessionReviewSnapshot(
            sessionID: sessionID,
            changeSets: [latestChangeSet, polishChangeSet],
            workingTree: workingTreeFiles
        )
    }

    static func workspaceSnapshot(path: String?) -> WorkspaceSnapshot {
        let currentPath = normalizedPath(path)
        let pathInfo = OCPathInfo(
            state: "ready",
            config: "openlens.config.json",
            worktree: projectPath,
            directory: currentPath == "." ? projectPath : projectPath + "/" + currentPath
        )

        return WorkspaceSnapshot(
            currentProject: currentProject,
            projects: [
                currentProject,
                releaseProject
            ],
            pathInfo: pathInfo,
            vcsInfo: OCVCSInfo(branch: branchName),
            commands: commands,
            fileItems: fileItems(for: currentPath),
            currentPath: currentPath,
            workingTree: workingTreeFiles,
            workingTreeSource: .gitStatus
        )
    }

    static func activityDays(since startDate: Date, calendar: Calendar = .current) -> [WorkspaceActivityDay] {
        let dayOffsetsAndCounts = [
            (0, 3),
            (1, 2),
            (2, 4),
            (4, 1),
            (6, 5),
            (9, 2),
            (12, 3),
            (15, 1),
            (18, 4),
            (21, 2),
            (26, 3),
            (33, 2),
            (40, 4),
            (55, 1),
            (69, 2)
        ]

        return dayOffsetsAndCounts.compactMap { offset, count in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: Date()) else {
                return nil
            }

            let normalizedDate = calendar.startOfDay(for: date)
            guard normalizedDate >= calendar.startOfDay(for: startDate) else {
                return nil
            }

            return WorkspaceActivityDay(date: normalizedDate, turnCount: count)
        }
        .sorted { $0.date < $1.date }
    }

    private static let currentProject = OCProject(
        id: projectID,
        worktree: projectPath,
        vcsDir: projectPath + "/.git",
        vcs: "git",
        time: OCProjectTime(created: nowMilliseconds - (30 * dayMilliseconds), initialized: nowMilliseconds - (30 * dayMilliseconds))
    )

    private static let releaseProject = OCProject(
        id: "proj_openlens_release",
        worktree: "/workspace/OpenLens-release",
        vcsDir: "/workspace/OpenLens-release/.git",
        vcs: "git",
        time: OCProjectTime(created: nowMilliseconds - (42 * dayMilliseconds), initialized: nowMilliseconds - (42 * dayMilliseconds))
    )

    private static let commands: [WorkspaceCommandItem] = [
        WorkspaceCommandItem(id: "review", title: "/review", description: "Summarize the current diff with risks and open questions.", prompt: "/review"),
        WorkspaceCommandItem(id: "test", title: "/test", description: "Run the focused test target for the selected changes.", prompt: "/test OpenLensTests"),
        WorkspaceCommandItem(id: "ship", title: "/ship", description: "Prepare release notes and final polish tasks.", prompt: "/ship")
    ]

    private static let rootFileItems: [WorkspaceFileItem] = [
        WorkspaceFileItem(path: "OpenLens", name: "OpenLens", absolutePath: projectPath + "/OpenLens", kind: .directory),
        WorkspaceFileItem(path: "OpenLensTests", name: "OpenLensTests", absolutePath: projectPath + "/OpenLensTests", kind: .directory),
        WorkspaceFileItem(path: "README.md", name: "README.md", absolutePath: projectPath + "/README.md", kind: .file),
        WorkspaceFileItem(path: "CODE_REVIEW.md", name: "CODE_REVIEW.md", absolutePath: projectPath + "/CODE_REVIEW.md", kind: .file)
    ]

    private static let openLensFileItems: [WorkspaceFileItem] = [
        WorkspaceFileItem(path: "OpenLens/Views", name: "Views", absolutePath: projectPath + "/OpenLens/Views", kind: .directory),
        WorkspaceFileItem(path: "OpenLens/Services", name: "Services", absolutePath: projectPath + "/OpenLens/Services", kind: .directory),
        WorkspaceFileItem(path: "OpenLens/OpenLensApp.swift", name: "OpenLensApp.swift", absolutePath: projectPath + "/OpenLens/OpenLensApp.swift", kind: .file),
        WorkspaceFileItem(path: "OpenLens/AppText.swift", name: "AppText.swift", absolutePath: projectPath + "/OpenLens/AppText.swift", kind: .file)
    ]

    private static let latestChangeSet = ReviewChangeSet(
        id: "changeset-screenshot-1",
        title: "Polish screenshot mode for App Store assets",
        createdAt: Date().addingTimeInterval(-(35 * 60)),
        messagePreview: "Seed the app with rich demo content across chat, review, and workspace.",
        files: [
            ReviewFileChange(
                path: "OpenLens/OpenLensApp.swift",
                status: "M",
                additions: 26,
                deletions: 3,
                beforeText: "if connection.isConnected {\n    ConnectedRootView(chatClient: chatClient)\n}",
                afterText: "if ScreenshotFixtures.isEnabled || connection.isConnected {\n    ConnectedRootView(chatClient: chatClient)\n}") ,
            ReviewFileChange(
                path: "OpenLens/Services/ScreenshotFixtures.swift",
                status: "A",
                additions: 214,
                deletions: 0,
                beforeText: nil,
                afterText: "enum ScreenshotFixtures {\n    static let launchArgument = \"SCREENSHOT_MODE\"\n    static let defaultSessionID = \"session-screenshot-1\"\n}"
            )
        ]
    )

    private static let polishChangeSet = ReviewChangeSet(
        id: "changeset-screenshot-2",
        title: "Refine review totals and workspace labels",
        createdAt: Date().addingTimeInterval(-(2.5 * 60 * 60)),
        messagePreview: "Tighten strings so screenshots read cleanly at a glance.",
        files: [
            ReviewFileChange(
                path: "OpenLens/Views/Review/ReviewRootView.swift",
                status: "M",
                additions: 14,
                deletions: 6,
                beforeText: "Text(\"Latest\")",
                afterText: "Text(\"Latest agent update\")"
            ),
            ReviewFileChange(
                path: "OpenLens/Views/Workspace/WorkspaceRootView.swift",
                status: "M",
                additions: 18,
                deletions: 4,
                beforeText: "Text(\"Commands\")",
                afterText: "Text(\"Workspace commands\")"
            )
        ]
    )

    private static let workingTreeFiles: [ReviewFileChange] = [
        ReviewFileChange(
            path: "OpenLens/Views/Workspace/WorkspaceRootView.swift",
            status: "M",
            additions: 42,
            deletions: 11,
            beforeText: "Text(\"Workspace\")\n",
            afterText: "Text(\"Workspace\")\nText(\"Source control and commands in one place\")\n"
        ),
        ReviewFileChange(
            path: "OpenLens/Views/Review/ReviewRootView.swift",
            status: "M",
            additions: 19,
            deletions: 8,
            beforeText: "Text(\"Review\")\n",
            afterText: "Text(\"Review\")\nText(\"Inspect scoped code changes\")\n"
        ),
        ReviewFileChange(
            path: "OpenLens/Services/ScreenshotFixtures.swift",
            status: "A",
            additions: 214,
            deletions: 0,
            beforeText: nil,
            afterText: "enum ScreenshotFixtures {\n    static let providersResult = ProvidersService.ProvidersResult(...)\n}"
        )
    ]

    private static func normalizedPath(_ path: String?) -> String {
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        return trimmed ?? "."
    }

    private static func fileItems(for path: String) -> [WorkspaceFileItem] {
        switch path {
        case ".":
            return rootFileItems
        case "OpenLens":
            return openLensFileItems
        default:
            return []
        }
    }
}
