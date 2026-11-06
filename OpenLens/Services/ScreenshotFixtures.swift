import Foundation

enum ScreenshotFixtures {
    static var showsActiveContextButton: Bool {
        showsContextUsage || opensActiveContext || (isEnabled && ProcessInfo.processInfo.arguments.contains("SCREENSHOT_ACTIVE_CONTEXT_BUTTON"))
    }

    static var showsContextUsage: Bool {
        isEnabled && ProcessInfo.processInfo.arguments.contains("SCREENSHOT_CONTEXT_USAGE")
    }

    @MainActor static func applyContextUsage(to chat: ChatClient) {
        guard let transcript = try? activeContextProjection() else { return }
        chat.providers = providersResult.providers
        chat.replaceTranscript(transcript)
    }

    static var opensActiveContext: Bool {
        isEnabled && ProcessInfo.processInfo.arguments.contains("SCREENSHOT_ACTIVE_CONTEXT")
    }

    static var activeContextState: String {
        ProcessInfo.processInfo.arguments.first { $0.hasPrefix("SCREENSHOT_ACTIVE_CONTEXT_STATE=") }?
            .split(separator: "=").last.map(String.init) ?? "loaded"
    }

    static var showsCompaction: Bool {
        isEnabled && ProcessInfo.processInfo.arguments.contains("SCREENSHOT_COMPACTION")
    }

    private static var compactionScenario: String {
        ProcessInfo.processInfo.arguments.first { $0.hasPrefix("SCREENSHOT_COMPACTION_STATE=") }?
            .split(separator: "=").last.map(String.init) ?? "ready"
    }

    @MainActor static var compactionState: ChatClient.CompactionState? {
        guard showsCompaction else { return nil }
        switch compactionScenario {
        case "submitting": return .submitting
        case "pending": return .pending
        case "running": return .running
        case "completed": return .completed
        case "failed": return .failed("The provider is offline. Try compaction again when it is available.")
        case "modelUnavailable": return .failed("Model unavailable: openai/gpt-5.4. Choose an available model for this session and try again.")
        case "interrupted": return .interrupted
        case "uncertain": return .uncertain
        case "unavailable": return .unavailable
        default: return .ready
        }
    }

    @MainActor static var canRequestCompaction: Bool? {
        guard let state = compactionState else { return nil }
        if compactionScenario == "disconnected" { return false }
        switch state {
        case .ready, .completed, .failed, .interrupted, .uncertain: return true
        default: return false
        }
    }

    @MainActor private static func compactionProjection() throws -> SessionTranscript {
        var records: [[String: Any]] = []
        if ["running", "completed", "failed", "interrupted"].contains(compactionScenario) {
            let failed = compactionScenario == "failed" || compactionScenario == "interrupted"
            var entry: [String: Any] = ["id": "msg_fixture_compact", "type": "compaction", "reason": "manual",
                "status": failed ? "failed" : compactionScenario]
            if failed {
                entry["error"] = ["type": "unknown", "message": compactionScenario == "interrupted"
                    ? "Execution was interrupted." : "The provider is offline."]
            } else {
                entry["summary"] = "Model selection is saved on the server. The tests pass. Keep the current branch for review."
                entry["recent"] = "Inspect the resulting summary on the phone."
            }
            records.append(entry)
            if compactionScenario == "interrupted" {
                records.append(["id": "msg_fixture_idle", "type": "idle", "outcome": "interrupted"])
            }
        } else {
            records.append(["id": "msg_fixture_user", "type": "user", "text": "Keep the conversation focused on the current task."])
        }
        let data = try JSONSerialization.data(withJSONObject: records)
        let entries = try JSONDecoder().decode([OCV2SessionMessage].self, from: data)
        return MessagesService.transcript(from: OCTranscriptEntry.projectV2(entries, sessionID: defaultSession.id))
    }

    @MainActor static func applyCompaction(to chat: ChatClient) {
        guard let transcript = try? compactionProjection() else { return }
        chat.replaceTranscript(transcript)
        if compactionScenario == "pending" {
            let entry = OCV2InboxEntry(id: "msg_fixture_compact", sessionID: defaultSession.id,
                                      type: "compaction", delivery: .steer, text: nil)
            if let pending = chat.queuedPrompt(for: entry) { chat.queuedPrompts = [pending] }
        }
    }

