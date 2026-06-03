import Foundation

/// Pure service for message fetch and domain model conversion.
/// No SwiftUI imports, no direct UI mutations.
final class MessagesService {

    private let connection: ConnectionManager

    init(connection: ConnectionManager) {
        self.connection = connection
    }

    // MARK: - Fetch Messages

    /// Fetch all messages for a session, converted to local ChatMessage models.
    func loadMessages(sessionID: String) async throws -> [ChatMessage] {
        guard let client = connection.client else {
            throw OpenCodeError.notConnected
        }

        let serverMessages = try await client.listMessages(sessionID: sessionID)
        return serverMessages.map { convertToChatMessage($0) }
    }

    // MARK: - Send Prompt (async/fire-and-forget via SSE)

    /// Send a prompt to the server. The response arrives via SSE, not as a return value.
    func sendPromptAsync(
        sessionID: String,
        text: String,
        model: OCPromptInput.OCModelRef? = nil,
        agent: String? = nil,
        variant: String? = nil
    ) async throws {
        guard let client = connection.client else {
            throw OpenCodeError.notConnected
        }

        try await client.sendPromptAsync(sessionID: sessionID, text: text, model: model, agent: agent, variant: variant)
    }

    func sendCommand(
        sessionID: String,
        command: String,
        arguments: String,
        model: String? = nil,
        agent: String? = nil,
        variant: String? = nil
    ) async throws {
        guard let client = connection.client else {
            throw OpenCodeError.notConnected
        }

        let _ = try await client.sendCommand(
            sessionID: sessionID,
            command: command,
            arguments: arguments,
            model: model,
            agent: agent,
            variant: variant
        )
    }

    // MARK: - Abort

    /// Abort the current generation for a session.
    func abort(sessionID: String) async throws {
        guard let client = connection.client else {
            throw OpenCodeError.notConnected
        }

        let _ = try await client.abortSession(id: sessionID)
    }

    // MARK: - Conversion

    /// Convert a server message (with parts) to the local ChatMessage model.
    func convertToChatMessage(_ msg: OCMessageWithParts) -> ChatMessage {
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
            finish: msg.info.finish
        )
    }
}
