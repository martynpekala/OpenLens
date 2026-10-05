import Foundation
import Testing
@testable import OpenLens

@MainActor
struct GitHubStarsServiceTests {

    private final class Loader {
        var results: [Result<Int, Error>]
        private(set) var callCount = 0

        init(_ results: [Result<Int, Error>]) {
            self.results = results
        }

        func load() async throws -> Int {
            callCount += 1
            return try results.removeFirst().get()
        }
    }

    private final class Clock {
        var date = Date(timeIntervalSince1970: 1_000)
    }

    @Test func decodesStarCountFromRepositoryPayload() throws {
        let data = Data(#"{"id":1,"name":"OpenLens","stargazers_count":412,"forks_count":3}"#.utf8)

        #expect(try GitHubStarsService.decodeStarCount(from: data) == 412)
    }

    @Test func decodingFailsWithoutStarCount() {
        let data = Data(#"{"message":"Not Found"}"#.utf8)

        #expect(throws: DecodingError.self) {
            try GitHubStarsService.decodeStarCount(from: data)
        }
    }

    @Test func progressIsFractionOfGoalAndClamped() async {
        let service = GitHubStarsService(goal: 1000) { 250 }
        #expect(service.progress == 0)

        await service.refresh()
        #expect(service.starCount == 250)
        #expect(service.progress == 0.25)

        let overGoal = GitHubStarsService(goal: 1000) { 1500 }
        await overGoal.refresh()
        #expect(overGoal.progress == 1)
    }

    @Test func failedLoadWithoutPreviousValueReportsFailure() async {
        struct Boom: Error {}
        let service = GitHubStarsService { throw Boom() }

        await service.refresh()

        #expect(service.state == .failed)
        #expect(service.starCount == nil)
        #expect(service.progress == 0)
    }

    @Test func failedRefreshKeepsLastKnownCount() async {
        struct Boom: Error {}
        let clock = Clock()
        let loader = Loader([.success(120), .failure(Boom())])
        let service = GitHubStarsService(cacheDuration: 60, now: { clock.date }, loadStarCount: loader.load)

        await service.refresh()
        clock.date.addTimeInterval(120)
        await service.refresh()

        #expect(loader.callCount == 2)
        #expect(service.state == .loaded(120))
    }

    @Test func freshValueIsNotReloadedUntilCacheExpires() async {
        let clock = Clock()
        let loader = Loader([.success(10), .success(11)])
        let service = GitHubStarsService(cacheDuration: 60, now: { clock.date }, loadStarCount: loader.load)

        await service.refresh()
        clock.date.addTimeInterval(30)
        await service.refresh()
        #expect(loader.callCount == 1)
        #expect(service.starCount == 10)

        clock.date.addTimeInterval(60)
        await service.refresh()
        #expect(loader.callCount == 2)
        #expect(service.starCount == 11)
    }

    @Test func cancelledLoadDoesNotReportFailure() async {
        let service = GitHubStarsService { throw URLError(.cancelled) }

        await service.refresh()

        #expect(service.state == .idle)
    }
}
