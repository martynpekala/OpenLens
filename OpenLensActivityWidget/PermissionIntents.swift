import AppIntents
import Foundation

// MARK: - Approve

struct ApprovePermissionIntent: AppIntent {
    static var title: LocalizedStringResource = "Approve Permission"
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Session ID")
    var sessionID: String

    @Parameter(title: "Request ID")
    var requestID: String

    init() {}

    init(sessionID: String, requestID: String) {
        self.sessionID = sessionID
        self.requestID = requestID
    }

    func perform() async throws -> some IntentResult {
        try await PermissionResponder.respond(sessionID: sessionID, requestID: requestID, approve: true)
        return .result()
    }
}

// MARK: - Deny

struct DenyPermissionIntent: AppIntent {
    static var title: LocalizedStringResource = "Deny Permission"
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Session ID")
    var sessionID: String

    @Parameter(title: "Request ID")
    var requestID: String

    init() {}

    init(sessionID: String, requestID: String) {
        self.sessionID = sessionID
        self.requestID = requestID
    }

    func perform() async throws -> some IntentResult {
        try await PermissionResponder.respond(sessionID: sessionID, requestID: requestID, approve: false)
        return .result()
    }
}

// MARK: - HTTP helper

private enum PermissionResponder {
    static func respond(sessionID: String, requestID: String, approve: Bool) async throws {
        guard !sessionID.isEmpty,
              !requestID.isEmpty,
              let baseURLString = SharedConnectionStore.baseURL,
              let baseURL = URL(string: baseURLString) else { return }

        let url = baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("session")
            .appendingPathComponent(sessionID)
            .appendingPathComponent("permission")
            .appendingPathComponent(requestID)
            .appendingPathComponent("reply")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let authHeader = SharedConnectionStore.authHeader {
            request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(["reply": approve ? "once" : "reject"])

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 204 else {
            throw URLError(.badServerResponse)
        }
    }
}
