import Foundation
import Observation
import os

/// Loads the public GitHub star count for the OpenLens repository and tracks progress toward the star goal.
@MainActor @Observable
final class GitHubStarsService {

    enum State: Equatable {
        case idle
        case loading
        case loaded(Int)
        case failed
    }

    nonisolated static let defaultGoal = 1000

    private(set) var state: State = .idle
    let goal: Int

    private let cacheDuration: TimeInterval
    private let now: () -> Date
    private let loadStarCount: () async throws -> Int
    private var lastLoadedAt: Date?

    init(
        goal: Int = GitHubStarsService.defaultGoal,
        cacheDuration: TimeInterval = 10 * 60,
        now: @escaping () -> Date = Date.init,
        loadStarCount: @escaping () async throws -> Int = GitHubStarsService.fetchStarCount
    ) {
        self.goal = goal
        self.cacheDuration = cacheDuration
        self.now = now
        self.loadStarCount = loadStarCount
    }

    var starCount: Int? {
        if case .loaded(let count) = state { return count }
        return nil
    }

    /// Fraction of the goal reached, clamped to `0...1`.
    var progress: Double {
        guard let starCount, goal > 0 else { return 0 }
        return min(max(Double(starCount) / Double(goal), 0), 1)
    }

    /// Fetches the star count unless a recent value is still fresh. Keeps the last known count if a refresh fails.
    func refresh() async {
        if case .loading = state { return }
        if let lastLoadedAt, now().timeIntervalSince(lastLoadedAt) < cacheDuration { return }

        let previous = state
        if case .loaded = previous {} else { state = .loading }

        do {
            let count = try await loadStarCount()
            state = .loaded(count)
            lastLoadedAt = now()
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                state = previous
                return
            }
            Logger.gitHubStars.error("Failed to load star count: \(error.localizedDescription, privacy: .public)")
            if case .loaded = previous {
                state = previous
            } else {
                state = .failed
            }
        }
    }

    // MARK: - Networking

    static func fetchStarCount() async throws -> Int {
        guard let url = URL(string: "https://api.github.com/repos/\(AppText.settingsSupportRepository)") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try decodeStarCount(from: data)
    }

    static func decodeStarCount(from data: Data) throws -> Int {
        try JSONDecoder().decode(RepositoryResponse.self, from: data).stargazersCount
    }

    private struct RepositoryResponse: Decodable {
        let stargazersCount: Int

        enum CodingKeys: String, CodingKey {
            case stargazersCount = "stargazers_count"
        }
    }
}
