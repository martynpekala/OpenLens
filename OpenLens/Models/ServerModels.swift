import Foundation

// MARK: - Session

/// Matches the server's `Session` type:
/// `{ id, projectID, directory, parentID?, title, version, time: { created, updated }, share?, summary?, revert? }`
struct OCSession: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let projectID: String?
    let directory: String?
    let parentID: String?
    let title: String
    let version: String?
    let time: OCSessionTime
    let share: OCShareInfo?

    /// Convenience: Unix timestamp (seconds) when last updated. Used for sorting.
    var updatedAt: Double { time.updated / 1000.0 }
    /// Convenience: Unix timestamp (seconds) when created.
    var createdAt: Double { time.created / 1000.0 }

    enum CodingKeys: String, CodingKey {
        case id, projectID, directory, parentID, title, version, time, share
    }

    init(
        id: String,
        projectID: String? = nil,
        directory: String? = nil,
        parentID: String? = nil,
        title: String,
        version: String? = nil,
        time: OCSessionTime,
        share: OCShareInfo? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.directory = directory
        self.parentID = parentID
        self.title = title
        self.version = version
        self.time = time
        self.share = share
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        projectID = try container.decodeIfPresent(String.self, forKey: .projectID)
        directory = try container.decodeIfPresent(String.self, forKey: .directory)
        parentID = try container.decodeIfPresent(String.self, forKey: .parentID)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        version = try container.decodeIfPresent(String.self, forKey: .version)
        time = try container.decodeIfPresent(OCSessionTime.self, forKey: .time) ?? OCSessionTime(created: 0, updated: 0)
        share = try container.decodeIfPresent(OCShareInfo.self, forKey: .share)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: OCSession, rhs: OCSession) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.time.updated == rhs.time.updated
    }
}

 struct OCSessionTime: Codable, Hashable, Sendable {
    let created: Double
    let updated: Double
    let compacting: Double?

    init(created: Double, updated: Double, compacting: Double? = nil) {
        self.created = created
        self.updated = updated
        self.compacting = compacting
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        created = try container.decodeIfPresent(Double.self, forKey: .created) ?? 0
        updated = try container.decodeIfPresent(Double.self, forKey: .updated) ?? 0
        compacting = try container.decodeIfPresent(Double.self, forKey: .compacting)
    }

    enum CodingKeys: String, CodingKey {
        case created, updated, compacting
    }
}

 struct OCShareInfo: Codable, Hashable, Sendable {
    let url: String?
}

// MARK: - Message

/// Server Message is a union of UserMessage | AssistantMessage.
/// Both share: id, sessionID, role, time: { created: number (milliseconds) }.
/// UserMessage adds: agent, model: { providerID, modelID }, system, tools, summary.
/// AssistantMessage adds: cost, tokens, error, modelID, providerID, mode, path, finish.
 struct OCMessage: Codable, Identifiable, Sendable {
    let id: String
    let sessionID: String
    let role: OCMessageRole
    let time: OCMessageTime?

    // Assistant-specific fields
    let cost: Double?
    let tokens: OCTokenUsage?
    let error: OCAPIError?
    let modelID: String?
    let providerID: String?
    let mode: String?
    let path: OCMessagePath?
    let finish: String?

    // User-specific fields (some shared with assistant, e.g. agent)
    let agent: String?
    let model: OCMessageModelRef?
    let system: String?
    let summary: OCMessageSummary?
    let parentID: String?

    /// Convenience for created timestamp (in seconds, converting from ms).
    var createdTimestamp: Double? {
        guard let ms = time?.created, ms > 0 else { return nil }
        return ms / 1000.0
    }

    /// Display-friendly model description for assistant messages.
    var modelDisplayName: String? {
        // Assistant messages have modelID/providerID at top level
        if let modelID, !modelID.isEmpty {
            if let providerID, !providerID.isEmpty {
                return "\(providerID)/\(modelID)"
            }
            return modelID
        }
        // User messages have model as nested object
        if let model {
            return "\(model.providerID)/\(model.modelID)"
        }
        return nil
    }

    enum CodingKeys: String, CodingKey {
        case id, sessionID, role, time, cost, tokens, error
        case modelID, providerID, mode, path, finish
        case agent, model, system, summary, parentID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID) ?? ""
        role = try container.decodeIfPresent(OCMessageRole.self, forKey: .role) ?? .assistant
        time = try container.decodeIfPresent(OCMessageTime.self, forKey: .time)
        cost = try container.decodeIfPresent(Double.self, forKey: .cost)
        tokens = try container.decodeIfPresent(OCTokenUsage.self, forKey: .tokens)
        error = try container.decodeIfPresent(OCAPIError.self, forKey: .error)
        modelID = try container.decodeIfPresent(String.self, forKey: .modelID)
        providerID = try container.decodeIfPresent(String.self, forKey: .providerID)
        mode = try container.decodeIfPresent(String.self, forKey: .mode)
        path = try? container.decodeIfPresent(OCMessagePath.self, forKey: .path)
        finish = try container.decodeIfPresent(String.self, forKey: .finish)
        agent = try container.decodeIfPresent(String.self, forKey: .agent)
        model = try? container.decodeIfPresent(OCMessageModelRef.self, forKey: .model)
        system = try container.decodeIfPresent(String.self, forKey: .system)
        summary = try? container.decodeIfPresent(OCMessageSummary.self, forKey: .summary)
        parentID = try container.decodeIfPresent(String.self, forKey: .parentID)
    }
}

/// The model reference embedded in user messages: `{ providerID, modelID }`.
 struct OCMessageModelRef: Codable, Sendable {
    let providerID: String
    let modelID: String
}

