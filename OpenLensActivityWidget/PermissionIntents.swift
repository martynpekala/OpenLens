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

        let request = try SharedConnectionStore.permissionReplyRequest(
            baseURL: baseURL, authHeader: SharedConnectionStore.authHeader,
            usesV2: SharedConnectionStore.usesV2,
            sessionID: sessionID, requestID: requestID, approve: approve
        )

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }
}
