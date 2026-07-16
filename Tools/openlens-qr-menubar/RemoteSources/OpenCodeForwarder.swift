import Foundation

final class OpenCodeForwarder: @unchecked Sendable {
    private let workspaceRegistry: WorkspaceRegistry
    private let authHeader: String
    private let session: URLSession

    init(workspaceRegistry: WorkspaceRegistry, password: String) {
        self.workspaceRegistry = workspaceRegistry
        authHeader = "Basic " + Data("opencode:\(password)".utf8).base64EncodedString()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        session = URLSession(configuration: configuration)
    }

    func perform(_ request: RemoteHTTPRequest) async throws -> RemoteHTTPResponse {
        let localRequest = try makeLocalRequest(from: request, requiresEventStream: false)
        let (data, response) = try await session.data(for: localRequest)
        guard let http = response as? HTTPURLResponse else {
            throw RemoteProtocolError.remoteError("invalid_local_response")
        }
        guard data.count <= RemoteProtocolVersion.maximumHTTPBodyBytes else {
            throw RemoteProtocolError.messageTooLarge
        }
        return RemoteHTTPResponse(
            statusCode: http.statusCode,
            headers: Self.forwardedResponseHeaders(http),
            body: data
        )
    }

    func makeEventStream(
        request: RemoteHTTPRequest,
        deliveryQueue: DispatchQueue,
        onOpened: @escaping @Sendable (Int, [String: String]) -> Void,
        onData: @escaping @Sendable (Data) -> Void,
        onComplete: @escaping @Sendable (Error?) -> Void
    ) throws -> GatewayEventStream {
        let localRequest = try makeLocalRequest(from: request, requiresEventStream: true)
        return GatewayEventStream(
            request: localRequest,
            deliveryQueue: deliveryQueue,
            onOpened: onOpened,
            onData: onData,
            onComplete: onComplete
        )
    }

