import Foundation
import os

func isTerminalSSEHTTPStatus(_ statusCode: Int) -> Bool {
    statusCode == 401 || statusCode == 403
}

/// Metadata from `message.updated` decoded before it reaches MainActor. These
/// updates are usually small, but OpenCode is free to attach a large summary
/// or model payload, so their JSON work belongs with the SSE reducer too.
nonisolated struct SSEMessageUpdate {
    let sessionID: String
    let messageID: String
    let role: String?
    let cost: Double?
    let tokens: OCTokenUsage?
    let modelID: String?
    let providerID: String?
    let finish: String?

    init?(event: OCEvent) {
        guard let properties = event.properties?.value as? [String: Any],
              let info = properties["info"] as? [String: Any],
              let sessionID = info["sessionID"] as? String,
              let messageID = info["id"] as? String,
              StreamDisplayValue.fitsIdentifier(sessionID),
              StreamDisplayValue.fitsIdentifier(messageID)
        else {
            return nil
        }

        let decodedInfo: OCMessage?
        if let data = try? JSONSerialization.data(withJSONObject: info) {
            decodedInfo = try? JSONDecoder().decode(OCMessage.self, from: data)
        } else {
            decodedInfo = nil
        }

        self.sessionID = sessionID
        self.messageID = messageID
        self.role = StreamDisplayValue.preview(info["role"] as? String, maximumBytes: 64)
        self.cost = decodedInfo?.cost ?? info["cost"] as? Double
        self.tokens = decodedInfo?.tokens
        self.modelID = StreamDisplayValue.preview(decodedInfo?.modelID ?? info["modelID"] as? String, maximumBytes: 160)
        self.providerID = StreamDisplayValue.preview(decodedInfo?.providerID ?? info["providerID"] as? String, maximumBytes: 160)
        self.finish = StreamDisplayValue.preview(decodedInfo?.finish ?? info["finish"] as? String, maximumBytes: 80)
    }
}

/// Lightweight cold-event payloads prepared on the SSE worker. They keep
/// infrequent but potentially large JSON documents (session, permission,
/// question and todo updates) out of `SSEEventHandler`'s MainActor path.
nonisolated struct SSESessionStatusUpdate {
    let sessionID: String
    let status: OCSessionStatus

    init?(event: OCEvent) {
        guard let properties = event.properties?.value as? [String: Any],
              let sessionID = properties["sessionID"] as? String,
              let statusDictionary = properties["status"] as? [String: Any],
              let rawType = statusDictionary["type"] as? String,
              StreamDisplayValue.fitsIdentifier(sessionID)
        else {
            return nil
        }

        self.sessionID = sessionID
        self.status = OCSessionStatus(
            type: OCSessionStatusType(rawValue: rawType) ?? .idle,
            attempt: statusDictionary["attempt"] as? Int,
            message: StreamDisplayValue.preview(statusDictionary["message"] as? String, maximumBytes: 512),
            next: statusDictionary["next"] as? Int
        )
    }
}

nonisolated struct SSESessionUpdate {
    let sessionID: String
    let presentFields: Set<String>
    let update: OCSession?
    let title: String?

    init?(event: OCEvent) {
        guard let properties = event.properties?.value as? [String: Any],
              let info = properties["info"] as? [String: Any],
              let sessionID = info["id"] as? String,
              StreamDisplayValue.fitsIdentifier(sessionID)
        else {
            return nil
        }

        self.sessionID = sessionID
        self.presentFields = Set(info.keys).intersection(Set([
            "projectID", "directory", "parentID", "title", "version", "time", "share",
        ]))
        self.update = SSEPreparedPayload.decode(OCSession.self, from: info).map(Self.boundedSession)
        self.title = StreamDisplayValue.preview(info["title"] as? String, maximumBytes: 512)
    }

    private static func boundedSession(_ session: OCSession) -> OCSession {
        OCSession(
            id: session.id,
            projectID: StreamDisplayValue.preview(session.projectID, maximumBytes: 512),
            directory: StreamDisplayValue.preview(session.directory, maximumBytes: 1_024),
            parentID: StreamDisplayValue.fitsIdentifier(session.parentID) ? session.parentID : nil,
            title: StreamDisplayValue.preview(session.title, maximumBytes: 512),
            version: StreamDisplayValue.preview(session.version, maximumBytes: 160),
            time: session.time,
            share: session.share.map {
                OCShareInfo(url: StreamDisplayValue.preview($0.url, maximumBytes: 2_048))
            }
        )
    }
}

nonisolated struct SSEPermissionAsked {
    let sessionID: String?
    let request: OCPermissionRequest?

    init?(event: OCEvent) {
        guard let properties = event.properties?.value as? [String: Any] else {
            return nil
        }

        let rawRequest: OCPermissionRequest
        if let decoded = SSEPreparedPayload.decode(OCPermissionRequest.self, from: properties) {
            rawRequest = decoded
        } else if let id = properties["id"] as? String {
            rawRequest = OCPermissionRequest(
                id: id,
                sessionID: properties["sessionID"] as? String,
                permission: properties["permission"] as? String,
                action: properties["action"] as? String,
                patterns: properties["patterns"] as? [String] ?? [],
                resources: properties["resources"] as? [String] ?? [],
                input: nil,
                description: properties["description"] as? String,
                title: properties["title"] as? String
            )
        } else {
            self.request = nil
            self.sessionID = nil
            return
        }
        self.request = PermissionRequestDisplaySafety.sanitize(rawRequest)
        self.sessionID = self.request?.sessionID
    }
}

nonisolated struct SSEQuestionAsked {
    let sessionID: String?
    let request: OCQuestionRequest?
    /// A decoded question that cannot be safely presented. The handler rejects
    /// it only after confirming that it belongs to the current conversation.
    let rejectedRequestID: String?

    init?(event: OCEvent) {
        guard let properties = event.properties?.value as? [String: Any] else {
            return nil
        }

        let decodedRequest = SSEPreparedPayload.decode(OCQuestionRequest.self, from: properties)
        let candidateSessionID = decodedRequest?.sessionID ?? (properties["sessionID"] as? String)
        let candidateRequestID = decodedRequest?.id ?? (properties["id"] as? String)

        self.sessionID = candidateSessionID.flatMap {
            InteractiveQuestionSafety.fitsIdentifier($0) ? $0 : nil
        }

        guard let decodedRequest else {
            self.request = nil
            self.rejectedRequestID = nil
            return
        }

        if InteractiveQuestionSafety.accepts(decodedRequest) {
            self.request = decodedRequest
            self.rejectedRequestID = nil
        } else {
            self.request = nil
            self.rejectedRequestID = candidateRequestID.flatMap {
                InteractiveQuestionSafety.fitsIdentifier($0) ? $0 : nil
            }
        }
    }
}

nonisolated struct SSETodoUpdated {
    let sessionID: String?
    let todos: [OCTodo]?
    let hiddenTodoCount: Int

    init?(event: OCEvent) {
        guard let properties = event.properties?.value as? [String: Any] else {
            return nil
        }

        self.sessionID = (properties["sessionID"] as? String).flatMap {
            StreamDisplayValue.fitsIdentifier($0) ? $0 : nil
        }
        if let todosRaw = properties["todos"] {
            if let decodedTodos = SSEPreparedPayload.decode([OCTodo].self, from: todosRaw) {
                let snapshot = TodoDisplaySafety.prepare(decodedTodos)
                self.todos = snapshot.todos
                self.hiddenTodoCount = snapshot.hiddenCount
            } else {
                self.todos = nil
                self.hiddenTodoCount = 0
            }
        } else {
            self.todos = nil
            self.hiddenTodoCount = 0
        }
    }
}

private enum SSEPreparedPayload {
    nonisolated static func decode<Value: Decodable>(_ type: Value.Type, from value: Any) -> Value? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value)
        else {
            return nil
        }
        return try? JSONDecoder().decode(Value.self, from: data)
    }
}

nonisolated enum SSEColdEvent {
    case sessionStatus(SSESessionStatusUpdate?)
    case sessionUpdated(SSESessionUpdate?)
    case permissionAsked(SSEPermissionAsked?)
    case questionAsked(SSEQuestionAsked?)
    case todoUpdated(SSETodoUpdated?)
}

/// The small, typed subset of events that is hot during a streamed response.
/// It is constructed on SSEClient's private serial queue, before the main queue
/// is ever involved. The original raw event is retained only when a legacy
/// callback or recording explicitly needs it; otherwise keeping both the typed
/// projection and the decoded `OCEvent` doubles the payload held behind a busy
/// MainActor.
nonisolated enum SSEInboundEvent {
    case raw(OCEvent)
    case cold(SSEColdEvent, rawEvent: OCEvent?)
    case messageUpdated(SSEMessageUpdate, rawEvent: OCEvent?)
    case partUpdated(
        part: OCPart,
        textChunks: [String]?,
        questionPayload: PreparedQuestionToolPayload?,
        rawEvent: OCEvent?
    )
    case textDelta(SSETextDelta, rawEvent: OCEvent?)

    /// `nil` means the typed projection was intentionally delivered without a
    /// retained original event. Raw/unknown events always keep their payload.
    var rawEvent: OCEvent? {
        switch self {
        case .raw(let event):
            event
        case .cold(_, let rawEvent),
             .messageUpdated(_, let rawEvent),
             .partUpdated(_, _, _, let rawEvent),
             .textDelta(_, let rawEvent):
            rawEvent
        }
    }

    /// The default preserves the existing standalone/replay API. Live SSE
    /// explicitly passes `false` unless recording or `onEvent` is active.
    nonisolated static func prepare(
        _ event: OCEvent,
        retainingRawEvent: Bool = true
    ) -> SSEInboundEvent? {
        let rawEvent = retainingRawEvent ? event : nil

        switch event.type {
        case "session.status":
            return .cold(.sessionStatus(SSESessionStatusUpdate(event: event)), rawEvent: rawEvent)

        case "session.updated":
            return .cold(.sessionUpdated(SSESessionUpdate(event: event)), rawEvent: rawEvent)

        case "permission.asked", "permission.v2.asked":
            return .cold(.permissionAsked(SSEPermissionAsked(event: event)), rawEvent: rawEvent)

        case "question.asked":
            return .cold(.questionAsked(SSEQuestionAsked(event: event)), rawEvent: rawEvent)

        case "todo.updated":
            return .cold(.todoUpdated(SSETodoUpdated(event: event)), rawEvent: rawEvent)

        case "message.updated":
            guard let update = SSEMessageUpdate(event: event) else { return nil }
            return .messageUpdated(update, rawEvent: rawEvent)

        case "message.part.updated":
            guard let properties = event.properties?.value as? [String: Any],
                  let partDictionary = properties["part"] as? [String: Any],
                  let partData = try? JSONSerialization.data(withJSONObject: partDictionary),
                  let part = try? JSONDecoder().decode(OCPart.self, from: partData),
                  StreamDisplayValue.fitsIdentifier(part.id),
                  StreamDisplayValue.fitsIdentifier(part.sessionID),
                  StreamDisplayValue.fitsIdentifier(part.messageID) else {
                return nil
            }
            let questionPayload = PreparedQuestionToolPayload.prepare(from: part)
            let deliveryPart = questionPayload.map { _ in
                PreparedQuestionToolPayload.sanitizedPart(from: part)
            } ?? StreamToolPartSafety.sanitize(part)
            let text = deliveryPart.type == .reasoning ? deliveryPart.text : deliveryPart.renderableText
            let textChunks = text.map(SSETextChunker.chunks)
            return .partUpdated(
                part: deliveryPart,
                textChunks: textChunks,
                questionPayload: questionPayload,
                rawEvent: rawEvent
            )

        case "message.part.delta":
            guard let delta = SSETextDelta(event: event) else { return nil }
            return .textDelta(delta, rawEvent: rawEvent)

        default:
            return nil
        }
    }
}

