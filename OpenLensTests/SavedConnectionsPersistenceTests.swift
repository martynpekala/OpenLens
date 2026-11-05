import Foundation
import Testing
@testable import OpenLens

extension MultiServerSuite {
    @Suite struct Persistence {

        private func makeDefaults() -> UserDefaults {
            let suiteName = "SavedConnectionsPersistenceTests-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defaults.removePersistentDomain(forName: suiteName)
            return defaults
        }

        private func connection(
            _ id: String,
            at seconds: TimeInterval? = nil,
            nickname: String? = nil
        ) -> SavedConnection {
            SavedConnection(
                id: id,
                serverURL: "http://\(id).local:4096",
                username: "opencode",
                password: "",
                lastConnectedAt: seconds.map { Date(timeIntervalSince1970: $0) },
                nickname: nickname
            )
        }

        @Test func nicknameRestoresFromPublicSnapshotWhenKeychainCopyLacksIt() {
            let keychainCopy = connection("a", at: 1)
            let snapshot = SavedConnectionPublicSnapshot(connection: connection("a", at: 1, nickname: "Home Mac"))

            let restored = SavedConnectionsStore.mergeKeychainConnections([keychainCopy], withPublicSnapshots: [snapshot])

            #expect(restored.first?.nickname == "Home Mac")
        }

        @Test func nicknameRestoresFromPublicSnapshotWhenKeychainIsEmpty() {
            let snapshot = SavedConnectionPublicSnapshot(connection: connection("a", at: 1, nickname: "Home Mac"))

            let restored = SavedConnectionsStore.mergeKeychainConnections([], withPublicSnapshots: [snapshot])

            #expect(restored.first?.nickname == "Home Mac")
            #expect(restored.first?.displayName == "Home Mac")
        }

        @Test func displayNamePrefersTrimmedNicknameAndIgnoresBlankOne() {
            #expect(connection("a", nickname: "  Work  ").displayName == "Work")
            #expect(connection("a", nickname: "   ").displayName == "a.local:4096")
            #expect(connection("a", nickname: nil).displayName == "a.local:4096")
        }

        @Test func updatingNicknameSetsTrimsAndClearsIt() {
            let store = SavedConnectionsStore(initialConnections: [connection("a")])

            store.updateNickname(connectionID: "a", nickname: "  Lab ")
            #expect(store.connections.first?.nickname == "Lab")

            store.updateNickname(connectionID: "a", nickname: "  ")
            #expect(store.connections.first?.nickname == nil)

            store.updateNickname(connectionID: "missing", nickname: "Ghost")
            #expect(store.connections.count == 1)
        }

        @Test func arrayOrderIsStableAcrossReconnectsWhileSuggestionsStayRecencyOrdered() {
            let store = SavedConnectionsStore(initialConnections: [])
            let first = store.saveConnection(serverURL: "http://one:4096", username: "u", password: "")
            let second = store.saveConnection(serverURL: "http://two:4096", username: "u", password: "")
            let third = store.saveConnection(serverURL: "http://three:4096", username: "u", password: "")
            let insertionOrder = [third.id, second.id, first.id]
            #expect(store.connections.map(\.id) == insertionOrder)

            Thread.sleep(forTimeInterval: 0.01)
            store.saveConnection(serverURL: "http://one:4096", username: "u", password: "")
            Thread.sleep(forTimeInterval: 0.01)
            store.saveConnection(serverURL: "http://two:4096", username: "u", password: "")

            #expect(store.connections.map(\.id) == insertionOrder)
            #expect(store.suggestions(for: "").map(\.id) == [second.id, first.id, third.id])
            #expect(store.mostRecent?.id == second.id)
        }

        @Test func cappingEvictsLeastRecentlyConnectedRegardlessOfArrayPosition() {
            // Array order is deliberately unrelated to recency; the oldest sit at the front.
            var connections = (0..<22).map { connection("c\($0)", at: TimeInterval(100 + $0)) }
            connections[0] = connection("oldest", at: 1)
            connections[1] = connection("never", at: nil)

            let store = SavedConnectionsStore(initialConnections: connections)

            #expect(store.connections.count == 20)
            #expect(!store.connections.contains { $0.id == "oldest" })
            #expect(!store.connections.contains { $0.id == "never" })
            #expect(store.connections.map(\.id) == (2..<22).map { "c\($0)" })
        }