    private func makeLocalRequest(
        from remote: RemoteHTTPRequest,
        requiresEventStream: Bool
    ) throws -> URLRequest {
        let decodedPathAndQuery = remote.pathAndQuery.removingPercentEncoding ?? remote.pathAndQuery
        guard Self.allowedMethods.contains(remote.method),
              remote.pathAndQuery.hasPrefix("/"),
              !remote.pathAndQuery.hasPrefix("//"),
              !remote.pathAndQuery.contains(".."),
              !decodedPathAndQuery.contains(".."),
              !decodedPathAndQuery.contains("\\"),
              !remote.pathAndQuery.contains("://"),
              (remote.body?.count ?? 0) <= RemoteProtocolVersion.maximumHTTPBodyBytes
        else {
            throw RemoteProtocolError.invalidRequest
        }

        let path = String(remote.pathAndQuery.split(separator: "?", maxSplits: 1).first ?? "")
        guard Self.isAllowed(method: remote.method, path: path),
              (!requiresEventStream || path == "/event"),
              (requiresEventStream || path != "/event")
        else {
            throw RemoteProtocolError.invalidRequest
        }

        let directoryHeaders = remote.headers.filter {
            $0.key.caseInsensitiveCompare("x-opencode-directory") == .orderedSame
        }
        guard directoryHeaders.count <= 1 else { throw RemoteProtocolError.invalidRequest }
        let requestedDirectory = directoryHeaders.first?.value
        guard workspaceRegistry.isAllowed(requestedDirectory),
              let allowedDirectory = workspaceRegistry.resolvedPath(requestedDirectory)
        else {
            throw RemoteProtocolError.invalidRequest
        }

        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(RemoteProtocolVersion.openCodePort)
        let split = remote.pathAndQuery.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        components.percentEncodedPath = String(split[0])
        if split.count == 2 { components.percentEncodedQuery = String(split[1]) }
        guard let url = components.url else { throw RemoteProtocolError.invalidRequest }

        var request = URLRequest(url: url)
        request.httpMethod = remote.method
        request.httpBody = remote.body
        request.timeoutInterval = requiresEventStream ? .infinity : 30
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        request.setValue(allowedDirectory, forHTTPHeaderField: "x-opencode-directory")
        remote.headers.forEach { name, value in
            guard Self.forwardedRequestHeaders.contains(name.lowercased()),
                  !value.contains("\r"),
                  !value.contains("\n")
            else { return }
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    private static let allowedMethods: Set<String> = ["GET", "POST", "PATCH", "DELETE"]
    private static let forwardedRequestHeaders: Set<String> = ["accept", "content-type"]

    static func isAllowed(method: String, path: String) -> Bool {
        let segments = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard path == "/" + segments.joined(separator: "/") else { return false }

        switch (method, segments) {
        case ("GET", ["global", "health"]),
             ("GET", ["session"]),
             ("POST", ["session"]),
             ("GET", ["session", "status"]),
             ("GET", ["provider"]),
             ("GET", ["config"]),
             ("GET", ["agent"]),
             ("GET", ["command"]),
             ("GET", ["file"]),
             ("GET", ["file", "status"]),
             ("GET", ["file", "content"]),
             ("GET", ["project"]),
             ("GET", ["project", "current"]),
             ("GET", ["path"]),
             ("GET", ["vcs"]),
             ("GET", ["permission"]),
             ("GET", ["question"]),
             ("GET", ["event"]):
            return true
        default:
            break
        }

        if segments.count == 2,
           segments[0] == "session",
           isSafeIdentifier(segments[1]) {
            return ["GET", "PATCH", "DELETE"].contains(method)
        }

        if segments.count == 3,
           segments[0] == "session",
           isSafeIdentifier(segments[1]) {
            switch (method, segments[2]) {
            case ("POST", "abort"),
                 ("GET", "message"),
                 ("POST", "message"),
                 ("GET", "todo"),
                 ("POST", "prompt_async"),
                 ("POST", "command"),
                 ("GET", "diff"),
                 ("POST", "share"),
                 ("POST", "revert"):
                return true
            default:
                return false
            }
        }

        if segments.count == 4,
           method == "GET",
           segments[0] == "session",
           isSafeIdentifier(segments[1]),
           segments[2] == "message",
           isSafeIdentifier(segments[3]) {
            return true
        }

        if segments.count == 3,
           method == "POST",
           ["permission", "question"].contains(segments[0]),
           isSafeIdentifier(segments[1]) {
            return (segments[0] == "permission" && segments[2] == "reply")
                || (segments[0] == "question" && ["reply", "reject"].contains(segments[2]))
        }

        return false
    }

    private static func isSafeIdentifier(_ value: String) -> Bool {
        guard (1...256).contains(value.utf8.count),
              let decoded = value.removingPercentEncoding,
              !decoded.isEmpty,
              decoded != ".",
              decoded != ".."
        else { return false }
        return decoded.unicodeScalars.allSatisfy {
            $0.value < 128
                && (CharacterSet.alphanumerics.contains($0) || "-._~".unicodeScalars.contains($0))
        }
    }

    fileprivate static func forwardedResponseHeaders(_ response: HTTPURLResponse) -> [String: String] {
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            guard let name = key as? String,
                  let value = value as? String,
                  ["content-type", "cache-control"].contains(name.lowercased())
            else { continue }
            headers[name] = value
        }
        return headers
    }
}

final class GatewayEventStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let request: URLRequest
    private let deliveryQueue: DispatchQueue
    private let onOpened: @Sendable (Int, [String: String]) -> Void
    private let onData: @Sendable (Data) -> Void
    private let onComplete: @Sendable (Error?) -> Void
    private var session: URLSession?
    private var task: URLSessionDataTask?

    init(
        request: URLRequest,
        deliveryQueue: DispatchQueue,
        onOpened: @escaping @Sendable (Int, [String: String]) -> Void,
        onData: @escaping @Sendable (Data) -> Void,
        onComplete: @escaping @Sendable (Error?) -> Void
    ) {
        self.request = request
        self.deliveryQueue = deliveryQueue
        self.onOpened = onOpened
        self.onData = onData
        self.onComplete = onComplete
    }

    func start() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = .infinity
        configuration.timeoutIntervalForResource = .infinity
        let operationQueue = OperationQueue()
        operationQueue.underlyingQueue = deliveryQueue
        operationQueue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: operationQueue)
        let task = session.dataTask(with: request)
        self.session = session
        self.task = task
        task.resume()
    }

    func cancel() {
        task?.cancel()
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard session === self.session,
              dataTask === task,
              let http = response as? HTTPURLResponse
        else {
            completionHandler(.cancel)
            return
        }
        onOpened(http.statusCode, OpenCodeForwarder.forwardedResponseHeaders(http))
        completionHandler(http.statusCode == 200 ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard session === self.session, dataTask === task else { return }
        if data.count > RemoteProtocolVersion.maximumWireMessageBytes {
            cancel()
            onComplete(RemoteProtocolError.messageTooLarge)
            return
        }
        onData(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard session === self.session, task === self.task else { return }
        self.task = nil
        self.session?.finishTasksAndInvalidate()
        self.session = nil
        onComplete(error)
    }
}
