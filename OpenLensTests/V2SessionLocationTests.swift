import Foundation
import Testing
@testable import OpenLens

@MainActor
struct V2SessionLocationTests {
    @Test(arguments: ["refresh", "status", "open"], ["/api/location", "/api/vcs", "/api/model"])
    func retryAfterACommittedRebindRestoresProjectMetadataAndModels(path: String, heldPath: String) async throws {
        let server = LocationServer()
        let (chat, connection, api) = try await makeChat(server)
        await chat.loadSession(session())
        await server.move(to: "/workspace/New")
        // The first location request authorizes the move. Hold the next one
        // so cancellation can occur after commit, before metadata is restored.
        await server.hold(heldPath, directory: "/workspace/New", skip: heldPath == "/api/location" ? 1 : 0)
        if path == "status" { chat.beginExternalResponse() }
        let recovery = Task {
            switch path {
            case "open": await chat.loadSession(session())
            case "status": _ = await chat.refreshCurrentSessionStatus()
            default: _ = await chat.refreshCurrentSessionFromServer()
            }
        }
        try await waitUntil { await server.isWaiting }
        #expect(connection.selectedProjectDirectory == "/workspace/New")
        #expect(await api.currentContextDirectory() == "/workspace/New")
        recovery.cancel()
        await server.release()
        await recovery.value
        #expect(chat.sessionLocationError != nil)
        #expect(!chat.canCompose)
        chat.synchronizeCurrentSessionFromServer()
        try await waitUntil { chat.isStreamSynchronized }
        #expect(chat.sessionLocationState == .ready)
        #expect(connection.branch == "New")
        #expect(connection.projectName == "New")
        #expect(connection.currentProject?.id == "New")
        #expect(chat.availableModels.map(\.modelID) == ["New-model"])
    }

    @Test func movingBackDuringCatalogRecoveryRestoresTheOriginalLocationsModels() async throws {
        let server = LocationServer()
        let (chat, connection, _) = try await makeChat(server)
        await chat.loadSession(session())
        await server.move(to: "/workspace/New")
        await server.hold("/api/model", directory: "/workspace/New")
        chat.synchronizeCurrentSessionFromServer()
        try await waitUntil { await server.isWaiting }
        await server.move(to: "/workspace/Old")
        chat.synchronizeCurrentSessionFromServer()
        await server.release()
        try await waitUntil { chat.isStreamSynchronized }
        #expect(connection.selectedProjectDirectory == "/workspace/Old")
        #expect(chat.sessionLocationState == .ready)
        #expect(chat.availableModels.map(\.modelID) == ["Old-model"])
    }

    @Test(arguments: ["/workspace/Old", "/workspace/New"])
    func rawSSEMoveReconnectsAndSwitchesTheProductionDirectoryFilter(eventDirectory: String) async throws {
        let server = LocationServer()
        let transport = LocationStreamingTransport(server: server)
        let stream = SSEClient(baseURL: URL(string: "https://example.com")!, protocolVersion: .v2,
                               contextDirectory: "/workspace/Old", transport: transport)
        let (chat, connection, _) = try await makeChat(server, stream: stream)
        await chat.loadSession(session())
        stream.connect()
        defer { stream.disconnect() }
        try await waitUntil { await stream.synchronizationGeneration() > 0 && chat.isStreamSynchronized }
        chat.attachComposerServerFile(relativePath: "Old.swift")
        await server.move(to: "/workspace/New")
        await server.hold("/api/vcs", directory: "/workspace/New")
        try transport.send(type: "session.moved", directory: eventDirectory, data: ["sessionID": "ses_move"])
        try await waitUntil { await server.isWaiting }
        // setProjectContext reconnects the real SSEClient while metadata is
        // held; its successful response starts a newer recovery generation.
        try await waitUntil { await stream.synchronizationGeneration() >= 2 && transport.streamCount == 2 }
        let gap = await stream.synchronizationGeneration()
        #expect(gap >= 2)
        await server.release()
        try await waitUntil { chat.isStreamSynchronized }
        #expect(connection.selectedProjectDirectory == "/workspace/New")
        #expect(chat.sessionLocationState == .ready)
        #expect(chat.composerAttachments.isEmpty)
        #expect(chat.availableModels.map(\.modelID) == ["New-model"])

        try transport.send(type: "session.renamed", directory: "/workspace/New",
                           data: ["sessionID": "ses_move", "title": "New workspace event"])
        try await waitUntil { chat.currentSession?.title == "New workspace event" }
        try transport.send(type: "session.renamed", directory: "/workspace/Old",
                           data: ["sessionID": "ses_move", "title": "Stale old event"])
        try transport.send(type: "session.moved", directory: "/workspace/Third", data: ["sessionID": "ses_other"])
        try await Task.sleep(for: .milliseconds(100))
        #expect(chat.currentSession?.title == "New workspace event")
        #expect(chat.sessionLocationState == .ready)
        #expect(transport.streamCount == 2)
    }

