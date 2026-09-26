import Foundation

/// Redeems native OpenCode pairing links using the JSON (non-browser) contract.
struct OpenCodePairingClient {
    private let session: URLSession

    init(session: URLSession? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        self.session = session ?? URLSession(configuration: configuration)
    }

    func pair(using link: OpenCodePairingLink) async throws -> DeepLinkConnection {
        var request = URLRequest(url: link.url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request, delegate: PairingRedirectDelegate())
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            // Do not surface an error containing the secret-bearing request URL.
            throw OpenCodePairingError.unreachable
        }
        guard let response = response as? HTTPURLResponse else {
            throw OpenCodePairingError.invalidResponse
        }
        switch response.statusCode {
        case 200: break
        case 401, 403, 404, 410: throw OpenCodePairingError.expiredOrUsed
        default: throw OpenCodePairingError.rejected(response.statusCode)
        }
        guard let credential = try? JSONDecoder().decode(PairingSession.self, from: data),
              !credential.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw OpenCodePairingError.invalidResponse }

        return DeepLinkConnection(
            serverURL: link.serverURL.absoluteString,
            username: "opencode",
            password: credential.token
        )
    }
}

private struct PairingSession: Decodable {
    let token: String
}

// A pairing code must only be sent to the origin the user scanned or pasted.
nonisolated private final class PairingRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

enum OpenCodePairingError: LocalizedError, Equatable {
    case expiredOrUsed
    case invalidResponse
    case unreachable
    case rejected(Int)

    var errorDescription: String? {
        switch self {
        case .expiredOrUsed:
            "This pairing link expired or was already used. Run opencode pair on your computer and scan or paste the new link."
        case .invalidResponse:
            "The server did not return a pairing token. Run opencode pair to get a new link."
        case .unreachable:
            "Could not reach the pairing server. Check that your iPhone can reach your computer, then try again. If the link was used, run opencode pair for a new one."
        case .rejected(let status):
            "The server rejected pairing (HTTP \(status)). Run opencode pair to get a new link."
        }
    }
}
