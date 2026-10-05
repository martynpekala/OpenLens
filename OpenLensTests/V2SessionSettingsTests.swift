import Foundation
import Testing
@testable import OpenLens

/// A v2 session owns its model, reasoning variant, and agent. These tests drive
/// ChatClient against a stateful fake server to show that the phone follows the
/// server's canonical selection and only changes it on explicit request.
@MainActor
struct V2SessionSettingsTests {
    private static let claude = OCV2ModelRef(id: "claude-a", providerID: "anthropic", variant: "high")
    private static let gpt = OCV2ModelRef(id: "gpt-x", providerID: "openai", variant: nil)

    // MARK: - Opening

    @Test func openingAnEmptySessionRestoresTheCanonicalSelectionOverSavedDefaults() async throws {
        let server = SettingsFakeServer()
        await server.addSession("ses_1", model: Self.claude, agent: "plan")
        let store = Self.store(savedSelection: Self.gpt, savedDefault: Self.gpt)
        let chat = try await Self.makeChat(server: server, store: store)

        await chat.loadSession(Self.listedSession("ses_1"))

        #expect(chat.selectedProviderID == "anthropic")
        #expect(chat.selectedModelID == "claude-a")
        #expect(chat.selectedVariant == "high")
        #expect(chat.currentSession?.agent == "plan")
        #expect(await server.switchRequests.isEmpty)
    }

