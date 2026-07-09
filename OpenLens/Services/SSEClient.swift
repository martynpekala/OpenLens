import Foundation
import os

func isTerminalSSEHTTPStatus(_ statusCode: Int) -> Bool {
    statusCode == 401 || statusCode == 403
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
        var delta: String
    }

    // MARK: - Public (read-only)

    /// Current connection state. Always updated on the main queue.
    private(set) var state: ConnectionState = .disconnected

    /// Called on every parsed SSE event (main queue).
    var onEvent: ((OCEvent) -> Void)?

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
    private var buffer: String = ""
    private var task: URLSessionDataTask?
    private var session: URLSession?
    private var reconnectWorkItem: DispatchWorkItem?
    private var pendingTextDelta: PendingTextDelta?
    private var pendingTextDeltaWorkItem: DispatchWorkItem?
    private var lastResponseStatusCode: Int?

    // MARK: - Constants

    private static let initialReconnectDelay: TimeInterval = 2.0
    private static let maxReconnectDelay: TimeInterval = 30.0
    private static let reconnectBackoffMultiplier: Double = 1.5
    private static let textDeltaCoalescingInterval: TimeInterval = 0.02

    // MARK: - Init

    init(baseURL: URL, authHeader: String? = nil) {
        self.baseURL = baseURL
        self.authHeader = authHeader
        super.init()
    }

    func updateConnection(baseURL: URL, authHeader: String?) {
        queue.async { [self] in
            self.baseURL = baseURL
            self.authHeader = authHeader
        }
    }

    // MARK: - Connect / Disconnect

    func connect() {
        queue.async { [self] in
            guard state == .disconnected else { return }
            shouldReconnect = true
            reconnectDelay = Self.initialReconnectDelay
            startConnection()
        }
    }

    func disconnect() {
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
        updateState(.connecting)

        let url = baseURL.appending(path: "event")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = .infinity
        if let authHeader {
            request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = .infinity
        config.timeoutIntervalForResource = .infinity

        // Delegate callbacks are dispatched onto our serial queue for thread safety.
        let delegateQueue = OperationQueue()
        delegateQueue.underlyingQueue = queue
        delegateQueue.maxConcurrentOperationCount = 1

        let newSession = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
        self.session = newSession

        buffer = ""
        let dataTask = newSession.dataTask(with: request)
        self.task = dataTask
        dataTask.resume()
    }

    /// Cancels the current task/session and resets transient state. Must be called on `queue`.
    private func cleanupConnection() {
        pendingTextDeltaWorkItem?.cancel()
        pendingTextDeltaWorkItem = nil
        pendingTextDelta = nil
        task?.cancel()
        task = nil
        session?.invalidateAndCancel()
        session = nil
        buffer = ""
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        // Already on `queue` (delegateQueue).
        if let http = response as? HTTPURLResponse {
            lastResponseStatusCode = http.statusCode

            if http.statusCode == 200 {
                reconnectDelay = Self.initialReconnectDelay
                updateState(.connected)
                completionHandler(.allow)
                return
            }

            if isTerminalSSEHTTPStatus(http.statusCode) {
                shouldReconnect = false
                let callback = onTerminalHTTPError
                let statusCode = http.statusCode
                DispatchQueue.main.async {
                    callback?(statusCode)
                }
                completionHandler(.cancel)
                return
            }
        }

        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // Already on `queue`.
        ChatStreamInstrumentation.recordSSEReceive(byteCount: data.count)
        guard let text = String(data: data, encoding: .utf8) else { return }
        buffer += text
        processBuffer()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Already on `queue`.
        flushPendingTextDelta()
        let statusCode = lastResponseStatusCode
        lastResponseStatusCode = nil
        cleanupConnection()
        updateState(.disconnected)

        if let statusCode, isTerminalSSEHTTPStatus(statusCode) {
            return
        }

        scheduleReconnect()
    }

    // MARK: - SSE Parsing (called on `queue`)

    private func processBuffer() {
        let events = buffer.components(separatedBy: "\n\n")

        // Keep the last incomplete chunk in the buffer.
        if buffer.hasSuffix("\n\n") {
            buffer = ""
            events.forEach { parseEvent($0) }
        } else {
            buffer = events.last ?? ""
            events.dropLast().forEach { parseEvent($0) }
        }
    }

    private func parseEvent(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var data: String?

        for line in trimmed.components(separatedBy: "\n") {
            guard let dataValue = extractDataField(from: line) else { continue }
            if data == nil {
                data = dataValue
            } else {
                data!.append("\n" + dataValue)
            }
        }

        guard let jsonString = data,
              let jsonData = jsonString.data(using: .utf8) else { return }

        let signpostID = ChatStreamInstrumentation.beginSSEDecode(byteCount: jsonData.count)
        defer {
            ChatStreamInstrumentation.endSSEDecode(signpostID)
        }

        do {
            let event = try JSONDecoder().decode(OCEvent.self, from: jsonData)
            enqueueEvent(event)
        } catch {
            Logger.sse.error("Parse error: \(error, privacy: .public) for data: \(jsonString.prefix(200), privacy: .private)")
        }
    }

    private func enqueueEvent(_ event: OCEvent) {
        guard !coalesceTextDeltaIfNeeded(event) else { return }
        flushPendingTextDelta()
        deliverEvent(event)
    }

    private func coalesceTextDeltaIfNeeded(_ event: OCEvent) -> Bool {
        guard event.type == "message.part.delta",
              let props = event.properties?.value as? [String: Any],
              let sessionID = props["sessionID"] as? String,
              let messageID = props["messageID"] as? String,
              let field = props["field"] as? String,
              field == "text",
              let delta = props["delta"] as? String
        else {
            return false
        }

        let partID = props["partID"] as? String ?? props["partId"] as? String

        if var pending = pendingTextDelta,
           pending.sessionID == sessionID,
           pending.messageID == messageID,
           pending.partID == partID,
           pending.field == field {
            pending.delta.append(delta)
            pendingTextDelta = pending
        } else {
            flushPendingTextDelta()
            pendingTextDelta = PendingTextDelta(
                sessionID: sessionID,
                messageID: messageID,
                partID: partID,
                field: field,
                delta: delta
            )
        }

        schedulePendingTextDeltaFlush()
        return true
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

        ChatStreamInstrumentation.recordCoalescedTextDelta(characterCount: pending.delta.count)
        var properties: [String: Any] = [
            "sessionID": pending.sessionID,
            "messageID": pending.messageID,
            "field": pending.field,
            "delta": pending.delta,
        ]
        if let partID = pending.partID {
            properties["partID"] = partID
        }

        deliverEvent(
            OCEvent(
                type: "message.part.delta",
                properties: AnyCodable(properties)
            )
        )
    }

    private func deliverEvent(_ event: OCEvent) {
        let callback = onEvent
        DispatchQueue.main.async {
            callback?(event)
        }
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
        guard shouldReconnect else { return }

        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * Self.reconnectBackoffMultiplier, Self.maxReconnectDelay)

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.shouldReconnect else { return }
            self.startConnection()
        }
        reconnectWorkItem = workItem
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    // MARK: - State Management

    /// Updates `state` and notifies the callback on the main queue. Thread-safe.
    private func updateState(_ newState: ConnectionState) {
        guard state != newState else { return }
        state = newState
        let callback = onStateChange
        DispatchQueue.main.async {
            callback?(newState)
        }
    }
}
