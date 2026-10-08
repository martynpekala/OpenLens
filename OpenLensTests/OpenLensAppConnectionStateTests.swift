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
            isConnectionStatusPresented: false,
            isQRScannerPresented: false,
            didManuallyDisconnect: false,
            savedConnection: nil
        ))

        #expect(!shouldAttemptAutoReconnect(
            isEnabled: true,
            isConnected: false,
            isConnectionStatusPresented: false,
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
            isConnectionStatusPresented: false,
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

    @Test func autoReconnectFailureShowsTheUnderlyingConnectionError() {
        #expect(connectionFailureMessage(
            localNetworkAccessRequired: false,
            connectionError: "HTTP error 401.",
            isAutoReconnect: true
        ) == "HTTP error 401.")
    }

    @Test func returningToActiveSetupDoesNotReconnectToThePreviousComputer() {
        #expect(!shouldAttemptAutoReconnect(
            isEnabled: true,
            isConnected: false,
            isConnectionStatusPresented: false,
            isQRScannerPresented: false,
            didManuallyDisconnect: false,
            savedConnection: SavedConnection(
                id: "previous-computer",
                serverURL: "http://192.168.1.50:4096",
                username: "opencode",
                password: ""
            ),
            isConnectionSetupInProgress: true
        ))
    }

    @Test func autoReconnectFailureUsesGenericCopyWhenNoErrorIsAvailable() {
        #expect(connectionFailureMessage(
            localNetworkAccessRequired: false,
            connectionError: nil,
            isAutoReconnect: true
        ) == AppText.autoReconnectErrorBody)
    }

    @Test func localNetworkFailureTakesPriorityOverTheTransportError() {
        #expect(connectionFailureMessage(
            localNetworkAccessRequired: true,
            connectionError: "The request timed out.",
            isAutoReconnect: true
        ) == AppText.localNetworkAccessRequiredBody)
    }

    @Test(arguments: [
        ("192.168.1.5:4096", "192.168.1.5:4096"),
        ("http://macbook.local:4096/", "macbook.local:4096"),
        ("  https://example.com  ", "example.com"),
        ("http://[fe80::1]:4096", "[fe80::1]:4096"),
    ])
    func connectionStatusNamesTheServerByHostAndPort(serverURL: String, expected: String) {
        #expect(connectionServerDisplayName(serverURL) == expected)
    }

    @Test func connectionStatusNeverShowsCredentialsOrTokensFromTheServerURL() {
        #expect(connectionServerDisplayName("https://user:secret@example.com/pair?token=abc") == "example.com")
    }

    @Test func connectionStatusShowsNoServerForABlankURL() {
        #expect(connectionServerDisplayName("   ") == nil)
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

    @Test @MainActor func openingTheAppCanReconnectOnlyBeforeAnyConnectionAttempt() async {
        let connection = ConnectionManager(localNetworkAccessProbe: LocalNetworkAccessProbeStub(result: .accessRequired))

        #expect(!connection.hasAttemptedConnection)

        await connection.connect(url: "192.168.1.50:4096", username: "opencode", password: "")
        connection.disconnect()

        #expect(connection.hasAttemptedConnection)
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
