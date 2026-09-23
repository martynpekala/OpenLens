import Foundation

/// Wire protocol selected from the server's reachable capability endpoints.
/// The server version is evidence only; it is never used as a compatibility threshold.
nonisolated enum OpenCodeProtocol: String, Codable, Equatable, Sendable {
    case v1
    case v2

    var eventStreamPath: String {
        switch self {
        case .v1:
            "/event"
        case .v2:
            "/api/event"
        }
    }
}

/// The v2 server-info response is intentionally a small, forward-compatible DTO.
/// The published contract requires all of these fields, but older experimental
/// builds have omitted non-identity fields. Only `version` is required to accept
/// the response as usable v2 capability evidence.
nonisolated struct OCV2ServerInfo: Codable, Equatable, Sendable {
    let version: String
    let pid: Int?
    let urls: [String]
    let paths: OCV2ServerPaths?

    init(
        version: String,
        pid: Int? = nil,
        urls: [String] = [],
        paths: OCV2ServerPaths? = nil
    ) {
        self.version = version
        self.pid = pid
        self.urls = urls
        self.paths = paths
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(String.self, forKey: .version)
        pid = try container.decodeIfPresent(Int.self, forKey: .pid)
        urls = try container.decodeIfPresent([String].self, forKey: .urls) ?? []
        paths = try container.decodeIfPresent(OCV2ServerPaths.self, forKey: .paths)
    }

    var isUsable: Bool {
        !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    enum CodingKeys: String, CodingKey {
        case version, pid, urls, paths
    }
}

nonisolated struct OCV2ServerPaths: Codable, Equatable, Sendable {
    let temporaryDirectory: String?

    init(temporaryDirectory: String? = nil) {
        self.temporaryDirectory = temporaryDirectory
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        temporaryDirectory = try container.decodeIfPresent(String.self, forKey: .temporaryDirectory)
    }

    enum CodingKeys: String, CodingKey {
        case temporaryDirectory = "tmp"
    }
}

nonisolated enum OpenCodeCapabilityEvidence: Equatable, Sendable {
    case v1Health
    case v2ServerInfo
}

/// The result of connection negotiation. Keeping the evidence with the selected
/// protocol makes compatibility failures diagnosable in tests and logs without
/// making version numbers part of the selection rule.
nonisolated struct OpenCodeServerCapabilities: Equatable, Sendable {
    let protocolVersion: OpenCodeProtocol
    let serverVersion: String?
    let evidence: OpenCodeCapabilityEvidence
    let serverInfo: OCV2ServerInfo?
    let health: OCHealthResponse?

    static func v2(_ info: OCV2ServerInfo) -> Self {
        Self(
            protocolVersion: .v2,
            serverVersion: info.version,
            evidence: .v2ServerInfo,
            serverInfo: info,
            health: nil
        )
    }

    static func v1(_ health: OCHealthResponse) -> Self {
        Self(
            protocolVersion: .v1,
            serverVersion: health.version,
            evidence: .v1Health,
            serverInfo: nil,
            health: health
        )
    }

    var eventStreamPath: String {
        protocolVersion.eventStreamPath
    }

    /// v2 `/api/info` returning 200 is the readiness/reachability signal. v1
    /// retains the explicit health flag from `/global/health`.
    var isHealthy: Bool {
        health?.healthy ?? true
    }
}
