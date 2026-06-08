import Foundation
import UIKit
import os

// MARK: - Delegate Protocol

/// Delegate that the SSEEventHandler calls to mutate ViewModel state.
/// All methods are called on the same thread as the SSE callback (main thread via SSEClient).
protocol SSEEventHandlerDelegate: AnyObject {
    var currentSessionID: String? { get }
    var messages: [ChatMessage] { get set }
    var pendingAssistantMessage: ChatMessage? { get set }
    var currentActivity: AgentActivity? { get set }
    var sessionStatus: OCSessionStatus? { get set }
    var isLoading: Bool { get set }
    var currentSession: OCSession? { get set }
    var pendingPermission: OCPermissionRequest? { get set }
    var showPermissionAlert: Bool { get set }
    var pendingQuestion: OCQuestionRequest? { get set }
    var showQuestionSheet: Bool { get set }
    var todos: [OCTodo] { get set }

    func finishLoading()

    /// Returns true when a message event belongs to a locally stopped turn and
    /// should not reopen streaming state.
    func shouldIgnoreAssistantEvent(sessionID: String, messageID: String) -> Bool

    /// Returns true when a busy status is stale for a locally stopped turn.
    func shouldIgnoreBusyStatus(sessionID: String) -> Bool

    /// Append streamed text to the pending assistant message (not shown in chat yet).
    func appendStreamingText(messageID: String, text: String)

    /// Discard any buffered streaming deltas for a message.
    /// Called when a `message.part.updated` snapshot supersedes pending deltas.
    func clearStreamingBuffer(messageID: String)

    /// Called when a new question is presented so the VM can start a timeout timer.
    func questionDidPresent()
}

// MARK: - SSEEventHandler

/// Handles incoming SSE events, parsing them and delegating state mutations
/// to the owning view model via `SSEEventHandlerDelegate`.
@MainActor
final class SSEEventHandler {

    // MARK: - Dependencies

    weak var delegate: SSEEventHandlerDelegate?

    /// Reference to the API client for fire-and-forget operations (e.g. rejecting overlapping questions).
    /// Set by the owning view model alongside the delegate.
    var connectionClient: OpenCodeClient?

    /// Reference to the connection manager for heartbeat tracking.
    weak var connectionManager: ConnectionManager?

    private let haptics: HapticController
    private let liveActivityTracker: LiveActivityTracker
    private var lastToolStatusByPartID: [String: OCToolStatus] = [:]

    init(haptics: HapticController, liveActivityTracker: LiveActivityTracker) {
        self.haptics = haptics
        self.liveActivityTracker = liveActivityTracker
    }

    // MARK: - Main Dispatch

    func handleEvent(_ event: OCEvent) {
        switch event.type {
        case "server.connected", "server.heartbeat":
            connectionManager?.receivedHeartbeat()

        case "session.status":
            handleSessionStatus(event)

        case "message.updated":
            handleMessageUpdated(event)

        case "message.part.updated":
            handlePartUpdated(event)

        case "message.part.delta":
            handlePartDelta(event)

        case "message.part.removed":
            handlePartRemoved(event)

        case "message.removed":
            handleMessageRemoved(event)

        case "session.updated":
            handleSessionUpdated(event)

        case "permission.asked":
            handlePermissionAsked(event)

        case "question.asked":
            handleQuestionAsked(event)

        case "question.replied", "question.rejected":
            // These confirm the question was answered/dismissed; clear UI if still showing
            handleQuestionDismissed(event)

        case "todo.updated":
            Logger.debug.info("[TODO] received todo.updated event")
            handleTodoUpdated(event)

        default:
            Logger.debug.debug("[SSE] unhandled event: \(event.type, privacy: .public)")
            break
        }
    }

    // MARK: - Event Handlers

