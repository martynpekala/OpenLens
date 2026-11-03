import Foundation
import Testing
@testable import OpenLens

@MainActor
struct UsageQuotaServiceTests {

    private final class Loader {
        var results: [Result<UsageQuotaService.QuotaSnapshot, Error>]
        private(set) var callCount = 0

        init(_ results: [Result<UsageQuotaService.QuotaSnapshot, Error>]) {
            self.results = results
        }

        func load(region: UsageQuotaService.Region, apiKey: String) async throws -> UsageQuotaService.QuotaSnapshot {
            callCount += 1
            if results.count > 1 {
                return try results.removeFirst().get()
            }
            guard let result = results.first else {
                throw UsageQuotaService.UsageQuotaError.invalidResponse
            }
            return try result.get()
        }
    }

    private func snapshot(
        planName: String? = "GLM Coding Plan",
        windows: [UsageQuotaService.QuotaWindow] = []
    ) -> UsageQuotaService.QuotaSnapshot {
        UsageQuotaService.QuotaSnapshot(
            planName: planName,
            windows: windows,
            fetchedAt: Date(timeIntervalSince1970: 1_000)
        )
    }

    // MARK: - Decoding

    @Test func decodesCodingPlanWindowsAndSortsByDuration() throws {
        let payload = Data(
            #"""
            {"data":{"planName":"GLM Coding Plan","limits":[
              {"type":"TOKENS_LIMIT","percentage":17,"usage":1000,"remaining":5000,
               "window":{"unit":"HOURS","number":168},"nextResetTime":1772985600000},
              {"type":"TOKENS_LIMIT","percentage":82,"usage":820,"remaining":180,
               "window":{"unit":"HOURS","number":5},"nextResetTime":1762236118000}
            ]}}
            """#.utf8
        )

        let decoded = try UsageQuotaService.decodeSnapshot(
            from: payload,
            fetchedAt: Date(timeIntervalSince1970: 0)
        )

        #expect(decoded.planName == "GLM Coding Plan")
        #expect(decoded.windows.count == 2)
        // Shortest window first.
        #expect(decoded.windows[0].title == AppText.quotaWindow5Hour)
        #expect(decoded.windows[0].percentage == 82)
        #expect(decoded.windows[1].title == AppText.quotaWindowWeekly)
        #expect(decoded.windows[1].percentage == 17)
        // nextResetTime is epoch milliseconds.
        #expect(decoded.windows[0].resetAt == Date(timeIntervalSince1970: 1_762_236_118))
    }

    @Test func ignoresTimeLimitsAndReportsNoLimitsWhenNothingRecognized() {
        let payload = Data(
            #"""
            {"data":{"limits":[{"type":"TIME_LIMIT","percentage":3}]}}
            """#.utf8
        )

        #expect(throws: UsageQuotaService.UsageQuotaError.noLimitsReported) {
            _ = try UsageQuotaService.decodeSnapshot(from: payload, fetchedAt: Date())
        }
    }

    @Test func missingLimitsArrayReportsNoLimits() {
        let payload = Data(#"{"data":{}}"#.utf8)

        #expect(throws: UsageQuotaService.UsageQuotaError.noLimitsReported) {
            _ = try UsageQuotaService.decodeSnapshot(from: payload, fetchedAt: Date())
        }
    }

    // MARK: - States

    @Test func unconfiguredKeyStaysIdle() async {
        let loader = Loader([.success(snapshot())])
        let service = UsageQuotaService(apiKeyProvider: { nil }, load: loader.load)

        await service.refresh()

        #expect(service.state == .idle)
        #expect(loader.callCount == 0)
    }

    @Test func loadsSnapshotAndCachesWithinTTL() async {
        let loader = Loader([.success(snapshot())])
        let service = UsageQuotaService(apiKeyProvider: { "key" }, load: loader.load)

        await service.refresh()
        guard case .loaded(let loaded) = service.state else {
            Issue.record("expected loaded, got \(service.state)")
            return
        }
        #expect(loaded.planName == "GLM Coding Plan")

        // Fresh cache: no second call.
        await service.refresh()
        #expect(loader.callCount == 1)

        // Forced refresh: second call.
        await service.refresh(force: true)
        #expect(loader.callCount == 2)
    }

    @Test func rejectedKeyReportsMissingGrants() async {
        let loader = Loader([.failure(UsageQuotaService.UsageQuotaError.keyRejected("unauthorized"))])
        let service = UsageQuotaService(apiKeyProvider: { "key" }, load: loader.load)

        await service.refresh()

        #expect(service.state == .keyRejected("unauthorized"))
    }

    @Test func emptyLimitListReportsNoLimits() async {
        let loader = Loader([.failure(UsageQuotaService.UsageQuotaError.noLimitsReported)])
        let service = UsageQuotaService(apiKeyProvider: { "key" }, load: loader.load)

        await service.refresh()

        #expect(service.state == .noLimitsReported)
    }

    @Test func failureWithoutPreviousSnapshotReportsFailed() async {
        struct Boom: Error {}
        let loader = Loader([.failure(Boom())])
        let service = UsageQuotaService(apiKeyProvider: { "key" }, load: loader.load)

        await service.refresh()

        guard case .failed = service.state else {
            Issue.record("expected failed, got \(service.state)")
            return
        }
    }

    @Test func failureKeepsLastLoadedSnapshot() async {
        struct Boom: Error {}
        let windows = [UsageQuotaService.QuotaWindow(
            id: "TOKENS_LIMIT-0",
            title: AppText.quotaWindow5Hour,
            percentage: 40,
            resetAt: nil
        )]
        let loader = Loader([.success(snapshot(windows: windows)), .failure(Boom())])
        let service = UsageQuotaService(apiKeyProvider: { "key" }, load: loader.load)

        await service.refresh()
        await service.refresh(force: true)

        guard case .loaded(let kept) = service.state else {
            Issue.record("expected loaded, got \(service.state)")
            return
        }
        #expect(kept.windows.first?.percentage == 40)
    }
}