        @Test func lastActiveConnectionSurvivesDisconnectAndRelaunch() {
            let defaults = makeDefaults()
            let store = SavedConnectionsStore(initialConnections: [], userDefaults: defaults)

            let saved = store.saveConnection(serverURL: "http://one:4096", username: "u", password: "")
            #expect(store.lastActiveConnectionID == nil)
            store.setLastActiveConnection(id: saved.id)
            #expect(store.lastActiveConnectionID == saved.id)

            store.clearActiveConnection()
            #expect(store.activeConnectionID == nil)
            #expect(store.lastActiveConnectionID == saved.id)

            let relaunched = SavedConnectionsStore(initialConnections: [saved], userDefaults: defaults)
            #expect(relaunched.lastActiveConnectionID == saved.id)
            #expect(relaunched.activeConnectionID == nil)
        }

        @Test func savingAConnectionDoesNotMakeItTheLastActiveOne() {
            let store = SavedConnectionsStore(initialConnections: [], userDefaults: makeDefaults())
            let first = store.saveConnection(serverURL: "http://one:4096", username: "u", password: "")
            store.setLastActiveConnection(id: first.id)

            store.saveConnection(serverURL: "http://two:4096", username: "u", password: "")

            #expect(store.lastActiveConnectionID == first.id)
        }

        @Test func forgettingTheLastActiveConnectionClearsIt() {
            let defaults = makeDefaults()
            let store = SavedConnectionsStore(initialConnections: [], userDefaults: defaults)
            let saved = store.saveConnection(serverURL: "http://one:4096", username: "u", password: "")
            store.setLastActiveConnection(id: saved.id)

            store.removeConnection(id: saved.id)

            #expect(store.lastActiveConnectionID == nil)
            #expect(SavedConnectionsStore(initialConnections: [saved], userDefaults: defaults).lastActiveConnectionID == nil)
        }

        @Test func connectPathMutationsCoalesceIntoOneWriteAttempt() {
            let store = SavedConnectionsStore(initialConnections: [connection("a")])

            // One connect calls this three times, so N servers at launch would otherwise mean
            // 3N whole-array Keychain writes. The directory is re-derived on the next connect,
            // which is what makes deferring it safe.
            store.updateProjectSelection(connectionID: "a", directory: "/tmp/one")
            store.updateProjectSelection(connectionID: "a", directory: "/tmp/two")
            store.updateProjectSelection(connectionID: "a", directory: "/tmp/three")
            #expect(store.persistWriteAttempts == 0)

            store.flushPendingPersist()
            #expect(store.persistWriteAttempts == 1)

            store.flushPendingPersist()
            #expect(store.persistWriteAttempts == 1)
        }

        @Test func aDeliberateUserActionIsWrittenWithoutWaitingForAFlush() {
            let store = SavedConnectionsStore(initialConnections: [connection("a"), connection("b")])

            // Naming a server, choosing a model, forgetting a server: nothing re-derives these,
            // so a termination straight after the action must not lose them.
            store.updateNickname(connectionID: "a", nickname: "A")
            #expect(store.persistWriteAttempts == 1)

            store.updateModelSelection(connectionID: "a", providerID: "anthropic", modelID: "m", variant: nil)
            #expect(store.persistWriteAttempts == 2)

            store.removeConnection(id: "b")
            #expect(store.persistWriteAttempts == 3)
        }

        @Test func pendingConnectPathMutationsAreFlushedOnTheNextMainActorTurn() async {
            let store = SavedConnectionsStore(initialConnections: [connection("a")])

            store.updateProjectSelection(connectionID: "a", directory: "/tmp/one")
            store.updateProjectSelection(connectionID: "a", directory: "/tmp/two")
            for _ in 0..<5 { await Task.yield() }

            #expect(store.persistWriteAttempts == 1)
        }
    }
}
