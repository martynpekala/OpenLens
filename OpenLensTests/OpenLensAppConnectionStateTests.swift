import Testing
@testable import OpenLens

struct OpenLensAppConnectionStateTests {

    @Test func treatsInitialConnectedTransitionAsFreshConnect() {
        #expect(shouldHandleConnectionAsFreshConnect(from: .connecting, to: .connected))
    }

    @Test func doesNotTreatReconnectAsFreshConnect() {
        #expect(!shouldHandleConnectionAsFreshConnect(from: .reconnecting, to: .connected))
    }

    @Test func ignoresNonConnectedTransitions() {
        #expect(!shouldHandleConnectionAsFreshConnect(from: .connected, to: .reconnecting))
    }

    @Test func autoReconnectRequiresConfiguredSavedConnection() {
        #expect(!shouldAttemptAutoReconnect(
            isEnabled: true,
            isConnected: false,
            isConnectionSheetPresented: false,
            isQRScannerPresented: false,
            didManuallyDisconnect: false,
            savedConnection: nil
        ))

        #expect(!shouldAttemptAutoReconnect(
            isEnabled: true,
            isConnected: false,
            isConnectionSheetPresented: false,
            isQRScannerPresented: false,
            didManuallyDisconnect: false,
            savedConnection: SavedConnection(
                id: "empty",
                serverURL: "",
                username: "opencode",
                password: ""
            )
        ))

        #expect(shouldAttemptAutoReconnect(
            isEnabled: true,
            isConnected: false,
            isConnectionSheetPresented: false,
            isQRScannerPresented: false,
            didManuallyDisconnect: false,
            savedConnection: SavedConnection(
                id: "configured",
                serverURL: "http://192.168.1.50:4096",
                username: "opencode",
                password: ""
            )
        ))
    }
}
