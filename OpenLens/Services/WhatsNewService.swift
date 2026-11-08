import Foundation
import Observation

/// Decides which release highlights a person should see after connecting, and remembers what this device has seen.
@MainActor @Observable
final class WhatsNewService {

    nonisolated static let lastSeenVersionKey = "whatsNewLastSeenVersion"
    nonisolated static let maximumReleasesShown = 3

    /// Releases waiting for the What's New sheet, newest first.
    private(set) var pendingReleases: [ReleaseHighlights] = []

    let currentVersion: String
    private let catalog: [ReleaseHighlights]
    private let userDefaults: UserDefaults

    init(
        currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
        catalog: [ReleaseHighlights] = ReleaseHighlights.catalog,
        userDefaults: UserDefaults = .standard
    ) {
        self.currentVersion = currentVersion
        self.catalog = catalog
        self.userDefaults = userDefaults
    }

    /// The newest release up to the current version that has highlights; what Settings reopens.
    var latestReleaseHighlights: ReleaseHighlights? {
        releases(after: nil).first
    }

    /// Call when a real connection to a server is established.
    /// - Parameter isFirstConnection: `true` when the person has never connected before, so nothing is new to them.
    func connectionEstablished(isFirstConnection: Bool) {
        guard pendingReleases.isEmpty else { return }

        let lastSeenVersion = userDefaults.string(forKey: Self.lastSeenVersionKey)
        if lastSeenVersion == nil, isFirstConnection {
            recordCurrentVersionAsSeen()
            return
        }

        let missed = Array(releases(after: lastSeenVersion).prefix(Self.maximumReleasesShown))
        if missed.isEmpty {
            recordCurrentVersionAsSeen()
        } else {
            pendingReleases = missed
        }
    }

    /// Hands the pending releases to the sheet and records them as seen the moment they appear.
    func takePendingReleases() -> [ReleaseHighlights] {
        let releases = pendingReleases
        pendingReleases = []
        recordCurrentVersionAsSeen()
        return releases
    }

    private func releases(after lastSeenVersion: String?) -> [ReleaseHighlights] {
        catalog
            .filter { release in
                !release.highlights.isEmpty
                    && !ReleaseHighlights.isVersion(release.version, newerThan: currentVersion)
                    && lastSeenVersion.map { ReleaseHighlights.isVersion(release.version, newerThan: $0) } ?? true
            }
            .sorted { ReleaseHighlights.isVersion($0.version, newerThan: $1.version) }
    }

    private func recordCurrentVersionAsSeen() {
        userDefaults.set(currentVersion, forKey: Self.lastSeenVersionKey)
    }
}