/// Summary attached to user messages: `{ title, diffs }`.
 struct OCMessageSummary: Codable, Sendable {
    let title: String?
    let diffs: [OCFileDiff]?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        diffs = try? container.decodeIfPresent([OCFileDiff].self, forKey: .diffs)
    }

    enum CodingKeys: String, CodingKey {
        case title, diffs
    }
}

/// Working directory path info on assistant messages: `{ cwd, root }`.
 struct OCMessagePath: Codable, Sendable {
    let cwd: String?
    let root: String?
}

 struct OCMessageTime: Codable, Sendable {
    /// Raw value from server — in **milliseconds** since epoch.
    let created: Double
    let completed: Double?

    /// Created timestamp in seconds (for Date conversion).
    var createdSeconds: Double { created / 1000.0 }
    /// Completed timestamp in seconds (for Date conversion).
    var completedSeconds: Double? {
        guard let completed else { return nil }
        return completed / 1000.0
    }

    init(created: Double, completed: Double? = nil) {
        self.created = created
        self.completed = completed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        created = try container.decodeIfPresent(Double.self, forKey: .created) ?? 0
        completed = try container.decodeIfPresent(Double.self, forKey: .completed)
    }

    enum CodingKeys: String, CodingKey {
        case created, completed
    }
}

 enum OCMessageRole: String, Codable, Sendable {
    case user
    case assistant
}

 struct OCTokenUsage: Codable, Sendable {
    let input: Int?
    let output: Int?
    let reasoning: Int?
    let cache: OCCacheTokens?

    /// Computed total for display.
    var total: Int? {
        let total = totalIncludingCache
        return total > 0 ? total : nil
    }

    var inputValue: Int { input ?? 0 }
    var outputValue: Int { output ?? 0 }
    var reasoningValue: Int { reasoning ?? 0 }
    var cacheReadValue: Int { cache?.read ?? 0 }
    var cacheWriteValue: Int { cache?.write ?? 0 }

    var totalIncludingCache: Int {
        inputValue + outputValue + reasoningValue + cacheReadValue + cacheWriteValue
    }
}

 struct OCCacheTokens: Codable, Sendable {
    let read: Int?
    let write: Int?
}

/// Server error is a union type with { name, data: { message, ... } }.
/// We decode flexibly to extract the message.
 struct OCAPIError: Codable, Sendable {
    let name: String?
    let data: OCAPIErrorData?

    var message: String? { data?.message }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        data = try container.decodeIfPresent(OCAPIErrorData.self, forKey: .data)
    }

    enum CodingKeys: String, CodingKey {
        case name, data
    }
}

 struct OCAPIErrorData: Codable, Sendable {
    let message: String?
}

