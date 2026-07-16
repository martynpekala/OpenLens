import Foundation

nonisolated struct OpenCodeEventStreamCallbacks: @unchecked Sendable {
    let onResponse: (URLResponse) -> Bool
    let onData: (Data) -> Void
    let onComplete: (Error?) -> Void
}

nonisolated protocol OpenCodeEventStream: AnyObject, Sendable {
    func start()
    func suspend()
    func resume()
    func cancel()
}

/// The only transport seam below the OpenCode facade. Both implementations
/// execute the same URLRequest contract and expose the same raw SSE byte stream.
nonisolated protocol OpenCodeTransport: AnyObject, Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
    func makeEventStream(
        request: URLRequest,
        deliveryQueue: DispatchQueue,
        callbacks: OpenCodeEventStreamCallbacks
    ) -> any OpenCodeEventStream
}

nonisolated final class DirectOpenCodeTransport: OpenCodeTransport, @unchecked Sendable {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        configuration.waitsForConnectivity = true
        session = URLSession(configuration: configuration)
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }

    func makeEventStream(
        request: URLRequest,
        deliveryQueue: DispatchQueue,
        callbacks: OpenCodeEventStreamCallbacks
    ) -> any OpenCodeEventStream {
        DirectOpenCodeEventStream(
            request: request,
            deliveryQueue: deliveryQueue,
            callbacks: callbacks
        )
    }
}

