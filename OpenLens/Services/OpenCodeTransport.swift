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
