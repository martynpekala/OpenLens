import Foundation

/// Pure service for message fetch and domain model conversion.
/// No SwiftUI imports, no direct UI mutations.
final class MessagesService {

    private let connection: ConnectionManager

    init(connection: ConnectionManager) {
        self.connection = connection
    }

    // MARK: - Fetch Messages

    /// `nil` means the negotiated protocol cannot supply active context.
    /// Historical usage and history pages are never fallback context data.
    func loadActiveContext(sessionID: String) async throws -> SessionTranscript? {
        guard let client = connection.client else { throw OpenCodeError.notConnected }
        let revision = connection.projectContextRevision
        let entries: [OCTranscriptEntry]?
        do {
            entries = try await client.getActiveContext(sessionID: sessionID)
        } catch {
            guard !Task.isCancelled, connection.client === client,
                  connection.projectContextRevision == revision else { throw CancellationError() }
            throw error
        }
        guard !Task.isCancelled, connection.client === client,
              connection.projectContextRevision == revision else { throw CancellationError() }
        guard let entries else { return nil }
        return Self.transcript(from: entries)
    }

    /// Fetch all messages for a session, converted to local ChatMessage models.
    func loadMessages(sessionID: String) async throws -> [ChatMessage] {
        guard let client = connection.client else {
            throw OpenCodeError.notConnected
        }

        let serverMessages = try await client.listMessages(sessionID: sessionID)
        return serverMessages.map { convertToChatMessage($0) }
    }

    /// Fetch the ordered transcript in one read, keeping context outside chat roles.
    func loadTranscript(sessionID: String) async throws -> SessionTranscript {
        guard let client = connection.client else { throw OpenCodeError.notConnected }
        let entries = try await client.listTranscript(sessionID: sessionID)
        return Self.transcript(from: entries)
    }

    /// Share domain conversion across both reads and fixture presentation.
    static func transcript(from entries: [OCTranscriptEntry]) -> SessionTranscript {
        return SessionTranscript(
            messages: entries.compactMap {
                guard case .message(let message) = $0 else { return nil }
                return Self.convert(message)
            },
            contextEntries: entries.compactMap {
                guard case .context(let context) = $0 else { return nil }
                return context
            },
            entryOrder: entries.map(\.id)
        )
    }

    // MARK: - Send Prompt (async/fire-and-forget via SSE)

    /// Send a prompt to the server. The response arrives via SSE, not as a return value.
    @discardableResult
    func sendPromptAsync(
        sessionID: String,
        text: String,
        model: OCPromptInput.OCModelRef? = nil,
        agent: String? = nil,
        variant: String? = nil,
        messageID: String? = nil,
        skills: [OCV2SkillAttachment] = [],
        attachments: [PromptAttachment] = []
    ) async throws -> OCV2PromptAdmission? {
        guard let client = connection.client else {
            throw OpenCodeError.notConnected
        }

        return try await client.sendPromptAsync(
            sessionID: sessionID,
            text: text,
            model: model,
            agent: agent,
            variant: variant,
            messageID: messageID,
            skills: skills,
            attachments: attachments
        )
    }

    /// Queue a follow-up behind the active session turn.
    @discardableResult
    func queuePrompt(
        sessionID: String,
        text: String,
        model: OCPromptInput.OCModelRef? = nil,
        agent: String? = nil,
        variant: String? = nil,
        messageID: String? = nil,
        skills: [OCV2SkillAttachment] = [],
        attachments: [PromptAttachment] = []
    ) async throws -> OCV2PromptAdmission? {
        guard let client = connection.client else {
            throw OpenCodeError.notConnected
        }

        return try await client.queuePrompt(
            sessionID: sessionID,
            text: text,
            model: model,
            agent: agent,
            variant: variant,
            messageID: messageID,
            skills: skills,
            attachments: attachments
        )
    }

    func generateSessionText(sessionID: String, prompt: String) async throws -> String {
        guard let client = connection.client else { throw OpenCodeError.notConnected }
        return try await client.generateSessionText(sessionID: sessionID, prompt: prompt)
    }

    func requestCompaction(sessionID: String, messageID: String) async throws -> OCV2InboxEntry? {
        guard let client = connection.client else { throw OpenCodeError.notConnected }
        return try await client.requestCompaction(sessionID: sessionID, messageID: messageID)
    }