    @Test func cancellationCannotSplitTheRequestAndPublishedProjectContexts() async throws {
        let server = LocationServer()
        let (chat, connection, api) = try await makeChat(server)
        await chat.loadSession(session())
        let change = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await connection.setProjectContext(directory: "/workspace/New")
        }
        await change.value
        #expect(await api.currentContextDirectory() == connection.selectedProjectDirectory)
        // The navigation restore must see the same directory as the API and
        // actually restore Old, rather than skipping a split client context.
        await chat.restoreProjectContext(for: session())
        #expect(await api.currentContextDirectory() == "/workspace/Old")
        #expect(connection.selectedProjectDirectory == "/workspace/Old")
    }

    @Test(arguments: ["prompt", "queue", "steer", "command", "queued-command"], [false, true])
    func workWaitingForSettingsIsRestoredSafelyWhenTheSessionMoves(delivery: String, refused: Bool) async throws {
        let server = LocationServer()
        let activity = LocationActivityProvider()
        let (chat, _, _) = try await makeChat(server, activity: activity)
        await chat.loadSession(session())
        if ["queue", "steer", "queued-command"].contains(delivery) { await server.setSessionActive(true) }
        await server.hold("/api/session/ses_move/model", directory: "/workspace/Old")
        chat.selectModel(try #require(chat.availableModels.first))
        try await waitUntil { await server.isWaiting }
        let isCommand = delivery.contains("command")
        let text = isCommand ? "/Old-command keep arguments" : "Keep this unsent draft"
        if !isCommand {
            chat.attachComposerServerFile(relativePath: "Old.swift")
        }
        chat.attachComposerTextFile(data: Data("Phone note".utf8), name: "note.txt")
        chat.updateSlashCatalog(commands: ["Old-command"], agents: [])
        chat.inputText = text
        switch delivery {
        case "queue", "queued-command": chat.beginExternalResponse(); chat.queuePrompt()
        case "steer": chat.beginExternalResponse(); chat.steerPrompt()
        default: chat.send()
        }
        try await Task.sleep(for: .milliseconds(20))
        await server.move(to: "/workspace/New")
        await server.refuseNewLocation(refused ? 403 : nil)
        chat.synchronizeCurrentSessionFromServer()
        try await waitUntil { refused ? chat.sessionLocationError != nil : chat.isStreamSynchronized }
        await server.release()
        try await waitUntil { chat.inputText == text }
        #expect(chat.errorMessage?.contains("session moved") == true)
        #expect(!chat.composerAttachments.contains { if case .serverFile = $0 { true } else { false } })
        #expect(chat.composerAttachments.map(\.promptFile.name) == ["note.txt"])
        #expect(await server.mutations == ["/api/session/ses_move/model"])
        if delivery == "queue" || delivery == "queued-command" {
            #expect(chat.isLoading)
            #expect(chat.responseState == .generating)
            #expect(activity.phases.isEmpty)
            #expect(activity.dismissCount == 0)
        }
    }

    @Test(arguments: ["refresh", "status", "open"])
    func cancellingARebindLeavesAnExplicitRetryInsteadOfABlockedComposer(path: String) async throws {
        let server = LocationServer()
        let (chat, connection, api) = try await makeChat(server)
        await chat.loadSession(session())
        await server.move(to: "/workspace/New")
        await server.hold("/api/location", directory: "/workspace/New")
        if path == "status" { chat.beginExternalResponse() }
        let recovery = Task {
            switch path {
            case "open": await chat.loadSession(session())
            case "status": _ = await chat.refreshCurrentSessionStatus()
            default: _ = await chat.refreshCurrentSessionFromServer()
            }
        }
        try await waitUntil { await server.isWaiting }
        recovery.cancel()
        await server.release()
        await recovery.value
        #expect(chat.sessionLocationError != nil)
        #expect(!chat.canCompose)
        #expect(connection.selectedProjectDirectory == "/workspace/Old")
        #expect(await api.currentContextDirectory() == "/workspace/Old")
        chat.synchronizeCurrentSessionFromServer()
        try await waitUntil { chat.isStreamSynchronized }
        #expect(chat.sessionLocationState == .ready)
        #expect(connection.selectedProjectDirectory == "/workspace/New")
    }

    @Test(arguments: [false, true])
    func returningToTheChatCannotRestoreAStaleOrRefusedNavigationLocation(refused: Bool) async throws {
        let server = LocationServer()
        let (chat, connection, api) = try await makeChat(server)
        let navigationSession = session()
        await chat.loadSession(navigationSession)
        await server.move(to: "/workspace/New")
        await server.refuseNewLocation(refused ? 403 : nil)
        chat.synchronizeCurrentSessionFromServer()
        try await waitUntil { refused ? chat.sessionLocationError != nil : chat.isStreamSynchronized }
        // SessionChatDestinationView's same-id on-appear path, including a
        // navigation value captured after a refused canonical recovery.
        let capturedSession = refused ? try #require(chat.currentSession) : navigationSession
        await chat.restoreProjectContext(for: capturedSession)
        let expected = refused ? "/workspace/Old" : "/workspace/New"
        #expect(connection.selectedProjectDirectory == expected)
        #expect(await api.currentContextDirectory() == expected)
        #expect(chat.canCompose == !refused)
    }

    @Test func reconnectDuringMetadataRecoveryStillFinishesTheWorkspaceHandoff() async throws {
        let server = LocationServer()
        let (chat, connection, _) = try await makeChat(server)
        await chat.loadSession(session())
        chat.attachComposerServerFile(relativePath: "Old.swift")
        chat.attachComposerTextFile(data: Data("Phone note".utf8), name: "note.txt")
        await server.hold("/api/vcs", directory: "/workspace/New")
        await server.move(to: "/workspace/New")
        chat.synchronizeCurrentSessionFromServer()
        try await waitUntil { await server.isWaiting }
        // The SSE connection's 200 response reports a reconnect during the
        // metadata load; a new recovery generation must finish the handoff.
        chat.synchronizeCurrentSessionFromServer()
        await server.release()
        try await waitUntil { chat.isStreamSynchronized }
        #expect(connection.selectedProjectDirectory == "/workspace/New")
        #expect(chat.sessionLocationState == .ready)
        #expect(chat.composerAttachments.map(\.promptFile.name) == ["note.txt"])
        #expect(chat.availableModels.map(\.modelID) == ["New-model"])
    }

    @Test(arguments: ["move-event", "reopen"])
    func canonicalReadFailureKeepsAKnownMoveBlockedUntilRetry(recovery: String) async throws {
        let server = LocationServer()
        let (chat, connection, api) = try await makeChat(server)
        await chat.loadSession(session())
        await server.move(to: "/workspace/New")
        if recovery == "reopen" {
            await server.refuseNewLocation(403)
            chat.synchronizeCurrentSessionFromServer()
            try await waitUntil { chat.sessionLocationError != nil }
        }
        await server.failCanonicalReads(true)
        if recovery == "reopen" {
            await chat.loadSession(session())
        } else {
            var adapter = V2EventAdapter()
            let event = try #require(try adapter.event([
                "type": "session.moved", "location": ["directory": "/workspace/New"],
                "data": ["sessionID": "ses_move"]
            ], directory: "/workspace/Old"))
            chat.receiveStreamEvent(.raw(event))
            try await waitUntil { chat.sessionLocationError != nil }
        }
        #expect(!chat.canCompose)
        #expect(chat.sessionDirectory == nil)
        #expect(chat.messages.first?.content == "Preserve this conversation")
        #expect(connection.selectedProjectDirectory == "/workspace/Old")
        #expect(await api.currentContextDirectory() == "/workspace/Old")

        await server.failCanonicalReads(false)
        await server.refuseNewLocation(nil)
        chat.synchronizeCurrentSessionFromServer()
        try await waitUntil { chat.isStreamSynchronized }
        #expect(chat.canCompose)
        #expect(chat.errorMessage == nil)
        #expect(connection.selectedProjectDirectory == "/workspace/New")
    }

    @Test(arguments: ["sync", "refresh"])
    func aMoveDuringTranscriptRecoveryRunsTheNewestRecoveryPass(recovery: String) async throws {
        let server = LocationServer()
        let (chat, connection, _) = try await makeChat(server)
        await chat.loadSession(session())
        await server.hold("/api/session/ses_move/message", directory: "/workspace/Old")
        await server.move(to: "/workspace/New")
        let oldRefresh = recovery == "refresh" ? Task { await chat.refreshCurrentSessionFromServer() } : nil
        if oldRefresh == nil { chat.synchronizeCurrentSessionFromServer() }
        try await waitUntil { await server.isWaiting }
        #expect(connection.selectedProjectDirectory == "/workspace/New")
        await server.move(to: "/workspace/Third")
        chat.synchronizeCurrentSessionFromServer()
        if oldRefresh != nil { try await waitUntil { chat.isStreamSynchronized } }
        await server.release()
        if let oldRefresh { #expect(await oldRefresh.value == false) }
        try await waitUntil { chat.isStreamSynchronized }
        #expect(chat.currentSession?.directory == "/workspace/Third")
        #expect(connection.selectedProjectDirectory == "/workspace/Third")
        #expect(chat.messages.first?.content == "Preserve this conversation")
    }

    @Test(arguments: ["refresh", "open"], [false, true])
    func anOldCanonicalReadCannotMoveTheReboundChatBack(path: String, failingResponse: Bool) async throws {
        let server = LocationServer()
        let (chat, connection, _) = try await makeChat(server)
        await chat.loadSession(session())
        await server.hold("/api/session/ses_move", directory: "/workspace/Old", fails: failingResponse)
        let oldRead = Task {
            if path == "open" { await chat.loadSession(session()); return false }
            return await chat.refreshCurrentSessionFromServer()
        }
        try await waitUntil { await server.isWaiting }
        await server.move(to: "/workspace/New")
        chat.synchronizeCurrentSessionFromServer()
        try await waitUntil { chat.isStreamSynchronized }
        await server.release()
        #expect(await oldRead.value == false)
        #expect(chat.currentSession?.directory == "/workspace/New")
        #expect(connection.selectedProjectDirectory == "/workspace/New")
        #expect(chat.messages.first?.content == "Preserve this conversation")
        #expect(chat.errorMessage == nil)
    }

    @Test(arguments: ["relative/location", "", "/missing-location"])
    func malformedDestinationsNeverBecomeTheActiveWorkspace(directory: String) async throws {
        let server = LocationServer()
        let (chat, connection, api) = try await makeChat(server)
        await chat.loadSession(session())
        await server.move(to: directory)
        chat.synchronizeCurrentSessionFromServer()
        try await waitUntil { chat.sessionLocationError != nil }
        #expect(!chat.canCompose)
        #expect(connection.selectedProjectDirectory == "/workspace/Old")
        #expect(await api.currentContextDirectory() == "/workspace/Old")
    }

    @Test func aSecondMoveSupersedesLocationAuthorizationStillInFlight() async throws {
        let server = LocationServer()
        let (chat, connection, _) = try await makeChat(server)
        await chat.loadSession(session())
        await server.hold("/api/location", directory: "/workspace/New")
        await server.move(to: "/workspace/New")
        chat.synchronizeCurrentSessionFromServer()
        try await waitUntil { await server.isWaiting }
        #expect(!chat.canCompose)
        #expect(chat.sessionDirectory == nil)
        await server.move(to: "/workspace/Third")
        chat.synchronizeCurrentSessionFromServer()
        await server.release()
        try await waitUntil { chat.isStreamSynchronized }
        #expect(chat.currentSession?.directory == "/workspace/Third")
        #expect(connection.selectedProjectDirectory == "/workspace/Third")
        #expect(connection.projectName == "Third")
        #expect(await server.ordinaryWorkspaceDirectories.contains("/workspace/New") == false)
    }

    @Test(arguments: ["refresh", "status", "event", "open"])
    func everyCanonicalRecoveryPathRebindsAndDropsOldRepositoryReferences(path: String) async throws {
        let server = LocationServer()
        let (chat, connection, _) = try await makeChat(server)
        await chat.loadSession(session())
        chat.inputText = "Keep my draft"
        chat.attachComposerServerFile(relativePath: "Old.swift")
        chat.attachComposerTextFile(data: Data("Local note".utf8), name: "note.txt")
        #expect(chat.composerAttachments.count == 2)
        await server.move(to: "/workspace/New")
        switch path {
        case "open": await chat.loadSession(session())
        case "refresh": #expect(await chat.refreshCurrentSessionFromServer())
        case "status":
            chat.beginExternalResponse()
            #expect(await chat.refreshCurrentSessionStatus())
        default:
            let event = OCEvent(type: "session.updated", properties: AnyCodable([
                "info": ["id": "ses_move", "directory": "/workspace/New"]
            ]))
            chat.receiveStreamEvent(try #require(SSEInboundEvent.prepare(event)))
            try await waitUntil { chat.isStreamSynchronized }
        }
        #expect(connection.selectedProjectDirectory == "/workspace/New")
        #expect(chat.inputText == "Keep my draft")
        #expect(chat.composerAttachments.count == 1)
        #expect(chat.composerAttachments.first?.promptFile.name == "note.txt")
    }

    @Test func delayedOldFilesCannotProduceAnApplicableWorkspaceSnapshot() async throws {
        let server = LocationServer()
        let (chat, connection, _) = try await makeChat(server)
        await chat.loadSession(session())
        let workspace = WorkspaceService(connection: connection)
        await server.hold("/api/fs/list", directory: "/workspace/Old")
        let oldFiles = Task { try await workspace.loadWorkspace() }
        try await waitUntil { await server.isWaiting }
        await server.move(to: "/workspace/New")
        chat.synchronizeCurrentSessionFromServer()
        try await waitUntil { chat.isStreamSynchronized }
        await server.release()
        await #expect(throws: CancellationError.self) { _ = try await oldFiles.value }
        let rebound = try await workspace.loadWorkspace()
        #expect(rebound.pathInfo?.directory == "/workspace/New")
        #expect(rebound.fileItems.map(\.name) == ["New.swift"])
    }

    @Test func delayedOldModelCatalogCannotReplaceTheNewLocationsModels() async throws {
        let server = LocationServer()
        let (chat, _, _) = try await makeChat(server)
        await chat.loadSession(session())
        await server.hold("/api/model", directory: "/workspace/Old")
        let oldCatalog = Task { await chat.loadProviders() }
        try await waitUntil { await server.isWaiting }
        await server.move(to: "/workspace/New")
        chat.synchronizeCurrentSessionFromServer()
        try await waitUntil { chat.isStreamSynchronized }
        await server.release()
        await oldCatalog.value
        #expect(chat.availableModels.map(\.modelID) == ["New-model"])
    }

    @Test func delayedOldProjectMetadataCannotOverwriteTheReboundWorkspace() async throws {
        let server = LocationServer()
        let (chat, connection, api) = try await makeChat(server)
        await chat.loadSession(session())
        await server.hold("/api/location", directory: "/workspace/Old")
        let oldRefresh = Task { await connection.setProjectContext(directory: "/workspace/Old") }
        try await waitUntil { await server.isWaiting }
        await server.move(to: "/workspace/New")
        chat.synchronizeCurrentSessionFromServer()
        try await waitUntil { chat.isStreamSynchronized }
        await server.release()
        await oldRefresh.value

        #expect(await api.currentContextDirectory() == "/workspace/New")
        #expect(connection.selectedProjectDirectory == "/workspace/New")
        #expect(connection.projectName == "New")
        #expect(connection.branch == "New")
    }

    @Test(arguments: [403, 503], ["sync", "refresh", "status", "open"])
    func refusedMoveStaysExplicitAndNeverSendsWorkUntilRecovery(status: Int, recovery: String) async throws {
        let server = LocationServer()
        let (chat, connection, api) = try await makeChat(server)
        await chat.loadSession(session())
        await server.refuseNewLocation(status)
        await server.move(to: "/workspace/New")
        switch recovery {
        case "open": await chat.loadSession(session())
        case "refresh": #expect(await chat.refreshCurrentSessionFromServer() == false)
        case "status":
            chat.beginExternalResponse()
            #expect(await chat.refreshCurrentSessionStatus() == false)
        default: chat.synchronizeCurrentSessionFromServer()
        }
        try await waitUntil { chat.errorMessage != nil }
        #expect(chat.messages.first?.content == "Preserve this conversation")

        #expect(!chat.isStreamSynchronized)
        #expect(connection.selectedProjectDirectory == "/workspace/Old")
        #expect(await api.currentContextDirectory() == "/workspace/Old")
        #expect(!chat.canCompose)
        #expect(chat.sessionDirectory == nil)
        chat.inputText = "Do not lose this draft"
        chat.send()
        let queued = QueuedPrompt(messageID: "msg_pending", text: "Pending work", state: .queued)
        chat.queuedPrompts = [queued]
        #expect(!chat.canSteerQueuedPrompt(queued))
        await chat.steerQueuedPrompt(queued)
        chat.pendingPermission = OCPermissionRequest(id: "per_move", sessionID: "ses_move", action: "shell")
        #expect(await chat.respondToPermission(requestID: "per_move", reply: .once) == false)
        try await Task.sleep(for: .milliseconds(30))
        #expect(chat.inputText == "Do not lose this draft")
        #expect(await server.mutations.isEmpty)

        await server.refuseNewLocation(nil)
        chat.synchronizeCurrentSessionFromServer()
        try await waitUntil { chat.isStreamSynchronized }
        #expect(chat.canCompose)
        #expect(chat.errorMessage == nil)
        #expect(connection.selectedProjectDirectory == "/workspace/New")
    }

    @Test(arguments: ["/workspace/Old", "/workspace/New"])
    func moveEventsFromEitherLocationRecoverOnlyTheOpenSession(eventDirectory: String) async throws {
        let server = LocationServer()
        let (chat, connection, _) = try await makeChat(server)
        await chat.loadSession(session())
        await server.move(to: "/workspace/New")
        var adapter = V2EventAdapter()
        let envelope: [String: Any] = [
            "type": "session.moved", "location": ["directory": eventDirectory],
            "data": ["sessionID": "ses_move", "location": ["directory": "/workspace/New"]]
        ]
        let event = try #require(try adapter.event(envelope, directory: "/workspace/Old"))
        chat.receiveStreamEvent(.raw(event))
        try await waitUntil { chat.isStreamSynchronized }
        #expect(connection.selectedProjectDirectory == "/workspace/New")

        // Once rebound, ordinary content from the old workspace is filtered.
        #expect(try adapter.event([
            "type": "session.execution.started", "location": ["directory": "/workspace/Old"],
            "data": ["sessionID": "ses_move"]
        ], directory: "/workspace/New") == nil)
        let unrelated = try #require(try adapter.event([
            "type": "session.moved", "location": ["directory": "/workspace/Third"],
            "data": ["sessionID": "ses_other"]
        ], directory: "/workspace/New"))
        chat.receiveStreamEvent(.raw(unrelated))
        #expect(chat.isStreamSynchronized)
        #expect(connection.selectedProjectDirectory == "/workspace/New")
    }

    @Test func externalMoveRebindsTheOpenChatAndItsWorkspace() async throws {
        let server = LocationServer()
        let (chat, connection, api) = try await makeChat(server)
        await chat.loadSession(session())
        #expect(connection.selectedProjectDirectory == "/workspace/Old")
        #expect(chat.messages.first?.content == "Preserve this conversation")
        await server.clearWorkspaceReads()

        // A second client moves the same session; foreground recovery must
        // follow canonical state even if the move event was missed.
        await server.move(to: "/workspace/New")
        chat.synchronizeCurrentSessionFromServer()
        try await waitUntil { chat.isStreamSynchronized }

        #expect(chat.currentSession?.id == "ses_move")
        #expect(chat.currentSession?.directory == "/workspace/New")
        #expect(chat.messages.first?.content == "Preserve this conversation")
        #expect(connection.selectedProjectDirectory == "/workspace/New")
        #expect(await api.currentContextDirectory() == "/workspace/New")
        #expect(connection.projectName == "New")
        #expect(connection.branch == "New")
        #expect(chat.availableModels.contains { $0.modelID == "New-model" })
        let workspace = WorkspaceService(connection: connection)
        #expect(await workspace.loadSlashActions().map(\.token).contains("New-command"))
        #expect(await workspace.loadSlashActions().map(\.token).contains("New-agent"))
        #expect(await workspace.loadSkills().map(\.id) == ["New-skill"])
        #expect(try await workspace.loadRepositoryEntries(at: "", in: chat.sessionDirectory!).map(\.name) == ["New.swift"])
        #expect(Set(await server.ordinaryWorkspaceDirectories) == ["/workspace/New"])
        chat.inputText = "Continue after the move"
        chat.send()
        try await waitUntil {
            if case .accepted = chat.promptSubmissions.last?.state { return true }
            return false
        }
        let prompt = try #require(await server.promptRequests.first)
        #expect(prompt.url?.path == "/api/session/ses_move/prompt")
        #expect(prompt.url?.query == nil) // V2 session work is routed by ID, not by location.
        let promptBody = try #require(prompt.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: promptBody) as? [String: Any])
        #expect(body["text"] as? String == "Continue after the move")
    }

    private func session() -> OCSession {
        OCSession(id: "ses_move", directory: "/workspace/Old", title: "Moved chat", time: .init(created: 0, updated: 0))
    }

    private func makeChat(_ server: LocationServer, stream: SSEClient? = nil,
                          activity: any LiveActivityProviding = TestLiveActivityProvider()) async throws -> (ChatClient, ConnectionManager, OpenCodeClient) {
        let api = OpenCodeClient(baseURL: URL(string: "https://example.com")!, contextDirectory: "/workspace/Old", transport: server)
        let connection = ConnectionManager(testClient: api, capabilities: try await api.probeCapabilities(), testSSEClient: stream)
        let chat = ChatClient(
            connection: connection, liveActivity: activity,
            sessionsService: SessionsService(connection: connection), messagesService: MessagesService(connection: connection),
            providersService: ProvidersService(connection: connection), questionService: QuestionService(connection: connection),
            savedConnectionsStore: SavedConnectionsStore(initialConnections: []), recordedReplayStore: RecordedReplayStore()
        )
        return (chat, connection, api)
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for location recovery")
    }
}