// MARK: - Message Parts

 struct OCMessageWithParts: Codable, Identifiable, Sendable {
    let info: OCMessage
    let parts: [OCPart]

    var id: String { info.id }

    enum CodingKeys: String, CodingKey {
        case info, parts
    }

    init(info: OCMessage, parts: [OCPart]) {
        self.info = info
        self.parts = parts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        info = try container.decode(OCMessage.self, forKey: .info)
        // Decode parts defensively: skip individual parts that fail rather than losing the whole message.
        if var partsContainer = try? container.nestedUnkeyedContainer(forKey: .parts) {
            var decoded: [OCPart] = []
            while !partsContainer.isAtEnd {
                if let part = try? partsContainer.decode(OCPart.self) {
                    decoded.append(part)
                } else {
                    // Skip the bad element by decoding as throwaway AnyCodable
                    _ = try? partsContainer.decode(AnyCodable.self)
                }
            }
            parts = decoded
        } else {
            parts = []
        }
    }
}

 enum OCPartType: String, Codable, Sendable {
    case text
    case reasoning
    case tool
    case file
    case stepStart = "step-start"
    case stepFinish = "step-finish"
    case snapshot
    case patch
    case retry
    case compaction
    case agent
    case subtask
    case unknown

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = OCPartType(rawValue: raw) ?? .unknown
    }
}

 struct OCPart: Codable, Identifiable, Sendable {
    let id: String
    let sessionID: String
    let messageID: String
    let type: OCPartType

    let text: String?
    let synthetic: Bool?
    let ignored: Bool?
    let metadata: [String: AnyCodable]?
    let time: AnyCodable?

    let callID: String?
    let tool: String?
    let state: OCToolState?

    let mime: String?
    let filename: String?
    let url: String?
    let source: AnyCodable?
    let snapshot: AnyCodable?
    let hash: String?
    let files: [AnyCodable]?
    let name: String?

    let reason: String?
    let cost: Double?
    let tokens: OCTokenUsage?
    let prompt: String?
    let partDescription: String?
    let agent: AnyCodable?
    let attempt: Int?
    let retryError: String?
    let auto: Bool?

    enum CodingKeys: String, CodingKey {
        case id, sessionID, messageID, type, text, synthetic, ignored, metadata, time
        case callID, tool, state
        case mime, filename, url, source, snapshot, hash, files, name
        case reason, cost, tokens, prompt, agent, attempt, auto
        case partDescription = "description"
        case retryError = "error"
    }

    init(id: String, sessionID: String, messageID: String, type: OCPartType,
         text: String? = nil, synthetic: Bool? = nil, ignored: Bool? = nil,
         metadata: [String: AnyCodable]? = nil, time: AnyCodable? = nil,
         callID: String? = nil, tool: String? = nil, state: OCToolState? = nil,
         mime: String? = nil, filename: String? = nil, url: String? = nil,
         source: AnyCodable? = nil, snapshot: AnyCodable? = nil, hash: String? = nil,
         files: [AnyCodable]? = nil, name: String? = nil,
         reason: String? = nil, cost: Double? = nil, tokens: OCTokenUsage? = nil,
         prompt: String? = nil, partDescription: String? = nil, agent: AnyCodable? = nil,
         attempt: Int? = nil, retryError: String? = nil, auto: Bool? = nil) {
        self.id = id
        self.sessionID = sessionID
        self.messageID = messageID
        self.type = type
        self.text = text
        self.synthetic = synthetic
        self.ignored = ignored
        self.metadata = metadata
        self.time = time
        self.callID = callID
        self.tool = tool
        self.state = state
        self.mime = mime
        self.filename = filename
        self.url = url
        self.source = source
        self.snapshot = snapshot
        self.hash = hash
        self.files = files
        self.name = name
        self.reason = reason
        self.cost = cost
        self.tokens = tokens
        self.prompt = prompt
        self.partDescription = partDescription
        self.agent = agent
        self.attempt = attempt
        self.retryError = retryError
        self.auto = auto
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID) ?? ""
        messageID = try container.decodeIfPresent(String.self, forKey: .messageID) ?? ""
        type = try container.decodeIfPresent(OCPartType.self, forKey: .type) ?? .unknown
        text = try container.decodeIfPresent(String.self, forKey: .text)
        synthetic = try container.decodeIfPresent(Bool.self, forKey: .synthetic)
        ignored = try container.decodeIfPresent(Bool.self, forKey: .ignored)
        metadata = try? container.decodeIfPresent([String: AnyCodable].self, forKey: .metadata)
        time = try? container.decodeIfPresent(AnyCodable.self, forKey: .time)
        callID = try container.decodeIfPresent(String.self, forKey: .callID)
        tool = try container.decodeIfPresent(String.self, forKey: .tool)
        state = try? container.decodeIfPresent(OCToolState.self, forKey: .state)
        mime = try container.decodeIfPresent(String.self, forKey: .mime)
        filename = try container.decodeIfPresent(String.self, forKey: .filename)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        source = try? container.decodeIfPresent(AnyCodable.self, forKey: .source)
        snapshot = try? container.decodeIfPresent(AnyCodable.self, forKey: .snapshot)
        hash = try container.decodeIfPresent(String.self, forKey: .hash)
        files = try? container.decodeIfPresent([AnyCodable].self, forKey: .files)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        cost = try container.decodeIfPresent(Double.self, forKey: .cost)
        tokens = try? container.decodeIfPresent(OCTokenUsage.self, forKey: .tokens)
        prompt = try container.decodeIfPresent(String.self, forKey: .prompt)
        partDescription = try container.decodeIfPresent(String.self, forKey: .partDescription)
        agent = try? container.decodeIfPresent(AnyCodable.self, forKey: .agent)
        attempt = try container.decodeIfPresent(Int.self, forKey: .attempt)
        retryError = try container.decodeIfPresent(String.self, forKey: .retryError)
        auto = try container.decodeIfPresent(Bool.self, forKey: .auto)
    }

    var isRenderableText: Bool {
        type == .text && synthetic != true && ignored != true
    }

    var renderableText: String? {
        guard isRenderableText else { return nil }
        return text
    }
}

 struct OCToolState: Codable, Sendable {
    let status: OCToolStatus
    let input: AnyCodable?
    let output: String?
    let title: String?
    let error: String?
    let metadata: [String: AnyCodable]?
    let time: OCToolTime?
    let attachments: [AnyCodable]?

    enum CodingKeys: String, CodingKey {
        case status, input, output, title, error, metadata, time, attachments
    }

    init(status: OCToolStatus, input: AnyCodable? = nil, output: String? = nil,
         title: String? = nil, error: String? = nil, metadata: [String: AnyCodable]? = nil,
         time: OCToolTime? = nil, attachments: [AnyCodable]? = nil) {
        self.status = status
        self.input = input
        self.output = output
        self.title = title
        self.error = error
        self.metadata = metadata
        self.time = time
        self.attachments = attachments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decodeIfPresent(OCToolStatus.self, forKey: .status) ?? .pending
        input = try? container.decodeIfPresent(AnyCodable.self, forKey: .input)
        // output can sometimes be a non-string value; fall back gracefully
        if let str = try? container.decodeIfPresent(String.self, forKey: .output) {
            output = str
        } else if let any = try? container.decodeIfPresent(AnyCodable.self, forKey: .output) {
            output = String(describing: any.value)
        } else {
            output = nil
        }
        title = try container.decodeIfPresent(String.self, forKey: .title)
        // error can sometimes be a non-string value
        if let str = try? container.decodeIfPresent(String.self, forKey: .error) {
            error = str
        } else if let any = try? container.decodeIfPresent(AnyCodable.self, forKey: .error) {
            error = String(describing: any.value)
        } else {
            error = nil
        }
        metadata = try? container.decodeIfPresent([String: AnyCodable].self, forKey: .metadata)
        time = try? container.decodeIfPresent(OCToolTime.self, forKey: .time)
        attachments = try? container.decodeIfPresent([AnyCodable].self, forKey: .attachments)
    }
}

 enum OCToolStatus: String, Codable, Sendable {
    case pending
    case running
    case completed
    case error
    case unknown

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = OCToolStatus(rawValue: raw) ?? .unknown
    }
}

 struct OCToolTime: Codable, Sendable {
    let start: Double?
    let end: Double?
}

// MARK: - SSE Events

 struct OCEvent: Codable, Sendable {
    let type: String
    let properties: AnyCodable?
 }