    /// Uses the production tagged-entry decoder and message conversion.
    @MainActor static func activeContextProjection() throws -> SessionTranscript {
        if showsCompaction && !showsContextUsage { return try compactionProjection() }
        let wire = activeContextState == "empty" ? "[]" : #"""
        [
          {"id":"active-summary","type":"compaction","status":"completed","reason":"manual","summary":"Model selection is saved on the server. The tests pass. Keep the current branch for review."},
          {"id":"active-user","type":"user","text":"Continue with active context inspection."},
          {"id":"active-reply","type":"assistant","model":{"providerID":"anthropic","id":"claude-sonnet-4-20250514"},"tokens":{"input":90000,"output":10000,"reasoning":1000,"cache":{"read":40000,"write":3000}},"content":[{"type":"text","text":"I’ll keep the context view separate from the full conversation."}]}
        ]
        """#
        let entries = try JSONDecoder().decode([OCV2SessionMessage].self, from: Data(wire.utf8))
        return MessagesService.transcript(from: OCTranscriptEntry.projectV2(entries, sessionID: defaultSession.id))
    }

    static var showsSubagentResults: Bool {
        ProcessInfo.processInfo.arguments.contains("SCREENSHOT_SUBAGENT_RESULTS")
    }

    /// Canonical synthetic records reconcile the actual persisted launch card.
    @MainActor static func applySubagentResults(to chat: ChatClient) {
        let arguments = ProcessInfo.processInfo.arguments
        let stateArgument = arguments.first { $0.hasPrefix("SCREENSHOT_SUBAGENT_RESULT_STATE=") }
        let state = stateArgument?.split(separator: "=").last.map(String.init) ?? "completed"
        let resultText: String
        if arguments.contains("SCREENSHOT_SUBAGENT_RESULT_LONG") {
            resultText = String(repeating: "Reviewed the changes. All checks passed. ", count: 1_000)
        } else {
            switch state {
            case "error": resultText = "The review could not finish. The provider is offline."
            case "cancelled": resultText = "The background review was cancelled."
            default: resultText = "Reviewed the changes. No blocking issues found.\nAll checks passed."
            }
        }
        var records: [[String: Any]] = [
            ["id": "fixture-user", "type": "user", "text": "Run the review in the background."],
            ["id": "fixture-launch", "type": "assistant", "content": [[
                "id": "fixture-call", "type": "tool", "name": "subagent", "state": [
                    "status": "completed", "input": ["agent": "review", "description": "Review the changes"],
                    "content": [["type": "text", "text": "Background job started"]],
                    "metadata": ["sessionID": "ses_fixture_child", "status": "running"]
                ]
            ]]],
            ["id": "fixture-result", "type": "synthetic", "description": "Review the changes",
             "text": "<subagent sessionID=\"ses_fixture_child\" state=\"\(state)\" description=\"Review the changes\">\n\(resultText)\n</subagent>",
             "metadata": ["source": "subagent", "childID": "ses_fixture_child", "agent": "review", "state": state]]
        ]
        if arguments.contains("SCREENSHOT_SUBAGENT_RESULT_UNKNOWN") {
            records[2]["text"] = "The server reported an unfamiliar child outcome."
            records[2]["metadata"] = ["source": "subagent", "childID": "ses_fixture_child", "agent": "review", "state": "future"]
            records.append(["id": "fixture-other", "type": "synthetic", "description": "Automatic context update",
                            "text": "Keep the current feature branch for review.", "metadata": ["source": "other"]])
        }
        var queuedEntry: OCV2InboxEntry?
        if arguments.contains("SCREENSHOT_SUBAGENT_RESULT_QUEUED") {
            let result = records.remove(at: 2)
            let wireEntry: [String: Any] = [
                "id": "fixture-result", "sessionID": defaultSession.id, "type": "synthetic", "delivery": "steer",
                "payload": ["text": result["text"] ?? "", "description": "Review the changes", "metadata": result["metadata"] ?? [:]]
            ]
            if let data = try? JSONSerialization.data(withJSONObject: wireEntry) {
                queuedEntry = try? JSONDecoder().decode(OCV2InboxEntry.self, from: data)
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: records),
              let entries = try? JSONDecoder().decode([OCV2SessionMessage].self, from: data) else { return }
        chat.replaceTranscript(MessagesService.transcript(from: OCTranscriptEntry.projectV2(entries, sessionID: defaultSession.id)))
        if let queuedEntry, let pending = chat.queuedPrompt(for: queuedEntry) {
            chat.queuedPrompts = [pending]
        }
    }

    static var showsContextTimeline: Bool {
        ProcessInfo.processInfo.arguments.contains("SCREENSHOT_CONTEXT_CHANGES") || showsContextResults
    }

    static var showsContextResults: Bool {
        ProcessInfo.processInfo.arguments.contains("SCREENSHOT_CONTEXT_RESULTS")
    }

    static var expandsContextDetails: Bool {
        isEnabled && ProcessInfo.processInfo.arguments.contains("SCREENSHOT_CONTEXT_DETAILS")
    }

    static var scrollsToContextDetailsEnd: Bool {
        isEnabled && ProcessInfo.processInfo.arguments.contains("SCREENSHOT_CONTEXT_LONG_DETAILS")
    }

    /// Decode the same tagged records as history, then use the production
    /// transcript projection. Variants fit all supported context kinds on screen.
    @MainActor static func applyContextTimeline(to chat: ChatClient) {
        let shellCommand = ProcessInfo.processInfo.arguments.contains("SCREENSHOT_CONTEXT_WRAPPING_SUMMARY")
            ? "swift test --filter V2ContextTimelineTests --configuration debug"
            : "swift test"
        let shellText = scrollsToContextDetailsEnd
            ? String(repeating: "Check passed. ", count: 4_000)
            : #"All 24 checks passed.\n/workspace/OpenLens"#
        let records = showsContextResults ? #"""
        [
          {"id":"fixture-shell","type":"shell","time":{"created":1,"completed":2},"shellID":"shell_checks","command":"\#(shellCommand)","status":"completed","exit":0,"output":{"text":"\#(shellText)","truncated":true}},
          {"id":"fixture-compaction","type":"compaction","time":{"created":3},"status":"completed","reason":"manual","summary":"The feature is implemented and verified.","recent":"Keep the current branch for review."},
          {"id":"fixture-reply","type":"assistant","time":{"created":4},"content":[{"type":"text","text":"The checks passed. Ready for review."}]},
          {"id":"fixture-idle","type":"idle","time":{"created":5},"outcome":"succeeded"}
        ]
        """# : #"""
        [
          {"id":"fixture-user","type":"user","time":{"created":1},"text":"Continue with the feature work."},
          {"id":"fixture-model","type":"model-switched","time":{"created":2},"model":{"providerID":"anthropic","id":"claude-sonnet-4","variant":"high"},"previous":{"providerID":"openai","id":"gpt-5"}},
          {"id":"fixture-agent","type":"agent-switched","time":{"created":3},"agent":"build","previous":"plan"},
          {"id":"fixture-location","type":"location-switched","time":{"created":4},"location":{"directory":"/workspace/OpenLens-feature"},"previous":{"location":{"directory":"/workspace/OpenLens"}}},
          {"id":"fixture-system","type":"system","time":{"created":5},"description":"Repository instructions updated","text":"Use Swift Testing for new coverage."},
          {"id":"fixture-skill","type":"skill","time":{"created":6},"skill":"skill_review","name":"code-review","text":"Review the changes against the project rules."}
        ]
        """#
        guard let entries = try? JSONDecoder().decode([OCV2SessionMessage].self, from: Data(records.utf8)) else { return }
        chat.replaceTranscript(MessagesService.transcript(from: OCTranscriptEntry.projectV2(entries, sessionID: defaultSession.id)))
    }

    static var showsSubagentTools: Bool {
        ProcessInfo.processInfo.arguments.contains("SCREENSHOT_SUBAGENT_TOOLS")
    }

    /// Uses the production activity projection, including successful launches
    /// retaining launch-time running evidence after the parent's response ends.
    static func applySubagentTools(to chat: ChatClient) {
        let sessionID = defaultSession.id
        let messageID = "fixture-subagents"
        func part(_ id: String, tool: String = "subagent", agent: String, description: String, childStatus: String, failed: Bool = false) -> OCPart {
            StreamToolPartSafety.sanitize(OCPart(
                id: id, sessionID: sessionID, messageID: messageID, type: .tool, tool: tool,
                state: OCToolState(
                    status: failed ? .error : .completed,
                    input: AnyCodable(["agent": agent, "description": description]),
                    error: failed ? "Subagent failed" : nil,
                    metadata: ["sessionID": AnyCodable("ses_\(id)"), "status": AnyCodable(childStatus)]
                )
            ))
        }
        let parts: [OCPart]
        if ProcessInfo.processInfo.arguments.contains("SCREENSHOT_SUBAGENT_UNKNOWN") {
            parts = [
                StreamToolPartSafety.sanitize(OCPart(
                    id: "unknown-child", sessionID: sessionID, messageID: messageID, type: .tool,
                    tool: "subagent", state: OCToolState(status: .unknown)
                )),
                OCPart(id: "fixture-result", sessionID: sessionID, messageID: messageID, type: .text,
                       text: "The server reported an unsupported tool state.")
            ]
        } else if ProcessInfo.processInfo.arguments.contains("SCREENSHOT_SUBAGENT_PENDING") {
            parts = [StreamToolPartSafety.sanitize(OCPart(
                id: "pending-child", sessionID: sessionID, messageID: messageID, type: .tool,
                tool: "subagent", state: OCToolState(status: .pending)
            ))]
        } else {
            parts = [
                part("legacy", tool: "task", agent: "explore", description: "Inspect the legacy task flow", childStatus: "running"),
                part("background", agent: "review", description: "Review changes in the background", childStatus: "running"),
                part("completed", agent: "test", description: "Run focused checks", childStatus: "completed"),
                part("failed", agent: "build", description: "Build the release target", childStatus: "running", failed: true)
            ]
        }
        chat.messages = [
            ChatMessage(id: "fixture-user", role: .user, content: "Delegate the review and verification work."),
            ChatMessage(id: messageID, role: .assistant, content: "", parts: parts)
        ]
    }

    static var showsSessionMove: Bool {
        ProcessInfo.processInfo.arguments.contains("SCREENSHOT_SESSION_MOVE") || failsSessionRebind || interruptsMoveSend
    }

    static var interruptsMoveSend: Bool {
        ProcessInfo.processInfo.arguments.contains("SCREENSHOT_SESSION_MOVE_INTERRUPTED_SEND") || interruptsQueuedMoveCommand
    }

    static var interruptsQueuedMoveCommand: Bool {
        ProcessInfo.processInfo.arguments.contains("SCREENSHOT_SESSION_MOVE_QUEUED_COMMAND")
    }

    static var failsSessionRebind: Bool {
        ProcessInfo.processInfo.arguments.contains("SCREENSHOT_SESSION_REBIND_FAILED")
    }

    static var showsExecutionOutcomes: Bool {
        ProcessInfo.processInfo.arguments.contains("SCREENSHOT_EXECUTION_OUTCOMES") || showsUnreadResults
    }

    static var showsUnreadResults: Bool {
        ProcessInfo.processInfo.arguments.contains("SCREENSHOT_UNREAD_RESULTS") || showsViewAcknowledgementFailure
    }

    static var showsViewAcknowledgementFailure: Bool {
        ProcessInfo.processInfo.arguments.contains("SCREENSHOT_VIEW_ACK_FAILED") || showsSendAndViewAcknowledgementFailure
    }

    static var showsSendAndViewAcknowledgementFailure: Bool {
        ProcessInfo.processInfo.arguments.contains("SCREENSHOT_SEND_AND_VIEW_ACK_FAILED")
    }

    static var simulatesOutcomeRefresh: Bool {
        ProcessInfo.processInfo.arguments.contains("SCREENSHOT_EXECUTION_REFRESH") || failsOutcomeRefresh
    }

    static var failsOutcomeRefresh: Bool {
        ProcessInfo.processInfo.arguments.contains("SCREENSHOT_EXECUTION_REFRESH_FAILED")
    }

    static var outcomeRefreshHasCompleted: Bool {
        simulatesOutcomeRefresh && Date().timeIntervalSince1970 * 1000 - nowMilliseconds > 1500
    }

    static var executionState: OCExecutionState {
        let prefix = "SCREENSHOT_EXECUTION_STATE="
        let value = ProcessInfo.processInfo.arguments.first { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) } ?? "succeeded"
        return OCExecutionState(rawValue: value) ?? .unknown
    }

    /// Stable transcript and execution projection for outcome screenshots.
    static func applyExecutionOutcome(to chat: ChatClient) {
        let reply: String
        switch executionState {
        case .succeeded: reply = "All checks passed. The release build is ready for review."
        case .failed: reply = "The test run reported a failure. I can investigate it next."
        case .interrupted: reply = "Execution was interrupted before the remaining checks finished."
        case .working: reply = "The suite is still running. I'll report the result when execution finishes."
        case .waitingPermission, .waitingForm: reply = "I need your response before continuing."
        case .unknown: reply = "The current result could not be confirmed."
        }
        chat.messages = [
            ChatMessage(id: "fixture-user", role: .user, content: "Run the test suite and report the result."),
            ChatMessage(id: "fixture-assistant", role: .assistant, content: reply)
        ]
        if showsViewAcknowledgementFailure {
            chat.resultViewingState = .failed(sessionID: defaultSessionID, idle: defaultSession.time.idle ?? 0,
                message: "Failed to confirm viewed result: The network connection was lost.")
        }
        if showsSendAndViewAcknowledgementFailure {
            chat.errorMessage = "Failed to send the prompt: The network connection was lost."
        }
        switch executionState {
        case .working:
            chat.beginExternalResponse()
        case .waitingPermission:
            chat.pendingPermission = inboxSnapshot.permissions.first
        case .waitingForm:
            chat.pendingForm = inboxSnapshot.forms.first
        default: break
        }
    }

    static let launchArgument = "SCREENSHOT_MODE"
    static let tabArgumentPrefix = "SCREENSHOT_TAB="
    static let chatSessionArgument = "SCREENSHOT_CHAT_SESSION"
    static let permissionSheetArgument = "SCREENSHOT_PERMISSION_SHEET"
    static let formSheetArgument = "SCREENSHOT_FORM_SHEET"
    static let permissionAllowAllConfirmationArgument = "SCREENSHOT_PERMISSION_ALLOW_ALL_CONFIRMATION"
    static let turnDiffSheetArgument = "CHAT_TURN_DIFF_SHEET_PREVIEW_MODE"
    static let settingsSectionArgumentPrefix = "SCREENSHOT_SETTINGS_SECTION="
    static let environmentKey = "OPENLENS_SCREENSHOT_MODE"
    static let tabEnvironmentKey = "OPENLENS_SCREENSHOT_TAB"
    static let chatSessionEnvironmentKey = "OPENLENS_SCREENSHOT_CHAT_SESSION"
    static let permissionSheetEnvironmentKey = "OPENLENS_SCREENSHOT_PERMISSION_SHEET"
    static let formSheetEnvironmentKey = "OPENLENS_SCREENSHOT_FORM_SHEET"
    static let permissionAllowAllConfirmationEnvironmentKey = "OPENLENS_SCREENSHOT_PERMISSION_ALLOW_ALL_CONFIRMATION"
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

    static var opensPermissionSheet: Bool {
        let processInfo = ProcessInfo.processInfo
        return processInfo.arguments.contains(permissionSheetArgument) || processInfo.environment[permissionSheetEnvironmentKey] == "1"
    }

    static var showsConditionalForm: Bool {
        isEnabled && ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("SCREENSHOT_CONDITIONAL_FORM=") }
    }

    static var opensInbox: Bool {
        isEnabled && ProcessInfo.processInfo.arguments.contains("SCREENSHOT_INBOX")
    }

    static var opensGlobalFormSheet: Bool {
        isEnabled && ProcessInfo.processInfo.arguments.contains("SCREENSHOT_GLOBAL_FORM_SHEET")
    }

    private static var globalFormScenario: String? {
        guard isEnabled else { return nil }
        return ProcessInfo.processInfo.arguments.first { $0.hasPrefix("SCREENSHOT_GLOBAL_FORM=") }?
            .split(separator: "=").last.map(String.init)
    }

    static var opensFormSheet: Bool {
        let processInfo = ProcessInfo.processInfo
        return processInfo.arguments.contains(formSheetArgument) || processInfo.environment[formSheetEnvironmentKey] == "1"
    }

    static var opensPermissionAllowAllConfirmation: Bool {
        let processInfo = ProcessInfo.processInfo
        return processInfo.arguments.contains(permissionAllowAllConfirmationArgument)
            || processInfo.environment[permissionAllowAllConfirmationEnvironmentKey] == "1"
    }

    static var opensTurnDiffSheet: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains(turnDiffSheetArgument)
#else
        false
#endif
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

    static let usageQuotaStateArgumentPrefix = "SCREENSHOT_USAGE_QUOTA_STATE="
    static let usageQuotaStateEnvironmentKey = "OPENLENS_SCREENSHOT_USAGE_QUOTA_STATE"

    static var usageQuotaScenario: String? {
        let processInfo = ProcessInfo.processInfo

        if let rawValue = processInfo.environment[usageQuotaStateEnvironmentKey] {
            return rawValue.lowercased()
        }

        return processInfo.arguments
            .first { $0.hasPrefix(usageQuotaStateArgumentPrefix) }
            .map { String($0.dropFirst(usageQuotaStateArgumentPrefix.count)).lowercased() }
    }

    @MainActor static func applyUsageQuota(to service: UsageQuotaService) {
        guard let scenario = usageQuotaScenario else { return }
        switch scenario {
        case "rejected":
            service.applyFixtureState(.keyRejected("HTTP 403 Forbidden"))
        case "nolimits":
            service.applyFixtureState(.noLimitsReported)
        case "failed":
            service.applyFixtureState(.failed("The request timed out."))
        default:
            service.applyFixtureState(.loaded(quotaSnapshot))
        }
    }

    static var quotaSnapshot: UsageQuotaService.QuotaSnapshot {
        UsageQuotaService.QuotaSnapshot(
            planName: "GLM Coding Plan",
            windows: [
                UsageQuotaService.QuotaWindow(
                    id: "TOKENS_LIMIT-0",
                    title: AppText.quotaWindow5Hour,
                    percentage: 82,
                    resetAt: Date(timeIntervalSinceNow: 47 * 60)
                ),
                UsageQuotaService.QuotaWindow(
                    id: "TOKENS_LIMIT-1",
                    title: AppText.quotaWindowWeekly,
                    percentage: 41,
                    resetAt: Date(timeIntervalSinceNow: 62 * 3600)
                )
            ],
            fetchedAt: Date()
        )
    }

    static var showsUsageLimitRetry: Bool {
        let processInfo = ProcessInfo.processInfo
        return isEnabled
            && (processInfo.arguments.contains("SCREENSHOT_USAGE_LIMIT_RETRY")
                || processInfo.environment["OPENLENS_SCREENSHOT_USAGE_LIMIT_RETRY"] == "1")
    }

    static var showsUsageLimitBanner: Bool {
        let processInfo = ProcessInfo.processInfo
        return isEnabled
            && (processInfo.arguments.contains("SCREENSHOT_USAGE_LIMIT_BANNER")
                || processInfo.environment["OPENLENS_SCREENSHOT_USAGE_LIMIT_BANNER"] == "1")
    }

    static let projectID = "proj_openlens_ios"
    static let projectName = showsSessionMove && !failsSessionRebind ? "OpenLens-feature" : "OpenLens"
    static let projectPath = "/workspace/" + projectName
    static let branchName = showsSessionMove && !failsSessionRebind ? "feature/session-move" : "feature/app-store-assets"

    private static let nowMilliseconds = Date().timeIntervalSince1970 * 1000
    private static let hourMilliseconds = 60.0 * 60.0 * 1000.0
    private static let dayMilliseconds = 24.0 * hourMilliseconds

    static let defaultSessionID = "session-screenshot-1"

    static let sessions: [OCSession] = showsExecutionOutcomes ? [
        outcomeSession(id: defaultSessionID, title: "Verify the release build", outcome: executionState.rawValue, minutesAgo: 8),
        outcomeSession(id: "session-screenshot-2", title: "Improve session recovery", outcome: "succeeded", minutesAgo: 20),
        outcomeSession(id: "session-screenshot-3", title: "Run integration tests", outcome: "failed", minutesAgo: 30),
        outcomeSession(id: "session-screenshot-4", title: "Investigate the slow build", outcome: "interrupted", minutesAgo: 40),
        outcomeSession(id: "session-screenshot-5", title: "Check the latest execution", outcome: nil, minutesAgo: 50)
    ] : [
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

    private static func outcomeSession(id: String, title: String, outcome: String?, minutesAgo: Double) -> OCSession {
        let idle = nowMilliseconds - minutesAgo * 60 * 1000
        return OCSession(
            id: id, projectID: projectID, directory: projectPath, title: title,
            time: .init(created: nowMilliseconds - dayMilliseconds, updated: idle,
                        idle: outcome == nil ? nil : idle,
                        viewed: showsUnreadResults && (id == "session-screenshot-4"
                            || ProcessInfo.processInfo.arguments.contains("SCREENSHOT_RESULT_VIEWED")) ? idle : nil),
            outcome: outcome
        )
    }

    static var sessionStatuses: [String: OCSessionStatus] {
        if outcomeRefreshHasCompleted { return [:] }
        return showsExecutionOutcomes ? [
        "session-screenshot-2": OCSessionStatus(type: .busy, attempt: nil, message: nil, next: nil)
    ] : [
        "session-screenshot-1": OCSessionStatus(type: .busy, attempt: 1, message: "Generating screenshot-ready copy", next: nil),
        "session-screenshot-2": OCSessionStatus(type: .idle, attempt: nil, message: nil, next: nil),
        "session-screenshot-3": OCSessionStatus(type: .idle, attempt: nil, message: nil, next: nil)
    ]
    }

    static let savedConnection: SavedConnection = {
        var connection = SavedConnection(
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
        connection.defaultProviderID = "anthropic"
        connection.defaultModelID = "claude-sonnet-4-20250514"
        return connection
    }()

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
                        inputMedia: ["text", "image"],
                        costTiers: [
                            OCModelCost(input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3),
                            OCModelCost(tier: 200_000, input: 6, output: 22, cacheRead: 0.6, cacheWrite: 6)
                        ],
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

    static var inboxSnapshot: InboxSnapshot {
        guard let scenario = globalFormScenario else { return standardInboxSnapshot }
        let extraField = scenario == "unsupported"
            ? #",{"key":"future","type":"server-control","title":"Integration control"}"#
            : scenario == "external"
                ? #",{"key":"login","type":"external","title":"Open the integration","url":"https://opencode.ai/docs/mcp-servers/","description":"Complete the action, then acknowledge it below."}"#
                : ""
        let wire = """
        {"id":"frm-global-screenshot","sessionID":"global","title":"Confirm the MCP workspace","fields":[
          {"key":"workspace","type":"string","title":"Workspace name","required":true,"default":"OpenLens"},
          {"key":"approved","type":"boolean","title":"Allow workspace access","required":true,"default":false}
          \(extraField)
        ]}
        """
        guard let global = try? JSONDecoder().decode(OCFormRequest.self, from: Data(wire.utf8)) else {
            preconditionFailure("Global screenshot form must decode.")
        }
        if ["remembered", "multiple"].contains(scenario) {
            let remembered = OCFormRequest(id: global.id, sessionID: "global", title: "Confirm MCP in Tools",
                fields: global.fields, globalDirectory: "/workspace/Tools")
            let forms = scenario == "multiple"
                ? [global.recovered(at: "/workspace/OpenLens"), remembered, standardScreenshotForm]
                : [remembered, standardScreenshotForm]
            return InboxSnapshot(permissions: [], questions: [], forms: forms)
        }
        return InboxSnapshot(permissions: [], questions: [],
            forms: [global.recovered(at: "/workspace/OpenLens"), standardScreenshotForm])
    }

    private static let standardInboxSnapshot = InboxSnapshot(
        permissions: [
            OCPermissionRequest(
                id: "perm-screenshot-1",
                sessionID: defaultSessionID,
                permission: "bash",
                patterns: ["git push origin feature/app-store-assets"],
                always: ["*"],
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
        ],
        forms: [screenshotForm]
    )

    private static var screenshotForm: OCFormRequest {
        guard isEnabled, let scenario = ProcessInfo.processInfo.arguments
            .first(where: { $0.hasPrefix("SCREENSHOT_CONDITIONAL_FORM=") })?
            .split(separator: "=").last else { return standardScreenshotForm }
        let enabled = scenario == "active"
        let predicate = scenario == "unsupported" ? "future" : "eq"
        let releaseProperties = scenario == "optional"
            ? #""description":"Choose an answer to show the matching fields.""#
            : "\"description\":\"Turn on to set the release details.\",\"required\":true,\"default\":\(enabled)"
        let wire = """
        {"id":"form-screenshot-1","sessionID":"session-screenshot-1",
         "title":"Choose the release plan","fields":[
          {"key":"release","type":"boolean","title":"Ship this release",
           \(releaseProperties)},
          {"key":"summary","type":"string","title":"Release summary","required":true,
           "minLength":3,"default":"Safer agent handoffs",
           "when":[{"key":"release","op":"\(predicate)","value":true}]},
          {"key":"confidence","type":"integer","title":"Confidence","required":true,
           "minimum":1,"maximum":10,"default":8,
           "when":[{"key":"release","op":"eq","value":true}]},
          {"key":"reason","type":"string","title":"Reason to wait","required":true,
           "default":"Finish verification first",
           "when":[{"key":"release","op":"neq","value":true}]}
         ]}
        """
        guard let form = try? JSONDecoder().decode(OCFormRequest.self, from: Data(wire.utf8)) else {
            preconditionFailure("Conditional screenshot form must decode.")
        }
        return form
    }

    private static let standardScreenshotForm: OCFormRequest = {
        let data = Data(#"""
        {
          "id": "form-screenshot-1",
          "sessionID": "session-screenshot-1",
          "title": "Choose the release focus",
          "fields": [
            {
              "key": "summary",
              "type": "string",
              "title": "Release summary",
              "description": "Describe the most important improvement for this release.",
              "required": true,
              "minLength": 3,
              "default": "Safer agent handoffs"
            },
            {
              "key": "confidence",
              "type": "integer",
              "title": "Confidence",
              "description": "How confident are you in the release plan?",
              "minimum": 1,
              "maximum": 10,
              "default": 8
            },
            {
              "key": "targets",
              "type": "multiselect",
              "title": "Ship targets",
              "required": true,
              "minItems": 1,
              "options": [
                {"value": "ios", "label": "iPhone app"},
                {"value": "widget", "label": "Live Activity"}
              ],
              "default": ["ios"]
            },
            {
              "key": "notes",
              "type": "external",
              "title": "Release checklist",
              "url": "https://opencode.ai/docs"
            }
          ]
        }
        """#.utf8)

        guard let form = try? JSONDecoder().decode(OCFormRequest.self, from: data) else {
            preconditionFailure("Screenshot form fixture must decode.")
        }
        return form
    }()

    static func session(withID id: String) -> OCSession? {
        if outcomeRefreshHasCompleted, id == "session-screenshot-2" {
            return outcomeSession(id: id, title: "Improve session recovery", outcome: "failed", minutesAgo: 0)
        }
        return sessions.first { $0.id == id }
    }

    static var defaultSession: OCSession {
        if showsSessionMove {
            return OCSession(id: defaultSessionID, directory: "/workspace/OpenLens-feature",
                             title: "Continue the moved session", time: .init(created: nowMilliseconds, updated: nowMilliseconds))
        }
        return session(withID: defaultSessionID) ?? sessions[0]
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

    private static let commands: [WorkspaceCommandItem] = showsSessionMove && !failsSessionRebind ? [
        WorkspaceCommandItem(id: "feature-test", title: "/feature-test", description: "Run tests in the feature worktree.", prompt: "/feature-test")
    ] : [
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

    static func repositoryEntries(at relativePath: String) -> [RepositoryEntry] {
        if showsSessionMove && !failsSessionRebind, relativePath.isEmpty {
            return [RepositoryEntry(path: "Feature.swift", name: "Feature.swift", isDirectory: false)]
        }
        switch relativePath {
        case "":
            return [
                RepositoryEntry(path: "OpenLens", name: "OpenLens", isDirectory: true),
                RepositoryEntry(path: "OpenLensTests", name: "OpenLensTests", isDirectory: true),
                RepositoryEntry(path: "AGENTS.md", name: "AGENTS.md", isDirectory: false),
                RepositoryEntry(path: "README.md", name: "README.md", isDirectory: false),
            ]
        default:
            return [
                RepositoryEntry(path: relativePath + "/ChatView.swift", name: "ChatView.swift", isDirectory: false),
                RepositoryEntry(path: relativePath + "/OpenLensApp.swift", name: "OpenLensApp.swift", isDirectory: false),
            ]
        }
    }

    static let repositoryFileContent = """
    # OpenLens

    OpenLens is a native iOS companion app for OpenCode.

    ## Getting started

    1. Start OpenCode on your Mac.
    2. Scan the QR code to connect.
    3. Pick a session and start chatting.
    """

    static func folderSnapshot(directory: String) -> WorkspaceFolderSnapshot {
        let names: [String]
        switch directory {
        case "/": names = ["workspace"]
        case "/workspace": names = ["OpenLens", "OpenLens-release", "Projects"]
        case "/workspace/Projects": names = ["Weather"]
        case projectPath: names = ["OpenLens", "OpenLensTests"]
        case projectPath + "/OpenLens": names = ["Services", "Views"]
        default: names = []
        }
        return WorkspaceFolderSnapshot(
            directory: directory,
            folders: names.map { name in
                let path = URL(fileURLWithPath: directory).appendingPathComponent(name).path
                return WorkspaceFileItem(path: path, name: name, absolutePath: path, kind: .directory)
            }
        )
    }

    private static func fileItems(for path: String) -> [WorkspaceFileItem] {
        if showsSessionMove && !failsSessionRebind, path == "." {
            return [WorkspaceFileItem(path: "Feature.swift", name: "Feature.swift",
                                      absolutePath: projectPath + "/Feature.swift", kind: .file)]
        }
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