nonisolated struct SSETextDelta {
    let sessionID: String
    let messageID: String
    let partID: String?
    let field: String
    let text: String
    let textChunks: [String]

    init(sessionID: String, messageID: String, partID: String?, field: String, text: String) {
        self.sessionID = sessionID
        self.messageID = messageID
        self.partID = partID
        self.field = field
        self.text = text
        self.textChunks = SSETextChunker.chunks(text)
    }

    init?(event: OCEvent) {
        guard let properties = event.properties?.value as? [String: Any],
              let sessionID = properties["sessionID"] as? String,
              let messageID = properties["messageID"] as? String,
              let field = properties["field"] as? String,
              field == "text",
              let text = properties["delta"] as? String,
              StreamDisplayValue.fitsIdentifier(sessionID),
              StreamDisplayValue.fitsIdentifier(messageID)
        else {
            return nil
        }

        let partID = properties["partID"] as? String ?? properties["partId"] as? String
        guard partID.map(StreamDisplayValue.fitsIdentifier) ?? true else { return nil }

        self.sessionID = sessionID
        self.messageID = messageID
        self.partID = partID
        self.field = field
        self.text = text
        self.textChunks = SSETextChunker.chunks(text)
    }

    var asRawEvent: OCEvent {
        var properties: [String: Any] = [
            "sessionID": sessionID,
            "messageID": messageID,
            "field": field,
            "delta": text,
        ]
        if let partID {
            properties["partID"] = partID
        }
        return OCEvent(type: "message.part.delta", properties: AnyCodable(properties))
    }
}

/// Splits potentially huge network payloads on the SSE worker. The projection
/// still owns the final boundaries, but the UI actor only joins small pieces.
private enum SSETextChunker {
    nonisolated static func chunks(_ text: String) -> [String] {
        let maximumChunkLength = 2_200
        guard text.count > maximumChunkLength else { return [text] }

        var chunks: [String] = []
        var start = text.startIndex

        while start < text.endIndex {
            let hardEnd = text.index(start, offsetBy: maximumChunkLength, limitedBy: text.endIndex) ?? text.endIndex
            if hardEnd == text.endIndex {
                chunks.append(String(text[start..<text.endIndex]))
                break
            }

            let segment = text[start..<hardEnd]
            let end = segment.lastIndex(of: "\n")
                .map { text.index(after: $0) }
                ?? segment.lastIndex(where: { $0.isWhitespace }).map { text.index(after: $0) }
                ?? hardEnd
            chunks.append(String(text[start..<end]))
            start = end
        }

        return chunks
    }
}

/// Server-Sent Events client for streaming OpenCode events.
/// Connects to `GET /event` and parses the SSE stream.
///
/// Thread safety: All mutable state is protected by a private serial `DispatchQueue`.
/// URLSession delegate callbacks are dispatched onto the same queue.
/// Public callbacks (`onEvent`, `onStateChange`) are always called on the **main queue**.
/// Rapid `message.part.delta` text events are coalesced on the private queue before delivery.
final class SSEClient: NSObject, URLSessionDataDelegate {

    // MARK: - Types

    enum ConnectionState {
        case disconnected
        case connecting
        case connected
    }

    private struct PendingTextDelta {
        let sessionID: String
        let messageID: String
        let partID: String?
        let field: String
        /// Preserve incoming fragments until the timed flush. Repeatedly
        /// appending to one growing `String` turns a high-rate stream into
        /// quadratic copying before it even reaches the mailbox.
        var fragments: [String]
        /// Source bytes represented by this coalesced delivery. The mailbox
        /// budgets bytes, not only event count, so one large delta can apply
        /// backpressure before it monopolizes MainActor memory.
        var mailboxByteCount: Int
        /// Text bytes are kept separately from the mailbox estimate so normal
        /// coalescing cannot combine several small source records into one
        /// giant UI string merely because their JSON overhead was tiny.
        var textByteCount: Int
        var retainsRawEvent: Bool
    }

    /// One bounded text delivery waiting behind a busy MainActor. A large wire
    /// delta is split into these groups before it can enter the main mailbox;
    /// keeping the groups here also preserves its position ahead of a later
    /// tool/status ordering barrier.
    private struct DeferredTextDelivery {
        let sessionID: String
        let messageID: String
        let partID: String?
        let field: String
        let fragments: [String]
        let mailboxByteCount: Int
        let textByteCount: Int
        let retainsRawEvent: Bool
    }

    /// A small worker-owned FIFO used only when a bounded text group cannot
    /// yet fit in the main mailbox. Non-text events can sit behind a split
    /// delta here, which is what keeps `delta → tool/status` ordering intact.
    private enum DeferredInboundDelivery {
        case text(DeferredTextDelivery)
        case event(SSEInboundEvent, byteCount: Int)

        var mailboxByteCount: Int {
            switch self {
            case .text(let delivery):
                delivery.mailboxByteCount
            case .event(_, let byteCount):
                byteCount
            }
        }
    }

    private struct PendingPartUpdate {
        let part: OCPart
        let textChunks: [String]?
        let questionPayload: PreparedQuestionToolPayload?
        let rawEvent: OCEvent?
        let mailboxByteCount: Int
    }

    private struct TextSnapshotKey: Hashable {
        let sessionID: String
        let messageID: String
        let partID: String
        let type: String
    }

    private struct PendingTransportCompletion {
        let statusCode: Int?
    }

    /// Fixed-capacity FIFO for work awaiting MainActor. Unlike `Array.removeFirst`,
    /// removing a delivery batch only touches the batch itself, never the whole
    /// backlog. It also tracks represented source bytes, because a handful of
    /// large prepared updates can be more dangerous than many tiny tool events.
    private struct MainEventMailbox {
        private struct Entry {
            let event: SSEInboundEvent
            let byteCount: Int
        }

        struct DeliveryBatch {
            let events: [SSEInboundEvent]
            let byteCount: Int
        }

        private let capacity: Int
        private var storage: [Entry?]
        private var readIndex = 0
        private var writeIndex = 0
        private(set) var count = 0
        private(set) var totalByteCount = 0

        init(capacity: Int) {
            precondition(capacity > 0)
            self.capacity = capacity
            storage = [Entry?](repeating: nil, count: capacity)
        }

        var isEmpty: Bool { count == 0 }

        var last: SSEInboundEvent? {
            guard count > 0 else { return nil }
            let lastIndex = (writeIndex - 1 + capacity) % capacity
            return storage[lastIndex]?.event
        }

        @discardableResult
        mutating func append(_ event: SSEInboundEvent, byteCount: Int) -> Bool {
            guard count < capacity else { return false }
            let normalizedByteCount = max(0, byteCount)
            storage[writeIndex] = Entry(event: event, byteCount: normalizedByteCount)
            writeIndex = (writeIndex + 1) % capacity
            count += 1
            totalByteCount += normalizedByteCount
            return true
        }

        mutating func replaceLast(with event: SSEInboundEvent, byteCount: Int) {
            precondition(count > 0)
            let lastIndex = (writeIndex - 1 + capacity) % capacity
            guard let previous = storage[lastIndex] else {
                preconditionFailure("Main event mailbox lost its last entry")
            }
            let normalizedByteCount = max(0, byteCount)
            totalByteCount -= previous.byteCount
            totalByteCount += normalizedByteCount
            storage[lastIndex] = Entry(event: event, byteCount: normalizedByteCount)
        }

        mutating func dequeue(upTo maximumCount: Int) -> DeliveryBatch {
            let batchCount = min(maximumCount, count)
            var events: [SSEInboundEvent] = []
            events.reserveCapacity(batchCount)
            var batchByteCount = 0

            for _ in 0..<batchCount {
                guard let entry = storage[readIndex] else {
                    preconditionFailure("Main event mailbox lost FIFO storage")
                }
                events.append(entry.event)
                batchByteCount += entry.byteCount
                totalByteCount -= entry.byteCount
                storage[readIndex] = nil
                readIndex = (readIndex + 1) % capacity
                count -= 1
            }

            return DeliveryBatch(events: events, byteCount: batchByteCount)
        }

        mutating func removeAll() {
            storage = [Entry?](repeating: nil, count: capacity)
            readIndex = 0
            writeIndex = 0
            count = 0
            totalByteCount = 0
        }
    }

    /// Gates state callbacks already queued on MainActor. An explicit
    /// disconnect also suppresses non-disconnected updates that were already
    /// executing on the worker when the user asked to leave the stream.
    private final class StateDeliveryGate: @unchecked Sendable {
        private let lock = NSLock()
        private var generation = 0
        private var suppressesNonDisconnectedStates = false