extension OCEvent {
    var sessionID: String? {
        guard let propertiesDictionary = propertiesDictionary else { return nil }

        switch type {
        case "session.status",
             "message.part.delta",
             "message.part.removed",
             "message.removed",
             "permission.asked",
             "permission.v2.asked",
             "permission.v2.replied",
             "question.asked",
             "question.replied",
             "question.rejected":
            return propertiesDictionary["sessionID"] as? String

        case "message.updated":
            return nestedDictionary(for: "info", in: propertiesDictionary)?["sessionID"] as? String

        case "message.part.updated":
            return nestedDictionary(for: "part", in: propertiesDictionary)?["sessionID"] as? String

        case "session.updated":
            return nestedDictionary(for: "info", in: propertiesDictionary)?["id"] as? String

        default:
            return nil
        }
    }

    var sessionStatusType: OCSessionStatusType? {
        guard type == "session.status",
              let statusDictionary = nestedDictionary(for: "status", in: propertiesDictionary),
              let rawType = statusDictionary["type"] as? String else {
            return nil
        }

        return OCSessionStatusType(rawValue: rawType)
    }

    var isReplayRecordable: Bool {
        switch type {
        case "server.connected", "server.heartbeat":
            return false
        default:
            return sessionID != nil
        }
    }

    private var propertiesDictionary: [String: Any]? {
        properties?.value as? [String: Any]
    }

    private func nestedDictionary(for key: String, in dictionary: [String: Any]?) -> [String: Any]? {
        dictionary?[key] as? [String: Any]
    }
}

// MARK: - Session Status

 enum OCSessionStatusType: String, Codable, Sendable {
    case idle
    case busy
    case retry
}

 struct OCSessionStatus: Codable, Sendable {
    let type: OCSessionStatusType
    let attempt: Int?
    let message: String?
    let next: Int?
}

// MARK: - Provider / Config

/// Matches the server's provider list item:
/// `{ id, name, env, models: { [key: string]: ProviderModel }, api?, npm? }`
 struct OCProvider: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let env: [String]?
    let models: [String: OCProviderModel]

    /// Convenience: array of all models in this provider.
    var modelList: [OCProviderModel] {
        Array(models.values)
    }

    init(id: String, name: String, env: [String]? = nil, models: [String: OCProviderModel] = [:]) {
        self.id = id
        self.name = name
        self.env = env
        self.models = models
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        env = try container.decodeIfPresent([String].self, forKey: .env)
        models = try container.decodeIfPresent([String: OCProviderModel].self, forKey: .models) ?? [:]
    }

    enum CodingKeys: String, CodingKey {
        case id, name, env, models
    }
}

/// Matches the provider list model shape:
/// `{ id, name, release_date, attachment, reasoning, temperature, tool_call, capabilities?, cost?, limit, status?, options, ... }`
/// We decode defensively — most fields are optional.
 struct OCProviderModel: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let releaseDate: String?
    let attachment: Bool?
    let reasoning: Bool?
    let temperature: Bool?
    let toolCall: Bool?
    let cost: OCModelCost?
    let limit: OCModelLimit?
    let status: String?
    let variants: [String: OCProviderVariant]?

    enum CodingKeys: String, CodingKey {
        case id, name
        case releaseDate = "release_date"
        case attachment, reasoning, temperature
        case toolCall = "tool_call"
        case capabilities
        case cost, limit, status, variants
    }

    init(id: String, name: String, releaseDate: String? = nil, attachment: Bool? = nil,
         reasoning: Bool? = nil, temperature: Bool? = nil, toolCall: Bool? = nil,
         cost: OCModelCost? = nil, limit: OCModelLimit? = nil, status: String? = nil,
         variants: [String: OCProviderVariant]? = nil) {
        self.id = id
        self.name = name
        self.releaseDate = releaseDate
        self.attachment = attachment
        self.reasoning = reasoning
        self.temperature = temperature
        self.toolCall = toolCall
        self.cost = cost
        self.limit = limit
        self.status = status
        self.variants = variants
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let capabilities = try container.decodeIfPresent(OCProviderModelCapabilities.self, forKey: .capabilities)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        releaseDate = try container.decodeIfPresent(String.self, forKey: .releaseDate)
        attachment = try container.decodeIfPresent(Bool.self, forKey: .attachment) ?? capabilities?.attachment
        reasoning = try container.decodeIfPresent(Bool.self, forKey: .reasoning) ?? capabilities?.reasoning
        temperature = try container.decodeIfPresent(Bool.self, forKey: .temperature) ?? capabilities?.temperature
        toolCall = try container.decodeIfPresent(Bool.self, forKey: .toolCall) ?? capabilities?.toolCall
        cost = try container.decodeIfPresent(OCModelCost.self, forKey: .cost)
        limit = try container.decodeIfPresent(OCModelLimit.self, forKey: .limit)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        variants = try container.decodeIfPresent([String: OCProviderVariant].self, forKey: .variants)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(releaseDate, forKey: .releaseDate)
        try container.encodeIfPresent(attachment, forKey: .attachment)
        try container.encodeIfPresent(reasoning, forKey: .reasoning)
        try container.encodeIfPresent(temperature, forKey: .temperature)
        try container.encodeIfPresent(toolCall, forKey: .toolCall)
        try container.encodeIfPresent(cost, forKey: .cost)
        try container.encodeIfPresent(limit, forKey: .limit)
        try container.encodeIfPresent(status, forKey: .status)
        try container.encodeIfPresent(variants, forKey: .variants)
    }
}

private struct OCProviderModelCapabilities: Decodable, Sendable {
    let attachment: Bool?
    let reasoning: Bool?
    let temperature: Bool?
    let toolCall: Bool?

