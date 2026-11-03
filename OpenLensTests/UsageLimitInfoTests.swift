import Foundation
import Testing
@testable import OpenLens

struct UsageLimitInfoTests {

    @Test func detectsGLMCodingPlanLimitWithResetTime() throws {
        let info = UsageLimitInfo.detect(
            message: "Usage limit reached for 5 hour. Your limit will reset at 2026-11-04 03:21:58"
        )

        #expect(info != nil)
        let resetAt = try #require(info?.resetAt)
        // Timezone-less timestamps are interpreted as UTC.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        #expect(calendar.component(.year, from: resetAt) == 2026)
        #expect(calendar.component(.month, from: resetAt) == 11)
        #expect(calendar.component(.day, from: resetAt) == 4)
        #expect(calendar.component(.hour, from: resetAt) == 3)
        #expect(calendar.component(.minute, from: resetAt) == 21)
    }

    @Test func detectsSpokenResetTimeVariant() throws {
        let info = UsageLimitInfo.detect(
            message: "You've hit your usage limit. Your limit will reset on Feb 25, 2026 12:31 PM"
        )

        let resetAt = try #require(info?.resetAt)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        #expect(calendar.component(.month, from: resetAt) == 2)
        #expect(calendar.component(.day, from: resetAt) == 25)
        #expect(calendar.component(.hour, from: resetAt) == 12)
        #expect(calendar.component(.minute, from: resetAt) == 31)
    }

    @Test func detectsRateLimitByStatusAlone() {
        let info = UsageLimitInfo.detect(message: "Something went wrong", status: 429)

        #expect(info != nil)
        #expect(info?.resetAt == nil)
    }

    @Test func quotaKeywordTriggersDetectionWithoutResetTime() {
        let info = UsageLimitInfo.detect(message: "Quota exceeded for this plan")

        #expect(info != nil)
        #expect(info?.resetAt == nil)
    }

    @Test func unrelatedErrorsAreNotUsageLimits() {
        #expect(UsageLimitInfo.detect(message: "Connection reset by peer") == nil)
        #expect(UsageLimitInfo.detect(message: "Tool execution failed") == nil)
        #expect(UsageLimitInfo.detect(message: "") == nil)
    }

    @Test func parseResetDateHandlesBothFormats() throws {
        let fixed = UsageLimitInfo.parseResetDate(from: "resets at 2026-12-31 23:59:59")
        #expect(fixed != nil)

        let spoken = UsageLimitInfo.parseResetDate(from: "resets on Dec 1, 2026 8:05 AM")
        #expect(spoken != nil)

        #expect(UsageLimitInfo.parseResetDate(from: "no date here") == nil)
    }
}
