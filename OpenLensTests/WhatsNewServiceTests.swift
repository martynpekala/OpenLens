import Foundation
import Testing
@testable import OpenLens

@MainActor
struct WhatsNewServiceTests {

    private static func release(_ version: String, highlights count: Int = 1) -> ReleaseHighlights {
        ReleaseHighlights(
            version: version,
            highlights: (0..<count).map {
                ReleaseHighlight(id: "\(version).\($0)", systemImage: "sparkles", title: "Title", text: "Text")
            }
        )
    }

    private static let catalog = [
        release("2.2"),
        release("2.3"),
        release("2.4", highlights: 0),
        release("2.5"),
        release("2.6"),
        release("2.10"),
    ]

    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let suiteName = "OpenLensTests.whats-new-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(defaults)
    }

    private func versions(_ releases: [ReleaseHighlights]) -> [String] {
        releases.map(\.version)
    }

    @Test func firstConnectionAfterFreshInstallShowsNothingAndRecordsVersion() {
        withDefaults { defaults in
            let service = WhatsNewService(currentVersion: "2.3", catalog: Self.catalog, userDefaults: defaults)

            service.connectionEstablished(isFirstConnection: true)

            #expect(service.pendingReleases.isEmpty)
            #expect(defaults.string(forKey: WhatsNewService.lastSeenVersionKey) == "2.3")
        }
    }

    @Test func existingUserWithoutStoredVersionSeesReleasesUpToCurrent() {
        withDefaults { defaults in
            let service = WhatsNewService(currentVersion: "2.3", catalog: Self.catalog, userDefaults: defaults)

            service.connectionEstablished(isFirstConnection: false)

            #expect(versions(service.pendingReleases) == ["2.3", "2.2"])
        }
    }

    @Test func showsOnlyMissedReleasesNewestFirstCappedAtThree() {
        withDefaults { defaults in
            defaults.set("2.2", forKey: WhatsNewService.lastSeenVersionKey)
            let service = WhatsNewService(currentVersion: "2.10", catalog: Self.catalog, userDefaults: defaults)

            service.connectionEstablished(isFirstConnection: false)

            #expect(versions(service.pendingReleases) == ["2.10", "2.6", "2.5"])
        }
    }

    @Test func releaseWithoutHighlightsShowsNothingButRecordsVersion() {
        withDefaults { defaults in
            defaults.set("2.3", forKey: WhatsNewService.lastSeenVersionKey)
            let service = WhatsNewService(currentVersion: "2.4", catalog: Self.catalog, userDefaults: defaults)

            service.connectionEstablished(isFirstConnection: false)

            #expect(service.pendingReleases.isEmpty)
            #expect(defaults.string(forKey: WhatsNewService.lastSeenVersionKey) == "2.4")
        }
    }

    @Test func takingPendingReleasesRecordsThemAsSeen() {
        withDefaults { defaults in
            defaults.set("2.2", forKey: WhatsNewService.lastSeenVersionKey)
            let service = WhatsNewService(currentVersion: "2.3", catalog: Self.catalog, userDefaults: defaults)
            service.connectionEstablished(isFirstConnection: false)

            let taken = service.takePendingReleases()
            service.connectionEstablished(isFirstConnection: false)

            #expect(versions(taken) == ["2.3"])
            #expect(service.pendingReleases.isEmpty)
            #expect(defaults.string(forKey: WhatsNewService.lastSeenVersionKey) == "2.3")
        }
    }

    @Test func pendingReleasesSurviveUntilPresented() {
        withDefaults { defaults in
            defaults.set("2.2", forKey: WhatsNewService.lastSeenVersionKey)
            let service = WhatsNewService(currentVersion: "2.3", catalog: Self.catalog, userDefaults: defaults)

            service.connectionEstablished(isFirstConnection: false)
            service.connectionEstablished(isFirstConnection: false)

            #expect(versions(service.pendingReleases) == ["2.3"])
            #expect(defaults.string(forKey: WhatsNewService.lastSeenVersionKey) == "2.2")
        }
    }

    @Test func settingsReopensLatestReleaseWithHighlights() {
        withDefaults { defaults in
            let service = WhatsNewService(currentVersion: "2.4", catalog: Self.catalog, userDefaults: defaults)

            #expect(service.latestReleaseHighlights?.version == "2.3")
        }
    }

    @Test func bundledCatalogHasHighlightsForCurrentRelease() {
        withDefaults { defaults in
            let service = WhatsNewService(currentVersion: "2.2", userDefaults: defaults)

            #expect(service.latestReleaseHighlights?.highlights.count == 5)
        }
    }
}