    enum CodingKeys: String, CodingKey {
        case attachment, reasoning, temperature
        case toolCall = "toolcall"
        case toolCallSnake = "tool_call"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        attachment = try container.decodeIfPresent(Bool.self, forKey: .attachment)
        reasoning = try container.decodeIfPresent(Bool.self, forKey: .reasoning)
        temperature = try container.decodeIfPresent(Bool.self, forKey: .temperature)
        toolCall = try container.decodeIfPresent(Bool.self, forKey: .toolCall)
            ?? container.decodeIfPresent(Bool.self, forKey: .toolCallSnake)
    }
}

struct OCProviderVariant: Codable, Hashable, Sendable {
    let disabled: Bool?
    let reasoningEffort: String?
    let effort: String?
    let budgetTokens: Int?
    let maxReasoningEffort: String?
    let thinking: OCThinkingVariant?
    let thinkingConfig: OCThinkingVariant?
    let reasoning: OCReasoningVariant?
    let reasoningConfig: OCReasoningConfigVariant?

    enum CodingKeys: String, CodingKey {
        case disabled
        case reasoningEffort
        case effort
        case budgetTokens
        case maxReasoningEffort
        case thinking
        case thinkingConfig
        case reasoning
        case reasoningConfig
    }

    var isDisabled: Bool { disabled ?? false }

    var isThinkingEffortVariant: Bool {
        if isDisabled { return false }

        return reasoningEffort != nil ||
            effort != nil ||
            budgetTokens != nil ||
            maxReasoningEffort != nil ||
            thinking != nil ||
            thinkingConfig != nil ||
            reasoning != nil ||
            reasoningConfig != nil
    }
}

struct OCThinkingVariant: Codable, Hashable, Sendable {
    let type: String?
    let budgetTokens: Int?
    let includeThoughts: Bool?

    enum CodingKeys: String, CodingKey {
        case type
        case budgetTokens
        case includeThoughts
    }
}

struct OCReasoningVariant: Codable, Hashable, Sendable {
    let effort: String?
    let summary: String?
}

struct OCReasoningConfigVariant: Codable, Hashable, Sendable {
    let type: String?
    let maxReasoningEffort: String?

    enum CodingKeys: String, CodingKey {
        case type
        case maxReasoningEffort
    }
}

 struct OCModelCost: Codable, Sendable {
    let input: Double?
    let output: Double?
    let cacheRead: Double?
    let cacheWrite: Double?

    enum CodingKeys: String, CodingKey {
        case input, output
        case cacheRead = "cache_read"
        case cacheWrite = "cache_write"
    }
}

 struct OCModelLimit: Codable, Sendable {
    let context: Int?
    let output: Int?
}

/// Response shape for `GET /provider`:
/// `{ all: Provider[], default: { [key: string]: string }, connected: string[] }`
 struct OCProviderResponse: Codable, Sendable {
    let all: [OCProvider]
    let `default`: [String: String]?
    let connected: [String]?
}

/// The server's Config type is very large. We only decode the fields we use.
/// Uses AnyCodable fallback to avoid decode failures on unknown fields.
 struct OCConfig: Codable, Sendable {
    let model: String?
    let provider: [String: AnyCodable]?
    /// When set, ONLY these providers will be enabled. All others are ignored.
    let enabledProviders: [String]?
    /// Disable providers that are loaded automatically.
    let disabledProviders: [String]?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        provider = try container.decodeIfPresent([String: AnyCodable].self, forKey: .provider)
        enabledProviders = try container.decodeIfPresent([String].self, forKey: .enabledProviders)
        disabledProviders = try container.decodeIfPresent([String].self, forKey: .disabledProviders)
    }

    enum CodingKeys: String, CodingKey {
        case model, provider
        case enabledProviders = "enabled_providers"
        case disabledProviders = "disabled_providers"
    }
}

// MARK: - Health

 struct OCHealthResponse: Codable, Sendable {
    let healthy: Bool
    let version: String?
}

// MARK: - Permission

