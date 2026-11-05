import Foundation
import Testing
@testable import OpenLens

extension MultiServerSuite {
    @Suite struct SharedCredentials {

        private func makeDefaults() -> (UserDefaults, cleanup: () -> Void) {
            let suiteName = "SharedCredentialsTests-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defaults.removePersistentDomain(forName: suiteName)
            return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
        }

        @Test func credentialsSavedForTwoServersResolveIndependently() {
            let (defaults, cleanup) = makeDefaults()
            defer { cleanup() }
            SharedConnectionStore.save(serverID: "A", baseURL: "https://a.example", authHeader: "Basic A", protocolVersion: "v1", defaults: defaults)
            SharedConnectionStore.save(serverID: "B", baseURL: "https://b.example", authHeader: "Basic B", protocolVersion: "v2", defaults: defaults)

            let a = SharedConnectionStore.credentials(for: "A", defaults: defaults)
            let b = SharedConnectionStore.credentials(for: "B", defaults: defaults)
            #expect(a == .init(baseURL: "https://a.example", authHeader: "Basic A", usesV2: false))
            #expect(b == .init(baseURL: "https://b.example", authHeader: "Basic B", usesV2: true))
        }

        @Test func unknownServerIDResolvesToNothingRatherThanAnotherServer() {
            let (defaults, cleanup) = makeDefaults()
            defer { cleanup() }
            SharedConnectionStore.save(serverID: "A", baseURL: "https://a.example", authHeader: "Basic A", defaults: defaults)
            SharedConnectionStore.save(serverID: "B", baseURL: "https://b.example", authHeader: "Basic B", protocolVersion: "v2", defaults: defaults)

            // The legacy slots hold B, but an activity that names a server OpenLens no longer
            // knows must not answer its prompt against B. This is the whole point of attribution.
            #expect(SharedConnectionStore.credentials(for: "missing", defaults: defaults) == nil)
        }

        @Test func nilServerIDResolvesToTheMostRecentlySavedServer() {
            let (defaults, cleanup) = makeDefaults()
            defer { cleanup() }
            SharedConnectionStore.save(serverID: "A", baseURL: "https://a.example", authHeader: "Basic A", defaults: defaults)
            SharedConnectionStore.save(serverID: "B", baseURL: "https://b.example", authHeader: nil, defaults: defaults)

            let resolved = SharedConnectionStore.credentials(for: nil, defaults: defaults)
            #expect(resolved == .init(baseURL: "https://b.example", authHeader: nil, usesV2: false))
        }

        @Test func clearingOneServerLeavesTheOtherIntact() {
            let (defaults, cleanup) = makeDefaults()
            defer { cleanup() }
            SharedConnectionStore.save(serverID: "A", baseURL: "https://a.example", authHeader: "Basic A", defaults: defaults)
            SharedConnectionStore.save(serverID: "B", baseURL: "https://b.example", authHeader: "Basic B", defaults: defaults)

            SharedConnectionStore.clear(serverID: "A", defaults: defaults)

            #expect(SharedConnectionStore.credentials(for: "B", defaults: defaults)?.baseURL == "https://b.example")
            // A is gone, and an attributed activity must not borrow B's credentials to answer
            // A's prompt -- resolving to nothing is the only safe answer.
            #expect(SharedConnectionStore.credentials(for: "A", defaults: defaults) == nil)
        }

        @Test func clearingTheLastSavedServerRemovesTheLegacySlots() {
            let (defaults, cleanup) = makeDefaults()
            defer { cleanup() }
            SharedConnectionStore.save(serverID: "A", baseURL: "https://a.example", authHeader: "Basic A", defaults: defaults)

            SharedConnectionStore.clear(serverID: "A", defaults: defaults)

            #expect(SharedConnectionStore.credentials(for: "A", defaults: defaults) == nil)
            #expect(SharedConnectionStore.credentials(for: nil, defaults: defaults) == nil)
        }

        @Test func clearAllRemovesEveryServerAndTheLegacySlots() {
            let (defaults, cleanup) = makeDefaults()
            defer { cleanup() }
            SharedConnectionStore.save(serverID: "A", baseURL: "https://a.example", authHeader: "Basic A", defaults: defaults)
            SharedConnectionStore.save(serverID: "B", baseURL: "https://b.example", authHeader: "Basic B", defaults: defaults)

            SharedConnectionStore.clearAll(defaults: defaults)

            #expect(SharedConnectionStore.credentials(for: "A", defaults: defaults) == nil)
            #expect(SharedConnectionStore.credentials(for: "B", defaults: defaults) == nil)
            #expect(SharedConnectionStore.credentials(for: nil, defaults: defaults) == nil)
        }

        @Test func saveStillWritesTheLegacySlotsSoAnAttributeLessActivityResolves() {
            let (defaults, cleanup) = makeDefaults()
            defer { cleanup() }
            SharedConnectionStore.save(serverID: "A", baseURL: "https://a.example", authHeader: "Basic A", protocolVersion: "v2", defaults: defaults)

            #expect(defaults.string(forKey: "server_base_url") == "https://a.example")
            #expect(defaults.string(forKey: "server_auth_header") == "Basic A")
            #expect(defaults.string(forKey: "server_api_protocol") == "v2")
        }
    }
}