        func invalidateForExplicitDisconnect() {
            lock.lock()
            generation &+= 1
            suppressesNonDisconnectedStates = true
            lock.unlock()
        }

        /// A newly started stream supersedes any queued transition from its
        /// predecessor and is once again allowed to publish connection state.
        func beginConnection() {
            lock.lock()
            generation &+= 1
            suppressesNonDisconnectedStates = false
            lock.unlock()
        }

        func deliveryGeneration(for state: ConnectionState) -> Int? {
            lock.lock()
            defer { lock.unlock() }
            guard state == .disconnected || !suppressesNonDisconnectedStates else {
                return nil
            }
            return generation
        }

        func isCurrent(_ candidate: Int) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return generation == candidate
        }
    }

    /// A cancellation token for a batch already enqueued on the main queue.
    /// `DispatchQueue.main.async` has no cancellation API, so an explicit
    /// disconnect/reset invalidates this token and prevents stale callbacks
    /// from mutating a newly selected session.
    private final class MainDeliveryTicket: @unchecked Sendable {
        private let lock = NSLock()
        private var valid = true

        func invalidate() {
            lock.lock()
            valid = false
            lock.unlock()
        }

        var isValid: Bool {
            lock.lock()
            defer { lock.unlock() }
            return valid
        }
    }

    // MARK: - Public (read-only)

    /// Current connection state. Always updated on the main queue.
    private(set) var state: ConnectionState = .disconnected

    /// Compatibility callback for raw parsed events (main queue). New chat code
    /// uses `onInboundEvent` so hot event payloads are already typed here.
    var onEvent: ((OCEvent) -> Void)?

    /// Called on the main queue with a preprocessed event. `rawEvent` is nil
    /// for prepared cases unless raw retention was explicitly enabled.
    var onInboundEvent: ((SSEInboundEvent) -> Void)?

    /// Called when connection state changes (main queue).
    var onStateChange: ((ConnectionState) -> Void)?

    /// Called when the SSE endpoint returns a terminal HTTP status that should not auto-reconnect.
    var onTerminalHTTPError: ((Int) -> Void)?

    // MARK: - Private state (protected by `queue`)

    private let queue = DispatchQueue(label: "com.opencode.SSEClient", qos: .userInitiated)

    private var baseURL: URL
    private var authHeader: String?
    private var shouldReconnect = true
    private var reconnectDelay: TimeInterval = 2.0
    /// Recording opts into keeping the original decoded OCEvent alongside a
    /// prepared projection. The legacy `onEvent` callback opts in separately.
    private var rawEventRetentionEnabled = false
    /// Raw transport bytes kept until a complete SSE record is framed. Keeping
    /// this as `Data` is important: URLSession may split a single UTF-8 scalar
    /// (or a CRLF record delimiter) between delegate callbacks.
    private var buffer = Data()
    /// Byte offset of the first record not yet handed to `parseEvent`.
    private var bufferedRecordStartOffset = 0
    /// The next byte to inspect for a record boundary. On an incomplete record
    /// it retains only the three-byte delimiter lookbehind, avoiding a full
    /// rescan of a growing payload on every transport callback.
    private var framingScanOffset = 0
    private var bufferedDrainScheduled = false
    private var oversizedRecordCancellationPending = false
    private var pendingTransportCompletion: PendingTransportCompletion?
    private let transport: any OpenCodeTransport
    private var eventStream: (any OpenCodeEventStream)?
    // Retained only by DEBUG lifecycle tests that inject URLSession callbacks
    // directly; production connections are owned by `eventStream`.
    private var task: URLSessionDataTask?
    private var session: URLSession?
    private var reconnectWorkItem: DispatchWorkItem?
    private var pendingTextDelta: PendingTextDelta?
    private var pendingTextDeltaWorkItem: DispatchWorkItem?
    /// Head-indexed rather than `removeFirst` because a 2 MB record may become
    /// dozens of bounded text groups. The queue never grows past one record
    /// plus its immediately-following ordering barrier: transport is paused as
    /// soon as it becomes non-empty.
    private var deferredInboundDeliveries: [DeferredInboundDelivery] = []
    private var deferredInboundDeliveryHead = 0
    private var pendingPartUpdate: PendingPartUpdate?
    private var pendingPartUpdateWorkItem: DispatchWorkItem?
    /// Last authoritative text/reasoning snapshot per part. This lives on the
    /// SSE worker, allowing growing snapshots to become suffix deltas before
    /// they ever reach MainActor.
    private var textSnapshotCache: [TextSnapshotKey: String] = [:]
    /// A fixed-size worker-owned mailbox. When MainActor cannot drain it fast
    /// enough, the underlying URLSession task is suspended rather than growing
    /// this queue or dropping ordered transcript/tool events.
    private var pendingMainEvents = MainEventMailbox(capacity: 64)
    /// The UI owns a second, bounded streaming-chunk ring after MainActor has
    /// accepted an SSE batch. This gate keeps transport backpressure active
    /// until that render ring drops below its low watermark, rather than
    /// acknowledging the network stream as soon as the handler enqueues work.
    private var isConsumerBackpressured = false
    private var isTransportPausedForMainBackpressure = false
    private var transportTaskSuspendedByBackpressure = false
    /// Heartbeats are liveness-only and may be reduced to their latest value.
    /// They are delivered after the bounded ordered mailbox drains, so they do
    /// not consume one entry per server heartbeat while the UI is busy.
    private var pendingHeartbeat: OCEvent?
    /// Non-nil while exactly one already-prepared batch is waiting for (or
    /// executing on) MainActor. New events continue to coalesce on `queue`.
    private var activeMainDeliveryTicket: MainDeliveryTicket?
    /// Bytes in the batch that was removed from the ring but is still waiting
    /// for MainActor. They remain part of backpressure until its ticket acks.
    private var activeMainDeliveryByteCount = 0
    /// Batch selection is deferred until the current worker-queue turn ends.
    /// A single URLSession callback can contain several complete SSE records;
    /// collecting all of their ordering barriers before taking a ticket avoids
    /// cascading one main-queue delivery per record.
    private var mainDeliverySelectionScheduled = false
    private var lastResponseStatusCode: Int?
    private let stateDeliveryGate = StateDeliveryGate()
#if DEBUG
    private var connectionStartHandlerForTesting: (() -> Void)?
    private var oversizedRecordCancellationCountForTesting = 0