struct OCPermissionToolRef: Codable, Sendable {
    let messageID: String
    let callID: String
}

 struct OCPermissionRequest: Codable, Identifiable, Sendable {
    let id: String
    let sessionID: String?
    let permission: String?
    let action: String?
    let patterns: [String]
    let resources: [String]
    let metadata: [String: AnyCodable]?
    let always: [String]
    let save: [String]
    let toolRef: OCPermissionToolRef?
    let input: AnyCodable?
    let legacyDescription: String?
    let legacyTitle: String?
    let legacyToolName: String?

    var title: String? {
        legacyTitle?.nilIfBlank ?? permission?.nilIfBlank ?? action?.nilIfBlank ?? legacyToolName?.nilIfBlank
    }

    var description: String? {
        if let legacyDescription = legacyDescription?.nilIfBlank {
            return legacyDescription
        }
        return patterns.first?.nilIfBlank ?? resources.first?.nilIfBlank
    }

    var toolDisplayName: String? {
        legacyToolName?.nilIfBlank ?? permission?.nilIfBlank ?? action?.nilIfBlank
    }

    init(
        id: String,
        sessionID: String? = nil,
        permission: String? = nil,
        action: String? = nil,
        patterns: [String] = [],
        resources: [String] = [],
        metadata: [String: AnyCodable]? = nil,
        always: [String] = [],
        save: [String] = [],
        toolRef: OCPermissionToolRef? = nil,
        input: AnyCodable? = nil,
        description: String? = nil,
        title: String? = nil,
        toolName: String? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.permission = permission
        self.action = action
        self.patterns = patterns
        self.resources = resources
        self.metadata = metadata
        self.always = always
        self.save = save
        self.toolRef = toolRef
        self.input = input
        self.legacyDescription = description
        self.legacyTitle = title
        self.legacyToolName = toolName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
        permission = try container.decodeIfPresent(String.self, forKey: .permission)
        action = try container.decodeIfPresent(String.self, forKey: .action)
        patterns = try container.decodeIfPresent([String].self, forKey: .patterns) ?? []
        resources = try container.decodeIfPresent([String].self, forKey: .resources) ?? []
        metadata = try container.decodeIfPresent([String: AnyCodable].self, forKey: .metadata)
        always = try container.decodeIfPresent([String].self, forKey: .always) ?? []
        save = try container.decodeIfPresent([String].self, forKey: .save) ?? []
        toolRef = (try? container.decodeIfPresent(OCPermissionToolRef.self, forKey: .tool))
            ?? (try? container.decodeIfPresent(OCPermissionToolRef.self, forKey: .source))
        input = try container.decodeIfPresent(AnyCodable.self, forKey: .input)
        legacyDescription = try container.decodeIfPresent(String.self, forKey: .description)
        legacyTitle = try container.decodeIfPresent(String.self, forKey: .title)
        legacyToolName = try? container.decodeIfPresent(String.self, forKey: .tool)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(sessionID, forKey: .sessionID)
        try container.encodeIfPresent(permission, forKey: .permission)
        try container.encodeIfPresent(action, forKey: .action)
        try container.encode(patterns, forKey: .patterns)
        try container.encode(resources, forKey: .resources)
        try container.encodeIfPresent(metadata, forKey: .metadata)
        try container.encode(always, forKey: .always)
        try container.encode(save, forKey: .save)
        try container.encodeIfPresent(toolRef, forKey: .tool)
        try container.encodeIfPresent(input, forKey: .input)
        try container.encodeIfPresent(legacyDescription, forKey: .description)
        try container.encodeIfPresent(legacyTitle, forKey: .title)
        if legacyToolName != nil, toolRef == nil {
            try container.encodeIfPresent(legacyToolName, forKey: .tool)
        }
    }

    enum CodingKeys: String, CodingKey {
        case id
        case sessionID
        case permission
        case action
        case patterns
        case resources
        case metadata
        case always
        case save
        case tool
        case source
        case input
        case description
        case title
    }
}

// MARK: - Question

/// A single option within a question.
 struct OCQuestionOption: Codable, Identifiable, Sendable {
    let label: String
    let description: String

    var id: String { label }

    init(label: String, description: String) {
        self.label = label
        self.description = description
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
    }

    enum CodingKeys: String, CodingKey {
        case label, description
    }
}

/// A single question with header, text, options, and selection mode.
 struct OCQuestionInfo: Codable, Identifiable, Sendable {
    let question: String
    let header: String
    let options: [OCQuestionOption]
    let multiple: Bool
    let custom: Bool

    var id: String { header + question }

    init(question: String, header: String, options: [OCQuestionOption], multiple: Bool = false, custom: Bool = true) {
        self.question = question
        self.header = header
        self.options = options
        self.multiple = multiple
        self.custom = custom
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        question = try container.decodeIfPresent(String.self, forKey: .question) ?? ""
        header = try container.decodeIfPresent(String.self, forKey: .header) ?? ""
        options = try container.decodeIfPresent([OCQuestionOption].self, forKey: .options) ?? []
        multiple = try container.decodeIfPresent(Bool.self, forKey: .multiple) ?? false
        custom = try container.decodeIfPresent(Bool.self, forKey: .custom) ?? true
    }

    enum CodingKeys: String, CodingKey {
        case question, header, options, multiple, custom
    }
}

/// Tool reference inside a question request (which message/tool call triggered it).
struct OCQuestionToolRef: Codable, Sendable {
    let messageID: String
    let callID: String
}

/// A question request from the server, sent via SSE `question.asked` event.
/// Contains one or more questions the AI wants to ask the user.
 struct OCQuestionRequest: Codable, Identifiable, Sendable {
    let id: String
    let sessionID: String
    let questions: [OCQuestionInfo]
    let tool: OCQuestionToolRef?

    init(id: String, sessionID: String, questions: [OCQuestionInfo], tool: OCQuestionToolRef? = nil) {
        self.id = id
        self.sessionID = sessionID
        self.questions = questions
        self.tool = tool
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID) ?? ""
        questions = try container.decodeIfPresent([OCQuestionInfo].self, forKey: .questions) ?? []
        tool = try container.decodeIfPresent(OCQuestionToolRef.self, forKey: .tool)
    }

    enum CodingKeys: String, CodingKey {
        case id, sessionID, questions, tool
    }
}

/// Reply body sent to POST /question/:id/reply
 struct OCQuestionReply: Codable, Sendable {
    let answers: [[String]]
}

// MARK: - Project / Path / VCS

/// Matches the server's `Project` type:
/// `{ id, worktree, vcsDir?, vcs?, time: { created, initialized? } }`
 struct OCProject: Codable, Identifiable {
    let id: String
    let worktree: String?
    let vcsDir: String?
    let vcs: String?
    let time: OCProjectTime?

    /// Convenience: extract a display name from the worktree path (last path component).
    var displayName: String? {
        guard let worktree, !worktree.isEmpty else { return nil }
        return (worktree as NSString).lastPathComponent
    }

    init(id: String, worktree: String?, vcsDir: String? = nil, vcs: String? = nil, time: OCProjectTime? = nil) {
        self.id = id
        self.worktree = worktree
        self.vcsDir = vcsDir
        self.vcs = vcs
        self.time = time
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        worktree = try container.decodeIfPresent(String.self, forKey: .worktree)
        vcsDir = try container.decodeIfPresent(String.self, forKey: .vcsDir)
        vcs = try container.decodeIfPresent(String.self, forKey: .vcs)
        time = try? container.decodeIfPresent(OCProjectTime.self, forKey: .time)
    }

    enum CodingKeys: String, CodingKey {
        case id, worktree, vcsDir, vcs, time
    }
}

 struct OCProjectTime: Codable {
    let created: Double?
    let initialized: Double?
}

 struct OCPathInfo: Codable {
    let state: String?
    let config: String?
    let worktree: String?
    let directory: String?
}

 struct OCVCSInfo: Codable {
    let branch: String?
}