    @Test func openingIgnoresTheModelOfOlderHistoricalReplies() async throws {
        let server = SettingsFakeServer()
        await server.addSession("ses_1", model: Self.claude, agent: "build")
        await server.setMessages("ses_1", json: #"""
        [{"id":"msg_1","type":"assistant","time":{"created":1},"agent":"build","model":{"id":"gpt-x","providerID":"openai"},"content":[{"type":"text","text":"Earlier"}],"finish":"stop"}]
        """#)
        let chat = try await Self.makeChat(server: server)

        await chat.loadSession(Self.listedSession("ses_1"))

        #expect(chat.selectedModelID == "claude-a")
        #expect(chat.selectedVariant == "high")
    }

    @Test func openingUsesAFreshSnapshotRatherThanTheListedSession() async throws {
        let server = SettingsFakeServer()
        await server.addSession("ses_1", model: Self.gpt, agent: "plan")
        let chat = try await Self.makeChat(server: server)

        // The list was loaded before another client switched to GPT.
        await chat.loadSession(Self.listedSession("ses_1", model: Self.claude, agent: "build"))

        #expect(chat.selectedModelID == "gpt-x")
        #expect(chat.selectedVariant == nil)
        #expect(chat.currentSession?.agent == "plan")
    }

    @Test func aCanonicalModelMissingFromTheCatalogStaysDisplayed() async throws {
        let server = SettingsFakeServer()
        let retired = OCV2ModelRef(id: "retired", providerID: "anthropic", variant: nil)
        await server.addSession("ses_1", model: retired, agent: nil)
        let chat = try await Self.makeChat(server: server, store: Self.store(savedSelection: Self.gpt, savedDefault: Self.gpt))

        await chat.loadSession(Self.listedSession("ses_1"))

        #expect(chat.selectedProviderID == "anthropic")
        #expect(chat.selectedModelID == "retired")
        #expect(chat.selectedModel == nil)
    }

    @Test func aSessionWithoutAModelShowsTheServerDefault() async throws {
        let server = SettingsFakeServer()
        await server.addSession("ses_1", model: nil, agent: nil)
        let chat = try await Self.makeChat(server: server, store: Self.store(savedSelection: Self.gpt, savedDefault: Self.gpt))

        await chat.loadSession(Self.listedSession("ses_1"))

        #expect(chat.selectedProviderID == "anthropic")
        #expect(chat.selectedModelID == "claude-a")
        #expect(chat.selectedVariant == nil)
    }

    // MARK: - Ordinary prompts

    @Test func externalSwitchFollowedByAnOrdinaryPhonePromptKeepsTheExternalSettings() async throws {
        let server = SettingsFakeServer()
        await server.addSession("ses_1", model: Self.claude, agent: "build")
        let chat = try await Self.makeChat(server: server)
        await chat.loadSession(Self.listedSession("ses_1"))

        // Another client switches the session while the phone has it open.
        await server.externallySwitch("ses_1", model: Self.gpt, agent: "plan")
        chat.synchronizeCurrentSessionFromServer()
        try await Self.waitUntil { chat.selectedModelID == "gpt-x" && chat.isStreamSynchronized }
        #expect(chat.selectedVariant == nil)
        #expect(chat.currentSession?.agent == "plan")

        chat.inputText = "Continue"
        chat.send()
        try await Self.waitUntil { await server.promptRequests.count == 1 }

        #expect(await server.switchRequests.isEmpty)
        #expect(await server.session("ses_1")?.model == Self.gpt)
        #expect(await server.session("ses_1")?.agent == "plan")
        let prompt = try #require(await server.promptRequests.first)
        #expect(prompt.json["model"] == nil)
        #expect(prompt.json["agent"] == nil)
        #expect(prompt.json["text"] as? String == "Continue")
    }

    @Test func switchEventsFromAnotherClientUpdateTheOpenSession() async throws {
        let server = SettingsFakeServer()
        await server.addSession("ses_1", model: Self.claude, agent: "build")
        let chat = try await Self.makeChat(server: server)
        await chat.loadSession(Self.listedSession("ses_1"))

        let urlSession = URLSession(configuration: .ephemeral)
        let task = urlSession.dataTask(with: URL(string: "http://127.0.0.1:1")!)
        let stream = SSEClient(baseURL: URL(string: "http://127.0.0.1:1")!, protocolVersion: .v2, contextDirectory: nil)
        stream.installActiveConnectionForTesting(session: urlSession, task: task)
        let handler = SSEEventHandler(
            haptics: HapticController(),
            liveActivityTracker: LiveActivityTracker(liveActivity: LiveActivityManager())
        )
        handler.delegate = chat
        stream.onInboundEvent = { handler.handleInboundEvent($0) }
        let frames: [(String, [String: Any])] = [
            ("session.model.selected", ["sessionID": "ses_1", "model": ["id": "gpt-x", "providerID": "openai"]]),
            ("session.agent.selected", ["sessionID": "ses_1", "agent": "plan"]),
        ]
        for (type, payload) in frames {
            let object: [String: Any] = ["id": "evt_\(type)", "created": 1, "type": type, "data": payload, "location": ["directory": "/workspace"]]
            var frame = Data("event: message\ndata: ".utf8)
            frame.append(try JSONSerialization.data(withJSONObject: object))
            frame.append(Data("\n\n".utf8))
            stream.receiveDataForTesting(session: urlSession, task: task, data: frame)
        }
        try await Self.waitUntil { chat.currentSession?.agent == "plan" }

        #expect(chat.selectedModelID == "gpt-x")
        #expect(chat.selectedVariant == nil)
        #expect(chat.currentSession?.agent == "plan")
        #expect(chat.currentSession?.title == "Session ses_1")
    }

    // MARK: - Explicit changes

    @Test func anExplicitModelChangeIsAppliedBeforeTheDependentPrompt() async throws {
        let server = SettingsFakeServer()
        await server.addSession("ses_1", model: Self.claude, agent: "build")
        let chat = try await Self.makeChat(server: server)
        await chat.loadSession(Self.listedSession("ses_1"))

        let gpt = try #require(chat.availableModels.first { $0.modelID == "gpt-x" })
        chat.selectModel(gpt)
        chat.inputText = "Use GPT"
        chat.send()
        try await Self.waitUntil { await server.promptRequests.count == 1 }

        let paths = await server.mutationPaths
        #expect(paths == ["/api/session/ses_1/model", "/api/session/ses_1/prompt"])
        let model = try #require(await server.switchRequests.first?.json["model"] as? [String: Any])
        #expect(model["id"] as? String == "gpt-x")
        #expect(model["providerID"] as? String == "openai")
        #expect(await server.session("ses_1")?.model == Self.gpt)
        #expect(chat.currentSession?.model == Self.gpt)
    }

    @Test func aSlashAgentPromptSwitchesTheAgentBeforeAdmission() async throws {
        let server = SettingsFakeServer()
        await server.addSession("ses_1", model: Self.claude, agent: "build")
        let chat = try await Self.makeChat(server: server)
        await chat.loadSession(Self.listedSession("ses_1"))
        chat.updateSlashCatalog(commands: [], agents: ["plan"])

        chat.inputText = "/plan Outline it"
        chat.send()
        try await Self.waitUntil { await server.promptRequests.count == 1 }

        #expect(await server.mutationPaths == ["/api/session/ses_1/agent", "/api/session/ses_1/prompt"])
        #expect(await server.session("ses_1")?.agent == "plan")
        #expect(await server.session("ses_1")?.model == Self.claude)
        #expect(chat.currentSession?.agent == "plan")
    }

    @Test func aFailedChangeKeepsItsPromptOutAndRestoresTheCanonicalSelection() async throws {
        let server = SettingsFakeServer()
        await server.addSession("ses_1", model: Self.claude, agent: "build")
        let chat = try await Self.makeChat(server: server)
        await chat.loadSession(Self.listedSession("ses_1"))
        await server.holdModelSwitches()

        let gpt = try #require(chat.availableModels.first { $0.modelID == "gpt-x" })
        chat.selectModel(gpt)
        #expect(chat.selectedModelID == "gpt-x")
        chat.inputText = "Use GPT"
        chat.send()
        try await Self.waitUntil { await server.isHoldingModelSwitch }
        await server.releaseModelSwitch(failing: true)

        try await Self.waitUntil { chat.selectedModelID == "claude-a" && !chat.isLoading }
        #expect(chat.selectedVariant == "high")
        #expect(chat.errorMessage?.hasPrefix("Failed to send") == true)
        #expect(await server.promptRequests.isEmpty)
        #expect(await server.session("ses_1")?.model == Self.claude)
    }

    @Test func aChangeThatSettlesAfterLeavingTheSessionCannotAdmitOrLeak() async throws {
        let server = SettingsFakeServer()
        await server.addSession("ses_1", model: Self.claude, agent: "build")
        await server.addSession("ses_2", model: Self.claude, agent: "review")
        let chat = try await Self.makeChat(server: server)
        await chat.loadSession(Self.listedSession("ses_1"))
        await server.holdModelSwitches()

        let gpt = try #require(chat.availableModels.first { $0.modelID == "gpt-x" })
        chat.selectModel(gpt)
        chat.inputText = "Use GPT"
        chat.send()
        try await Self.waitUntil { await server.isHoldingModelSwitch }

        await chat.loadSession(Self.listedSession("ses_2"))
        await server.releaseModelSwitch(failing: false)
        try await Task.sleep(for: .milliseconds(100))

        #expect(chat.currentSession?.id == "ses_2")
        #expect(chat.selectedModelID == "claude-a")
        #expect(chat.selectedVariant == "high")
        #expect(chat.currentSession?.agent == "review")
        #expect(await server.promptRequests.isEmpty)
    }

    @Test func choosingTheCurrentSelectionWithoutASessionSendsNoSwitch() async throws {
        let server = SettingsFakeServer()
        let chat = try await Self.makeChat(server: server)
        await chat.loadProviders()

        let gpt = try #require(chat.availableModels.first { $0.modelID == "gpt-x" })
        chat.selectModel(gpt)

        #expect(chat.selectedModelID == "gpt-x")
        #expect(await server.switchRequests.isEmpty)
    }

    // MARK: - New sessions

    @Test func newSessionsUseOnlyAvailableSavedPreferences() async throws {
        let server = SettingsFakeServer()
        let retired = OCV2ModelRef(id: "retired", providerID: "openai", variant: nil)

        let claudeDefault = OCV2ModelRef(id: "claude-a", providerID: "anthropic", variant: nil)
        let chosen = try await Self.makeChat(server: server, store: Self.store(savedSelection: Self.gpt, savedDefault: claudeDefault))
        #expect(await chosen.newSessionModelPreference() == Self.gpt)

        let defaulted = try await Self.makeChat(server: server, store: Self.store(savedSelection: retired, savedDefault: Self.gpt))
        #expect(await defaulted.newSessionModelPreference() == Self.gpt)

        let unavailable = try await Self.makeChat(server: server, store: Self.store(savedSelection: retired, savedDefault: retired))
        #expect(await unavailable.newSessionModelPreference() == nil)
    }

    @Test func aChoiceMadeWithoutASessionSeedsTheNextNewSession() async throws {
        let server = SettingsFakeServer()
        let chat = try await Self.makeChat(server: server, store: Self.store(savedSelection: nil, savedDefault: nil))
        await chat.loadProviders()

        let gpt = try #require(chat.availableModels.first { $0.modelID == "gpt-x" })
        chat.selectModel(gpt)
        chat.selectVariant("low")

        #expect(await chat.newSessionModelPreference() == OCV2ModelRef(id: "gpt-x", providerID: "openai", variant: "low"))
    }

    @Test func existingSessionChangesStayOutOfTheNewSessionPreference() async throws {
        let server = SettingsFakeServer()
        await server.addSession("ses_1", model: Self.claude, agent: "build")
        let store = Self.store(savedSelection: Self.claude, savedDefault: nil)
        let chat = try await Self.makeChat(server: server, store: store)
        await chat.loadSession(Self.listedSession("ses_1"))

        let gpt = try #require(chat.availableModels.first { $0.modelID == "gpt-x" })
        chat.selectModel(gpt)
        try await Self.waitUntil { await server.session("ses_1")?.model == Self.gpt }

        let connectionID = try #require(store.activeConnectionID)
        #expect(store.savedModelSelection(connectionID: connectionID)?.modelID == "claude-a")
        #expect(store.savedModelSelection(connectionID: connectionID)?.variant == "high")
        #expect(store.recentModelSelections(connectionID: connectionID).map(\.modelID).contains("gpt-x"))
        #expect(await chat.newSessionModelPreference() == Self.claude)
    }

    @Test func creatingASessionSendsTheNewSessionModel() async throws {
        let server = SettingsFakeServer()
        let api = OpenCodeClient(baseURL: URL(string: "https://example.com")!, transport: server)
        let connection = ConnectionManager(testClient: api, capabilities: try await api.probeCapabilities())
        let sessions = SessionsService(connection: connection)

        let created = try await sessions.createSession(title: "New", model: Self.gpt)
        let defaulted = try await sessions.createSession(title: "Default")

        let bodies = await server.createRequests.map(\.json)
        let model = try #require(bodies.first?["model"] as? [String: Any])
        #expect(model["id"] as? String == "gpt-x")
        #expect(model["providerID"] as? String == "openai")
        #expect(bodies.last?["model"] == nil)
        #expect(created.model == Self.gpt)
        #expect(defaulted.model == nil)
    }

    // MARK: - Helpers

    private static func makeChat(
        server: SettingsFakeServer,
        store: SavedConnectionsStore = SavedConnectionsStore(initialConnections: [])
    ) async throws -> ChatClient {
        let api = OpenCodeClient(baseURL: URL(string: "https://example.com")!, transport: server)
        let connection = ConnectionManager(testClient: api, capabilities: try await api.probeCapabilities())
        return ChatClient(
            connection: connection, liveActivity: LiveActivityManager(),
            sessionsService: SessionsService(connection: connection), messagesService: MessagesService(connection: connection),
            providersService: ProvidersService(connection: connection), questionService: QuestionService(connection: connection),
            savedConnectionsStore: store, recordedReplayStore: RecordedReplayStore()
        )
    }

    private static func store(savedSelection: OCV2ModelRef?, savedDefault: OCV2ModelRef?) -> SavedConnectionsStore {
        let store = SavedConnectionsStore(initialConnections: [])
        let connection = store.saveConnection(serverURL: "https://example.com", username: "", password: "")
        if let savedSelection {
            store.updateModelSelection(
                connectionID: connection.id,
                providerID: savedSelection.providerID,
                modelID: savedSelection.id,
                variant: savedSelection.variant
            )
        }
        if let savedDefault {
            store.updateDefaultModelSelection(
                connectionID: connection.id,
                providerID: savedDefault.providerID,
                modelID: savedDefault.id
            )
        }
        return store
    }

    private static func listedSession(_ id: String, model: OCV2ModelRef? = nil, agent: String? = nil) -> OCSession {
        OCSession(id: id, title: "Session \(id)", time: .init(created: 0, updated: 0), agent: agent, model: model)
    }

    private static func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for condition")
    }
}

// MARK: - Fake server

private actor SettingsFakeServer: OpenCodeTransport {
    struct Session: Sendable {
        var model: OCV2ModelRef?
        var agent: String?
        var messagesJSON = "[]"
    }

    struct Request: Sendable {
        let method: String
        let path: String
        let body: Data

        var json: [String: Any] {
            (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        }
    }

    private var sessions: [String: Session] = [:]
    private(set) var requests: [Request] = []
    private var holdsModelSwitches = false
    private var modelSwitchWaiter: CheckedContinuation<Bool, Never>?

    var isHoldingModelSwitch: Bool { modelSwitchWaiter != nil }
    var switchRequests: [Request] {
        requests.filter { $0.path.hasSuffix("/model") || $0.path.hasSuffix("/agent") }
    }
    var promptRequests: [Request] { requests.filter { $0.path.hasSuffix("/prompt") } }
    var createRequests: [Request] { requests.filter { $0.method == "POST" && $0.path == "/api/session" } }
    var mutationPaths: [String] { requests.filter { $0.method == "POST" }.map(\.path) }

    func session(_ id: String) -> Session? { sessions[id] }
    func addSession(_ id: String, model: OCV2ModelRef?, agent: String?) {
        sessions[id] = Session(model: model, agent: agent)
    }
    func setMessages(_ id: String, json: String) { sessions[id]?.messagesJSON = json }
    func externallySwitch(_ id: String, model: OCV2ModelRef, agent: String) {
        sessions[id]?.model = model
        sessions[id]?.agent = agent
    }
    func holdModelSwitches() { holdsModelSwitches = true }
    func releaseModelSwitch(failing: Bool) {
        modelSwitchWaiter?.resume(returning: !failing)
        modelSwitchWaiter = nil
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url!
        let method = request.httpMethod ?? "GET"
        let path = url.path
        let body = request.httpBody ?? Data()
        let recorded = Request(method: method, path: path, body: body)
        let components = path.split(separator: "/").map(String.init)

        func respond(_ status: Int, _ json: String = "") -> (Data, URLResponse) {
            (Data(json.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }

        if method == "POST" {
            requests.append(recorded)
            if path == "/api/session" {
                let input = recorded.json
                let id = input["id"] as? String ?? "ses_new"
                let model = (input["model"] as? [String: Any]).flatMap(Self.modelRef)
                sessions[id] = Session(model: model, agent: nil)
                return respond(200, #"{"data":\#(sessionJSON(id))}"#)
            }
            guard components.count == 4, components[1] == "session", let id = Optional(components[2]),
                  sessions[id] != nil else { return respond(404) }
            switch components[3] {
            case "model":
                if holdsModelSwitches {
                    let succeeds = await withCheckedContinuation { modelSwitchWaiter = $0 }
                    guard succeeds else { return respond(500, #"{"error":"switch failed"}"#) }
                }
                let model = (recorded.json["model"] as? [String: Any]).flatMap(Self.modelRef)
                sessions[id]?.model = model
                return respond(204)
            case "agent":
                sessions[id]?.agent = recorded.json["agent"] as? String
                return respond(204)
            case "prompt", "command":
                return respond(204)
            default:
                return respond(404)
            }
        }

        let location = #""location":{"directory":"/workspace","project":{"id":"p","directory":"/workspace"}}"#
        switch path {
        case "/api/info":
            return respond(200, #"{"version":"2.0.23"}"#)
        case "/api/model":
            return respond(200, #"""
            {\#(location),"data":[
              {"id":"claude-a","providerID":"anthropic","name":"Claude A","variants":[{"id":"high","reasoningEffort":"high"}]},
              {"id":"gpt-x","providerID":"openai","name":"GPT X","variants":[{"id":"low","reasoningEffort":"low"}]}
            ]}
            """#)
        case "/api/model/default":
            return respond(200, #"{\#(location),"data":{"id":"claude-a","providerID":"anthropic","name":"Claude A"}}"#)
        case "/api/provider":
            return respond(200, #"{\#(location),"data":[{"id":"anthropic","name":"Anthropic"},{"id":"openai","name":"OpenAI"}]}"#)
        case "/api/session/active":
            return respond(200, #"{"data":{}}"#)
        default:
            break
        }

        guard components.count >= 3, components[1] == "session", let session = sessions[components[2]] else {
            return respond(404)
        }
        let id = components[2]
        if components.count == 3 {
            return respond(200, #"{"data":\#(sessionJSON(id))}"#)
        }
        switch components[3] {
        case "message":
            return respond(200, #"{"data":\#(session.messagesJSON),"cursor":{"next":null}}"#)
        case "permission", "form":
            return respond(200, #"{"data":[]}"#)
        default:
            return respond(404)
        }
    }

    private func sessionJSON(_ id: String) -> String {
        let session = sessions[id]
        var info: [String: Any] = ["id": id, "title": "Session \(id)", "time": ["created": 0, "updated": 0]]
        if let agent = session?.agent { info["agent"] = agent }
        if let model = session?.model {
            var ref: [String: Any] = ["id": model.id, "providerID": model.providerID]
            if let variant = model.variant { ref["variant"] = variant }
            info["model"] = ref
        }
        let data = try! JSONSerialization.data(withJSONObject: info)
        return String(decoding: data, as: UTF8.self)
    }

    private static func modelRef(_ json: [String: Any]) -> OCV2ModelRef? {
        guard let id = json["id"] as? String, let providerID = json["providerID"] as? String else { return nil }
        return OCV2ModelRef(id: id, providerID: providerID, variant: json["variant"] as? String)
    }

    nonisolated func makeEventStream(
        request: URLRequest,
        deliveryQueue: DispatchQueue,
        callbacks: OpenCodeEventStreamCallbacks
    ) -> any OpenCodeEventStream {
        SettingsUnusedStream()
    }
}

private final class SettingsUnusedStream: OpenCodeEventStream, @unchecked Sendable {
    func start() {}
    func suspend() {}
    func resume() {}
    func cancel() {}
}