nonisolated private final class DirectOpenCodeEventStream: NSObject, OpenCodeEventStream, URLSessionDataDelegate, @unchecked Sendable {
    private let request: URLRequest
    private let deliveryQueue: DispatchQueue
    private let callbacks: OpenCodeEventStreamCallbacks
    private var session: URLSession?
    private var task: URLSessionDataTask?

    init(
        request: URLRequest,
        deliveryQueue: DispatchQueue,
        callbacks: OpenCodeEventStreamCallbacks
    ) {
        self.request = request
        self.deliveryQueue = deliveryQueue
        self.callbacks = callbacks
    }

    func start() {
        deliveryQueue.async { [self] in
            guard task == nil, session == nil else { return }

            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = .infinity
            configuration.timeoutIntervalForResource = .infinity

            let delegateQueue = OperationQueue()
            delegateQueue.underlyingQueue = deliveryQueue
            delegateQueue.maxConcurrentOperationCount = 1

            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
            let task = session.dataTask(with: request)
            self.session = session
            self.task = task
            task.resume()
        }
    }

    func suspend() {
        deliveryQueue.async { [weak self] in
            guard self?.task?.state == .running else { return }
            self?.task?.suspend()
        }
    }

    func resume() {
        deliveryQueue.async { [weak self] in
            guard self?.task?.state == .suspended else { return }
            self?.task?.resume()
        }
    }

    func cancel() {
        deliveryQueue.async { [weak self] in
            self?.task?.cancel()
            self?.task = nil
            self?.session?.invalidateAndCancel()
            self?.session = nil
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard session === self.session, dataTask === task else {
            completionHandler(.cancel)
            return
        }
        completionHandler(callbacks.onResponse(response) ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard session === self.session, dataTask === task else { return }
        callbacks.onData(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard session === self.session, task === self.task else { return }
        self.task = nil
        self.session?.finishTasksAndInvalidate()
        self.session = nil
        callbacks.onComplete(error)
    }
}

nonisolated final class RemoteOpenCodeTransport: OpenCodeTransport, @unchecked Sendable {
    private let session: RemoteWebSocketSession

    init(credential: RemoteDeviceCredential) {
        session = RemoteWebSocketSession(credential: credential)
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let response = try await session.perform(RemoteHTTPRequest(request: request))
        guard let url = request.url,
              let httpResponse = HTTPURLResponse(
                url: url,
                statusCode: response.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: response.headers
              )
        else {
            throw OpenCodeError.invalidResponse
        }
        return (response.body, httpResponse)
    }

    func makeEventStream(
        request: URLRequest,
        deliveryQueue: DispatchQueue,
        callbacks: OpenCodeEventStreamCallbacks
    ) -> any OpenCodeEventStream {
        RemoteOpenCodeEventStream(
            request: request,
            session: session,
            deliveryQueue: deliveryQueue,
            callbacks: callbacks
        )
    }

    func disconnect() {
        Task { await session.disconnect() }
    }
}

nonisolated private final class RemoteOpenCodeEventStream: OpenCodeEventStream, @unchecked Sendable {
    private let request: URLRequest
    private let session: RemoteWebSocketSession
    private let deliveryQueue: DispatchQueue
    private let callbacks: OpenCodeEventStreamCallbacks
    private let subscriptionID = UUID().uuidString
    private let lock = NSLock()
    private var isPaused = false
    private var isCancelled = false
    private var bufferedChunks: [Data] = []
    private var bufferedByteCount = 0
    private static let maximumBufferedBytes = RemoteProtocolVersion.maximumWireMessageBytes

    init(
        request: URLRequest,
        session: RemoteWebSocketSession,
        deliveryQueue: DispatchQueue,
        callbacks: OpenCodeEventStreamCallbacks
    ) {
        self.request = request
        self.session = session
        self.deliveryQueue = deliveryQueue
        self.callbacks = callbacks
    }

    func start() {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await session.subscribe(
                    id: subscriptionID,
                    request: RemoteHTTPRequest(request: request),
                    onOpened: { [weak self] statusCode, headers in
                        self?.opened(statusCode: statusCode, headers: headers)
                    },
                    onData: { [weak self] data in
                        self?.received(data)
                    },
                    onComplete: { [weak self] error in
                        self?.completed(error)
                    }
                )
            } catch {
                completed(error)
            }
        }
    }

    func suspend() {
        lock.lock()
        isPaused = true
        lock.unlock()
    }

    func resume() {
        lock.lock()
        guard !isCancelled else {
            lock.unlock()
            return
        }
        isPaused = false
        let chunks = bufferedChunks
        bufferedChunks.removeAll(keepingCapacity: false)
        bufferedByteCount = 0
        lock.unlock()

        for chunk in chunks {
            deliveryQueue.async { [callbacks] in callbacks.onData(chunk) }
        }
    }

    func cancel() {
        lock.lock()
        guard !isCancelled else {
            lock.unlock()
            return
        }
        isCancelled = true
        bufferedChunks.removeAll()
        bufferedByteCount = 0
        lock.unlock()
        Task { await session.unsubscribe(id: subscriptionID) }
    }

    private func opened(statusCode: Int, headers: [String: String]) {
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: headers
              )
        else {
            completed(OpenCodeError.invalidResponse)
            return
        }
        deliveryQueue.async { [callbacks] in
            if !callbacks.onResponse(response) {
                callbacks.onComplete(nil)
            }
        }
    }

    private func received(_ data: Data) {
        lock.lock()
        guard !isCancelled else {
            lock.unlock()
            return
        }
        if isPaused {
            let newByteCount = bufferedByteCount + data.count
            guard newByteCount <= Self.maximumBufferedBytes else {
                isCancelled = true
                bufferedChunks.removeAll()
                bufferedByteCount = 0
                lock.unlock()
                Task { await session.unsubscribe(id: subscriptionID) }
                deliveryQueue.async { [callbacks] in
                    callbacks.onComplete(RemoteProtocolError.messageTooLarge)
                }
                return
            }
            bufferedChunks.append(data)
            bufferedByteCount = newByteCount
            lock.unlock()
            return
        }
        lock.unlock()
        deliveryQueue.async { [callbacks] in callbacks.onData(data) }
    }

    private func completed(_ error: Error?) {
        lock.lock()
        guard !isCancelled else {
            lock.unlock()
            return
        }
        isCancelled = true
        bufferedChunks.removeAll()
        bufferedByteCount = 0
        lock.unlock()
        deliveryQueue.async { [callbacks] in callbacks.onComplete(error) }
    }
}

