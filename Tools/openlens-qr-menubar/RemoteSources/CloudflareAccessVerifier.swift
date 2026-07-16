import Foundation
import Security

struct CloudflareAccessConfiguration: Codable, Equatable, Sendable {
    let teamDomain: String
    let audience: String
    let clientID: String

    var issuer: String { "https://\(teamDomain)" }

    var certificatesURL: URL {
        URL(string: "https://\(teamDomain)/cdn-cgi/access/certs")!
    }
}

protocol CloudflareAccessValidating: AnyObject, Sendable {
    func validate(assertion: String, now: Date) -> Bool
}

final class CloudflareAccessVerifier: CloudflareAccessValidating, @unchecked Sendable {
    private struct JWKSet: Decodable {
        let keys: [JWK]
    }

    private struct JWK: Codable {
        let alg: String?
        let e: String
        let kid: String
        let kty: String
        let n: String
        let use: String?
    }

    private struct PersistedCache: Codable {
        let issuer: String
        let fetchedAt: Date
        let keys: [JWK]
    }

    private struct State {
        var configuration: CloudflareAccessConfiguration?
        var fetchedAt: Date?
        var keys: [String: SecKey] = [:]
        var lastUnknownKeyRefreshAt: Date?
    }

    private static let refreshInterval: TimeInterval = 6 * 60 * 60
    private static let maximumCacheAge: TimeInterval = 12 * 60 * 60
    private static let unknownKeyRefreshCooldown: TimeInterval = 30

    private let lock = NSLock()
    private let session: URLSession
    private let cacheURL: URL
    private let refreshQueue = DispatchQueue(label: "dev.openlens.remote.access-refresh")
    private var state = State()
    private var refreshTimer: DispatchSourceTimer?

    init(
        cacheURL: URL = RemoteAgentPaths.accessJWKSFile,
        session: URLSession = .shared
    ) {
        self.cacheURL = cacheURL
        self.session = session
    }

    deinit {
        refreshTimer?.cancel()
    }

    func prepare(
        configuration: CloudflareAccessConfiguration,
        requiresNetworkRefresh: Bool
    ) async throws {
        lock.withLock {
            state.configuration = configuration
            state.fetchedAt = nil
            state.keys = [:]
        }
        loadCache(for: configuration)

        let hasFreshCache = lock.withLock {
            guard let fetchedAt = state.fetchedAt else { return false }
            let age = Date().timeIntervalSince(fetchedAt)
            return (-300...Self.maximumCacheAge).contains(age) && !state.keys.isEmpty
        }
        if requiresNetworkRefresh || !hasFreshCache {
            try await refresh(configuration: configuration)
        } else if shouldRefresh(now: Date()) {
            refreshInBackground(configuration: configuration)
        }
        startRefreshTimer()
    }

    func validate(assertion: String, now: Date = Date()) -> Bool {
        let snapshot = lock.withLock {
            (state.configuration, state.fetchedAt, state.keys)
        }
        guard let configuration = snapshot.0,
              let fetchedAt = snapshot.1,
              (-300...Self.maximumCacheAge).contains(now.timeIntervalSince(fetchedAt)),
              assertion.utf8.count <= 128 * 1_024,
              let parsed = Self.parse(assertion: assertion)
        else {
            return false
        }

        guard let key = snapshot.2[parsed.keyID] else {
            refreshForUnknownKey(configuration: configuration, now: now)
            return false
        }
        return Self.validate(
            parsed: parsed,
            configuration: configuration,
            key: key,
            now: now
        )
    }

    static func validate(
        assertion: String,
        configuration: CloudflareAccessConfiguration,
        key: SecKey,
        now: Date
    ) -> Bool {
        guard let parsed = parse(assertion: assertion) else { return false }
        return validate(
            parsed: parsed,
            configuration: configuration,
            key: key,
            now: now
        )
    }

    private func loadCache(for configuration: CloudflareAccessConfiguration) {
        guard let data = try? Data(contentsOf: cacheURL),
              data.count <= 2 * 1_024 * 1_024,
              let cache = try? JSONDecoder().decode(PersistedCache.self, from: data),
              cache.issuer == configuration.issuer,
              (-300...Self.maximumCacheAge).contains(Date().timeIntervalSince(cache.fetchedAt)),
              let keys = try? Self.securityKeys(from: cache.keys),
              !keys.isEmpty
        else {
            return
        }
        lock.withLock {
            guard state.configuration == configuration else { return }
            state.fetchedAt = cache.fetchedAt
            state.keys = keys
        }
    }

    private func refresh(configuration: CloudflareAccessConfiguration) async throws {
        var request = URLRequest(url: configuration.certificatesURL)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              data.count <= 2 * 1_024 * 1_024
        else {
            throw RemoteAgentError.accessJWKSUnavailable
        }
        let jwks = try JSONDecoder().decode(JWKSet.self, from: data)
        let keys = try Self.securityKeys(from: jwks.keys)
        guard !keys.isEmpty else { throw RemoteAgentError.accessJWKSUnavailable }
        guard lock.withLock({ state.configuration == configuration }) else { return }

        let fetchedAt = Date()
        try RemoteAgentPaths.prepare()
        let cache = PersistedCache(
            issuer: configuration.issuer,
            fetchedAt: fetchedAt,
            keys: jwks.keys
        )
        try JSONEncoder().encode(cache).write(
            to: cacheURL,
            options: [.atomic, .completeFileProtection]
        )
        lock.withLock {
            guard state.configuration == configuration else { return }
            state.fetchedAt = fetchedAt
            state.keys = keys
        }
    }

