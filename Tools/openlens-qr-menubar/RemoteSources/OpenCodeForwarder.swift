import Foundation

final class OpenCodeForwarder: @unchecked Sendable {
    private let workspaceRegistry: WorkspaceRegistry
    private let authHeader: String
    private let session: URLSession

    init(
        workspaceRegistry: WorkspaceRegistry,
        password: String,
        session: URLSession? = nil
    ) {
        self.workspaceRegistry = workspaceRegistry
        authHeader = "Basic " + Data("opencode:\(password)".utf8).base64EncodedString()
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 300
            self.session = URLSession(configuration: configuration)
        }
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
        let parsed = try Self.parsePathAndQuery(remote.pathAndQuery)
        let path = parsed.path
        guard Self.allowedMethods.contains(remote.method),
              (remote.body?.count ?? 0) <= RemoteProtocolVersion.maximumHTTPBodyBytes
        else {
            throw RemoteProtocolError.invalidRequest
        }

        guard Self.isAllowed(method: remote.method, path: path),
              (!requiresEventStream || Self.eventStreamPaths.contains(path)),
              (requiresEventStream || !Self.eventStreamPaths.contains(path))
        else {
            throw RemoteProtocolError.invalidRequest
        }

        let directoryHeaders = remote.headers.filter {
            $0.key.caseInsensitiveCompare("x-opencode-directory") == .orderedSame
        }
        guard directoryHeaders.count <= 1 else { throw RemoteProtocolError.invalidRequest }
        let requestedHeaderDirectory = directoryHeaders.first?.value
        let directoryQueryItems = parsed.queryItems.filter {
            ["directory", "location[directory]"].contains($0.name.lowercased())
        }
        guard directoryQueryItems.count <= 1 else { throw RemoteProtocolError.invalidRequest }
        if parsed.queryItems.contains(where: {
            ["workspace", "location[workspace]"].contains($0.name.lowercased())
        }) {
            throw RemoteProtocolError.invalidRequest
        }

        let requestedQueryDirectory = directoryQueryItems.first.map(\.value)
        guard requestedHeaderDirectory == nil || requestedQueryDirectory == nil,
              let allowedDirectory = workspaceRegistry.resolvedPath(
                  requestedHeaderDirectory ?? requestedQueryDirectory
              )
        else {
            throw RemoteProtocolError.invalidRequest
        }

        if path == "/api/fs/list" {
            let filePathItems = parsed.queryItems.filter { $0.name == "path" }
            guard filePathItems.count <= 1,
                  filePathItems.allSatisfy({ Self.isSafeWorkspaceRelativePath($0.value, allowsCurrentDirectory: true) })
            else {
                throw RemoteProtocolError.invalidRequest
            }
        }

        if path.hasPrefix("/api/fs/read/") {
            let filePath = String(path.dropFirst("/api/fs/read/".count))
            guard Self.isSafeWorkspaceRelativePath(filePath, allowsCurrentDirectory: false) else {
                throw RemoteProtocolError.invalidRequest
            }
        }

        if let queryDirectory = directoryQueryItems.first {
            guard queryDirectory.rawName == queryDirectory.name,
                  queryDirectory.rawValue == queryDirectory.value
            else {
                throw RemoteProtocolError.invalidRequest
            }
        }

        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(RemoteProtocolVersion.openCodePort)
        components.percentEncodedPath = path
        let forwardedQuery = parsed.queryItems
            .filter { !["directory", "location[directory]"].contains($0.name.lowercased()) }
            .map { $0.rawPair }
            .joined(separator: "&")
        if path.hasPrefix("/api/") {
            let v2LocationQuery = try [
                Self.encodedQueryItem(name: "directory", value: allowedDirectory),
                Self.encodedQueryItem(name: "location[directory]", value: allowedDirectory),
            ].joined(separator: "&")
            components.percentEncodedQuery = [forwardedQuery, v2LocationQuery]
                .filter { !$0.isEmpty }
                .joined(separator: "&")
        } else if !forwardedQuery.isEmpty {
            components.percentEncodedQuery = forwardedQuery
        }
        guard let url = components.url else { throw RemoteProtocolError.invalidRequest }

        var request = URLRequest(url: url)
        request.httpMethod = remote.method
        request.httpBody = remote.body
        request.timeoutInterval = requiresEventStream ? .infinity : 30
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        if !path.hasPrefix("/api/") {
            request.setValue(allowedDirectory, forHTTPHeaderField: "x-opencode-directory")
        }
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
    private static let eventStreamPaths: Set<String> = ["/event", "/api/event"]