    /// Durable work admitted to the v2 session and not yet delivered.
    func listSessionInbox(sessionID: String) async throws -> [OCV2InboxEntry] {
        guard let client = connection.client else {
            throw OpenCodeError.notConnected
        }
        return try await client.listSessionInbox(sessionID: sessionID)
    }

    func cancelSessionInboxEntry(sessionID: String, inboxID: String) async throws {
        guard let client = connection.client else { throw OpenCodeError.notConnected }
        try await client.cancelSessionInboxEntry(sessionID: sessionID, inboxID: inboxID)
    }

    func changeSessionInboxDelivery(sessionID: String, inboxID: String, delivery: OCV2PromptInput.Delivery) async throws {
        guard let client = connection.client else { throw OpenCodeError.notConnected }
        try await client.changeSessionInboxDelivery(sessionID: sessionID, inboxID: inboxID, delivery: delivery)
    }

    /// Looks up a prompt admitted under `messageID` in the v2 inbox or history.
    func findPromptAdmission(sessionID: String, messageID: String) async throws -> OCV2PromptAdmission? {
        guard let client = connection.client else {
            throw OpenCodeError.notConnected
        }
        return try await client.findPromptAdmission(sessionID: sessionID, messageID: messageID)
    }

    func sendCommand(
        sessionID: String,
        command: String,
        arguments: String,
        model: OCPromptInput.OCModelRef? = nil,
        agent: String? = nil,
        variant: String? = nil,
        files: [String] = [],
        agents: [String] = [],
        skills: [OCV2SkillAttachment] = [],
        delivery: OCV2PromptInput.Delivery = .steer
    ) async throws {
        guard let client = connection.client else {
            throw OpenCodeError.notConnected
        }

        try await client.sendCommand(
            sessionID: sessionID,
            command: command,
            arguments: arguments,
            model: model,
            agent: agent,
            variant: variant,
            files: files,
            agents: agents,
            skills: skills,
            delivery: delivery
        )
    }

    // MARK: - Abort

    /// Abort the current generation for a session.
    func abort(sessionID: String) async throws -> Bool {
        guard let client = connection.client else {
            throw OpenCodeError.notConnected
        }

        return try await client.abortSession(id: sessionID)
    }

    // MARK: - Turn Diffs

    func loadTurnFileChanges(sessionID: String, userMessageID: String) async throws -> [ReviewFileChange] {
        guard let client = connection.client else {
            throw OpenCodeError.notConnected
        }

        return try await client.getSessionDiff(sessionID: sessionID, messageID: userMessageID)
            .map(ReviewFileChange.init(diff:))
            .sorted { lhs, rhs in
                lhs.path.localizedCaseInsensitiveCompare(rhs.path) == .orderedAscending
            }
    }

    // MARK: - Undo

    /// Reverts a user message and the work that followed it, restoring the
    /// session to the state immediately before that message.
    func revertMessage(sessionID: String, messageID: String) async throws -> OCSession? {
        guard let client = connection.client else {
            throw OpenCodeError.notConnected
        }

        return try await client.revertMessage(
            sessionID: sessionID,
            messageID: messageID
        )
    }

    // MARK: - Conversion

    /// Convert a server message (with parts) to the local ChatMessage model.
    func convertToChatMessage(_ msg: OCMessageWithParts) -> ChatMessage {
        Self.convert(msg)
    }

    static func convert(_ msg: OCMessageWithParts) -> ChatMessage {
        let textContent = msg.parts
            .compactMap(\.renderableText)
            .joined()

        let resolvedModelID = msg.info.modelID?.nilIfBlank ?? msg.info.model?.modelID
        let resolvedProviderID = msg.info.providerID?.nilIfBlank ?? msg.info.model?.providerID

        return ChatMessage(
            id: msg.info.id,
            role: msg.info.role,
            content: textContent,
            parts: msg.parts,
            isStreaming: false,
            cost: msg.info.cost,
            tokens: msg.info.tokens,
            modelID: resolvedModelID,
            providerID: resolvedProviderID,
            finish: msg.info.finish,
            parentUserMessageID: msg.info.parentID
        )
    }
}