    private func handleSessionStatus(_ event: OCEvent) {
        guard let delegate else { return }
        guard let props = event.properties?.value as? [String: Any],
              let sessionID = props["sessionID"] as? String,
              sessionID == delegate.currentSessionID,
              let statusDict = props["status"] as? [String: Any],
              let typeStr = statusDict["type"] as? String else { return }

        let statusType = OCSessionStatusType(rawValue: typeStr) ?? .idle

        if statusType == .busy, delegate.shouldIgnoreBusyStatus(sessionID: sessionID) {
            return
        }

        delegate.sessionStatus = OCSessionStatus(
            type: statusType,
            attempt: statusDict["attempt"] as? Int,
            message: statusDict["message"] as? String,
            next: statusDict["next"] as? Int
        )

        if statusType == .idle {
            lastToolStatusByPartID.removeAll()
            delegate.finishLoading()
        } else if statusType == .busy {
            lastToolStatusByPartID.removeAll()
            if !delegate.isLoading {
                delegate.isLoading = true
                delegate.currentActivity = AgentActivity()
                delegate.currentActivity?.currentLabel = "Thinking..."

                // Start Live Activity for externally-triggered turns (e.g. message
                // sent from desktop). When the user sends from iOS, ChatClient.send()
                // already calls start() before this event arrives, so the tracker
                // will end the previous activity and create a fresh one — which is fine.
                let userTask = delegate.messages.last(where: { $0.role == .user })?.content ?? ""
                liveActivityTracker.start(
                    agentName: delegate.currentSession?.title ?? "OpenCode",
                    userTask: String(userTask.prefix(80))
                )

                if let permission = delegate.pendingPermission {
                    liveActivityTracker.setPendingPermission(permission)
                } else if let question = delegate.pendingQuestion {
                    liveActivityTracker.setPendingQuestion(question)
                }
            }
        }
    }

    private func handleMessageUpdated(_ event: OCEvent) {
        guard let delegate else { return }
        guard let props = event.properties?.value as? [String: Any],
              let infoDict = props["info"] as? [String: Any],
              let sessionID = infoDict["sessionID"] as? String,
              sessionID == delegate.currentSessionID,
              let messageID = infoDict["id"] as? String else { return }

        let role = infoDict["role"] as? String

        if role == "assistant",
           delegate.shouldIgnoreAssistantEvent(sessionID: sessionID, messageID: messageID) {
            return
        }

        if role == "user" {
            // User message confirmed by server — already shown optimistically
            return
        }

        if role == "assistant" {
            let decodedInfo = decodeMessageInfo(from: infoDict)
            let cost = decodedInfo?.cost ?? infoDict["cost"] as? Double
            let serverModelID = decodedInfo?.modelID ?? infoDict["modelID"] as? String
            let serverProviderID = decodedInfo?.providerID ?? infoDict["providerID"] as? String
            let finish = decodedInfo?.finish ?? infoDict["finish"] as? String
            let tokens = decodedInfo?.tokens

            if let existing = delegate.pendingAssistantMessage {
                // Update the pending message in-place (not visible yet).
                if existing.id != messageID {
                    let replacement = ChatMessage(
                        id: messageID,
                        role: .assistant,
                        content: existing.content,
                        parts: existing.parts,
                        isStreaming: true,
                        createdAt: existing.createdAt,
                        cost: cost,
                        tokens: tokens ?? existing.tokens,
                        modelID: serverModelID ?? existing.modelID,
                        providerID: serverProviderID ?? existing.providerID,
                        finish: finish
                    )
                    delegate.pendingAssistantMessage = replacement
                } else {
                    existing.cost = cost
                    if let tokens { existing.tokens = tokens }
                    if let mid = serverModelID { existing.modelID = mid }
                    if let pid = serverProviderID { existing.providerID = pid }
                    existing.finish = finish
                }

                // Update Live Activity cost
                if let cost {
                    liveActivityTracker.updateCost(String(format: "$%.3f", cost))
                }
            } else if !delegate.messages.contains(where: { $0.id == messageID }) {
                // New assistant message — create as pending (hidden from chat).
                delegate.pendingAssistantMessage = ChatMessage(
                    id: messageID,
                    role: .assistant,
                    content: "",
                    isStreaming: true,
                    cost: cost,
                    tokens: tokens,
                    modelID: serverModelID,
                    providerID: serverProviderID,
                    finish: finish
                )
                if !delegate.isLoading {
                    delegate.isLoading = true
                    delegate.currentActivity = AgentActivity()
                    delegate.currentActivity?.currentLabel = "Thinking..."
                }
            }
        }
    }