// MARK: - File Browser

struct OCWorkspaceFileEntry: Codable, Identifiable, Sendable {
    let name: String
    let path: String
    let absolute: String?
    let type: String?
    let ignored: Bool?

    var id: String { absolute ?? path }
}

struct OCWorkspaceFileStatus: Codable, Hashable, Sendable {
    let path: String
    let added: Int
    let removed: Int
    let status: String

    var resolvedStatus: String {
        switch status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "added":
            "A"
        case "deleted":
            "D"
        default:
            "M"
        }
    }
}

struct OCFilePatchHunk: Codable, Hashable, Sendable {
    let oldStart: Int
    let oldLines: Int
    let newStart: Int
    let newLines: Int
    let lines: [String]
}

struct OCFilePatch: Codable, Hashable, Sendable {
    let oldFileName: String
    let newFileName: String
    let oldHeader: String?
    let newHeader: String?
    let hunks: [OCFilePatchHunk]
    let index: String?
}

struct OCFileContent: Codable, Hashable, Sendable {
    let type: String?
    let content: String?
    let diff: String?
    let patch: OCFilePatch?
    let patchText: String?
    let encoding: String?
    let mimeType: String?

    var resolvedTextContent: String? {
        guard type?.lowercased() == "text" else { return nil }
        guard encoding?.lowercased() != "base64" else { return nil }
        return content
    }

    var unifiedPatchText: String? {
        diff?.nilIfBlank ?? patchText?.nilIfBlank
    }

    init(
        type: String? = nil,
        content: String? = nil,
        diff: String? = nil,
        patch: OCFilePatch? = nil,
        patchText: String? = nil,
        encoding: String? = nil,
        mimeType: String? = nil
    ) {
        self.type = type
        self.content = content
        self.diff = diff
        self.patch = patch
        self.patchText = patchText
        self.encoding = encoding
        self.mimeType = mimeType
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        content = try container.decodeIfPresent(String.self, forKey: .content)
        diff = try container.decodeIfPresent(String.self, forKey: .diff)
        if let patchObject = try? container.decodeIfPresent(OCFilePatch.self, forKey: .patch) {
            patch = patchObject
            patchText = nil
        } else {
            patch = nil
            patchText = try container.decodeIfPresent(String.self, forKey: .patch)
        }
        encoding = try container.decodeIfPresent(String.self, forKey: .encoding)
        mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(type, forKey: .type)
        try container.encodeIfPresent(content, forKey: .content)
        try container.encodeIfPresent(diff, forKey: .diff)
        if let patch {
            try container.encode(patch, forKey: .patch)
        } else {
            try container.encodeIfPresent(patchText, forKey: .patch)
        }
        try container.encodeIfPresent(encoding, forKey: .encoding)
        try container.encodeIfPresent(mimeType, forKey: .mimeType)
    }

    enum CodingKeys: String, CodingKey {
        case type, content, diff, patch, encoding, mimeType
    }
}

