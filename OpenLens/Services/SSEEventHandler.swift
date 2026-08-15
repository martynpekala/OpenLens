import Foundation
import UIKit
import os

// MARK: - Delegate Protocol

/// Delegate that the SSEEventHandler calls to mutate chat state on the UI actor.
@MainActor
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
    var hiddenTodoCount: Int { get set }

    func finishLoading()
    func beginExternalResponse()
    /// Applies an explicit server-side message deletion. Implementations can
    /// cancel deferred finalization before mutating their visible history.
    func removeAssistantMessage(messageID: String)

    /// Returns true when a message event belongs to a locally stopped turn and
    /// should not reopen streaming state.
    func shouldIgnoreAssistantEvent(sessionID: String, messageID: String) -> Bool

    /// Returns true when a busy status is stale for a locally stopped turn.
    func shouldIgnoreBusyStatus(sessionID: String) -> Bool

    /// Remaps an optimistic pending assistant ID without dropping its streaming
    /// projections or queued chunks. Returns true when a remap occurred.
    func remapStreamingMessageID(from oldID: String, to newID: String) -> Bool

    /// Append streamed text to the pending assistant message (not shown in chat yet).
    func appendStreamingText(messageID: String, text: String, chunks: [String])

    /// Append text to one ordered text-part slot. A `nil` part ID keeps the
    /// compatibility fallback for servers that do not identify text deltas.
    func appendStreamingText(messageID: String, partID: String?, text: String, chunks: [String])

    /// Discard any buffered streaming deltas for a message.
    /// Called when a `message.part.updated` snapshot supersedes pending deltas.
    func clearStreamingBuffer(messageID: String)

    /// Authoritative text snapshots clear the live projection in O(1), then
    /// feed their already-worker-chunked payload through the normal bounded
    /// stream buffer. This prevents one 100 KB snapshot from becoming a single
    /// MainActor update.
    func replaceStreamingText(messageID: String, text: String, chunks: [String])

    /// Replaces one authoritative text snapshot without invalidating other
    /// text slots in the same assistant response.
    func replaceStreamingText(messageID: String, partID: String?, text: String, chunks: [String])

    /// Buffer reasoning independently from final answer text. This keeps a
    /// burst of thinking deltas from rebuilding the parts array on every event.
    func appendStreamingReasoning(messageID: String, partID: String, text: String, chunks: [String])

    /// Discard buffered reasoning when an authoritative part snapshot arrives.
    func clearStreamingReasoningBuffer(messageID: String, partID: String)

    /// Same bounded replacement path for reasoning snapshots.
    func replaceStreamingReasoning(messageID: String, partID: String, text: String, chunks: [String])

    /// A server part changed the rendered message layout (for example a task
    /// card appeared or completed). The chat can coalesce an auto-follow update.
    func messageLayoutDidChange()

    /// A streaming text projection changed without adding/removing a timeline
    /// row. This requests auto-follow without rematerializing the timeline.
    func streamingContentDidChange()

    /// Offline producers (demo and replay) do not have URLSession transport
    /// backpressure. They call this after each event so the bounded render
    /// mailbox can drain before another immediate burst arrives.
    func waitForStreamingRenderCapacity() async -> Bool

    /// Called when a new question is presented so the VM can start a timeout timer.
    func questionDidPresent()
}