#endif

    // MARK: - Constants

    private static let initialReconnectDelay: TimeInterval = 2.0
    private static let maxReconnectDelay: TimeInterval = 30.0
    private static let reconnectBackoffMultiplier: Double = 1.5
    private static let textDeltaCoalescingInterval: TimeInterval = 0.02
    private static let mainDeliveryBatchLimit = 16
    /// Leave room below the ring capacity for one parsed ordering barrier plus
    /// any pending text/part flushes that it must emit atomically.
    private static let mainMailboxHighWatermark = 40
    private static let mainMailboxLowWatermark = 16
    private static let mainMailboxHighWatermarkBytes = 512 * 1_024
    private static let mainMailboxLowWatermarkBytes = 128 * 1_024
    /// A coalesced text event must leave headroom for regular ordering barriers
    /// in the 512 KB main mailbox. This is measured after raw-event retention
    /// has been accounted for, so recording naturally uses smaller groups.
    private static let maximumTextDeliveryMailboxBytes = 128 * 1_024
    /// Normal typed UI delivery does not retain the raw event, while recording
    /// may retain it too. Keeping source text at half the mailbox limit means a
    /// synthetic raw delta still fits inside one bounded delivery group.
    private static let maximumTextDeliveryTextBytes = 64 * 1_024
    /// A byte cap alone still permits tens of thousands of one-byte `String`
    /// fragments to accumulate before the timed flush. Cap the fragment count
    /// too; reaching it flushes the current bounded group without reintroducing
    /// repeated string concatenation on the SSE worker.
    private static let maximumTextDeliveryFragmentCount = 64
    /// A complete SSE record is capped at 2 MB, so 32 text groups plus one
    /// prior pending group and one later barrier are sufficient. Exceeding this
    /// indicates an invariant failure, and cancelling is safer than allowing
    /// the worker queue to grow without bound.
    private static let maximumDeferredInboundDeliveryCount = 40
    /// Suffix reduction is an optimization only. Beyond this size, retaining
    /// and repeatedly comparing a growing snapshot can monopolize the worker.
    /// The next authoritative snapshot is still correct; it simply takes the
    /// bounded replacement path instead of the suffix path.
    private static let maximumTextSnapshotBytes = 256 * 1_024
    private static let maximumTextSnapshotCount = 32
    private static let maximumRecordsPerBufferDrain = 64
    private static let bufferCompactionMinimumPrefix = 64 * 1_024
    private static let maximumDelimiterByteCount = 4
    private static let maximumIncompleteRecordBytes = 2 * 1_024 * 1_024
    private static let maximumCompleteRecordBytes = 2 * 1_024 * 1_024
    private static let maximumBufferedTransportBytes = 4 * 1_024 * 1_024

    // MARK: - Init

    init(
        baseURL: URL,
        authHeader: String? = nil,
        transport: (any OpenCodeTransport)? = nil
    ) {
        self.baseURL = baseURL
        self.authHeader = authHeader
        self.transport = transport ?? DirectOpenCodeTransport()
        super.init()
    }

    func updateConnection(baseURL: URL, authHeader: String?) {
        queue.async { [self] in
            self.baseURL = baseURL
            self.authHeader = authHeader
        }
    }

    /// Enables retaining raw events for a recorder that consumes
    /// `SSEInboundEvent.rawEvent`. Leave this off for normal typed UI delivery;
    /// a non-nil legacy `onEvent` callback automatically retains raw events.
    func setRawEventRetentionEnabled(_ enabled: Bool) {
        queue.async { [weak self] in
            self?.rawEventRetentionEnabled = enabled
        }
    }

    /// Called by ChatClient when its bounded render mailbox crosses a
    /// high/low watermark. The setter runs only on the SSE worker so a UI
    /// flush never synchronously waits for network parsing or URLSession.
    func setConsumerBackpressured(_ backpressured: Bool) {
        queue.async { [weak self] in
            guard let self, self.isConsumerBackpressured != backpressured else { return }

            self.isConsumerBackpressured = backpressured
            if backpressured {
                self.pauseTransportForMainBackpressureIfNeeded()
            } else {
                self.drainDeferredInboundDeliveriesIfPossible()
                if !self.hasDeferredInboundDeliveries {
                    self.flushPendingTextDelta()
                }
                self.resumeTransportFromMainBackpressureIfPossible()
                self.scheduleMainDeliveryIfNeeded()
            }
        }
    }

    // MARK: - Connect / Disconnect

    func connect() {
        queue.async { [self] in
            // A manual connection request supersedes a delayed automatic retry.
            // Without this, the old work item could open a second SSE session
            // after this one is already connected.
            reconnectWorkItem?.cancel()
            reconnectWorkItem = nil

            guard state == .disconnected, eventStream == nil, task == nil, session == nil else { return }
            shouldReconnect = true
            reconnectDelay = Self.initialReconnectDelay
            startConnection()
        }
    }

    func disconnect() {
        // This runs on the caller's executor before the worker queue can be
        // busy decoding another transport callback. It prevents a previously
        // enqueued state notification from resurrecting ConnectionManager after
        // an explicit user disconnect.
        stateDeliveryGate.invalidateForExplicitDisconnect()
        queue.async { [self] in
            shouldReconnect = false
            reconnectWorkItem?.cancel()
            reconnectWorkItem = nil
            cleanupConnection()
            updateState(.disconnected)
        }
    }

    // MARK: - Connection Lifecycle (called on `queue`)

    /// Must be called on `queue`.
    private func startConnection() {
        // Both the manual path and the reconnect path converge here. Keep this
        // guard as the final protection against two live URLSession instances.
        guard eventStream == nil, task == nil, session == nil else { return }
        reconnectWorkItem = nil

        stateDeliveryGate.beginConnection()
        updateState(.connecting)
#if DEBUG
        if let connectionStartHandlerForTesting {
            connectionStartHandlerForTesting()
            return
        }
#endif

        let url = baseURL.appending(path: "event")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = .infinity
        if let authHeader {
            request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        }

        resetFramingBuffer()
        isTransportPausedForMainBackpressure = false
        transportTaskSuspendedByBackpressure = false
        oversizedRecordCancellationPending = false
        pendingTransportCompletion = nil
        let stream = transport.makeEventStream(
            request: request,
            deliveryQueue: queue,
            callbacks: OpenCodeEventStreamCallbacks(
                onResponse: { [weak self] response in
                    self?.receiveTransportResponse(response) ?? false
                },
                onData: { [weak self] data in
                    self?.receiveTransportData(data)
                },
                onComplete: { [weak self] error in
                    self?.completeTransport(error: error)
                }
            )
        )
        eventStream = stream
        stream.start()
        // A natural reconnect may occur while the UI is still draining its
        // bounded render ring. Keep that gate closed across the new transport.
        pauseTransportForMainBackpressureIfNeeded()
    }

    /// Cancels the current task/session and resets transient state. Must be called on `queue`.
    ///
    /// Automatic transport completion preserves the delivery mailbox: a final
    /// `idle` event and the last text batch may already be waiting for
    /// MainActor. An explicit disconnect discards it instead.
    private func cleanupConnection(discardPendingMainEvents: Bool = true) {
        pendingTextDeltaWorkItem?.cancel()
        pendingTextDeltaWorkItem = nil
        pendingTextDelta = nil
        pendingPartUpdateWorkItem?.cancel()
        pendingPartUpdateWorkItem = nil
        pendingPartUpdate = nil
        textSnapshotCache.removeAll()
        isTransportPausedForMainBackpressure = false
        transportTaskSuspendedByBackpressure = false
        bufferedDrainScheduled = false
        oversizedRecordCancellationPending = false
        pendingTransportCompletion = nil
        if discardPendingMainEvents {
            isConsumerBackpressured = false
            clearDeferredInboundDeliveries()
            invalidateMainMailbox()
        }
        eventStream?.cancel()
        eventStream = nil
        task?.cancel()
        task = nil
        session?.invalidateAndCancel()
        session = nil
        resetFramingBuffer()
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        // Already on `queue` (delegateQueue).
        guard isCurrentConnection(session: session, task: dataTask) else {
            completionHandler(.cancel)
            return
        }

        completionHandler(receiveTransportResponse(response) ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // Already on `queue`.
        guard isCurrentConnection(session: session, task: dataTask),
              !oversizedRecordCancellationPending
        else { return }

        receiveTransportData(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Already on `queue`.
        guard isCurrentConnection(session: session, task: task) else { return }

        completeTransport(error: error)
    }

    private func receiveTransportResponse(_ response: URLResponse) -> Bool {
        if let http = response as? HTTPURLResponse {
            lastResponseStatusCode = http.statusCode

            if http.statusCode == 200 {
                reconnectDelay = Self.initialReconnectDelay
                updateState(.connected)
                return true
            }

            if isTerminalSSEHTTPStatus(http.statusCode) {
                shouldReconnect = false
                let callback = onTerminalHTTPError
                let statusCode = http.statusCode
                DispatchQueue.main.async {
                    callback?(statusCode)
                }
                return false
            }
        }

        return true
    }

    private func receiveTransportData(_ data: Data) {
        guard !oversizedRecordCancellationPending else { return }
        ChatStreamInstrumentation.recordSSEReceive(byteCount: data.count)
        buffer.append(data)
        if buffer.count - bufferedRecordStartOffset > Self.maximumBufferedTransportBytes {
            cancelOversizedIncompleteRecord()
            return
        }
        guard !isTransportPausedForMainBackpressure else { return }
        processBuffer()
    }

    private func completeTransport(error: Error?) {
        // A paused stream can still have complete records already received in
        // `buffer`. Drain those records through the same bounded mailbox before
        // tearing down the transport, otherwise a final tool/status/idle event
        // could be silently lost at connection completion.
        pendingTransportCompletion = PendingTransportCompletion(statusCode: lastResponseStatusCode)
        flushPendingTextDelta()
        flushPendingPartUpdate()
        lastResponseStatusCode = nil
        if !isConsumerBackpressured {
            isTransportPausedForMainBackpressure = false
            transportTaskSuspendedByBackpressure = false
            processBuffer()
            finishPendingTransportCompletionIfPossible()
        }
    }

    // MARK: - SSE Parsing (called on `queue`)

    private func processBuffer() {
        guard !isTransportPausedForMainBackpressure,
              !oversizedRecordCancellationPending
        else { return }

        var parsedEventCount = 0
        var inspectedRecordCount = 0
        var reachedIncompleteRecord = false

        // Frame incrementally. A single enormous incomplete record is scanned
        // only once per appended suffix, not from byte zero on every callback.
        while inspectedRecordCount < Self.maximumRecordsPerBufferDrain,
              !needsMainBackpressure {
            guard let delimiter = nextEventDelimiter() else {
                reachedIncompleteRecord = true
                break
            }

            let recordByteCount = delimiter.start - bufferedRecordStartOffset
            guard recordByteCount <= Self.maximumCompleteRecordBytes else {
                cancelOversizedCompleteRecord(byteCount: recordByteCount)
                return
            }
            let rawEvent = Data(buffer[bufferedRecordStartOffset..<delimiter.start])
            bufferedRecordStartOffset = delimiter.end
            framingScanOffset = bufferedRecordStartOffset
            inspectedRecordCount += 1

            if parseEvent(rawEvent, sourceByteCount: recordByteCount) {
                parsedEventCount += 1
            }
        }

        // The normal 20 ms coalescing window remains in place for a single
        // record callback. When a transport callback already contains several
        // complete records, flush its final pending text/part update now so
        // every ordering barrier can enter the same deferred main batch.
        if parsedEventCount > 1 {
            flushPendingTextDelta()
            flushPendingPartUpdate()
        }

        pauseTransportForMainBackpressureIfNeeded()

        if oversizedRecordCancellationPending || isTransportPausedForMainBackpressure {
            compactConsumedBufferPrefixIfHelpful()
            return
        }

        if reachedIncompleteRecord {
            if pendingTransportCompletion != nil {
                if buffer.count > bufferedRecordStartOffset {
                    Logger.sse.warning("Discarding unterminated SSE record at transport completion")
                }
                resetFramingBuffer()
                flushPendingTextDelta()
                flushPendingPartUpdate()
                finishPendingTransportCompletionIfPossible()
                return
            }

            if buffer.count - bufferedRecordStartOffset > Self.maximumIncompleteRecordBytes {
                cancelOversizedIncompleteRecord()
                return
            }
            framingScanOffset = max(
                bufferedRecordStartOffset,
                max(0, buffer.count - Self.maximumDelimiterByteCount + 1)
            )
            discardConsumedBufferPrefixAfterCompleteDrain()
            scheduleMainDeliveryIfNeeded()
            return
        }

        // Yield after a bounded number of complete records so one transport
        // callback cannot monopolize the SSE worker. The next queue turn keeps
        // decoding from the cursor without disturbing event order.
        if inspectedRecordCount == Self.maximumRecordsPerBufferDrain {
            if bufferedRecordStartOffset < buffer.count {
                scheduleBufferedDrainIfNeeded()
            } else {
                discardConsumedBufferPrefixAfterCompleteDrain()
                finishPendingTransportCompletionIfPossible()
                scheduleMainDeliveryIfNeeded()
            }
        }
    }

    /// Returns the byte range of a complete SSE blank line after the current
    /// record, scanning only the new suffix of `buffer`.
    private func nextEventDelimiter() -> (start: Int, end: Int)? {
        var offset = max(framingScanOffset, bufferedRecordStartOffset)

        while offset < buffer.count {
            if let delimiterLength = eventDelimiterLength(at: offset) {
                return (start: offset, end: offset + delimiterLength)
            }
            offset += 1
        }

        return nil
    }

    /// Returns the byte width of a complete SSE blank line at `offset`.
    /// The OpenCode stream normally uses LF-LF; CRLF-CRLF is also valid SSE and
    /// must remain intact when split across transport callbacks.
    private func eventDelimiterLength(at offset: Int) -> Int? {
        let remainingByteCount = buffer.count - offset
        guard remainingByteCount >= 2 else { return nil }

        let first = buffer[offset]
        let second = buffer[offset + 1]

        if first == 0x0A, second == 0x0A { // \n\n
            return 2
        }

        guard first == 0x0D, second == 0x0A, remainingByteCount >= 4 else {
            return nil
        }

        guard buffer[offset + 2] == 0x0D, buffer[offset + 3] == 0x0A else {
            return nil
        }

        return 4 // \r\n\r\n
    }

    private func scheduleBufferedDrainIfNeeded() {
        guard !bufferedDrainScheduled,
              !isTransportPausedForMainBackpressure,
              !oversizedRecordCancellationPending
        else { return }

        bufferedDrainScheduled = true
        queue.async { [weak self] in
            guard let self else { return }
            self.bufferedDrainScheduled = false
            self.processBuffer()
        }
    }

    private func resetFramingBuffer() {
        buffer = Data()
        bufferedRecordStartOffset = 0
        framingScanOffset = 0
    }

    private func discardConsumedBufferPrefixAfterCompleteDrain() {
        guard bufferedRecordStartOffset > 0 else { return }

        if bufferedRecordStartOffset == buffer.count {
            resetFramingBuffer()
            return
        }

        buffer = buffer.subdata(in: bufferedRecordStartOffset..<buffer.count)
        bufferedRecordStartOffset = 0
        framingScanOffset = max(0, buffer.count - Self.maximumDelimiterByteCount + 1)
    }

    private func compactConsumedBufferPrefixIfHelpful() {
        guard bufferedRecordStartOffset >= Self.bufferCompactionMinimumPrefix,
              bufferedRecordStartOffset * 2 >= buffer.count
        else { return }

        if bufferedRecordStartOffset == buffer.count {
            resetFramingBuffer()
            return
        }

        // Backpressure stopped before scanning the remaining record, so restart
        // its framing cursor at byte zero after dropping the consumed prefix.
        buffer = buffer.subdata(in: bufferedRecordStartOffset..<buffer.count)
        bufferedRecordStartOffset = 0
        framingScanOffset = 0
    }

    private func cancelOversizedIncompleteRecord() {
        cancelOversizedRecord(
            "an unterminated SSE record exceeded \(Self.maximumIncompleteRecordBytes) bytes"
        )
    }

    private func cancelOversizedCompleteRecord(byteCount: Int) {
        cancelOversizedRecord(
            "a complete SSE record used \(byteCount) bytes (limit \(Self.maximumCompleteRecordBytes))"
        )
    }

    private func cancelOversizedRecord(_ reason: String) {
        guard !oversizedRecordCancellationPending else { return }

        oversizedRecordCancellationPending = true
#if DEBUG
        oversizedRecordCancellationCountForTesting += 1
#endif
        Logger.sse.error("Cancelling SSE stream after \(reason, privacy: .public)")
        resetFramingBuffer()
        eventStream?.cancel()
        task?.cancel()
    }

    private func finishPendingTransportCompletionIfPossible() {
        guard let completion = pendingTransportCompletion,
              buffer.isEmpty
        else { return }

        pendingTransportCompletion = nil
        let statusCode = completion.statusCode
        cleanupConnection(discardPendingMainEvents: false)
        // `cleanupConnection` intentionally preserves the bounded mailbox for
        // a natural transport completion. A heartbeat may be the only pending
        // item, so explicitly arm its deferred delivery as well.
        scheduleMainDeliveryIfNeeded()
        updateState(.disconnected)

        if let statusCode, isTerminalSSEHTTPStatus(statusCode) {
            return
        }

        scheduleReconnect()
    }

    @discardableResult
    private func parseEvent(_ raw: Data, sourceByteCount: Int) -> Bool {
        guard let rawString = String(data: raw, encoding: .utf8) else {
            Logger.sse.error("Discarding malformed UTF-8 SSE record")
            return false
        }

        let trimmed = rawString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        var dataLines: [String] = []

        for line in trimmed.components(separatedBy: "\n") {
            guard let dataValue = extractDataField(from: line) else { continue }
            dataLines.append(dataValue)
        }

        guard !dataLines.isEmpty else { return false }
        let jsonString = dataLines.joined(separator: "\n")
        guard let jsonData = jsonString.data(using: .utf8) else { return false }

        let signpostID = ChatStreamInstrumentation.beginSSEDecode(byteCount: jsonData.count)
        defer {
            ChatStreamInstrumentation.endSSEDecode(signpostID)
        }

        do {
            let event = try JSONDecoder().decode(OCEvent.self, from: jsonData)
            enqueueEvent(event, sourceByteCount: sourceByteCount)
            return true
        } catch {
            Logger.sse.error("Parse error: \(error, privacy: .public) for data: \(jsonString.prefix(200), privacy: .private)")
            return false
        }
    }

    private func enqueueEvent(_ event: OCEvent, sourceByteCount: Int) {
        if event.type == "server.connected" || event.type == "server.heartbeat" {
            // Liveness signals do not affect transcript ordering. Retaining
            // only the newest one keeps a busy MainActor from accumulating an
            // unbounded row of heartbeats while still delivering a refresh once
            // its ordered backlog drains.
            pendingHeartbeat = event
            return
        }

        let retainsRawEvent = rawEventRetentionEnabled || onEvent != nil
        let preparedMailboxByteCount = mailboxByteCount(
            forSourceByteCount: sourceByteCount,
            retainsRawEvent: retainsRawEvent
        )
        if let inboundEvent = SSEInboundEvent.prepare(
            event,
            retainingRawEvent: retainsRawEvent
        ) {
            switch inboundEvent {
            case .cold:
                // Prepared cold payloads are still ordering barriers. Their
                // potentially costly JSON decode already happened on this
                // worker, but text/tool updates preceding them must remain
                // visible to MainActor first.
                flushPendingTextDelta()
                flushPendingPartUpdate()
                clearTextSnapshotCache(for: event)
                deliverInboundEvent(inboundEvent, byteCount: preparedMailboxByteCount)

            case .textDelta(let delta, let rawEvent):
                appendToTextSnapshotCache(delta)
                flushPendingPartUpdate()
                enqueueTextDelta(
                    delta,
                    mailboxByteCount: preparedMailboxByteCount,
                    retainsRawEvent: rawEvent != nil
                )

            case .partUpdated(let part, let textChunks, let questionPayload, let rawEvent):
                switch reduceTextSnapshot(
                    part,
                    textChunks: textChunks,
                    questionPayload: questionPayload,
                    rawEvent: rawEvent
                ) {
                case .none:
                    // A repeated authoritative snapshot with no textual change.
                    break

                case .some(.textDelta(let delta, _)):
                    flushPendingPartUpdate()
                    enqueueTextDelta(
                        delta,
                        mailboxByteCount: preparedMailboxByteCount,
                        retainsRawEvent: rawEvent != nil
                    )

                case .some(.partUpdated(let part, let textChunks, let questionPayload, let rawEvent)):
                    flushPendingTextDelta()
                    enqueuePartUpdate(
                        part,
                        textChunks: textChunks,
                        questionPayload: questionPayload,
                        rawEvent: rawEvent,
                        mailboxByteCount: preparedMailboxByteCount
                    )

                case .some(.messageUpdated(_, _)):
                    break

                case .some(.cold(_, _)):
                    break

                case .some(.raw(_)):
                    break
                }

            case .messageUpdated:
                // Metadata updates can carry an arbitrarily large server
                // payload. Keep their decoding on this worker, while still
                // respecting text/tool ordering before MainActor sees them.
                flushPendingTextDelta()
                flushPendingPartUpdate()
                deliverInboundEvent(inboundEvent, byteCount: preparedMailboxByteCount)

            case .raw:
                break
            }
            return
        }

        // Cold events are ordering barriers: any buffered stream data must be
        // visible before status changes, removals, permissions, or completion.
        flushPendingTextDelta()
        flushPendingPartUpdate()
        clearTextSnapshotCache(for: event)
        deliverInboundEvent(.raw(event), byteCount: sourceByteCount)
    }

    /// Converts a growing `message.part.updated` snapshot into a suffix delta
    /// when its text has only been appended. A genuine rewrite remains an
    /// authoritative replacement, preserving server semantics.
    private func reduceTextSnapshot(
        _ part: OCPart,
        textChunks: [String]?,
        questionPayload: PreparedQuestionToolPayload?,
        rawEvent: OCEvent?
    ) -> SSEInboundEvent? {
        guard part.type == .text || part.type == .reasoning,
              let text = (part.type == .reasoning ? part.text : part.renderableText)
        else {
            return .partUpdated(
                part: part,
                textChunks: textChunks,
                questionPayload: questionPayload,
                rawEvent: rawEvent
            )
        }

        let key = TextSnapshotKey(
            sessionID: part.sessionID,
            messageID: part.messageID,
            partID: part.id,
            type: part.type.rawValue
        )
        let textByteCount = text.utf8.count
        guard textByteCount <= Self.maximumTextSnapshotBytes else {
            // Do not repeatedly compare or retain an unbounded server snapshot
            // on the worker. The caller still receives the authoritative,
            // worker-chunked replacement and remains semantically correct.
            textSnapshotCache.removeValue(forKey: key)
            return .partUpdated(
                part: part,
                textChunks: textChunks,
                questionPayload: questionPayload,
                rawEvent: rawEvent
            )
        }
        defer { cacheTextSnapshot(text, byteCount: textByteCount, for: key) }

        guard let previous = textSnapshotCache[key] else {
            return .partUpdated(
                part: part,
                textChunks: textChunks,
                questionPayload: questionPayload,
                rawEvent: rawEvent
            )
        }

        guard text.hasPrefix(previous) else {
            return .partUpdated(
                part: part,
                textChunks: textChunks,
                questionPayload: questionPayload,
                rawEvent: rawEvent
            )
        }

        guard text.count > previous.count else {
            return nil
        }

        let start = text.index(text.startIndex, offsetBy: previous.count)
        let suffix = String(text[start...])
        let delta = SSETextDelta(
            sessionID: part.sessionID,
            messageID: part.messageID,
            partID: part.id,
            field: "text",
            text: suffix
        )
        // Preserve the source `message.part.updated` for recording/replay even
        // though the UI receives the cheaper append operation.
        return .textDelta(delta, rawEvent: rawEvent)
    }

    /// A delta invalidates its matching snapshot baseline. Rebuilding a growing
    /// baseline by repeatedly appending deltas has quadratic worker cost; the
    /// next full snapshot instead takes the safe authoritative replacement path.
    private func appendToTextSnapshotCache(_ delta: SSETextDelta) {
        guard let partID = delta.partID else { return }

        let matchingKeys = textSnapshotCache.keys.filter {
            $0.sessionID == delta.sessionID
                && $0.messageID == delta.messageID
                && $0.partID == partID
        }
        for key in matchingKeys {
            textSnapshotCache.removeValue(forKey: key)
        }
    }

    private func cacheTextSnapshot(
        _ text: String,
        byteCount: Int,
        for key: TextSnapshotKey
    ) {
        guard byteCount <= Self.maximumTextSnapshotBytes else {
            textSnapshotCache.removeValue(forKey: key)
            return
        }

        if textSnapshotCache[key] == nil,
           textSnapshotCache.count >= Self.maximumTextSnapshotCount {
            // This is an optimization cache only. Clearing a small fixed set is
            // safer than retaining one baseline per untrusted server part.
            textSnapshotCache.removeAll()
        }
        textSnapshotCache[key] = text
    }

    private func clearTextSnapshotCache(for event: OCEvent) {
        guard let properties = event.properties?.value as? [String: Any] else { return }

        if event.type == "session.status",
           let sessionID = properties["sessionID"] as? String,
           let status = properties["status"] as? [String: Any],
           status["type"] as? String == OCSessionStatusType.idle.rawValue {
            let keysToRemove = textSnapshotCache.keys.filter { $0.sessionID == sessionID }
            for key in keysToRemove {
                textSnapshotCache.removeValue(forKey: key)
            }
            return
        }

        guard event.type == "message.part.removed" || event.type == "message.removed",
              let sessionID = properties["sessionID"] as? String,
              let messageID = properties["messageID"] as? String
        else { return }

        if event.type == "message.part.removed",
           let partID = properties["partID"] as? String ?? properties["partId"] as? String {
            let keysToRemove = textSnapshotCache.keys.filter {
                $0.sessionID == sessionID
                    && $0.messageID == messageID
                    && $0.partID == partID
            }
            for key in keysToRemove {
                textSnapshotCache.removeValue(forKey: key)
            }
        } else {
            let keysToRemove = textSnapshotCache.keys.filter {
                $0.sessionID == sessionID && $0.messageID == messageID
            }
            for key in keysToRemove {
                textSnapshotCache.removeValue(forKey: key)
            }
        }
    }

    private func saturatedByteCount(_ current: Int, plus additional: Int) -> Int {
        let normalizedCurrent = max(0, current)
        let normalizedAdditional = max(0, additional)
        guard normalizedCurrent <= Int.max - normalizedAdditional else {
            return Int.max
        }
        return normalizedCurrent + normalizedAdditional
    }

    /// A prepared event always keeps its typed projection. Opting into the
    /// original `OCEvent` usually retains a second decoded representation of
    /// the same transport payload, so account for both before deciding whether
    /// MainActor can accept more work.
    private func mailboxByteCount(
        forSourceByteCount sourceByteCount: Int,
        retainsRawEvent: Bool
    ) -> Int {
        let normalizedSourceByteCount = max(0, sourceByteCount)
        guard retainsRawEvent else { return normalizedSourceByteCount }
        return saturatedByteCount(normalizedSourceByteCount, plus: normalizedSourceByteCount)
    }

    private func enqueueTextDelta(
        _ delta: SSETextDelta,
        mailboxByteCount: Int,
        retainsRawEvent: Bool
    ) {
        let deliveries = boundedTextDeliveries(
            for: delta,
            mailboxByteCount: mailboxByteCount,
            retainsRawEvent: retainsRawEvent
        )
        guard !deliveries.isEmpty else { return }

        // A single bounded group preserves the normal 20 ms coalescing path.
        // A large record becomes several groups and enters the deferred FIFO in
        // one go, so no later event can overtake a suffix of that record.
        if deliveries.count == 1, let delivery = deliveries.first {
            enqueueBoundedTextDelivery(delivery)
        } else {
            flushPendingTextDelta()
            for delivery in deliveries {
                enqueueDeferredInboundDelivery(.text(delivery))
            }
            drainDeferredInboundDeliveriesIfPossible()
        }
    }

    private func enqueueBoundedTextDelivery(_ delivery: DeferredTextDelivery) {
        if var pending = pendingTextDelta,
           pending.sessionID == delivery.sessionID,
           pending.messageID == delivery.messageID,
           pending.partID == delivery.partID,
           pending.field == delivery.field,
           !hasDeferredInboundDeliveries,
           pending.fragments.count + delivery.fragments.count <= Self.maximumTextDeliveryFragmentCount,
           saturatedByteCount(
                pending.mailboxByteCount,
                plus: delivery.mailboxByteCount
           ) <= Self.maximumTextDeliveryMailboxBytes,
           saturatedByteCount(
                pending.textByteCount,
                plus: delivery.textByteCount
           ) <= Self.maximumTextDeliveryTextBytes {
            pending.fragments.append(contentsOf: delivery.fragments)
            pending.mailboxByteCount = saturatedByteCount(
                pending.mailboxByteCount,
                plus: delivery.mailboxByteCount
            )
            pending.textByteCount = saturatedByteCount(
                pending.textByteCount,
                plus: delivery.textByteCount
            )
            pending.retainsRawEvent = pending.retainsRawEvent || delivery.retainsRawEvent
            pendingTextDelta = pending
            schedulePendingTextDeltaFlush()
            return
        }

        flushPendingTextDelta()

        // If an older group had to wait behind MainActor, this group must join
        // that worker FIFO rather than arm a later timer that could overtake it.
        if hasDeferredInboundDeliveries {
            enqueueDeferredInboundDelivery(.text(delivery))
            drainDeferredInboundDeliveriesIfPossible()
            return
        }

        pendingTextDelta = PendingTextDelta(
            sessionID: delivery.sessionID,
            messageID: delivery.messageID,
            partID: delivery.partID,
            field: delivery.field,
            fragments: delivery.fragments,
            mailboxByteCount: delivery.mailboxByteCount,
            textByteCount: delivery.textByteCount,
            retainsRawEvent: delivery.retainsRawEvent
        )
        schedulePendingTextDeltaFlush()
    }

    private func schedulePendingTextDeltaFlush() {
        guard pendingTextDeltaWorkItem == nil else { return }

        let workItem = DispatchWorkItem { [weak self] in
            self?.flushPendingTextDelta()
        }
        pendingTextDeltaWorkItem = workItem
        queue.asyncAfter(deadline: .now() + Self.textDeltaCoalescingInterval, execute: workItem)
    }

    private func flushPendingTextDelta() {
        pendingTextDeltaWorkItem?.cancel()
        pendingTextDeltaWorkItem = nil

        guard let pending = pendingTextDelta else { return }
        pendingTextDelta = nil
        enqueueOrDeliverTextGroup(
            DeferredTextDelivery(
                sessionID: pending.sessionID,
                messageID: pending.messageID,
                partID: pending.partID,
                field: pending.field,
                fragments: pending.fragments,
                mailboxByteCount: pending.mailboxByteCount,
                textByteCount: pending.textByteCount,
                retainsRawEvent: pending.retainsRawEvent
            )
        )
    }

    /// Splits a server delta by UTF-8 byte count, not Swift `Character` count.
    /// A pathological single grapheme can otherwise bypass a character-based
    /// chunker and reach one UI `Text` node as a multi-megabyte string.
    private func boundedTextDeliveries(
        for delta: SSETextDelta,
        mailboxByteCount: Int,
        retainsRawEvent: Bool
    ) -> [DeferredTextDelivery] {
        let fragments = splitTextForBoundedDelivery(delta.text)
        guard !fragments.isEmpty else { return [] }

        let totalTextByteCount = fragments.reduce(into: 0) {
            $0 = saturatedByteCount($0, plus: $1.utf8.count)
        }
        guard totalTextByteCount > 0 else { return [] }

        var deliveries: [DeferredTextDelivery] = []
        var groupFragments: [String] = []
        var groupTextByteCount = 0
        var remainingSourceByteCount = max(0, mailboxByteCount)
        var remainingTextByteCount = totalTextByteCount

        func appendGroup() {
            guard !groupFragments.isEmpty else { return }

            let proportionalByteCount: Int
            if remainingTextByteCount <= groupTextByteCount {
                proportionalByteCount = remainingSourceByteCount
            } else {
                proportionalByteCount = max(
                    groupTextByteCount,
                    Int((Double(remainingSourceByteCount)
                        * Double(groupTextByteCount)
                        / Double(remainingTextByteCount)).rounded(.up))
                )
            }
            let boundedByteCount = min(
                Self.maximumTextDeliveryMailboxBytes,
                max(groupTextByteCount, proportionalByteCount)
            )
            deliveries.append(
                DeferredTextDelivery(
                    sessionID: delta.sessionID,
                    messageID: delta.messageID,
                    partID: delta.partID,
                    field: delta.field,
                    fragments: groupFragments,
                    mailboxByteCount: boundedByteCount,
                    textByteCount: groupTextByteCount,
                    retainsRawEvent: retainsRawEvent
                )
            )
            remainingSourceByteCount = max(0, remainingSourceByteCount - boundedByteCount)
            remainingTextByteCount = max(0, remainingTextByteCount - groupTextByteCount)
            groupFragments = []
            groupTextByteCount = 0
        }

        for fragment in fragments {
            let fragmentByteCount = fragment.utf8.count
            if !groupFragments.isEmpty,
               groupTextByteCount + fragmentByteCount > Self.maximumTextDeliveryTextBytes {
                appendGroup()
            }
            groupFragments.append(fragment)
            groupTextByteCount += fragmentByteCount
        }
        appendGroup()
        return deliveries
    }

    private func splitTextForBoundedDelivery(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }

        var fragments: [String] = []
        var current = String.UnicodeScalarView()
        var currentByteCount = 0

        for scalar in text.unicodeScalars {
            let scalarByteCount = scalar.utf8.count
            if !current.isEmpty,
               currentByteCount + scalarByteCount > Self.maximumTextDeliveryTextBytes {
                fragments.append(String(current))
                current = String.UnicodeScalarView()
                currentByteCount = 0
            }
            current.append(scalar)
            currentByteCount += scalarByteCount
        }

        if !current.isEmpty {
            fragments.append(String(current))
        }
        return fragments
    }

    private var hasDeferredInboundDeliveries: Bool {
        deferredInboundDeliveryHead < deferredInboundDeliveries.count
    }

    private func enqueueOrDeliverTextGroup(_ delivery: DeferredTextDelivery) {
        if hasDeferredInboundDeliveries || !canQueueBoundedTextDelivery(delivery.mailboxByteCount) {
            enqueueDeferredInboundDelivery(.text(delivery))
            return
        }
        deliverTextGroupImmediately(delivery)
    }

    private func deliverTextGroupImmediately(_ delivery: DeferredTextDelivery) {
        let text = delivery.fragments.joined()
        ChatStreamInstrumentation.recordCoalescedTextDelta(characterCount: text.count)
        let delta = SSETextDelta(
            sessionID: delivery.sessionID,
            messageID: delivery.messageID,
            partID: delivery.partID,
            field: delivery.field,
            text: text
        )
        let rawEvent = delivery.retainsRawEvent ? delta.asRawEvent : nil
        deliverInboundEventImmediately(
            .textDelta(delta, rawEvent: rawEvent),
            byteCount: delivery.mailboxByteCount
        )
    }

    private func canQueueBoundedTextDelivery(_ byteCount: Int) -> Bool {
        let normalizedByteCount = max(0, byteCount)
        return pendingMainEvents.count < Self.mainMailboxHighWatermark
            && outstandingMainDeliveryByteCount <= Self.mainMailboxHighWatermarkBytes - normalizedByteCount
    }

    private func enqueueDeferredInboundDelivery(_ delivery: DeferredInboundDelivery) {
        let deliveryCount = deferredInboundDeliveries.count - deferredInboundDeliveryHead
        guard deliveryCount < Self.maximumDeferredInboundDeliveryCount else {
            deferredInboundDeliveries.removeAll()
            deferredInboundDeliveryHead = 0
            cancelOversizedRecord("bounded text delivery FIFO exceeded \(Self.maximumDeferredInboundDeliveryCount) entries")
            return
        }

        deferredInboundDeliveries.append(delivery)
        pauseTransportForMainBackpressureIfNeeded()
    }

    private func drainDeferredInboundDeliveriesIfPossible() {
        guard hasDeferredInboundDeliveries else { return }

        let next = deferredInboundDeliveries[deferredInboundDeliveryHead]
        switch next {
        case .text(let delivery):
            guard canQueueBoundedTextDelivery(delivery.mailboxByteCount) else { return }
            deferredInboundDeliveryHead += 1
            compactDeferredInboundDeliveriesIfNeeded()
            deliverTextGroupImmediately(delivery)

        case .event(let event, let byteCount):
            deferredInboundDeliveryHead += 1
            compactDeferredInboundDeliveriesIfNeeded()
            deliverInboundEventImmediately(event, byteCount: byteCount)
        }
    }

    private func compactDeferredInboundDeliveriesIfNeeded() {
        guard deferredInboundDeliveryHead > 0 else { return }
        if deferredInboundDeliveryHead == deferredInboundDeliveries.count {
            deferredInboundDeliveries.removeAll(keepingCapacity: true)
            deferredInboundDeliveryHead = 0
        } else if deferredInboundDeliveryHead >= 16 {
            deferredInboundDeliveries.removeFirst(deferredInboundDeliveryHead)
            deferredInboundDeliveryHead = 0
        }
    }

    private func clearDeferredInboundDeliveries() {
        deferredInboundDeliveries.removeAll(keepingCapacity: true)
        deferredInboundDeliveryHead = 0
    }

    private func enqueuePartUpdate(
        _ part: OCPart,
        textChunks: [String]?,
        questionPayload: PreparedQuestionToolPayload?,
        rawEvent: OCEvent?,
        mailboxByteCount: Int
    ) {
        // Text/reasoning snapshots are reducible. Tool state transitions remain
        // ordering barriers, but duplicate snapshots of the *same* status can
        // share the same short coalescing window.
        guard part.type == .text || part.type == .reasoning || part.type == .tool else {
            flushPendingPartUpdate()
            deliverInboundEvent(
                .partUpdated(
                    part: part,
                    textChunks: textChunks,
                    questionPayload: questionPayload,
                    rawEvent: rawEvent
                ),
                byteCount: mailboxByteCount
            )
            return
        }

        if let pending = pendingPartUpdate,
           pending.part.id == part.id,
           pending.part.messageID == part.messageID,
           pending.part.sessionID == part.sessionID,
            pending.part.type == part.type {
            if part.type != .tool || pending.part.state?.status == part.state?.status {
                pendingPartUpdate = PendingPartUpdate(
                    part: part,
                    textChunks: textChunks,
                    questionPayload: questionPayload,
                    rawEvent: rawEvent,
                    mailboxByteCount: max(0, mailboxByteCount)
                )
            } else {
                // Never collapse `running → completed/error`: the UI and
                // activity feed need to observe that state transition.
                flushPendingPartUpdate()
                pendingPartUpdate = PendingPartUpdate(
                    part: part,
                    textChunks: textChunks,
                    questionPayload: questionPayload,
                    rawEvent: rawEvent,
                    mailboxByteCount: max(0, mailboxByteCount)
                )
            }
        } else {
            flushPendingPartUpdate()
            pendingPartUpdate = PendingPartUpdate(
                part: part,
                textChunks: textChunks,
                questionPayload: questionPayload,
                rawEvent: rawEvent,
                mailboxByteCount: max(0, mailboxByteCount)
            )
        }

        schedulePendingPartUpdateFlush()
    }

    private func schedulePendingPartUpdateFlush() {
        guard pendingPartUpdateWorkItem == nil else { return }

        let workItem = DispatchWorkItem { [weak self] in
            self?.flushPendingPartUpdate()
        }
        pendingPartUpdateWorkItem = workItem
        queue.asyncAfter(deadline: .now() + Self.textDeltaCoalescingInterval, execute: workItem)
    }

    private func flushPendingPartUpdate() {
        pendingPartUpdateWorkItem?.cancel()
        pendingPartUpdateWorkItem = nil

        guard let pending = pendingPartUpdate else { return }
        pendingPartUpdate = nil
        deliverInboundEvent(
            .partUpdated(
                part: pending.part,
                textChunks: pending.textChunks,
                questionPayload: pending.questionPayload,
                rawEvent: pending.rawEvent
            ),
            byteCount: pending.mailboxByteCount
        )
    }

    private func deliverInboundEvent(_ inboundEvent: SSEInboundEvent, byteCount: Int) {
        // A split text delta may still have suffix groups waiting on the worker.
        // Every later event must queue behind those groups, otherwise a tool
        // barrier could become visible before the text that preceded it.
        if hasDeferredInboundDeliveries {
            enqueueDeferredInboundDelivery(.event(inboundEvent, byteCount: byteCount))
            return
        }

        deliverInboundEventImmediately(inboundEvent, byteCount: byteCount)
    }

    private func deliverInboundEventImmediately(_ inboundEvent: SSEInboundEvent, byteCount: Int) {
        if !coalesceMainMailbox(with: inboundEvent, byteCount: byteCount) {
            precondition(
                pendingMainEvents.append(inboundEvent, byteCount: byteCount),
                "Transport backpressure must keep the main event mailbox below capacity"
            )
        }
        scheduleMainDeliveryIfNeeded()
        pauseTransportForMainBackpressureIfNeeded()
    }

    /// Runs only on `queue`; merges work that accumulated while MainActor was
    /// occupied. Tool transitions stay distinct, while adjacent snapshots retain
    /// only their newest authoritative state. Text deltas deliberately do not
    /// concatenate here: doing so copied/chunked the growing transcript on every
    /// mailbox update. Backpressure now bounds their count without losing data.
    private func coalesceMainMailbox(with incoming: SSEInboundEvent, byteCount: Int) -> Bool {
        guard let last = pendingMainEvents.last else { return false }

        switch (last, incoming) {
        case let (
            .partUpdated(existing, _, _, _),
            .partUpdated(next, nextChunks, nextQuestionPayload, nextRaw)
        )
            where (existing.type == .text || existing.type == .reasoning)
                && existing.type == next.type
                && existing.id == next.id
                && existing.messageID == next.messageID
                && existing.sessionID == next.sessionID:
            pendingMainEvents.replaceLast(with: .partUpdated(
                part: next,
                textChunks: nextChunks,
                questionPayload: nextQuestionPayload,
                rawEvent: nextRaw
            ), byteCount: byteCount)
            return true

        case let (
            .partUpdated(existing, _, _, _),
            .partUpdated(next, nextChunks, nextQuestionPayload, nextRaw)
        )
            where existing.type == .tool
                && next.type == .tool
                && existing.id == next.id
                && existing.messageID == next.messageID
                && existing.sessionID == next.sessionID
                && existing.state?.status == next.state?.status:
            // Preserve all status transitions as barriers, but a backlog does
            // not need every repeated `running` (or duplicate `completed`)
            // snapshot for the same tool row.
            pendingMainEvents.replaceLast(with: .partUpdated(
                part: next,
                textChunks: nextChunks,
                questionPayload: nextQuestionPayload,
                rawEvent: nextRaw
            ), byteCount: byteCount)
            return true

        default:
            return false
        }
    }

    /// Must run on `queue`. Deferring batch selection by one queue turn lets
    /// all records decoded from the current URLSession callback enter the
    /// mailbox before a ticket claims the bounded prefix.
    private func scheduleMainDeliveryIfNeeded() {
        guard !isConsumerBackpressured,
              activeMainDeliveryTicket == nil,
              !pendingMainEvents.isEmpty || pendingHeartbeat != nil,
              !mainDeliverySelectionScheduled
        else { return }

        mainDeliverySelectionScheduled = true
        queue.async { [weak self] in
            guard let self else { return }
            self.mainDeliverySelectionScheduled = false
            self.beginMainDeliveryIfNeeded()
        }
    }

    /// Must run on `queue`. It removes the next batch before scheduling the
    /// main callback, so MainActor never synchronously waits for this worker
    /// queue while it is decoding or reducing incoming SSE data.
    private func beginMainDeliveryIfNeeded() {
        guard !isConsumerBackpressured,
              activeMainDeliveryTicket == nil else { return }

        let batch: MainEventMailbox.DeliveryBatch
        if !pendingMainEvents.isEmpty {
            batch = pendingMainEvents.dequeue(upTo: Self.mainDeliveryBatchLimit)
        } else if let heartbeat = pendingHeartbeat {
            // The latest heartbeat is sufficient to refresh liveness. It is
            // sent only after all ordered transcript/tool events ahead of it.
            pendingHeartbeat = nil
            batch = MainEventMailbox.DeliveryBatch(events: [.raw(heartbeat)], byteCount: 0)
        } else {
            return
        }

        let ticket = MainDeliveryTicket()
        let rawCallback = onEvent
        let inboundCallback = onInboundEvent
        activeMainDeliveryTicket = ticket
        activeMainDeliveryByteCount = batch.byteCount

        // Removing a batch may create room for the suspended transport. This
        // also drains already-received bytes on the worker before new network
        // callbacks arrive, preserving FIFO order.
        resumeTransportFromMainBackpressureIfPossible()

        DispatchQueue.main.async { [weak self] in
            self?.deliverMainBatch(
                batch.events,
                rawCallback: rawCallback,
                inboundCallback: inboundCallback,
                ticket: ticket
            )
        }
    }

    /// Runs on MainActor. `ticket` is invalidated by an explicit disconnect or
    /// session reset, so stale enqueued batches cannot affect the next stream.
    private func deliverMainBatch(
        _ events: [SSEInboundEvent],
        rawCallback: ((OCEvent) -> Void)?,
        inboundCallback: ((SSEInboundEvent) -> Void)?,
        ticket: MainDeliveryTicket
    ) {
        defer { acknowledgeMainDelivery(ticket) }

        for event in events {
            guard ticket.isValid else { return }
            if let rawEvent = event.rawEvent {
                rawCallback?(rawEvent)
            }
            inboundCallback?(event)
        }
    }

    /// Switches the mailbox back to the worker queue after MainActor applies a
    /// batch. A delayed acknowledgment for an invalidated ticket is ignored.
    private func acknowledgeMainDelivery(_ ticket: MainDeliveryTicket) {
        queue.async { [weak self] in
            guard let self, self.activeMainDeliveryTicket === ticket else { return }
            self.activeMainDeliveryTicket = nil
            self.activeMainDeliveryByteCount = 0
            self.drainDeferredInboundDeliveriesIfPossible()
            if !self.hasDeferredInboundDeliveries {
                self.flushPendingTextDelta()
            }
            self.resumeTransportFromMainBackpressureIfPossible()
            self.scheduleMainDeliveryIfNeeded()
        }
    }

    /// Must run on `queue`. Used only for an explicit disconnect/reset, not a
    /// transient transport completion that may carry a final `idle` event.
    private func invalidateMainMailbox() {
        pendingMainEvents.removeAll()
        pendingHeartbeat = nil
        clearDeferredInboundDeliveries()
        activeMainDeliveryTicket?.invalidate()
        activeMainDeliveryTicket = nil
        activeMainDeliveryByteCount = 0
    }

    private var outstandingMainDeliveryByteCount: Int {
        saturatedByteCount(pendingMainEvents.totalByteCount, plus: activeMainDeliveryByteCount)
    }

    private var needsMainBackpressure: Bool {
        isConsumerBackpressured
            || hasDeferredInboundDeliveries
            || pendingMainEvents.count >= Self.mainMailboxHighWatermark
            || outstandingMainDeliveryByteCount >= Self.mainMailboxHighWatermarkBytes
    }

    /// Pauses network delivery before the fixed mailbox reaches either its
    /// event-count or byte budget. The high watermark leaves enough headroom
    /// for one record's ordering-barrier flushes, so `deliverInboundEvent`
    /// never needs to discard an event.
    private func pauseTransportForMainBackpressureIfNeeded() {
        guard needsMainBackpressure, !isTransportPausedForMainBackpressure else { return }

        isTransportPausedForMainBackpressure = true
        if eventStream != nil {
            transportTaskSuspendedByBackpressure = true
            eventStream?.suspend()
        } else if task?.state == .running {
            transportTaskSuspendedByBackpressure = true
            task?.suspend()
        }
    }

    /// Resumes only after the ordered queue and the active main-delivery batch
    /// are below their low watermarks, and any coalesced heartbeat has been
    /// selected for delivery. Holding the transport until then guarantees a
    /// real liveness callback after a blocked main turn.
    private func resumeTransportFromMainBackpressureIfPossible() {
        guard isTransportPausedForMainBackpressure,
              !needsMainBackpressure,
              pendingMainEvents.count <= Self.mainMailboxLowWatermark,
              outstandingMainDeliveryByteCount <= Self.mainMailboxLowWatermarkBytes,
              pendingHeartbeat == nil,
              !oversizedRecordCancellationPending
        else { return }

        isTransportPausedForMainBackpressure = false
        if transportTaskSuspendedByBackpressure {
            transportTaskSuspendedByBackpressure = false
            if let eventStream {
                eventStream.resume()
            } else {
                task?.resume()
            }
        }

        processBuffer()
    }

    /// Extracts the value after `data:` from a single SSE line, or returns `nil` if not a data line.
    private func extractDataField(from line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let afterPrefix = line.dropFirst(5) // "data:" is 5 characters
        // SSE spec: if character after the colon is a space, skip it.
        if afterPrefix.first == " " {
            return String(afterPrefix.dropFirst())
        }
        return String(afterPrefix)
    }

    // MARK: - Reconnect (called on `queue`)

    private func scheduleReconnect() {
        guard shouldReconnect, eventStream == nil, task == nil, session == nil else { return }

        reconnectWorkItem?.cancel()

        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * Self.reconnectBackoffMultiplier, Self.maxReconnectDelay)

        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.shouldReconnect,
                  self.state == .disconnected,
                  self.eventStream == nil,
                  self.task == nil,
                  self.session == nil
            else { return }

            self.reconnectWorkItem = nil
            self.startConnection()
        }
        reconnectWorkItem = workItem
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    // MARK: - State Management

    /// Updates `state` and notifies the callback on the main queue. Thread-safe.
    private func updateState(_ newState: ConnectionState) {
        let deliveryGate = stateDeliveryGate
        guard let generation = deliveryGate.deliveryGeneration(for: newState),
              state != newState
        else { return }

        state = newState
        let callback = onStateChange
        DispatchQueue.main.async {
            guard deliveryGate.isCurrent(generation) else { return }
            callback?(newState)
        }
    }

    /// URLSession may deliver cancellation/completion callbacks for an old
    /// stream after a manual reconnect has created a newer one. Every delegate
    /// entry point must reject those callbacks before touching shared state.
    private func isCurrentConnection(session: URLSession, task: URLSessionTask) -> Bool {
        guard let activeSession = self.session,
              let activeTask = self.task
        else {
            return false
        }

        return session === activeSession && task === activeTask
    }
}