// MARK: - File Diff

 struct OCFileDiff: Codable, Sendable {
    let file: String?
    let path: String?
    let status: String?
    let additions: Int?
    let deletions: Int?
    let before: String?
    let after: String?
    let diff: String?
    let patch: OCFilePatch?
    let patchText: String?

    init(
        file: String? = nil,
        path: String? = nil,
        status: String? = nil,
        additions: Int? = nil,
        deletions: Int? = nil,
        before: String? = nil,
        after: String? = nil,
        diff: String? = nil,
        patch: OCFilePatch? = nil,
        patchText: String? = nil
    ) {
        self.file = file
        self.path = path
        self.status = status
        self.additions = additions
        self.deletions = deletions
        self.before = before
        self.after = after
        self.diff = diff
        self.patch = patch
        self.patchText = patchText
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        file = try container.decodeIfPresent(String.self, forKey: .file)
        path = try container.decodeIfPresent(String.self, forKey: .path)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        additions = try container.decodeIfPresent(Int.self, forKey: .additions)
        deletions = try container.decodeIfPresent(Int.self, forKey: .deletions)
        before = try container.decodeIfPresent(String.self, forKey: .before)
        after = try container.decodeIfPresent(String.self, forKey: .after)
        diff = try container.decodeIfPresent(String.self, forKey: .diff)
        if let patchObject = try? container.decodeIfPresent(OCFilePatch.self, forKey: .patch) {
            patch = patchObject
            patchText = nil
        } else {
            patch = nil
            patchText = try container.decodeIfPresent(String.self, forKey: .patch)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(file, forKey: .file)
        try container.encodeIfPresent(path, forKey: .path)
        try container.encodeIfPresent(status, forKey: .status)
        try container.encodeIfPresent(additions, forKey: .additions)
        try container.encodeIfPresent(deletions, forKey: .deletions)
        try container.encodeIfPresent(before, forKey: .before)
        try container.encodeIfPresent(after, forKey: .after)
        try container.encodeIfPresent(diff, forKey: .diff)
        if let patch {
            try container.encode(patch, forKey: .patch)
        } else {
            try container.encodeIfPresent(patchText, forKey: .patch)
        }
    }

    var resolvedPath: String? {
        path?.nilIfBlank ?? file?.nilIfBlank
    }

    var resolvedStatus: String {
        if let status = status?.nilIfBlank?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            switch status {
            case "a", "add", "added":
                return "A"
            case "d", "delete", "deleted", "removed":
                return "D"
            case "r", "rename", "renamed":
                return "R"
            default:
                return "M"
            }
        }

        switch (before?.nilIfBlank, after?.nilIfBlank) {
        case (.none, .some):
            return "A"
        case (.some, .none):
            return "D"
        default:
            return "M"
        }
    }

    var resolvedAdditions: Int {
        additions ?? derivedLineCounts.additions
    }

    var resolvedDeletions: Int {
        deletions ?? derivedLineCounts.deletions
    }

    var unifiedPatchText: String? {
        diff?.nilIfBlank ?? patchText?.nilIfBlank
    }

    private var derivedLineCounts: (additions: Int, deletions: Int) {
        if let patch {
            return patch.hunks.reduce(into: (additions: 0, deletions: 0)) { counts, hunk in
                for line in hunk.lines {
                    if line.hasPrefix("+") {
                        counts.additions += 1
                    } else if line.hasPrefix("-") {
                        counts.deletions += 1
                    }
                }
            }
        }

        let parsedHunks = ReviewFilePatchHunk.parseUnifiedDiff(unifiedPatchText)
        if !parsedHunks.isEmpty {
            return parsedHunks.reduce(into: (additions: 0, deletions: 0)) { counts, hunk in
                for line in hunk.lines {
                    if line.hasPrefix("+") {
                        counts.additions += 1
                    } else if line.hasPrefix("-") {
                        counts.deletions += 1
                    }
                }
            }
        }

        let beforeLines = (before ?? "").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let afterLines = (after ?? "").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let difference = afterLines.difference(from: beforeLines, by: ==)

        var additions = 0
        var deletions = 0

        for change in difference {
            switch change {
            case .insert:
                additions += 1
            case .remove:
                deletions += 1
            }
        }

        return (additions, deletions)
    }

    enum CodingKeys: String, CodingKey {
        case file, path, status, additions, deletions, before, after, diff, patch
    }
}

// MARK: - Agent

 struct OCAgent: Codable, Identifiable {
    let id: String
    let name: String?
    let description: String?
    let mode: String?
    let native: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name, description, mode, native
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedName = try container.decodeIfPresent(String.self, forKey: .name)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let decodedID = try container.decodeIfPresent(String.self, forKey: .id)?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let resolvedID = decodedID, !resolvedID.isEmpty {
            id = resolvedID
        } else if let resolvedName = decodedName, !resolvedName.isEmpty {
            id = resolvedName
        } else {
            throw DecodingError.keyNotFound(
                CodingKeys.id,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected either 'id' or 'name' for OCAgent."
                )
            )
        }

        name = decodedName
        description = try container.decodeIfPresent(String.self, forKey: .description)
        mode = try container.decodeIfPresent(String.self, forKey: .mode)
        native = try container.decodeIfPresent(Bool.self, forKey: .native)
    }
}

// MARK: - Command

 struct OCCommand: Codable, Identifiable {
    let id: String
    let name: String?
    let description: String?
    let source: String?
    let template: String?
    let hints: [String]?

    enum CodingKeys: String, CodingKey {
        case id, name, description, source, template, hints
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedName = try container.decodeIfPresent(String.self, forKey: .name)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let decodedID = try container.decodeIfPresent(String.self, forKey: .id)?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let resolvedID = decodedID, !resolvedID.isEmpty {
            id = resolvedID
        } else if let resolvedName = decodedName, !resolvedName.isEmpty {
            id = resolvedName
        } else {
            throw DecodingError.keyNotFound(
                CodingKeys.id,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected either 'id' or 'name' for OCCommand."
                )
            )
        }

        name = decodedName
        description = try container.decodeIfPresent(String.self, forKey: .description)
        source = try container.decodeIfPresent(String.self, forKey: .source)
        if let str = try? container.decodeIfPresent(String.self, forKey: .template) {
            template = str
        } else if let dict = try? container.decodeIfPresent([String: AnyCodable].self, forKey: .template),
                  let content = dict["content"]?.value as? String {
            template = content
        } else {
            template = nil
        }
        hints = try container.decodeIfPresent([String].self, forKey: .hints)
    }
}

// MARK: - Prompt Input

 struct OCPromptInput: Codable {
    let parts: [OCPromptPart]
    let model: OCModelRef?
    let agent: String?
    let messageID: String?
    let variant: String?

    struct OCModelRef: Codable {
        let providerID: String
        let modelID: String
    }
}

 struct OCPromptPart: Codable {
    let type: String // "text"
    let text: String?
}

// MARK: - Todo

struct OCTodo: Identifiable, Codable {
    let id: String
    let content: String
    let status: String
    let priority: String?

    enum CodingKeys: String, CodingKey {
        case content, status, priority
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.content = try container.decode(String.self, forKey: .content)
        self.status = try container.decode(String.self, forKey: .status)
        self.priority = try container.decodeIfPresent(String.self, forKey: .priority)
        self.id = self.content
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(content, forKey: .content)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(priority, forKey: .priority)
    }
}

// MARK: - AnyCodable (utility for dynamic JSON)

 struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map(\.value)
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues(\.value)
        } else {
            value = NSNull()
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            try container.encodeNil()
        }
    }
}