extension SSEEventHandlerDelegate {
    func removeAssistantMessage(messageID: String) {
        if pendingAssistantMessage?.id == messageID {
            pendingAssistantMessage = nil
        }
        messages.removeAll { $0.id == messageID }
    }
    func messageLayoutDidChange() {}
    func streamingContentDidChange() {}
    func appendStreamingText(messageID: String, text: String, chunks: [String]) {}
    func appendStreamingText(messageID: String, partID: String?, text: String, chunks: [String]) {
        appendStreamingText(messageID: messageID, text: text, chunks: chunks)
    }
    func replaceStreamingText(messageID: String, text: String, chunks: [String]) {}
    func replaceStreamingText(messageID: String, partID: String?, text: String, chunks: [String]) {
        replaceStreamingText(messageID: messageID, text: text, chunks: chunks)
    }
    func appendStreamingReasoning(messageID: String, partID: String, text: String, chunks: [String]) {}
    func replaceStreamingReasoning(messageID: String, partID: String, text: String, chunks: [String]) {}
    func clearStreamingReasoningBuffer(messageID: String, partID: String) {}
    func remapStreamingMessageID(from oldID: String, to newID: String) -> Bool { false }
    func waitForStreamingRenderCapacity() async -> Bool { !Task.isCancelled }
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
    private var relatedSessionIDsByParentSessionID: [String: Set<String>] = [:]

    init(haptics: HapticController, liveActivityTracker: LiveActivityTracker) {
        self.haptics = haptics
        self.liveActivityTracker = liveActivityTracker
    }

    // MARK: - Main Dispatch

    /// The only production entry point. It deliberately accepts an already
    /// prepared event: decoding a large part snapshot or message metadata on
    /// MainActor would regress the streaming-hang guarantee. Live SSE prepares
    /// events on `SSEClient`'s worker, while replay does so in a detached task.
    func handleInboundEvent(_ inboundEvent: SSEInboundEvent) {
        switch inboundEvent {
        case .raw(let event):
            handleRawEvent(event)

        case .cold(let event, _):
            handleColdEvent(event)

        case .messageUpdated(let update, _):
            handleMessageUpdated(update)

        case .partUpdated(let part, let textChunks, let questionPayload, _):
            handlePartUpdated(
                part,
                textChunks: textChunks,
                questionPayload: questionPayload
            )

        case .textDelta(let delta, _):
            handleTextDelta(delta)
        }
    }

    /// Keeps replay producers from outrunning ChatClient's bounded render
    /// mailbox. Live SSE uses transport suspension instead, so this remains a
    /// no-op unless the owning delegate reports render pressure.
    func waitForStreamingRenderCapacity() async -> Bool {
        guard let delegate else { return !Task.isCancelled }
        return await delegate.waitForStreamingRenderCapacity()
    }

    private func handleColdEvent(_ event: SSEColdEvent) {
        switch event {
        case .sessionStatus(let update):
            if let update {
                handleSessionStatus(update)
            }

        case .sessionUpdated(let update):
            if let update {
                handleSessionUpdated(update)
            }

        case .permissionAsked(let request):
            if let request {
                handlePermissionAsked(request)
            }

        case .questionAsked(let request):
            if let request {
                handleQuestionAsked(request)
            }

        case .todoUpdated(let update):
            if let update {
                handleTodoUpdated(update)
            }
        }
    }

    private func handleRawEvent(_ event: OCEvent) {
        switch event.type {
        case "server.connected", "server.heartbeat":
            connectionManager?.receivedHeartbeat()

        case "session.status", "session.updated", "permission.asked", "permission.v2.asked",
             "question.asked", "todo.updated", "message.updated":
            // Valid message updates are prepared before MainActor. An invalid
            // payload cannot affect UI state, so avoid retrying its potentially
            // expensive model decode on MainActor.
            break

        // Valid hot events are decoded before they reach MainActor. Invalid
        // payloads deliberately remain no-ops, matching the previous guards.
        case "message.part.updated", "message.part.delta":
            break

        case "message.part.removed":
            handlePartRemoved(event)

        case "message.removed":
            handleMessageRemoved(event)

        case "question.replied", "question.rejected":
            // These confirm the question was answered/dismissed; clear UI if still showing
            handleQuestionDismissed(event)

        default:
            Logger.debug.debug("[SSE] unhandled event: \(event.type, privacy: .public)")
            break
        }
    }

    // MARK: - Event Handlers