#if DEBUG
extension SSEClient {
    /// Test-only seam that installs a connection identity without opening a
    /// network stream. It keeps lifecycle tests on the same serial queue as
    /// real URLSession delegate callbacks.
    func installActiveConnectionForTesting(session: URLSession, task: URLSessionDataTask) {
        queue.sync {
            reconnectWorkItem?.cancel()
            reconnectWorkItem = nil
            resetFramingBuffer()
            pendingMainEvents.removeAll()
            pendingHeartbeat = nil
            clearDeferredInboundDeliveries()
            activeMainDeliveryTicket?.invalidate()
            activeMainDeliveryTicket = nil
            activeMainDeliveryByteCount = 0
            isConsumerBackpressured = false
            isTransportPausedForMainBackpressure = false
            transportTaskSuspendedByBackpressure = false
            oversizedRecordCancellationPending = false
            pendingTransportCompletion = nil
#if DEBUG
            oversizedRecordCancellationCountForTesting = 0
#endif
            self.session = session
            self.task = task
            state = .connected
        }
    }

    func receiveDataForTesting(session: URLSession, task: URLSessionDataTask, data: Data) {
        queue.sync {
            urlSession(session, dataTask: task, didReceive: data)
        }
    }

    func receiveResponseForTesting(
        session: URLSession,
        task: URLSessionDataTask,
        response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        queue.sync {
            urlSession(session, dataTask: task, didReceive: response, completionHandler: completionHandler)
        }
    }

    func completeForTesting(session: URLSession, task: URLSessionTask) {
        queue.sync {
            urlSession(session, task: task, didCompleteWithError: nil)
        }
    }

    var hasPendingReconnectForTesting: Bool {
        queue.sync { reconnectWorkItem != nil }
    }

    var isTransportPausedForTesting: Bool {
        queue.sync { isTransportPausedForMainBackpressure }
    }

    var isConsumerBackpressuredForTesting: Bool {
        queue.sync { isConsumerBackpressured }
    }

    var outstandingMainDeliveryByteCountForTesting: Int {
        queue.sync { outstandingMainDeliveryByteCount }
    }

    var hasOversizedRecordCancellationForTesting: Bool {
        queue.sync { oversizedRecordCancellationCountForTesting > 0 }
    }

    func updateStateForTesting(_ state: ConnectionState) {
        queue.sync {
            updateState(state)
        }
    }

    func setConnectionStartHandlerForTesting(_ handler: @escaping () -> Void) {
        queue.sync {
            connectionStartHandlerForTesting = handler
        }
    }
}
#endif