private actor RemoteWebSocketSession {
    struct EventSubscription: @unchecked Sendable {
        let onOpened: (Int, [String: String]) -> Void
        let onData: (Data) -> Void
        let onComplete: (Error?) -> Void
    }

    private let credential: RemoteDeviceCredential
    private let urlSession: URLSession
    private var webSocket: URLSessionWebSocketTask?
    private var connectTask: Task<Void, Error>?
    private var receiveTask: Task<Void, Never>?
    private var sessionID: String?
    private var encryptor: RemoteEncryptor?
    private var decryptor: RemoteDecryptor?
    private var pendingRequests: [String: CheckedContinuation<RemoteHTTPResponse, Error>] = [:]
    private var requestTimeouts: [String: Task<Void, Never>] = [:]
    private var subscriptions: [String: EventSubscription] = [:]

    init(credential: RemoteDeviceCredential) {
        self.credential = credential
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = .infinity
        urlSession = URLSession(configuration: configuration)
    }

    func perform(_ request: RemoteHTTPRequest) async throws -> RemoteHTTPResponse {
        try await ensureConnected()
        let message = RemoteMessage(kind: .request, request: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingRequests[message.id] = continuation
                requestTimeouts[message.id] = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(30))
                    await self?.timeOutRequest(id: message.id)
                }
                Task { [weak self] in
                    do {
                        try await self?.send(message)
                    } catch {
                        await self?.failRequest(id: message.id, error: error)
                    }
                }
            }
        } onCancel: {
            Task { [weak self] in
                await self?.failRequest(id: message.id, error: CancellationError())
            }
        }
    }

    func subscribe(
        id: String,
        request: RemoteHTTPRequest,
        onOpened: @escaping (Int, [String: String]) -> Void,
        onData: @escaping (Data) -> Void,
        onComplete: @escaping (Error?) -> Void
    ) async throws {
        try await ensureConnected()
        subscriptions[id] = EventSubscription(
            onOpened: onOpened,
            onData: onData,
            onComplete: onComplete
        )
        do {
            try await send(RemoteMessage(kind: .subscribeEvents, id: id, request: request))
        } catch {
            subscriptions.removeValue(forKey: id)
            throw error
        }
    }

    func unsubscribe(id: String) async {
        guard subscriptions.removeValue(forKey: id) != nil else { return }
        try? await send(RemoteMessage(kind: .unsubscribeEvents, id: id))
    }

    func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
        connectTask?.cancel()
        connectTask = nil
        sessionID = nil
        encryptor = nil
        decryptor = nil
        failAll(with: RemoteProtocolError.disconnected)
    }

    private func ensureConnected() async throws {
        if webSocket != nil, encryptor != nil, decryptor != nil { return }
        if let connectTask {
            try await connectTask.value
            return
        }

        let task = Task { [weak self] in
            guard let self else { throw RemoteProtocolError.disconnected }
            try await self.connect()
        }
        connectTask = task
        do {
            try await task.value
            connectTask = nil
        } catch {
            connectTask = nil
            webSocket?.cancel(with: .goingAway, reason: nil)
            webSocket = nil
            throw error
        }
    }

    private func connect() async throws {
        let privateKey = try RemoteCrypto.privateKey(rawRepresentation: credential.devicePrivateKey)
        let gatewayPublicKey = try RemoteCrypto.publicKey(rawRepresentation: credential.gatewayPublicKey)
        let sessionID = UUID().uuidString
        var request = URLRequest(url: try Self.webSocketURL(for: credential.endpoint))
        request.timeoutInterval = 30
        request.setValue(RemoteProtocolVersion.webSocketSubprotocol, forHTTPHeaderField: "Sec-WebSocket-Protocol")
        request.setValue(credential.accessCredential.clientID, forHTTPHeaderField: "CF-Access-Client-Id")
        request.setValue(credential.accessCredential.clientSecret, forHTTPHeaderField: "CF-Access-Client-Secret")
        request.setValue(sessionID, forHTTPHeaderField: "X-OpenLens-Handshake-ID")

        let socket = urlSession.webSocketTask(with: request)
        webSocket = socket
        socket.resume()

        var encryptor = try RemoteCrypto.deviceSessionSender(
            devicePrivateKey: privateKey,
            gatewayPublicKey: gatewayPublicKey,
            sessionID: sessionID
        )
        let hello = RemoteSessionHello(
            deviceName: credential.deviceName,
            protocolVersion: RemoteProtocolVersion.current
        )
        let sealed = try encryptor.seal(try JSONEncoder().encode(hello))
        let envelope = RemoteWireEnvelope(
            kind: .sessionHello,
            deviceID: credential.deviceID,
            sessionID: sessionID,
            encapsulatedKey: encryptor.encapsulatedKey,
            sequence: sealed.sequence,
            ciphertext: sealed.ciphertext
        )
        try await socket.send(.data(try envelope.encoded()))

        let welcomeWire = try await Self.receiveWithTimeout(from: socket)
        let welcomeEnvelope = try RemoteWireEnvelope.decode(try Self.data(from: welcomeWire))
        guard welcomeEnvelope.kind == .sessionWelcome,
              welcomeEnvelope.deviceID == credential.deviceID,
              welcomeEnvelope.sessionID == sessionID,
              let encapsulatedKey = welcomeEnvelope.encapsulatedKey,
              let sequence = welcomeEnvelope.sequence,
              let ciphertext = welcomeEnvelope.ciphertext
        else {
            throw RemoteProtocolError.authenticationFailed
        }
        var decryptor = try RemoteCrypto.deviceSessionRecipient(
            devicePrivateKey: privateKey,
            gatewayPublicKey: gatewayPublicKey,
            sessionID: sessionID,
            encapsulatedKey: encapsulatedKey
        )
        let welcome = try JSONDecoder().decode(
            RemoteSessionWelcome.self,
            from: decryptor.open(sequence: sequence, ciphertext: ciphertext)
        )
        guard welcome.gatewayID == credential.gatewayID,
              welcome.protocolVersion == RemoteProtocolVersion.current
        else {
            throw RemoteProtocolError.authenticationFailed
        }

        self.sessionID = sessionID
        self.encryptor = encryptor
        self.decryptor = decryptor
        receiveTask = Task { [weak self] in
            await self?.receiveLoop(socket: socket, expectedSessionID: sessionID)
        }
    }

    private func send(_ message: RemoteMessage) async throws {
        guard let webSocket, let sessionID, var encryptor else {
            throw RemoteProtocolError.disconnected
        }
        let sealed = try encryptor.seal(try message.encoded())
        self.encryptor = encryptor
        let envelope = RemoteWireEnvelope(
            kind: .encrypted,
            deviceID: credential.deviceID,
            sessionID: sessionID,
            sequence: sealed.sequence,
            ciphertext: sealed.ciphertext
        )
        try await webSocket.send(.data(try envelope.encoded()))
    }

    private func receiveLoop(socket: URLSessionWebSocketTask, expectedSessionID: String) async {
        do {
            while !Task.isCancelled {
                let wire = try await socket.receive()
                let envelope = try RemoteWireEnvelope.decode(try Self.data(from: wire))
                guard envelope.kind == .encrypted,
                      envelope.deviceID == credential.deviceID,
                      envelope.sessionID == expectedSessionID,
                      let sequence = envelope.sequence,
                      let ciphertext = envelope.ciphertext,
                      var decryptor
                else {
                    throw RemoteProtocolError.authenticationFailed
                }
                let message = try RemoteMessage.decode(
                    try decryptor.open(sequence: sequence, ciphertext: ciphertext)
                )
                self.decryptor = decryptor
                try await handle(message)
            }
        } catch {
            guard webSocket === socket else { return }
            self.webSocket = nil
            sessionID = nil
            encryptor = nil
            decryptor = nil
            receiveTask = nil
            failAll(with: error)
        }
    }

    private func handle(_ message: RemoteMessage) async throws {
        switch message.kind {
        case .response:
            guard let continuation = pendingRequests.removeValue(forKey: message.id),
                  let response = message.response
            else { return }
            requestTimeouts.removeValue(forKey: message.id)?.cancel()
            continuation.resume(returning: response)

        case .eventOpened:
            subscriptions[message.id]?.onOpened(message.statusCode ?? 200, message.response?.headers ?? [:])

        case .eventData:
            if let payload = message.payload {
                subscriptions[message.id]?.onData(payload)
            }

        case .eventCompleted:
            let subscription = subscriptions.removeValue(forKey: message.id)
            subscription?.onComplete(message.errorCode.map(RemoteProtocolError.remoteError))

        case .ping:
            try await send(RemoteMessage(kind: .pong, id: message.id))

        case .error:
            if let continuation = pendingRequests.removeValue(forKey: message.id) {
                requestTimeouts.removeValue(forKey: message.id)?.cancel()
                continuation.resume(throwing: RemoteProtocolError.remoteError(message.errorCode ?? "unknown"))
            } else if let subscription = subscriptions.removeValue(forKey: message.id) {
                subscription.onComplete(RemoteProtocolError.remoteError(message.errorCode ?? "unknown"))
            }

        case .sessionHello, .sessionWelcome, .request, .subscribeEvents,
             .unsubscribeEvents, .pong:
            break
        }
    }

    private func timeOutRequest(id: String) {
        failRequest(id: id, error: RemoteProtocolError.timeout)
    }

    private func failRequest(id: String, error: Error) {
        requestTimeouts.removeValue(forKey: id)?.cancel()
        pendingRequests.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func failAll(with error: Error) {
        let continuations = pendingRequests.values
        pendingRequests.removeAll()
        requestTimeouts.values.forEach { $0.cancel() }
        requestTimeouts.removeAll()
        continuations.forEach { $0.resume(throwing: error) }

        let activeSubscriptions = subscriptions.values
        subscriptions.removeAll()
        activeSubscriptions.forEach { $0.onComplete(error) }
    }

    static func webSocketURL(for endpoint: URL) throws -> URL {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw RemoteProtocolError.invalidPairingOffer
        }
        switch components.scheme?.lowercased() {
        case "https": components.scheme = "wss"
#if DEBUG
        case "http": components.scheme = "ws"
#endif
        default: throw RemoteProtocolError.invalidPairingOffer
        }
        components.path = "/remote"
        components.query = nil
        guard let url = components.url else { throw RemoteProtocolError.invalidPairingOffer }
        return url
    }

    static func data(from message: URLSessionWebSocketTask.Message) throws -> Data {
        switch message {
        case .data(let data): return data
        case .string(let string):
            guard let data = string.data(using: .utf8) else {
                throw RemoteProtocolError.malformedMessage
            }
            return data
        @unknown default:
            throw RemoteProtocolError.malformedMessage
        }
    }


    static func receiveWithTimeout(
        from socket: URLSessionWebSocketTask
    ) async throws -> URLSessionWebSocketTask.Message {
        try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
            group.addTask { try await socket.receive() }
            group.addTask {
                try await Task.sleep(for: .seconds(30))
                socket.cancel(with: .goingAway, reason: nil)
                throw RemoteProtocolError.timeout
            }
            guard let message = try await group.next() else {
                throw RemoteProtocolError.disconnected
            }
            group.cancelAll()
            return message
        }
    }
}
