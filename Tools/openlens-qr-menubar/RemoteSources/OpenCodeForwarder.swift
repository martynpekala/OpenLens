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
        let path = localRequest.url!.path
        let segments = path.split(separator: "/").map(String.init)
        let ownedSessionID = segments.count >= 3 && segments[0] == "api" && segments[1] == "session" && segments[2] != "active"
            ? segments[2] : nil
        if let ownedSessionID {
            guard try await ownsSession(ownedSessionID) else { throw RemoteProtocolError.invalidRequest }
        }
        let (responseData, response) = try await session.data(for: localRequest)
        var data = responseData
        guard let http = response as? HTTPURLResponse else {
            throw RemoteProtocolError.remoteError("invalid_local_response")
        }
        guard data.count <= RemoteProtocolVersion.maximumHTTPBodyBytes else {
            throw RemoteProtocolError.messageTooLarge
        }
        if (200..<300).contains(http.statusCode), !data.isEmpty {
            if path == "/api/session/active" {
                guard var envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let active = envelope["data"] as? [String: Any]
                else { throw RemoteProtocolError.invalidRequest }
                var allowed: [String: Any] = [:]
                for (id, value) in active {
                    if try await ownsSession(id) { allowed[id] = value }
                }
                envelope["data"] = allowed
                data = try JSONSerialization.data(withJSONObject: envelope)
            } else if path == "/api/session", localRequest.httpMethod == "GET" {
                guard var envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let sessions = envelope["data"] as? [[String: Any]]
                else { throw RemoteProtocolError.invalidRequest }
                envelope["data"] = sessions.filter { ownsLocation($0["location"]) }
                data = try JSONSerialization.data(withJSONObject: envelope)
            } else if path == "/api/project" {
                guard let projects = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
                else { throw RemoteProtocolError.invalidRequest }
                data = try JSONSerialization.data(withJSONObject: projects.filter {
                    guard let directory = ($0["directory"] ?? $0["worktree"]) as? String else { return false }
                    return workspaceRegistry.isAllowed(directory)
                })
            } else if ownedSessionID != nil, segments.count == 3, localRequest.httpMethod == "GET" {
                guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let info = envelope["data"] as? [String: Any], ownsLocation(info["location"])
                else { throw RemoteProtocolError.invalidRequest }
            }
        }
        return RemoteHTTPResponse(
            statusCode: http.statusCode,
            headers: Self.forwardedResponseHeaders(http),
            body: data
        )
    }

    private func ownsLocation(_ value: Any?) -> Bool {
        guard let location = value as? [String: Any], let directory = location["directory"] as? String else { return false }
        return workspaceRegistry.isAllowed(directory)
    }

    /// No ownership cache: sessions can move and the approved registry can change.
    private func ownsSession(_ id: String) async throws -> Bool {
        guard Self.isSafeIdentifier(id) else { return false }
        let url = URL(string: "http://127.0.0.1:\(RemoteProtocolVersion.openCodePort)/api/session")!.appendingPathComponent(id)
        var request = URLRequest(url: url)
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw RemoteProtocolError.invalidRequest }
        if response.statusCode == 404 { return false }
        guard response.statusCode == 200, data.count <= RemoteProtocolVersion.maximumHTTPBodyBytes,
              let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let info = envelope["data"] as? [String: Any], info["id"] as? String == id
        else { throw RemoteProtocolError.invalidRequest }
        return ownsLocation(info["location"])
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
            eventFilter: localRequest.url?.path == "/api/event" ? GatewayV2EventFilter(registry: workspaceRegistry) : nil,
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

        var forwardedBody = remote.body
        var createBody: [String: Any]?
        var bodyDirectory: String?
        if remote.method == "POST", path == "/api/session" {
            guard let data = remote.body,
                  let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { throw RemoteProtocolError.invalidRequest }
            createBody = body
            if let location = body["location"], !(location is NSNull) {
                guard let location = location as? [String: Any],
                      Set(location.keys) == ["directory"],
                      let directory = location["directory"] as? String
                else { throw RemoteProtocolError.invalidRequest }
                bodyDirectory = directory
            }
        }

        let requestedQueryDirectory = directoryQueryItems.first.map(\.value)
        guard requestedHeaderDirectory == nil || requestedQueryDirectory == nil,
              let allowedDirectory = workspaceRegistry.resolvedPath(
                  bodyDirectory ?? requestedHeaderDirectory ?? requestedQueryDirectory
              )
        else {
            throw RemoteProtocolError.invalidRequest
        }

        if let bodyDirectory {
            guard workspaceRegistry.resolvedPath(bodyDirectory) == allowedDirectory,
                  [requestedHeaderDirectory, requestedQueryDirectory].compactMap({ $0 }).allSatisfy({
                      workspaceRegistry.resolvedPath($0) == allowedDirectory
                  })
            else { throw RemoteProtocolError.invalidRequest }
        }
        if var body = createBody {
            body["location"] = ["directory": allowedDirectory]
            forwardedBody = try JSONSerialization.data(withJSONObject: body)
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
        var query = forwardedQuery
        let locationQueryName: String?
        if path == "/api/session", remote.method == "GET" {
            locationQueryName = "directory"
        } else if path == "/api/event" {
            locationQueryName = nil
        } else if path.hasPrefix("/api/"),
                  !path.hasPrefix("/api/session"),
                  !["/api/info", "/api/project"].contains(path) {
            locationQueryName = "location[directory]"
        } else {
            locationQueryName = nil
        }
        if let locationQueryName {
            query = try [query, Self.encodedQueryItem(name: locationQueryName, value: allowedDirectory)]
                .filter { !$0.isEmpty }.joined(separator: "&")
        }
        components.percentEncodedQuery = query.isEmpty ? nil : query
        guard let url = components.url else { throw RemoteProtocolError.invalidRequest }

        var request = URLRequest(url: url)
        request.httpMethod = remote.method
        request.httpBody = forwardedBody
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
             ("GET", ["api", "session"]),
             ("POST", ["api", "session"]),
             ("GET", ["api", "location"]),
             ("GET", ["api", "project"]),
             ("GET", ["api", "project", "current"]),
             ("GET", ["api", "model"]),
             ("GET", ["api", "model", "default"]),
             ("GET", ["api", "provider"]),
             ("GET", ["api", "agent"]),
             ("GET", ["api", "command"]),
             ("GET", ["api", "form"]),
             ("GET", ["api", "permission", "request"]),
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

        if segments.count == 3,
           segments[0] == "api",
           segments[1] == "session",
           isSafeIdentifier(segments[2]) {
            return ["GET", "PATCH", "DELETE"].contains(method)
        }

        if segments.count == 4,
           segments[0] == "api",
           segments[1] == "session",
           isSafeIdentifier(segments[2]) {
            switch (method, segments[3]) {
            case ("DELETE", "revert"),
                 ("POST", "interrupt"),
                 ("GET", "message"),
                 ("POST", "prompt"),
                 ("POST", "model"),
                 ("POST", "agent"),
                 ("GET", "diff"),
                 ("GET", "permission"),
                 ("GET", "form"):
                return true
            default:
                return false
            }
        }

        if segments.count == 5,
           method == "GET",
           segments[0] == "api",
           segments[1] == "session",
           isSafeIdentifier(segments[2]),
           segments[3] == "message",
           isSafeIdentifier(segments[4]) {
            return true
        }

        if segments.count == 6,
           method == "POST",
           segments[0] == "api",
           segments[1] == "session",
           isSafeIdentifier(segments[2]),
           segments[3] == "permission",
           isSafeIdentifier(segments[4]),
           segments[5] == "reply" {
            return true
        }

        if segments.count == 5,
           method == "POST",
           segments[0] == "api",
           segments[1] == "session",
           isSafeIdentifier(segments[2]),
           segments[3] == "revert",
           ["stage", "commit"].contains(segments[4]) {
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
    private let eventFilter: GatewayV2EventFilter?
    private let deliveryQueue: DispatchQueue
    private let onOpened: @Sendable (Int, [String: String]) -> Void
    private let onData: @Sendable (Data) -> Void
    private let onComplete: @Sendable (Error?) -> Void
    private var session: URLSession?
    private var task: URLSessionDataTask?

    init(
        request: URLRequest,
        eventFilter: GatewayV2EventFilter? = nil,
        deliveryQueue: DispatchQueue,
        onOpened: @escaping @Sendable (Int, [String: String]) -> Void,
        onData: @escaping @Sendable (Data) -> Void,
        onComplete: @escaping @Sendable (Error?) -> Void
    ) {
        self.request = request
        self.eventFilter = eventFilter
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
        do {
            if let eventFilter {
                for record in try eventFilter.append(data) { onData(record) }
            } else {
                onData(data)
            }
        } catch {
            cancel()
            onComplete(error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard session === self.session, task === self.task else { return }
        self.task = nil
        self.session?.finishTasksAndInvalidate()
        self.session = nil
        onComplete(error)
    }
}
