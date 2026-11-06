import Testing
@testable import OpenLens

extension MultiServerSuite {
    @Suite struct ServerRows {
        @Test func aConnectedServerThatIsShownReadsAsActive() {
            #expect(serverRowStatus(connectionState: .connected, isActive: true) == .active)
        }

        @Test func aConnectedServerThatIsNotShownReadsAsConnected() {
            #expect(serverRowStatus(connectionState: .connected, isActive: false) == .connected)
        }

        @Test func connectingAndReconnectingServersReadAsPendingWhetherOrNotTheyAreShown() {
            #expect(serverRowStatus(connectionState: .connecting, isActive: true) == .connecting)
            #expect(serverRowStatus(connectionState: .connecting, isActive: false) == .connecting)
            #expect(serverRowStatus(connectionState: .reconnecting, isActive: true) == .reconnecting)
            #expect(serverRowStatus(connectionState: .reconnecting, isActive: false) == .reconnecting)
        }

        @Test func anErroredServerReadsAsFailedWhetherOrNotItIsShown() {
            #expect(serverRowStatus(connectionState: .error("refused"), isActive: true) == .failed)
            #expect(serverRowStatus(connectionState: .error("refused"), isActive: false) == .failed)
        }

        @Test func aDisconnectedServerReadsAsIdleEvenWhenItIsTheActiveOne() {
            #expect(serverRowStatus(connectionState: .disconnected, isActive: true) == .idle)
            #expect(serverRowStatus(connectionState: .disconnected, isActive: false) == .idle)
        }

        @Test func onlyMeaningfulStatesCarryASemanticDotColour() {
            #expect(ServerRowStatus.active.tone == .success)
            #expect(ServerRowStatus.connected.tone == .success)
            #expect(ServerRowStatus.connecting.tone == .warning)
            #expect(ServerRowStatus.reconnecting.tone == .warning)
            #expect(ServerRowStatus.failed.tone == .danger)
            #expect(ServerRowStatus.idle.tone == .neutral)
        }

        @Test func everyStatusHasADistinctNonEmptyLabel() {
            let labels = [ServerRowStatus.active, .connected, .connecting, .reconnecting, .failed, .idle].map(\.label)
            #expect(labels.allSatisfy { !$0.isEmpty })
            #expect(Set(labels).count == labels.count)
        }

        @Test func multiServerChromeStaysOffForNoServersAndForOne() {
            #expect(!isMultiServerUIEnabled(savedServerCount: 0))
            #expect(!isMultiServerUIEnabled(savedServerCount: 1))
        }

        @Test func multiServerChromeTurnsOnAtTwoSavedServers() {
            #expect(isMultiServerUIEnabled(savedServerCount: 2))
        }
    }
}
