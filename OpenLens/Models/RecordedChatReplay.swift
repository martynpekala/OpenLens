import Foundation

struct RecordedChatReplay: Codable, Identifiable, Sendable {
    static let currentVersion = 1

    struct EventEnvelope: Codable, Identifiable, Sendable {
        let id: Int
        let offset: TimeInterval
        let event: OCEvent
    }

    struct Descriptor: Codable, Identifiable, Hashable, Sendable {
        let version: Int
        let id: String
        let name: String
        let sessionID: String
        let sessionTitle: String?
        let projectName: String?
        let branch: String?
        let createdAt: Date
        let duration: TimeInterval
        let eventCount: Int
    }

    let version: Int
    let id: String
    let name: String
    let sessionID: String
    let sessionTitle: String?
    let projectName: String?
    let branch: String?
    let createdAt: Date
    let duration: TimeInterval
    let eventCount: Int
    let events: [EventEnvelope]

    init(
        id: String? = nil,
        name: String? = nil,
        sessionID: String,
        sessionTitle: String?,
        projectName: String?,
        branch: String?,
        createdAt: Date,
        events: [EventEnvelope],
        version: Int = Self.currentVersion
    ) {
        let replayID = id ?? Self.makeID(createdAt: createdAt, sessionID: sessionID)

        self.version = version
        self.id = replayID
        self.name = name ?? Self.makeName(createdAt: createdAt)
        self.sessionID = sessionID
        self.sessionTitle = sessionTitle?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        self.projectName = projectName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        self.branch = branch?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        self.createdAt = createdAt
        self.duration = events.last?.offset ?? 0
        self.eventCount = events.count
        self.events = events
    }

    var descriptor: Descriptor {
        Descriptor(
            version: version,
            id: id,
            name: name,
            sessionID: sessionID,
            sessionTitle: sessionTitle,
            projectName: projectName,
            branch: branch,
            createdAt: createdAt,
            duration: duration,
            eventCount: eventCount
        )
    }
}

private extension RecordedChatReplay {
    static let idFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    static let nameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    static func makeID(createdAt: Date, sessionID: String) -> String {
        let sessionFragment = String(sanitizedIdentifierFragment(sessionID).prefix(8)).nilIfBlank ?? "session"
        return "capture-\(idFormatter.string(from: createdAt))-\(sessionFragment)"
    }

    static func makeName(createdAt: Date) -> String {
        "Capture \(nameFormatter.string(from: createdAt))"
    }

    static func sanitizedIdentifierFragment(_ value: String) -> String {
        let mapped = value.lowercased().map { character in
            character.isLetter || character.isNumber ? character : "-"
        }

        var result = String(mapped)
        while result.contains("--") {
            result = result.replacingOccurrences(of: "--", with: "-")
        }

        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