    private func decodeMessageInfo(from payload: [String: Any]) -> OCMessage? {
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return try? JSONDecoder().decode(OCMessage.self, from: data)
    }

    private func handlePartUpdated(_ event: OCEvent) {
        guard let delegate else { return }
        guard let props = event.properties?.value as? [String: Any],
              let partDict = props["part"] as? [String: Any],
              let sessionID = partDict["sessionID"] as? String,
              sessionID == delegate.currentSessionID,
              let messageID = partDict["messageID"] as? String else { return }

        guard !delegate.shouldIgnoreAssistantEvent(sessionID: sessionID, messageID: messageID) else {
            return
        }

        // Look up the message: first in the pending message, then in committed messages.
        let msg: ChatMessage? = {
            if let pending = delegate.pendingAssistantMessage, pending.id == messageID {
                return pending
            }
            return delegate.messages.first(where: { $0.id == messageID })
        }()
        guard let msg else { return }

        guard let partData = try? JSONSerialization.data(withJSONObject: partDict),
              let part = try? JSONDecoder().decode(OCPart.self, from: partData) else { return }

        if part.type != .text || !msg.isStreaming {
            if let partIndex = msg.parts.firstIndex(where: { $0.id == part.id }) {
                msg.parts[partIndex] = part
            } else {
                msg.parts.append(part)
            }
        }

        switch part.type {
        case .text:
            if let text = part.renderableText {
                // part.updated carries the full authoritative text — use it directly
                // and discard any buffered deltas to avoid double-appending content
                // that is already included in this snapshot.
                delegate.clearStreamingBuffer(messageID: messageID)
                if msg.content != text {
                    msg.content = text
                }
                haptics.playFirstResponseIfNeeded()
            }

        case .tool:
            handleToolPartUpdate(part, delegate: delegate)

        case .reasoning:
            if let text = part.text {
                delegate.currentActivity?.thinkingText = text
                // Extract first line as subject for Live Activity
                if liveActivityTracker.subject == nil, !text.isEmpty {
                    let firstLine = text.components(separatedBy: .newlines).first ?? text
                    liveActivityTracker.updateSubject(String(firstLine.prefix(60)))
                }
            }

        case .stepFinish:
            if let stepIndex = delegate.currentActivity?.steps.lastIndex(where: { !$0.isCompleted }) {
                delegate.currentActivity?.steps[stepIndex].isCompleted = true
            }

        case .file,
             .stepStart,
             .snapshot,
             .patch,
             .retry,
             .compaction,
             .agent,
             .subtask,
             .unknown:
            break
        }
    }

    private func handlePartDelta(_ event: OCEvent) {
        guard let delegate else { return }
        guard let props = event.properties?.value as? [String: Any],
              let sessionID = props["sessionID"] as? String,
              sessionID == delegate.currentSessionID,
              let messageID = props["messageID"] as? String,
              let field = props["field"] as? String,
              let delta = props["delta"] as? String else { return }

        guard !delegate.shouldIgnoreAssistantEvent(sessionID: sessionID, messageID: messageID) else {
            return
        }

        if field == "text" {
            delegate.appendStreamingText(messageID: messageID, text: delta)
            haptics.playFirstResponseIfNeeded()
        }
    }

    private func handlePartRemoved(_ event: OCEvent) {
        guard let delegate else { return }
        guard let props = event.properties?.value as? [String: Any],
              let sessionID = props["sessionID"] as? String,
              sessionID == delegate.currentSessionID,
              let messageID = props["messageID"] as? String,
              let partID = props["partID"] as? String else { return }

        guard !delegate.shouldIgnoreAssistantEvent(sessionID: sessionID, messageID: messageID) else {
            return
        }

        let msg: ChatMessage? = {
            if let pending = delegate.pendingAssistantMessage, pending.id == messageID {
                return pending
            }
            return delegate.messages.first(where: { $0.id == messageID })
        }()
        msg?.parts.removeAll { $0.id == partID }
    }