    private func handleSessionStatus(_ update: SSESessionStatusUpdate) {
        guard let delegate else { return }
        guard update.sessionID == delegate.currentSessionID else { return }

        if update.status.type == .busy,
           delegate.shouldIgnoreBusyStatus(sessionID: update.sessionID) {
            return
        }

        delegate.sessionStatus = update.status

        if update.status.type == .idle {
            lastToolStatusByPartID.removeAll()
            delegate.finishLoading()
        } else if update.status.type == .busy {
            lastToolStatusByPartID.removeAll()
            if !delegate.isLoading {
                delegate.beginExternalResponse()

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

    private func handleMessageUpdated(_ update: SSEMessageUpdate) {
        guard let delegate else { return }
        guard update.sessionID == delegate.currentSessionID else { return }

        let sessionID = update.sessionID
        let messageID = update.messageID
        let role = update.role

        if role == "assistant",
           delegate.shouldIgnoreAssistantEvent(sessionID: sessionID, messageID: messageID) {
            return
        }

        if role == "user" {
            // User message confirmed by server — already shown optimistically
            return
        }

        if role == "assistant" {
            let cost = update.cost
            let serverModelID = update.modelID
            let serverProviderID = update.providerID
            let finish = update.finish
            let tokens = update.tokens

            if let existing = delegate.pendingAssistantMessage {
                // Update the pending message in-place (not visible yet).
                if existing.id != messageID {
                    if delegate.remapStreamingMessageID(from: existing.id, to: messageID) {
                        delegate.messageLayoutDidChange()
                    } else {
                        // Compatibility fallback for lightweight delegates used
                        // by previews/tests that do not own a stream buffer.
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
                    }
                }

                existing.cost = cost
                if let tokens { existing.tokens = tokens }
                if let mid = serverModelID { existing.modelID = mid }
                if let pid = serverProviderID { existing.providerID = pid }
                existing.finish = finish

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
                    delegate.beginExternalResponse()
                }
            }
        }
    }

    private func handlePartUpdated(
        _ part: OCPart,
        textChunks: [String]?,
        questionPayload: PreparedQuestionToolPayload?
    ) {
        guard let delegate,
              part.sessionID == delegate.currentSessionID,
              !delegate.shouldIgnoreAssistantEvent(sessionID: part.sessionID, messageID: part.messageID),
              let message = assistantMessage(withID: part.messageID, delegate: delegate)
        else { return }

        let requiresTimelineRebuild: Bool
        if part.type == .reasoning, message.isStreaming {
            // Keep the canonical server snapshot, but leave its potentially
            // large pre-chunked payload for ChatClient's bounded flush path.
            requiresTimelineRebuild = message.applyPartUpdate(
                part,
                textChunks: [],
                questionPayload: questionPayload
            )
        } else {
            requiresTimelineRebuild = message.applyPartUpdate(
                part,
                textChunks: textChunks,
                questionPayload: questionPayload
            )
        }
        switch part.type {
        case .text:
            // A server can retract a previously visible text slot by marking
            // it ignored/synthetic. Unlike a normal delta, that changes the
            // flattened transcript and must be published immediately.
            if requiresTimelineRebuild {
                delegate.messageLayoutDidChange()
            }
            if let text = part.renderableText {
                // Full snapshots supersede queued deltas, but a 100 KB snapshot
                // must not synchronously walk every chunk on MainActor.
                if message.isStreaming {
                    delegate.replaceStreamingText(
                        messageID: part.messageID,
                        partID: part.id,
                        text: text,
                        chunks: textChunks ?? []
                    )
                } else {
                    delegate.messageLayoutDidChange()
                }
                haptics.playFirstResponseIfNeeded()
            }

        case .tool:
            handleToolPartUpdate(part, delegate: delegate)
            if requiresTimelineRebuild {
                delegate.messageLayoutDidChange()
            } else {
                // `AssistantSegmentTimelineRow` observes this single segment
                // directly. Rebuilding the complete flattened timeline for a
                // running → completed status change is unnecessary work.
                delegate.streamingContentDidChange()
            }

        case .reasoning:
            if let text = part.text {
                delegate.replaceStreamingReasoning(
                    messageID: part.messageID,
                    partID: part.id,
                    text: text,
                    chunks: textChunks ?? []
                )
                updateReasoningActivity(text: text, delegate: delegate)
            }
            if requiresTimelineRebuild {
                delegate.messageLayoutDidChange()
            } else {
                delegate.streamingContentDidChange()
            }

        case .stepFinish:
            delegate.currentActivity?.completeMostRecentIncompleteStep()
            if requiresTimelineRebuild {
                delegate.messageLayoutDidChange()
            } else {
                delegate.streamingContentDidChange()
            }

        case .agent,
             .subtask:
            // Like tool rows, an in-place subagent status change is observed
            // by its stable timeline row. Rebuild only when a row was actually
            // inserted or removed.
            if requiresTimelineRebuild {
                delegate.messageLayoutDidChange()
            } else {
                delegate.streamingContentDidChange()
            }

        case .file,
             .stepStart,
             .snapshot,
             .patch,
             .retry,
             .compaction,
             .unknown:
            // These protocol records are dropped from a streaming transcript
            // because they have no timeline representation. Keep auto-follow
            // responsive without rebuilding the flattened list for each one.
            if requiresTimelineRebuild {
                delegate.messageLayoutDidChange()
            } else {
                delegate.streamingContentDidChange()
            }
        }
    }

    private func handleTextDelta(_ delta: SSETextDelta) {
        guard let delegate,
              delta.sessionID == delegate.currentSessionID,
              !delegate.shouldIgnoreAssistantEvent(sessionID: delta.sessionID, messageID: delta.messageID)
        else { return }

        if let partID = delta.partID,
           let msg = assistantMessage(withID: delta.messageID, delegate: delegate),
           let partType = msg.partType(withID: partID) {
            switch partType {
            case .reasoning:
                delegate.appendStreamingReasoning(
                    messageID: delta.messageID,
                    partID: partID,
                    text: delta.text,
                    chunks: delta.textChunks
                )
                updateReasoningActivity(text: delta.text, delegate: delegate)
                return

            case .text:
                delegate.appendStreamingText(
                    messageID: delta.messageID,
                    partID: partID,
                    text: delta.text,
                    chunks: delta.textChunks
                )
                haptics.playFirstResponseIfNeeded()
                return

            case .tool,
                 .file,
                 .stepStart,
                 .stepFinish,
                 .snapshot,
                 .patch,
                 .retry,
                 .compaction,
                 .agent,
                 .subtask,
                 .unknown:
                return
            }
        } else if let partID = delta.partID,
                  let message = assistantMessage(withID: delta.messageID, delegate: delegate) {
            // A delta can arrive one main-delivery batch before its snapshot.
            // Keep a lightweight ordered placeholder instead of falling back
            // to the global tail, which would put it after later tool rows.
            message.registerStreamingTextPart(
                id: partID,
                sessionID: delta.sessionID,
                messageID: delta.messageID
            )
            delegate.appendStreamingText(
                messageID: delta.messageID,
                partID: partID,
                text: delta.text,
                chunks: delta.textChunks
            )
            haptics.playFirstResponseIfNeeded()
            return
        }

        delegate.appendStreamingText(
            messageID: delta.messageID,
            text: delta.text,
            chunks: delta.textChunks
        )
        haptics.playFirstResponseIfNeeded()
    }

    private func assistantMessage(withID messageID: String, delegate: SSEEventHandlerDelegate) -> ChatMessage? {
        if let pending = delegate.pendingAssistantMessage, pending.id == messageID {
            return pending
        }
        return delegate.messages.first(where: { $0.id == messageID })
    }

    private func updateReasoningActivity(text: String, delegate: SSEEventHandlerDelegate) {
        // The activity card is only a transient status surface; keeping a
        // bounded preview avoids copying/layouting a growing reasoning transcript.
        let preview = String(text.prefix(280))
        delegate.currentActivity?.thinkingText = preview
        if liveActivityTracker.subject == nil, !preview.isEmpty {
            let firstLine = preview.split(separator: "\n", maxSplits: 1).first ?? ""
            liveActivityTracker.updateSubject(String(firstLine.prefix(60)))
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
        guard let msg else { return }

        if msg.removePart(id: partID) {
            delegate.messageLayoutDidChange()
        }
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

        delegate.removeAssistantMessage(messageID: messageID)
    }

    private func handleSessionUpdated(_ incoming: SSESessionUpdate) {
        guard let delegate else { return }
        guard incoming.sessionID == delegate.currentSessionID else { return }

        if let currentSession = delegate.currentSession,
           let update = incoming.update {
            delegate.currentSession = mergeSessionUpdate(
                update,
                into: currentSession,
                fields: incoming.presentFields
            )
        }

        if let title = incoming.title {
            liveActivityTracker.updateSubject(title)
        }
    }

    private func mergeSessionUpdate(
        _ update: OCSession,
        into currentSession: OCSession,
        fields: Set<String>
    ) -> OCSession {
        func includes(_ field: String) -> Bool {
            fields.contains(field)
        }

        return OCSession(
            id: update.id,
            projectID: includes("projectID") ? update.projectID : currentSession.projectID,
            directory: includes("directory") ? update.directory : currentSession.directory,
            parentID: includes("parentID") ? update.parentID : currentSession.parentID,
            title: includes("title") ? update.title : currentSession.title,
            version: includes("version") ? update.version : currentSession.version,
            time: includes("time") ? update.time : currentSession.time,
            share: includes("share") ? update.share : currentSession.share
        )
    }

    private func handlePermissionAsked(_ incoming: SSEPermissionAsked) {
        guard let delegate else { return }
        guard let permission = incoming.request else { return }

        if !sessionBelongsToCurrentConversation(incoming.sessionID, delegate: delegate) {
            return
        }

        delegate.pendingPermission = permission
        delegate.showPermissionAlert = true

        haptics.playWarning()
    }

    private func handleQuestionAsked(_ incoming: SSEQuestionAsked) {
        guard let delegate else { return }

        if !sessionBelongsToCurrentConversation(incoming.sessionID, delegate: delegate) {
            return
        }

        if let requestID = incoming.rejectedRequestID {
            Logger.sseHandler.warning("Rejecting oversized interactive question \(requestID, privacy: .public)")
            rejectQuestion(requestID)
            return
        }

        guard let question = incoming.request else { return }

        // If a question is already pending, reject it before replacing
        if let existing = delegate.pendingQuestion {
            Logger.sseHandler.warning("Overlapping question: rejecting \(existing.id, privacy: .public) in favor of \(question.id, privacy: .public)")
            rejectQuestion(existing.id)
        }
        delegate.pendingQuestion = question
        delegate.showQuestionSheet = true
        delegate.questionDidPresent()

        haptics.playWarning()
    }

    private func rejectQuestion(_ requestID: String) {
        guard let client = connectionClient else { return }
        Task {
            let _ = try? await client.rejectQuestion(requestID: requestID)
        }
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

    private func handleTodoUpdated(_ incoming: SSETodoUpdated) {
        guard let delegate else {
            Logger.debug.warning("[TODO] no delegate")
            return
        }

        guard let sessionID = incoming.sessionID else {
            Logger.debug.warning("[TODO] no sessionID in update")
            return
        }

        guard sessionID == delegate.currentSessionID else {
            Logger.debug.info("[TODO] sessionID mismatch: got \(sessionID, privacy: .public), expected \(delegate.currentSessionID ?? "nil", privacy: .public)")
            return
        }

        guard let todos = incoming.todos else {
            Logger.debug.warning("[TODO] no decodable todos in update")
            return
        }

        delegate.todos = todos
        delegate.hiddenTodoCount = incoming.hiddenTodoCount
        Logger.debug.info("[TODO] decoded \(todos.count) todos")
    }

    // MARK: - Tool Part Handling

    private func handleToolPartUpdate(_ part: OCPart, delegate: SSEEventHandlerDelegate) {
        guard let toolName = part.tool,
              let state = part.state else { return }

        registerRelatedSessionIfNeeded(from: state, parentSessionID: part.sessionID, delegate: delegate)

        Logger.sseHandler.debug("tool update: \(toolName, privacy: .public), status=\(String(describing: state.status), privacy: .public)")

        let category = ToolCategory.from(toolName: toolName)
        let statusChanged = trackToolStatusIfNeeded(partID: part.id, status: state.status)
        // The part itself has already been updated by the caller, so repeated
        // snapshots can still refresh its visible detail. Avoid repeating the
        // activity transition and haptic side effects for the same status.
        guard statusChanged else { return }

        switch state.status {
        case .pending, .running:
            let label = ToolLabelFormatter.label(toolName: toolName, state: state)
            delegate.currentActivity?.currentLabel = label

            if let activity = delegate.currentActivity,
               activity.recordToolCallIfNeeded(
                   label: label,
                   detail: ToolLabelFormatter.detail(state: state),
                   toolCategory: category
               ) {
                liveActivityTracker.pushIntent(label, icon: category.iconName)
            }

        case .completed:
            if let activity = delegate.currentActivity {
                let label = ToolLabelFormatter.label(toolName: toolName, state: state)
                if !activity.completeToolCall(matching: label) {
                    // Keep the completion activity on the same bounded
                    // display path as running tools. Server titles and
                    // tool identifiers are untrusted and can be huge.
                    activity.recordCompletedToolResult(label: label, toolCategory: category)
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
            // Do not interpolate the raw server tool name into an observed UI
            // property. `label` bounds both the name and optional title.
            let label = ToolLabelFormatter.label(toolName: toolName, state: state)
            delegate.currentActivity?.currentLabel = "Error: \(label)"

        case .unknown:
            break // Ignore unknown tool statuses
        }
    }

    @discardableResult
    private func trackToolStatusIfNeeded(partID: String, status: OCToolStatus) -> Bool {
        let previousStatus = lastToolStatusByPartID[partID]
        guard previousStatus != status else { return false }

        lastToolStatusByPartID[partID] = status
        return true
    }

    private func sessionBelongsToCurrentConversation(
        _ sessionID: String?,
        delegate: SSEEventHandlerDelegate
    ) -> Bool {
        guard let sessionID else { return true }
        guard let currentSessionID = delegate.currentSessionID else { return true }

        return sessionID == currentSessionID
            || relatedSessionIDsByParentSessionID[currentSessionID]?.contains(sessionID) == true
    }

    private func registerRelatedSessionIfNeeded(
        from state: OCToolState,
        parentSessionID: String,
        delegate: SSEEventHandlerDelegate
    ) {
        guard parentSessionID == delegate.currentSessionID,
              let relatedSessionID = relatedSessionID(from: state),
              relatedSessionID != parentSessionID else { return }

        relatedSessionIDsByParentSessionID[parentSessionID, default: []].insert(relatedSessionID)
    }

    private func relatedSessionID(from state: OCToolState) -> String? {
        let metadata = state.metadata ?? [:]

        return stringValue(for: "sessionId", in: metadata)
            ?? stringValue(for: "sessionID", in: metadata)
            ?? stringValue(for: "session_id", in: metadata)
    }

    private func stringValue(for key: String, in metadata: [String: AnyCodable]) -> String? {
        (metadata[key]?.value as? String)?.nilIfBlank
    }
}
