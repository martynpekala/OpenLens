import AppIntents
import Foundation

// MARK: - Approve

struct ApprovePermissionIntent: AppIntent {
    static var title: LocalizedStringResource = "Approve Permission"
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Request ID")
    var requestID: String

    init() {}

    init(requestID: String) {
        self.requestID = requestID
    }

    func perform() async throws -> some IntentResult {
        try await PermissionResponder.respond(requestID: requestID, approve: true)
        return .result()
    }
}

// MARK: - Deny

struct DenyPermissionIntent: AppIntent {
    static var title: LocalizedStringResource = "Deny Permission"
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Request ID")
    var requestID: String

    init() {}

    init(requestID: String) {
        self.requestID = requestID
    }

    func perform() async throws -> some IntentResult {
        try await PermissionResponder.respond(requestID: requestID, approve: false)
        return .result()
    }
}

// MARK: - HTTP helper

private enum PermissionResponder {
    static func respond(requestID: String, approve: Bool) async throws {
        guard !requestID.isEmpty,
              let baseURLString = SharedConnectionStore.baseURL,
              let baseURL = URL(string: baseURLString) else { return }

        let url = baseURL
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

        let _ = try await URLSession.shared.data(for: request)
    }
}