    private func handleMessageRemoved(_ event: OCEvent) {
        guard let delegate else { return }
        guard let props = event.properties?.value as? [String: Any],
              let sessionID = props["sessionID"] as? String,
              sessionID == delegate.currentSessionID,
              let messageID = props["messageID"] as? String else { return }

        guard !delegate.shouldIgnoreAssistantEvent(sessionID: sessionID, messageID: messageID) else {
            return
        }

        delegate.messages.removeAll { $0.id == messageID }
    }

    private func handleSessionUpdated(_ event: OCEvent) {
        guard let delegate else { return }
        guard let props = event.properties?.value as? [String: Any],
              let infoDict = props["info"] as? [String: Any],
              let sessionID = infoDict["id"] as? String,
              sessionID == delegate.currentSessionID else { return }

        if let title = infoDict["title"] as? String {
            if let data = try? JSONSerialization.data(withJSONObject: infoDict),
               let updated = try? JSONDecoder().decode(OCSession.self, from: data) {
                delegate.currentSession = updated
            }
            liveActivityTracker.updateSubject(title)
        }
    }

    private func handlePermissionAsked(_ event: OCEvent) {
        guard let delegate else { return }
        guard let props = event.properties?.value as? [String: Any] else { return }

        // Chat should only interrupt the currently opened session.
        if let sessionID = props["sessionID"] as? String,
           sessionID != delegate.currentSessionID {
            return
        }

        if let data = try? JSONSerialization.data(withJSONObject: props),
           let permission = try? JSONDecoder().decode(OCPermissionRequest.self, from: data) {
            delegate.pendingPermission = permission
            delegate.showPermissionAlert = true
        } else {
            let id = props["id"] as? String ?? UUID().uuidString
            let permission = OCPermissionRequest(
                id: id,
                sessionID: props["sessionID"] as? String,
                permission: props["permission"] as? String,
                patterns: props["patterns"] as? [String] ?? [],
                input: nil,
                description: props["description"] as? String,
                title: props["title"] as? String
            )
            delegate.pendingPermission = permission
            delegate.showPermissionAlert = true
        }

        haptics.playWarning()
    }

    private func handleQuestionAsked(_ event: OCEvent) {
        guard let delegate else { return }
        guard let props = event.properties?.value as? [String: Any] else { return }

        // Check session matches
        if let sessionID = props["sessionID"] as? String,
           sessionID != delegate.currentSessionID {
            return
        }

        if let data = try? JSONSerialization.data(withJSONObject: props),
           let question = try? JSONDecoder().decode(OCQuestionRequest.self, from: data) {
            // If a question is already pending, reject it before replacing
            if let existing = delegate.pendingQuestion {
                Logger.sseHandler.warning("Overlapping question: rejecting \(existing.id, privacy: .public) in favor of \(question.id, privacy: .public)")
                // Fire-and-forget rejection of the old question
                if let client = connectionClient {
                    Task {
                        let _ = try? await client.rejectQuestion(requestID: existing.id)
                    }
                }
            }
            delegate.pendingQuestion = question
            delegate.showQuestionSheet = true
            delegate.questionDidPresent()
        }

        haptics.playWarning()
    }

    private func handleQuestionDismissed(_ event: OCEvent) {
        guard let delegate else { return }
        guard let props = event.properties?.value as? [String: Any],
              let requestID = props["requestID"] as? String else { return }

        // Only clear if it matches the currently pending question
        if delegate.pendingQuestion?.id == requestID {
            delegate.pendingQuestion = nil
            delegate.showQuestionSheet = false
        }
    }

