import Foundation

nonisolated enum RemoteProtocolVersion {
    static let current = 1
    static let gatewayPort: UInt16 = 49_634
    static let openCodePort: UInt16 = 4_096
    static let webSocketSubprotocol = "openlens-remote-v1"
    static let maximumWireMessageBytes = 4 * 1_024 * 1_024
    static let maximumHTTPBodyBytes = 2 * 1_024 * 1_024
}

nonisolated struct CloudflareAccessCredential: Codable, Equatable, Sendable {
    let clientID: String
    let clientSecret: String

    init(clientID: String, clientSecret: String) {
        self.clientID = clientID
        self.clientSecret = clientSecret
    }
}

nonisolated enum RemoteWireKind: String, Codable, Sendable {
    case pairingRequest
    case pairingResponse
    case sessionHello
    case sessionWelcome
    case encrypted
    case rejected
}

nonisolated struct RemoteWireEnvelope: Codable, Equatable, Sendable {
    let version: Int
    let kind: RemoteWireKind
    let pairingID: String?
    let deviceID: String?
    let sessionID: String?
    let encapsulatedKey: Data?
    let sequence: UInt64?
    let ciphertext: Data?
    let errorCode: String?

    init(
        kind: RemoteWireKind,
        pairingID: String? = nil,
        deviceID: String? = nil,
        sessionID: String? = nil,
        encapsulatedKey: Data? = nil,
        sequence: UInt64? = nil,
        ciphertext: Data? = nil,
        errorCode: String? = nil
    ) {
        self.version = RemoteProtocolVersion.current
        self.kind = kind
        self.pairingID = pairingID
        self.deviceID = deviceID
        self.sessionID = sessionID
        self.encapsulatedKey = encapsulatedKey
        self.sequence = sequence
        self.ciphertext = ciphertext
        self.errorCode = errorCode
    }

    func encoded() throws -> Data {
        let data = try Self.encoder.encode(self)
        guard data.count <= RemoteProtocolVersion.maximumWireMessageBytes else {
            throw RemoteProtocolError.messageTooLarge
        }
        return data
    }

    static func decode(_ data: Data) throws -> RemoteWireEnvelope {
        guard data.count <= RemoteProtocolVersion.maximumWireMessageBytes else {
            throw RemoteProtocolError.messageTooLarge
        }
        let envelope = try decoder.decode(RemoteWireEnvelope.self, from: data)
        guard envelope.version == RemoteProtocolVersion.current else {
            throw RemoteProtocolError.unsupportedVersion
        }
        return envelope
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder = JSONDecoder()
}

nonisolated struct RemotePairingOffer: Codable, Equatable, Sendable {
    let endpoint: URL
    let gatewayID: String
    let gatewayPublicKey: Data
    let pairingID: String
    let pairingSecret: Data
    let accessCredential: CloudflareAccessCredential
    let expiresAt: Date

    var isExpired: Bool {
        expiresAt <= Date()
    }

    init(
        endpoint: URL,
        gatewayID: String,
        gatewayPublicKey: Data,
        pairingID: String,
        pairingSecret: Data,
        accessCredential: CloudflareAccessCredential,
        expiresAt: Date
    ) {
        self.endpoint = endpoint
        self.gatewayID = gatewayID
        self.gatewayPublicKey = gatewayPublicKey
        self.pairingID = pairingID
        self.pairingSecret = pairingSecret
        self.accessCredential = accessCredential
        self.expiresAt = expiresAt
    }

    init?(url: URL) {
        guard url.scheme == "openlens",
              url.host == "remote",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems,
              let endpointValue = queryItems.value(named: "endpoint"),
              let endpoint = URL(string: endpointValue),
              endpoint.scheme == "https",
              endpoint.host != nil,
              let gatewayID = queryItems.value(named: "gatewayID")?.remoteNilIfBlank,
              let gatewayKeyValue = queryItems.value(named: "gatewayKey"),
              let gatewayPublicKey = Data(base64URL: gatewayKeyValue),
              let pairingID = queryItems.value(named: "pairingID")?.remoteNilIfBlank,
              let secretValue = queryItems.value(named: "secret"),
              let pairingSecret = Data(base64URL: secretValue),
              let accessClientID = queryItems.value(named: "accessClientID")?.remoteNilIfBlank,
              let accessClientSecret = queryItems.value(named: "accessClientSecret")?.remoteNilIfBlank,
              accessClientID.count <= 2_048,
              accessClientSecret.count <= 2_048,
              let expiryValue = queryItems.value(named: "expires"),
              let expirySeconds = TimeInterval(expiryValue)
        else {
            return nil
        }

        self.endpoint = endpoint
        self.gatewayID = gatewayID
        self.gatewayPublicKey = gatewayPublicKey
        self.pairingID = pairingID
        self.pairingSecret = pairingSecret
        self.accessCredential = CloudflareAccessCredential(
            clientID: accessClientID,
            clientSecret: accessClientSecret
        )
        self.expiresAt = Date(timeIntervalSince1970: expirySeconds)
    }

    var deepLinkURL: URL? {
        var components = URLComponents()
        components.scheme = "openlens"
        components.host = "remote"
        components.queryItems = [
            URLQueryItem(name: "endpoint", value: endpoint.absoluteString),
            URLQueryItem(name: "gatewayID", value: gatewayID),
            URLQueryItem(name: "gatewayKey", value: gatewayPublicKey.base64URLEncodedString()),
            URLQueryItem(name: "pairingID", value: pairingID),
            URLQueryItem(name: "secret", value: pairingSecret.base64URLEncodedString()),
            URLQueryItem(name: "accessClientID", value: accessCredential.clientID),
            URLQueryItem(name: "accessClientSecret", value: accessCredential.clientSecret),
            URLQueryItem(name: "expires", value: String(Int(expiresAt.timeIntervalSince1970))),
        ]
        return components.url
    }
}

nonisolated struct RemotePairingRequest: Codable, Equatable, Sendable {
    let pairingSecret: Data
    let devicePublicKey: Data
    let deviceName: String
}

nonisolated struct RemotePairingResponse: Codable, Equatable, Sendable {
    let gatewayID: String
    let deviceID: String
    let deviceName: String
}

nonisolated struct RemoteDeviceCredential: Codable, Equatable, Sendable {
    let connectionID: String
    let endpoint: URL
    let gatewayID: String
    let gatewayPublicKey: Data
    let deviceID: String
    let deviceName: String
    let devicePrivateKey: Data
    let accessCredential: CloudflareAccessCredential
}

nonisolated struct RemoteSessionHello: Codable, Equatable, Sendable {
    let deviceName: String
    let protocolVersion: Int
}

nonisolated struct RemoteSessionWelcome: Codable, Equatable, Sendable {
    let gatewayID: String
    let protocolVersion: Int
}

nonisolated enum RemoteMessageKind: String, Codable, Sendable {
    case sessionHello
    case sessionWelcome
    case request
    case response
    case subscribeEvents
    case unsubscribeEvents
    case eventOpened
    case eventData
    case eventCompleted
    case ping
    case pong
    case error
}

nonisolated struct RemoteMessage: Codable, Equatable, Sendable {
    let kind: RemoteMessageKind
    let id: String
    let request: RemoteHTTPRequest?
    let response: RemoteHTTPResponse?
    let payload: Data?
    let statusCode: Int?
    let errorCode: String?

    init(
        kind: RemoteMessageKind,
        id: String = UUID().uuidString,
        request: RemoteHTTPRequest? = nil,
        response: RemoteHTTPResponse? = nil,
        payload: Data? = nil,
        statusCode: Int? = nil,
        errorCode: String? = nil
    ) {
        self.kind = kind
        self.id = id
        self.request = request
        self.response = response
        self.payload = payload
        self.statusCode = statusCode
        self.errorCode = errorCode
    }

    func encoded() throws -> Data {
        try Self.encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> RemoteMessage {
        try decoder.decode(RemoteMessage.self, from: data)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder = JSONDecoder()
}

nonisolated struct RemoteHTTPRequest: Codable, Equatable, Sendable {
    let method: String
    let pathAndQuery: String
    let headers: [String: String]
    let body: Data?

    init(request: URLRequest) throws {
        guard let url = request.url,
              let method = request.httpMethod?.uppercased(),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            throw RemoteProtocolError.invalidRequest
        }

        let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        self.method = method
        self.pathAndQuery = components.percentEncodedQuery.map { "\(path)?\($0)" } ?? path
        self.headers = request.allHTTPHeaderFields?
            .filter { Self.forwardedHeaderNames.contains($0.key.lowercased()) } ?? [:]
        self.body = request.httpBody

        if let body, body.count > RemoteProtocolVersion.maximumHTTPBodyBytes {
            throw RemoteProtocolError.messageTooLarge
        }
    }

    init(method: String, pathAndQuery: String, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method.uppercased()
        self.pathAndQuery = pathAndQuery
        self.headers = headers.filter { Self.forwardedHeaderNames.contains($0.key.lowercased()) }
        self.body = body
    }

    private static let forwardedHeaderNames: Set<String> = [
        "accept",
        "content-type",
        "x-opencode-directory",
    ]
}

nonisolated struct RemoteHTTPResponse: Codable, Equatable, Sendable {
    let statusCode: Int
    let headers: [String: String]
    let body: Data
}

nonisolated enum RemoteProtocolError: LocalizedError, Equatable {
    case unsupportedVersion
    case malformedMessage
    case invalidRequest
    case invalidPairingOffer
    case expiredPairingOffer
    case pairingRejected
    case unknownDevice
    case authenticationFailed
    case replayDetected
    case messageTooLarge
    case disconnected
    case timeout
    case remoteError(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion: "This OpenLens Remote protocol version is not supported."
        case .malformedMessage: "OpenLens Remote received a malformed message."
        case .invalidRequest: "OpenLens Remote rejected an invalid request."
        case .invalidPairingOffer: "This OpenLens Remote pairing code is invalid."
        case .expiredPairingOffer: "This OpenLens Remote pairing code has expired."
        case .pairingRejected: "The Mac rejected this pairing request."
        case .unknownDevice: "This device is no longer trusted by the Mac."
        case .authenticationFailed: "OpenLens Remote could not authenticate the encrypted connection."
        case .replayDetected: "OpenLens Remote rejected a repeated or out-of-order message."
        case .messageTooLarge: "The OpenLens Remote message is too large."
        case .disconnected: "The OpenLens Remote connection was closed."
        case .timeout: "The OpenLens Remote connection timed out."
        case .remoteError(let code): "OpenLens Remote failed (\(code))."
        }
    }
}

extension Data {
    nonisolated init?(base64URL value: String) {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - base64.count % 4) % 4
        base64.append(String(repeating: "=", count: padding))
        self.init(base64Encoded: base64)
    }

    nonisolated func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension Array where Element == URLQueryItem {
    nonisolated func value(named name: String) -> String? {
        first(where: { $0.name == name })?.value
    }
}

private extension String {
    nonisolated var remoteNilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