private actor LocationServer: OpenCodeTransport {
    private struct PromptIdentity: Decodable { let id: String }
    var directory = "/workspace/Old"
    var refusal: Int?
    var canonicalReadsFail = false
    var sessionActive = false
    func setSessionActive(_ active: Bool) { sessionActive = active }
    func failCanonicalReads(_ fail: Bool) { canonicalReadsFail = fail }
    var mutations: [String] = []
    var ordinaryWorkspaceDirectories: [String] = []
    var promptRequests: [URLRequest] = []
    func clearWorkspaceReads() { ordinaryWorkspaceDirectories = [] }
    var heldRequest: (path: String, directory: String, fails: Bool, skip: Int)?
    var waiter: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { waiter != nil }
    func hold(_ path: String, directory: String, fails: Bool = false, skip: Int = 0) { heldRequest = (path, directory, fails, skip) }
    func release() { waiter?.resume(); waiter = nil }
    func refuseNewLocation(_ status: Int?) { refusal = status }
    func move(to directory: String) { self.directory = directory }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url!
        let selected = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "location[directory]" }?.value ?? "/workspace/Old"
        let name = (selected as NSString).lastPathComponent
        let location = #"{"directory":"\#(selected)","project":{"id":"\#(name)","directory":"\#(selected)"}}"#
        if url.path == "/api/session/ses_move", canonicalReadsFail {
            return (Data(), HTTPURLResponse(url: url, statusCode: 503, httpVersion: nil, headerFields: nil)!)
        }
        if ["POST", "PATCH", "DELETE"].contains(request.httpMethod ?? "") { mutations.append(url.path) }
        if ["/api/model", "/api/vcs", "/api/command", "/api/skill", "/api/fs/list"].contains(url.path) {
            ordinaryWorkspaceDirectories.append(selected)
        }
        if url.path == "/api/location", selected == "/workspace/New", let refusal {
            return (Data(), HTTPURLResponse(url: url, statusCode: refusal, httpVersion: nil, headerFields: nil)!)
        }
        let body: String
        switch url.path {
        case "/api/info": body = #"{"version":"2.0.23"}"#
        case "/api/session/ses_move":
            let canonicalLocation = directory == "/missing-location" ? "null" : #"{"directory":"\#(directory)"}"#
            body = #"{"data":{"id":"ses_move","title":"Moved chat","location":\#(canonicalLocation),"time":{"created":0,"updated":0}}}"#
        case "/api/location": body = location
        case "/api/vcs": body = #"{"location":\#(location),"data":{"branch":"\#(name)"}}"#
        case "/api/model", "/api/model/default":
            let model = #"{"id":"\#(name)-model","providerID":"provider","modelID":"\#(name)-model","name":"\#(name) model"}"#
            body = #"{"location":\#(location),"data":\#(url.path.hasSuffix("default") ? model : "[" + model + "]")}"#
        case "/api/provider": body = #"{"location":\#(location),"data":[]}"#
        case "/api/command": body = #"{"location":\#(location),"data":[{"id":"\#(name)-command","name":"/\#(name)-command"}]}"#
        case "/api/agent": body = #"{"location":\#(location),"data":[{"name":"\#(name)-agent"}]}"#
        case "/api/skill": body = #"{"location":\#(location),"data":[{"id":"\#(name)-skill","name":"\#(name) skill"}]}"#
        case "/api/fs/list": body = #"{"location":\#(location),"data":[{"path":"\#(name).swift","type":"file"}]}"#
        case "/api/session/active": body = sessionActive ? #"{"data":{"ses_move":{"type":"running"}}}"# : #"{"data":{}}"#
        case "/api/session/ses_move/model": body = ""
        case "/api/session/ses_move/message": body = #"{"data":[{"id":"msg_existing","type":"user","time":{"created":1},"text":"Preserve this conversation"}],"cursor":{"next":null}}"#
        case "/api/session/ses_move/prompt":
            let input = try JSONDecoder().decode(PromptIdentity.self, from: #require(request.httpBody))
            promptRequests.append(request)
            body = #"{"data":{"id":"\#(input.id)","sessionID":"ses_move"}}"#
        case "/api/session/ses_move/inbox", "/api/session/ses_move/permission", "/api/session/ses_move/form": body = #"{"data":[]}"#
        default: throw URLError(.unsupportedURL)
        }
        if heldRequest?.path == url.path, heldRequest?.directory == selected {
            if let skip = heldRequest?.skip, skip > 0 {
                heldRequest?.skip = skip - 1
                return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            let fails = heldRequest?.fails == true
            heldRequest = nil
            await withCheckedContinuation { waiter = $0 }
            if fails { throw URLError(.networkConnectionLost) }
        }
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    nonisolated func makeEventStream(request: URLRequest, deliveryQueue: DispatchQueue, callbacks: OpenCodeEventStreamCallbacks) -> any OpenCodeEventStream {
        LocationUnusedStream()
    }
}

private final class LocationUnusedStream: OpenCodeEventStream, @unchecked Sendable {
    func start() {}; func suspend() {}; func resume() {}; func cancel() {}
}

private final class LocationActivityProvider: LiveActivityProviding {
    private var startedSessionIDs: Set<String> = []
    func isActive(sessionID: String?) -> Bool { startedSessionIDs.contains(sessionID ?? "") }
    var phases: [OpenLensActivityAttributes.Phase] = []
    var dismissCount = 0
    func startActivity(sessionID: String?, directory: String?, title: String?) { startedSessionIDs.insert(sessionID ?? "") }
    func update(sessionID: String?, pendingUserResponse: OpenLensActivityAttributes.PendingUserResponse?) {}
    func endActivity(sessionID: String?, phase: OpenLensActivityAttributes.Phase) { phases.append(phase) }
    func dismissImmediately(sessionID: String?) { dismissCount += 1 }
    func dismissAll() {}
    func previewLiveActivity() {}
}

nonisolated private final class LocationStreamingTransport: OpenCodeTransport, @unchecked Sendable {
    private let server: LocationServer
    private let lock = NSLock()
    private var streams: [LocationEventStream] = []

    init(server: LocationServer) { self.server = server }
    var streamCount: Int { lock.withLock { streams.count } }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await server.data(for: request)
    }

    func makeEventStream(request: URLRequest, deliveryQueue: DispatchQueue,
                         callbacks: OpenCodeEventStreamCallbacks) -> any OpenCodeEventStream {
        let stream = LocationEventStream(request: request, queue: deliveryQueue, callbacks: callbacks)
        lock.withLock { streams.append(stream) }
        return stream
    }

    func send(type: String, directory: String, data: [String: Any]) throws {
        let envelope: [String: Any] = ["type": type, "location": ["directory": directory], "data": data]
        var bytes = Data("event: message\ndata: ".utf8)
        bytes.append(try JSONSerialization.data(withJSONObject: envelope))
        bytes.append(Data("\n\n".utf8))
        lock.withLock { streams.last }?.send(bytes)
    }
}

nonisolated private final class LocationEventStream: OpenCodeEventStream, @unchecked Sendable {
    private let request: URLRequest
    private let queue: DispatchQueue
    private let callbacks: OpenCodeEventStreamCallbacks

    init(request: URLRequest, queue: DispatchQueue, callbacks: OpenCodeEventStreamCallbacks) {
        self.request = request
        self.queue = queue
        self.callbacks = callbacks
    }
    func start() {
        queue.async { [self] in
            _ = callbacks.onResponse(HTTPURLResponse(url: request.url!, statusCode: 200,
                                                     httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!)
        }
    }
    func send(_ data: Data) { queue.async { [self] in callbacks.onData(data) } }
    func suspend() {}
    func resume() {}
    func cancel() {}
}