    private func startRefreshTimer() {
        refreshQueue.async { [weak self] in
            guard let self, refreshTimer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: refreshQueue)
            timer.schedule(
                deadline: .now() + Self.refreshInterval,
                repeating: Self.refreshInterval
            )
            timer.setEventHandler { [weak self] in
                guard let self,
                      let configuration = lock.withLock({ self.state.configuration })
                else { return }
                refreshInBackground(configuration: configuration)
            }
            refreshTimer = timer
            timer.resume()
        }
    }

    private func shouldRefresh(now: Date) -> Bool {
        lock.withLock {
            guard let fetchedAt = state.fetchedAt else { return true }
            return now.timeIntervalSince(fetchedAt) >= Self.refreshInterval
        }
    }

    private func refreshForUnknownKey(
        configuration: CloudflareAccessConfiguration,
        now: Date
    ) {
        let shouldRefresh = lock.withLock {
            if let lastAttempt = state.lastUnknownKeyRefreshAt,
               now.timeIntervalSince(lastAttempt) < Self.unknownKeyRefreshCooldown {
                return false
            }
            state.lastUnknownKeyRefreshAt = now
            return true
        }
        guard shouldRefresh else { return }
        refreshInBackground(configuration: configuration)
    }

    private func refreshInBackground(configuration: CloudflareAccessConfiguration) {
        Task { [weak self] in
            try? await self?.refresh(configuration: configuration)
        }
    }

    private struct ParsedAssertion {
        let keyID: String
        let signingInput: Data
        let signature: Data
        let claims: [String: Any]
    }

    private static func parse(assertion: String) -> ParsedAssertion? {
        let segments = assertion.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3,
              segments[0].count <= 16 * 1_024,
              segments[1].count <= 64 * 1_024,
              segments[2].count <= 4 * 1_024,
              let headerData = Data(base64URL: String(segments[0])),
              let payloadData = Data(base64URL: String(segments[1])),
              let signature = Data(base64URL: String(segments[2])),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              header["alg"] as? String == "RS256",
              let keyID = header["kid"] as? String,
              !keyID.isEmpty,
              let claims = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        else {
            return nil
        }
        return ParsedAssertion(
            keyID: keyID,
            signingInput: Data("\(segments[0]).\(segments[1])".utf8),
            signature: signature,
            claims: claims
        )
    }

    private static func validate(
        parsed: ParsedAssertion,
        configuration: CloudflareAccessConfiguration,
        key: SecKey,
        now: Date
    ) -> Bool {
        let claims = parsed.claims
        guard claims["iss"] as? String == configuration.issuer,
              claims["type"] as? String == "app",
              claims["common_name"] as? String == configuration.clientID,
              let expiresAt = numericDate(claims["exp"]),
              expiresAt > now.timeIntervalSince1970 - 30,
              audience(claims["aud"], contains: configuration.audience)
        else {
            return false
        }
        if let notBefore = numericDate(claims["nbf"]),
           notBefore > now.timeIntervalSince1970 + 30 {
            return false
        }
        if let issuedAt = numericDate(claims["iat"]),
           issuedAt > now.timeIntervalSince1970 + 30 {
            return false
        }
        return SecKeyVerifySignature(
            key,
            .rsaSignatureMessagePKCS1v15SHA256,
            parsed.signingInput as CFData,
            parsed.signature as CFData,
            nil
        )
    }

    private static func numericDate(_ value: Any?) -> TimeInterval? {
        switch value {
        case let number as NSNumber: number.doubleValue
        case let string as String: TimeInterval(string)
        default: nil
        }
    }

    private static func audience(_ value: Any?, contains expected: String) -> Bool {
        if let value = value as? String { return value == expected }
        if let values = value as? [String] { return values.contains(expected) }
        return false
    }

    private static func securityKeys(from jwks: [JWK]) throws -> [String: SecKey] {
        var result: [String: SecKey] = [:]
        for jwk in jwks where jwk.kty == "RSA"
            && (jwk.alg == nil || jwk.alg == "RS256")
            && (jwk.use == nil || jwk.use == "sig") {
            guard !jwk.kid.isEmpty,
                  let modulus = Data(base64URL: jwk.n),
                  let exponent = Data(base64URL: jwk.e),
                  !modulus.isEmpty,
                  !exponent.isEmpty,
                  (256...1_024).contains(modulus.count),
                  exponent.count <= 8,
                  let key = rsaPublicKey(modulus: modulus, exponent: exponent)
            else { continue }
            result[jwk.kid] = key
        }
        return result
    }

    private static func rsaPublicKey(modulus: Data, exponent: Data) -> SecKey? {
        let body = derInteger(modulus) + derInteger(exponent)
        let representation = Data([0x30]) + derLength(body.count) + body
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits: modulus.count * 8,
        ]
        return SecKeyCreateWithData(representation as CFData, attributes as CFDictionary, nil)
    }

    private static func derInteger(_ input: Data) -> Data {
        var value = Data(input.drop(while: { $0 == 0 }))
        if value.isEmpty { value = Data([0]) }
        if value.first.map({ $0 & 0x80 != 0 }) == true { value.insert(0, at: 0) }
        return Data([0x02]) + derLength(value.count) + value
    }

    private static func derLength(_ length: Int) -> Data {
        if length < 128 { return Data([UInt8(length)]) }
        var value = length
        var bytes: [UInt8] = []
        while value > 0 {
            bytes.insert(UInt8(value & 0xff), at: 0)
            value >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }
}
