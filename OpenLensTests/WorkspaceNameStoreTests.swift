import Foundation
import Testing
@testable import OpenLens

struct WorkspaceNameStoreTests {

    private func makeDefaults() -> UserDefaults {
        let suiteName = "WorkspaceNameStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test func displayNameFallsBackToLastPathComponent() {
        let store = WorkspaceNameStore(userDefaults: makeDefaults())

        #expect(store.customName(forDirectory: "/Users/dev/OpenLens") == nil)
        #expect(store.displayName(forDirectory: "/Users/dev/OpenLens") == "OpenLens")
    }

    @Test func customNameOverridesDefaultName() {
        let defaults = makeDefaults()
        let store = WorkspaceNameStore(userDefaults: defaults)

        store.setCustomName("Client work", forDirectory: "/Users/dev/OpenLens")

        #expect(store.customName(forDirectory: "/Users/dev/OpenLens") == "Client work")
        #expect(store.displayName(forDirectory: "/Users/dev/OpenLens") == "Client work")
    }

    @Test func emptyNameRemovesCustomName() {
        let store = WorkspaceNameStore(userDefaults: makeDefaults())
        store.setCustomName("Client work", forDirectory: "/Users/dev/OpenLens")

        store.setCustomName("   ", forDirectory: "/Users/dev/OpenLens")

        #expect(store.customName(forDirectory: "/Users/dev/OpenLens") == nil)
        #expect(store.displayName(forDirectory: "/Users/dev/OpenLens") == "OpenLens")
    }

    @Test func nilNameRemovesCustomName() {
        let store = WorkspaceNameStore(userDefaults: makeDefaults())
        store.setCustomName("Client work", forDirectory: "/Users/dev/OpenLens")

        store.setCustomName(nil, forDirectory: "/Users/dev/OpenLens")

        #expect(store.customName(forDirectory: "/Users/dev/OpenLens") == nil)
    }

    @Test func directoryVariationsResolveToTheSameName() {
        let store = WorkspaceNameStore(userDefaults: makeDefaults())

        store.setCustomName("Client work", forDirectory: "/Users/dev/OpenLens")

        #expect(store.customName(forDirectory: "/Users/dev/OpenLens/") == "Client work")
        #expect(store.customName(forDirectory: "  /Users/dev/OpenLens ") == "Client work")
        #expect(store.displayName(forDirectory: "/Users/dev/Other") == "Other")
    }

    @Test func namesPersistAcrossStoreInstances() {
        let defaults = makeDefaults()
        WorkspaceNameStore(userDefaults: defaults)
            .setCustomName("Client work", forDirectory: "/Users/dev/OpenLens")

        let reloadedStore = WorkspaceNameStore(userDefaults: defaults)

        #expect(reloadedStore.customName(forDirectory: "/Users/dev/OpenLens") == "Client work")
    }

    @Test func blankDirectoryHasNoName() {
        let store = WorkspaceNameStore(userDefaults: makeDefaults())

        #expect(store.customName(forDirectory: nil) == nil)
        #expect(store.displayName(forDirectory: nil) == nil)
        #expect(store.displayName(forDirectory: "") == nil)
        #expect(store.displayName(forDirectory: "   ") == nil)
    }
}
