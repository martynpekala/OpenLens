import Foundation
import Testing
@testable import OpenLens

struct SavedConnectionsStoreTests {

    @Test func keepsRecentConnectionsForSuggestions() {
        let store = SavedConnectionsStore(initialConnections: [])

        store.saveConnection(
            serverURL: "http://192.168.1.50:4096",
            username: "opencode",
            password: ""
        )
        store.saveConnection(
            serverURL: "http://10.0.0.12:4096",
            username: "opencode",
            password: "secret"
        )

        #expect(store.connections.count == 2)
        #expect(Set(store.suggestions(for: "").map(\.serverURL)) == Set([
            "http://192.168.1.50:4096",
            "http://10.0.0.12:4096",
        ]))
        #expect(store.suggestions(for: "10.0").map(\.serverURL) == [
            "http://10.0.0.12:4096",
        ])
    }

    @Test func capsHistoryToMostRecentConnections() {
        let connections = (0..<7).map { index in
            SavedConnection(
                id: "\(index)",
                serverURL: "http://192.168.1.\(index):4096",
                username: "opencode",
                password: "",
                lastConnectedAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }

        let store = SavedConnectionsStore(initialConnections: connections)

        #expect(store.connections.map(\.id) == ["6", "5", "4", "3", "2"])
    }

    @Test func reusingSavedConnectionMovesItToFront() {
        let store = SavedConnectionsStore(initialConnections: [
            SavedConnection(
                id: "newer",
                serverURL: "http://10.0.0.12:4096",
                username: "opencode",
                password: "",
                lastConnectedAt: Date(timeIntervalSince1970: 20)
            ),
            SavedConnection(
                id: "older",
                serverURL: "http://192.168.1.50:4096",
                username: "opencode",
                password: "",
                lastConnectedAt: Date(timeIntervalSince1970: 10)
            ),
        ])

        store.saveConnection(
            serverURL: "http://192.168.1.50:4096",
            username: "opencode",
            password: "updated"
        )

        #expect(store.connections.count == 2)
        #expect(store.mostRecent?.id == "older")
        #expect(store.mostRecent?.password == "updated")
    }

    @Test func publicSnapshotFallbackRestoresAddressWithoutPassword() {
        let snapshots = [
            SavedConnectionPublicSnapshot(connection: SavedConnection(
                id: "fallback",
                serverURL: "http://192.168.1.50:4096",
                username: "opencode",
                password: "secret",
                lastConnectedAt: Date(timeIntervalSince1970: 10)
            )),
        ]

        let restored = SavedConnectionsStore.mergeKeychainConnections([], withPublicSnapshots: snapshots)

        #expect(restored.count == 1)
        #expect(restored.first?.serverURL == "http://192.168.1.50:4096")
        #expect(restored.first?.username == "opencode")
        #expect(restored.first?.password == "")
    }

    @Test func publicSnapshotMergePreservesKeychainPassword() {
        let keychainConnection = SavedConnection(
            id: "existing",
            serverURL: "http://192.168.1.50:4096",
            username: "opencode",
            password: "secret",
            lastConnectedAt: Date(timeIntervalSince1970: 5)
        )
        let snapshot = SavedConnectionPublicSnapshot(connection: SavedConnection(
            id: "existing",
            serverURL: "http://192.168.1.50:4096",
            username: "opencode",
            password: "",
            selectedProjectDirectory: "/Users/me/project",
            lastConnectedAt: Date(timeIntervalSince1970: 15)
        ))

        let restored = SavedConnectionsStore.mergeKeychainConnections(
            [keychainConnection],
            withPublicSnapshots: [snapshot]
        )

        #expect(restored.count == 1)
        #expect(restored.first?.password == "secret")
        #expect(restored.first?.selectedProjectDirectory == "/Users/me/project")
        #expect(restored.first?.lastConnectedAt == Date(timeIntervalSince1970: 15))
    }
}