    static func isAllowed(method: String, path: String) -> Bool {
        guard !path.contains("%"),
              !path.contains("\\"),
              path.hasPrefix("/"),
              !path.hasPrefix("//")
        else { return false }

        let segments = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard path == "/" + segments.joined(separator: "/") else { return false }

        switch (method, segments) {
        case ("GET", ["global", "health"]),
             ("GET", ["api", "info"]),
             ("GET", ["api", "event"]),
             ("GET", ["api", "session", "active"]),
             ("GET", ["api", "location"]),
             ("GET", ["api", "project"]),
             ("GET", ["api", "project", "current"]),
             ("GET", ["api", "form"]),
             ("GET", ["api", "fs", "list"]),
             ("GET", ["api", "vcs"]),
             ("GET", ["api", "vcs", "diff"]),
             ("GET", ["api", "vcs", "status"]),
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

        if method == "GET",
           segments.count >= 4,
           segments[0] == "api",
           segments[1] == "fs",
           segments[2] == "read" {
            return isSafeWorkspaceRelativePath(
                segments.dropFirst(3).joined(separator: "/"),
                allowsCurrentDirectory: false
            )
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

        if segments.count == 4,
           method == "POST",
           segments[0] == "api",
           segments[1] == "session",
           isSafeIdentifier(segments[2]),
           segments[3] == "command" {
            return true
        }

        if segments.count == 4,
           method == "GET",
           segments[0] == "api",
           segments[1] == "session",
           isSafeIdentifier(segments[2]),
           segments[3] == "form" {
            return true
        }

        if segments.count == 5,
           segments[0] == "api",
           segments[1] == "session",
           isSafeIdentifier(segments[2]),
           segments[3] == "form",
           isSafeIdentifier(segments[4]) {
            return method == "DELETE"
        }

        if segments.count == 6,
           method == "POST",
           segments[0] == "api",
           segments[1] == "session",
           isSafeIdentifier(segments[2]),
           segments[3] == "form",
           isSafeIdentifier(segments[4]),
           segments[5] == "reply" {
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

    private struct QueryItem {
        let rawName: String
        let rawValue: String
        let name: String
        let value: String

        var rawPair: String {
            rawValue.isEmpty ? rawName : "\(rawName)=\(rawValue)"
        }
    }

    private struct ParsedPathAndQuery {
        let path: String
        let queryItems: [QueryItem]
    }

    private static func parsePathAndQuery(_ pathAndQuery: String) throws -> ParsedPathAndQuery {
        let split = pathAndQuery.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(split[0])
        guard path.hasPrefix("/"),
              !path.hasPrefix("//"),
              !path.contains("://"),
              split.count < 2 || !String(split[1]).contains("#")
        else {
            throw RemoteProtocolError.invalidRequest
        }

        guard split.count == 2 else {
            return ParsedPathAndQuery(path: path, queryItems: [])
        }

        let query = String(split[1])
        guard !query.isEmpty else {
            throw RemoteProtocolError.invalidRequest
        }

        let queryItems = try query
            .split(separator: "&", omittingEmptySubsequences: false)
            .map { pair -> QueryItem in
                guard !pair.isEmpty else { throw RemoteProtocolError.invalidRequest }
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let rawName = String(parts[0])
                let rawValue = parts.count == 2 ? String(parts[1]) : ""
                guard let name = rawName.removingPercentEncoding,
                      let value = rawValue.removingPercentEncoding,
                      !name.isEmpty
                else {
                    throw RemoteProtocolError.invalidRequest
                }
                return QueryItem(
                    rawName: rawName,
                    rawValue: rawValue,
                    name: name,
                    value: value
                )
            }
        return ParsedPathAndQuery(path: path, queryItems: queryItems)
    }

    private static func encodedQueryItem(name: String, value: String) throws -> String {
        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: name, value: value)]
        guard let query = components.percentEncodedQuery else {
            throw RemoteProtocolError.invalidRequest
        }
        return query
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

    private static func isSafeWorkspaceRelativePath(_ value: String, allowsCurrentDirectory: Bool) -> Bool {
        guard !value.hasPrefix("/"),
              !value.contains("\\"),
              !value.contains("%"),
              value.rangeOfCharacter(from: .newlines) == nil
        else {
            return false
        }

        if allowsCurrentDirectory && (value.isEmpty || value == ".") {
            return true
        }

        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty else { return false }
        return components.allSatisfy { component in
            !component.isEmpty && component != "." && component != ".."
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
