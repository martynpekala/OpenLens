import Foundation
import Testing
@testable import OpenLens

struct OpenLensAppConnectionStateTests {

    @Test func initialSessionsRemainUnresolvedWhileLoading() {
        var readiness = InitialSessionsReadiness()

        #expect(readiness.state == .idle)
        #expect(!readiness.isResolved)

        _ = readiness.beginLoading()

        #expect(readiness.state == .loading)
        #expect(!readiness.isResolved)
    }

    @Test func anEmptySessionListIsStillAResolvedInitialLoad() {
        var readiness = InitialSessionsReadiness()
        let generation = readiness.beginLoading()

        readiness.succeed(with: [], generation: generation)

        #expect(readiness.state == .loaded([]))
        #expect(readiness.isResolved)
    }

    @Test func disconnectInvalidatesAnInFlightInitialSessionLoad() {
        var readiness = InitialSessionsReadiness()
        let staleGeneration = readiness.beginLoading()

        readiness.reset()
        readiness.succeed(
            with: ScreenshotFixtures.sessions,
            generation: staleGeneration
        )

        #expect(readiness.state == .idle)
        #expect(!readiness.isResolved)
    }

    @Test func reconnectRetriesOnlyAnUnresolvedInitialSessionLoad() {
        var loadingReadiness = InitialSessionsReadiness()
        let staleGeneration = loadingReadiness.beginLoading()

        loadingReadiness.cancelLoading()
        loadingReadiness.succeed(
            with: ScreenshotFixtures.sessions,
            generation: staleGeneration
        )

        #expect(loadingReadiness.state == .idle)

        var loadedReadiness = InitialSessionsReadiness(
            initialSessions: ScreenshotFixtures.sessions
        )
        loadedReadiness.cancelLoading()

        #expect(loadedReadiness.state == .loaded(ScreenshotFixtures.sessions))
    }

    @Test func initialSessionFailureIsResolvedWithoutWaitingForever() {
        var readiness = InitialSessionsReadiness()
        let generation = readiness.beginLoading()

        readiness.fail(with: "Server error", generation: generation)

        #expect(readiness.state == .failed("Server error"))
        #expect(readiness.isResolved)
    }

    @Test func screenshotSessionsAreResolvedAtInitialization() {
        let readiness = InitialSessionsReadiness(
            initialSessions: ScreenshotFixtures.sessions
        )

        #expect(readiness.state == .loaded(ScreenshotFixtures.sessions))
        #expect(readiness.isResolved)
    }

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

    @Test @MainActor func localNetworkProbeStopsConnectionBeforeHTTPWhenAccessIsRequired() async {
        let probe = LocalNetworkAccessProbeStub(result: .accessRequired)
        let connection = ConnectionManager(localNetworkAccessProbe: probe)

        await connection.connect(
            url: "192.168.1.50:4096",
            username: "opencode",
            password: ""
        )

        #expect(connection.localNetworkAccessRequired)
        #expect(connection.state == .error(AppText.localNetworkAccessRequiredBody))
        #expect(connection.client == nil)
        #expect(probe.urls == [URL(string: "http://192.168.1.50:4096")!])
    }

    @Test func bonjourPolicyDeniedCodeRequiresLocalNetworkAccess() {
        #expect(BonjourDiscovery.isLocalNetworkPolicyDeniedDNSCode(-65570))
        #expect(!BonjourDiscovery.isLocalNetworkPolicyDeniedDNSCode(-65569))
    }
}

@MainActor
private final class LocalNetworkAccessProbeStub: LocalNetworkAccessProbing {
    let result: LocalNetworkAccessProbeResult
    private(set) var urls: [URL] = []

    init(result: LocalNetworkAccessProbeResult) {
        self.result = result
    }

    func probe(_ url: URL) async -> LocalNetworkAccessProbeResult {
        urls.append(url)
        return result
    }
}