    private func handleTodoUpdated(_ event: OCEvent) {
        guard let delegate else {
            Logger.debug.warning("[TODO] no delegate")
            return
        }

        guard let props = event.properties?.value as? [String: Any] else {
            Logger.debug.warning("[TODO] no properties")
            return
        }

        Logger.debug.info("[TODO] event keys: \(Array(props.keys).joined(separator: ", "), privacy: .public)")

        guard let sessionID = props["sessionID"] as? String else {
            Logger.debug.warning("[TODO] no sessionID in props")
            return
        }

        guard sessionID == delegate.currentSessionID else {
            Logger.debug.info("[TODO] sessionID mismatch: got \(sessionID, privacy: .public), expected \(delegate.currentSessionID ?? "nil", privacy: .public)")
            return
        }

        guard let todosRaw = props["todos"] else {
            Logger.debug.warning("[TODO] no 'todos' key in props. Available keys: \(Array(props.keys).joined(separator: ", "), privacy: .public)")
            return
        }

        Logger.debug.info("[TODO] todosRaw type: \(String(describing: type(of: todosRaw)), privacy: .public)")

        do {
            let data = try JSONSerialization.data(withJSONObject: todosRaw)
            let todos = try JSONDecoder().decode([OCTodo].self, from: data)
            delegate.todos = todos
            Logger.debug.info("[TODO] decoded \(todos.count) todos")
        } catch {
            Logger.debug.error("[TODO] decode failed: \(error.localizedDescription, privacy: .public)")
            // Try logging raw JSON for inspection
            if let data = try? JSONSerialization.data(withJSONObject: todosRaw, options: .prettyPrinted),
               let str = String(data: data, encoding: .utf8) {
                Logger.debug.info("[TODO] raw JSON: \(str.prefix(500), privacy: .public)")
            }
        }
    }

    // MARK: - Tool Part Handling

    private func handleToolPartUpdate(_ part: OCPart, delegate: SSEEventHandlerDelegate) {
        guard let toolName = part.tool,
              let state = part.state else { return }

        Logger.sseHandler.debug("tool update: \(toolName, privacy: .public), status=\(String(describing: state.status), privacy: .public)")

        let category = ToolCategory.from(toolName: toolName)
        trackToolStatusIfNeeded(partID: part.id, toolName: toolName, category: category, status: state.status)

        switch state.status {
        case .pending, .running:
            let label = ToolLabelFormatter.label(toolName: toolName, state: state)
            delegate.currentActivity?.currentLabel = label

            // Add step if new
            if !(delegate.currentActivity?.steps.contains(where: { $0.label == label && $0.type == .toolCall }) ?? false) {
                delegate.currentActivity?.steps.append(ActivityStep(
                    type: .toolCall,
                    label: label,
                    detail: ToolLabelFormatter.detail(state: state),
                    toolCategory: category
                ))
                liveActivityTracker.pushIntent(label, icon: category.iconName)
            }

        case .completed:
            if let activity = delegate.currentActivity {
                let label = ToolLabelFormatter.label(toolName: toolName, state: state)
                if let index = activity.steps.lastIndex(where: { $0.label == label || $0.type == .toolCall && !$0.isCompleted }) {
                    activity.steps[index].isCompleted = true
                } else {
                    activity.steps.append(ActivityStep(
                        type: .toolResult,
                        label: state.title ?? "Completed \(toolName)",
                        detail: "",
                        toolCategory: category,
                        isCompleted: true
                    ))
                }
                activity.currentLabel = "Thinking..."
                haptics.playStepCompletion()
            }

            // Update Live Activity cost if available
            let lastAssistant = delegate.pendingAssistantMessage
                ?? delegate.messages.last(where: { $0.role == .assistant })
            if let cost = lastAssistant?.cost {
                liveActivityTracker.updateCost(String(format: "$%.3f", cost))
            }

        case .error:
            delegate.currentActivity?.currentLabel = "Error: \(toolName)"

        case .unknown:
            break // Ignore unknown tool statuses
        }
    }

    private func trackToolStatusIfNeeded(partID: String, toolName: String, category: ToolCategory, status: OCToolStatus) {
        let previousStatus = lastToolStatusByPartID[partID]
        guard previousStatus != status else { return }

        lastToolStatusByPartID[partID] = status
    }
}
