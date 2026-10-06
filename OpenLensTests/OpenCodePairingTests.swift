import Foundation
import Testing
@testable import OpenLens

struct OpenCodePairingTests {
    @Test(arguments: [
        "http://192.168.1.106:49374/auth/connect/test-one_time-code",
        "https://opencode.example.com/auth/connect/test-code",
        "http://[::1]:49374/auth/connect/test-code",
    ])
    func scannerRoutesNativePairingLinks(value: String) throws {
        let url = try #require(URL(string: value))
        guard case .openCodePairing(let link) = ScannedOpenLensCode(url: url) else {
            Issue.record("The QR scanner rejected a native OpenCode pairing link")
            return
        }
        #expect(link.url == url)
        #expect(link.serverURL.host == url.host)
        #expect(link.serverURL.port == url.port)
        #expect(link.serverURL.path.isEmpty)
    }

    @Test func scannerRoutesCurrentCredentialPairingLinks() throws {
        let payload = #"{"username":"opencode","password":"test-session-token"}"#
        let fragment = Data(payload.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        let url = try #require(URL(string: "http://192.168.1.106:49374/connect#\(fragment)"))

        guard case .openCodePairing(let link) = ScannedOpenLensCode(url: url) else {
            Issue.record("The QR scanner rejected the current OpenCode pairing link")
            return
        }

        #expect(link.serverURL.absoluteString == "http://192.168.1.106:49374")
        #expect(link.credentials == OpenCodePairingCredentials(
            username: "opencode",
            password: "test-session-token"
        ))
    }

    @Test(arguments: [
        "http://example.com/auth/connect/",
        "http://example.com/auth/connect/code/extra",
        "http://example.com/auth/connect/code/",
        "http://example.com/auth/connect/code?next=elsewhere",
        "http://example.com/auth/connect/code#fragment",
        "http://example.com/connect",
        "http://example.com/connect#not-base64",
        "http://example.com/connect#e30",
        "http://user:password@example.com/auth/connect/code",
        "http://example.com/auth/connect/code%2Fextra",
        "http://example.com/auth/connect/..",
        "http://example.com/api/info",
        "ftp://example.com/auth/connect/code",
    ])
    func rejectsInvalidPairingLinks(value: String) throws {
        #expect(OpenCodePairingLink(url: try #require(URL(string: value))) == nil)
    }

    @Test func scannerStillAcceptsLegacyDirectCodes() throws {
        let directURL = try #require(URL(string: "openlens://connect?url=http%3A%2F%2Flocalhost%3A4096&pass=test"))
        guard case .direct(let direct) = ScannedOpenLensCode(url: directURL) else {
            Issue.record("Legacy direct QR was rejected")
            return
        }
        #expect(direct.password == "test")
    }

    @Test func redeemsJSONAndReturnsReusableBasicAuthCredentials() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let link = try makeLink(code: "success")
        let credential = try await OpenCodePairingClient(session: session).pair(using: link)
        #expect(credential.serverURL == "http://pairing.example.com:49374")
        #expect(credential.username == "opencode")
        #expect(credential.password == "test-session-token")
        #expect(credential.sessionID == nil)

        let store = SavedConnectionsStore(initialConnections: [])
        let saved = store.saveConnection(
            serverURL: credential.serverURL,
            username: credential.username,
            password: credential.password
        )
        #expect(store.mostRecent?.password == "test-session-token")
        #expect(saved.authHeader == "Basic " + Data("opencode:test-session-token".utf8).base64EncodedString())
        #expect(!saved.serverURL.contains("auth/connect"))
    }

    @Test func resolvesCurrentCredentialPairingLinksWithoutNetwork() async throws {
        let payload = #"{"username":"opencode","password":"test-session-token"}"#
        let fragment = Data(payload.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        let url = try #require(URL(string: "http://pairing.example.com:49374/connect#\(fragment)"))
        let link = try #require(OpenCodePairingLink(url: url))

        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let credential = try await OpenCodePairingClient(session: session).pair(using: link)

        #expect(credential.serverURL == "http://pairing.example.com:49374")
        #expect(credential.username == "opencode")
        #expect(credential.password == "test-session-token")
    }

    @Test(arguments: [401, 403, 404, 410])
    func expiredOrConsumedCodeExplainsHowToRecover(status: Int) async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        await #expect(throws: OpenCodePairingError.expiredOrUsed) {
            _ = try await OpenCodePairingClient(session: session).pair(using: makeLink(code: "status-\(status)"))
        }
    }

    @Test(arguments: ["empty", "missing", "html", "enveloped"])
    func rejectsUnusableSuccessResponses(code: String) async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        await #expect(throws: OpenCodePairingError.invalidResponse) {
            _ = try await OpenCodePairingClient(session: session).pair(using: makeLink(code: code))
        }
    }

    @Test func connectionErrorsDoNotRevealThePairingLink() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        await #expect(throws: OpenCodePairingError.unreachable) {
            _ = try await OpenCodePairingClient(session: session).pair(using: makeLink(code: "offline"))
        }
        #expect(!OpenCodePairingError.unreachable.localizedDescription.contains("auth/connect"))
    }

    @Test func cancellationIsNotReportedAsPairingFailure() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        await #expect(throws: CancellationError.self) {
            _ = try await OpenCodePairingClient(session: session).pair(using: makeLink(code: "cancelled"))
        }
    }

    @Test(arguments: [302, 500])
    func unexpectedStatusIsNotTreatedAsSuccessfulPairing(status: Int) async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        await #expect(throws: OpenCodePairingError.rejected(status)) {
            _ = try await OpenCodePairingClient(session: session).pair(using: makeLink(code: "status-\(status)"))
        }
    }

    private func makeLink(code: String) throws -> OpenCodePairingLink {
        let url = try #require(URL(string: "http://pairing.example.com:49374/auth/connect/\(code)"))
        return try #require(OpenCodePairingLink(url: url))
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PairingFixtureProtocol.self]
        return URLSession(configuration: configuration)
    }
}

nonisolated private final class PairingFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
        let url = request.url!
        let code = url.lastPathComponent
        if code == "offline" || code == "cancelled" {
            client?.urlProtocol(self, didFailWithError: URLError(
                code == "cancelled" ? .cancelled : .cannotConnectToHost,
                userInfo: [NSURLErrorFailingURLErrorKey: url]
            ))
            return
        }
        let status = code.hasPrefix("status-") ? Int(code.dropFirst(7))! : 200
        let body: String
        switch code {
        case "empty": body = #"{"token":"  "}"#
        case "missing": body = "{}"
        case "html": body = "<html>Sign in</html>"
        case "enveloped": body = #"{"data":{"token":"test-session-token"}}"#
        default: body = #"{"token":"test-session-token"}"#
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
