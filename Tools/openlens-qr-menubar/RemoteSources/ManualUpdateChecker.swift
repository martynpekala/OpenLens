import Foundation

struct RemoteAgentRelease: Decodable {
    let tagName: String
    let name: String?
    let pageURL: URL

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case pageURL = "html_url"
    }

    func matches(version: String) -> Bool {
        normalized(tagName) == normalized(version)
    }

    private func normalized(_ version: String) -> String {
        version.trimmingCharacters(in: .whitespacesAndNewlines)
            .drop(while: { $0 == "v" || $0 == "V" })
            .description
    }
}

struct ManualUpdateChecker {
    func latestRelease() async throws -> RemoteAgentRelease {
        let url = URL(string: "https://api.github.com/repos/martynpekala/OpenLens/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("OpenLensRemote", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        let (data, response) = try await URLSession(configuration: configuration).data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw RemoteProtocolError.remoteError("update_check_failed")
        }
        return try JSONDecoder().decode(RemoteAgentRelease.self, from: data)
    }
}
