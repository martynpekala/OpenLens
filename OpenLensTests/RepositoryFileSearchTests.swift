import Foundation
import Testing
@testable import OpenLens

/// The attachment picker searches file paths in the session's folder and the
/// composer tells a failed skill catalog apart from an empty one.
@MainActor
struct RepositoryFileSearchTests {
    private static let sessionDirectory = "/Users/me/Projects/Weather & Maps"

    @Test func searchUsesTheSessionFolderAndKeepsTheServerRanking() async throws {
        let transport = OpenCodeContractTransport(routes: [
            "/api/info": .init(statusCode: 200, body: OpenCodeContractFixtures.v2InfoResponse),
            "/api/fs/find": .init(statusCode: 200, body: Data(#"""
            {"location":{"directory":"/Users/me/Projects/Weather & Maps"},"data":[
              {"path":"Sources/Forecast/ForecastView.swift","type":"file"},
              {"path":"Sources/Forecast","type":"directory"},
              {"path":"Tests/ForecastTests.swift","type":"file"},
              {"path":".build/Forecast.o","type":"file"}
            ]}
            """#.utf8)),
        ])
        let service = try await makeService(transport, contextDirectory: "/Users/me/Projects/Other")

        let results = try await service.searchRepositoryFiles(matching: "  forecast ", in: Self.sessionDirectory)

        #expect(results.map(\.path) == ["Sources/Forecast/ForecastView.swift", "Tests/ForecastTests.swift"])
        #expect(results.map(\.name) == ["ForecastView.swift", "ForecastTests.swift"])
        #expect(results.allSatisfy { !$0.isDirectory })
        let request = try #require(await transport.recordedRequests().last)
        #expect(request.path == "/api/fs/find")
        #expect(request.queryItems["location[directory]"] == Self.sessionDirectory)
        #expect(request.queryItems["query"] == "forecast")
        #expect(request.queryItems["type"] == "file")
    }

    @Test func noMatchesIsAnEmptySuccessAndABlankQueryNeverCallsTheServer() async throws {
        let transport = OpenCodeContractTransport(routes: [
            "/api/info": .init(statusCode: 200, body: OpenCodeContractFixtures.v2InfoResponse),
            "/api/fs/find": .init(statusCode: 200, body: Data(#"{"location":{"directory":"/x"},"data":[]}"#.utf8)),
        ])
        let service = try await makeService(transport)

        #expect(try await service.searchRepositoryFiles(matching: "   ", in: Self.sessionDirectory).isEmpty)
        #expect(await transport.recordedPaths() == ["/api/info"])
        #expect(try await service.searchRepositoryFiles(matching: "nothing", in: Self.sessionDirectory).isEmpty)
    }

    @Test func aFailedSearchIsAnErrorNotAnEmptyResult() async throws {
        let transport = OpenCodeContractTransport(routes: [
            "/api/info": .init(statusCode: 200, body: OpenCodeContractFixtures.v2InfoResponse),
            "/api/fs/find": .init(statusCode: 404, body: Data(#"{"message":"Location not found"}"#.utf8)),
        ])
        let service = try await makeService(transport)

        await #expect(throws: (any Error).self) {
            try await service.searchRepositoryFiles(matching: "readme", in: Self.sessionDirectory)
        }
    }

    @Test func v1ServersReportSearchAsUnsupportedWithoutARequest() async throws {
        let transport = OpenCodeContractTransport(routes: [
            "/api/info": .init(statusCode: 404, body: Data(#"{"message":"not found"}"#.utf8)),
            "/global/health": .init(statusCode: 200, body: OpenCodeContractFixtures.v1HealthResponse),
        ])
        let service = try await makeService(transport)

        await #expect(throws: RepositorySearchError.unsupported) {
            try await service.searchRepositoryFiles(matching: "readme", in: Self.sessionDirectory)
        }
        #expect(await transport.recordedPaths() == ["/api/info", "/global/health"])
    }

    @Test func skillCatalogSeparatesEmptyFailedAndUnsupported() async throws {
        let empty = try await makeService(OpenCodeContractTransport(routes: [
            "/api/info": .init(statusCode: 200, body: OpenCodeContractFixtures.v2InfoResponse),
            "/api/skill": .init(statusCode: 200, body: Data(#"{"location":{"directory":"/x"},"data":[]}"#.utf8)),
        ]))
        #expect(await empty.loadSkillCatalog() == .loaded([]))

        let loaded = try await makeService(OpenCodeContractTransport(routes: [
            "/api/info": .init(statusCode: 200, body: OpenCodeContractFixtures.v2InfoResponse),
            "/api/skill": .init(statusCode: 200, body: Data(#"{"location":{"directory":"/x"},"data":[{"id":"swift-testing","name":" Swift Testing ","description":"Write tests"}]}"#.utf8)),
        ]))
        #expect(await loaded.loadSkillCatalog() == .loaded([
            WorkspaceSkillItem(id: "swift-testing", name: "Swift Testing", description: "Write tests"),
        ]))

        let failing = try await makeService(OpenCodeContractTransport(routes: [
            "/api/info": .init(statusCode: 200, body: OpenCodeContractFixtures.v2InfoResponse),
            "/api/skill": .init(statusCode: 500, body: Data(#"{"message":"boom"}"#.utf8)),
        ]))
        guard case .failed(let message) = await failing.loadSkillCatalog() else {
            Issue.record("A failed catalog request must not look like an empty catalog")
            return
        }
        #expect(!message.isEmpty)

        let legacy = try await makeService(OpenCodeContractTransport(routes: [
            "/api/info": .init(statusCode: 404, body: Data(#"{"message":"not found"}"#.utf8)),
            "/global/health": .init(statusCode: 200, body: OpenCodeContractFixtures.v1HealthResponse),
        ]))
        #expect(await legacy.loadSkillCatalog() == .unsupported)
    }

    private func makeService(
        _ transport: OpenCodeContractTransport,
        contextDirectory: String = "/"
    ) async throws -> WorkspaceService {
        let client = OpenCodeClient(
            baseURL: try #require(URL(string: "http://opencode.example.com")),
            contextDirectory: contextDirectory,
            transport: transport
        )
        let connection = ConnectionManager(testClient: client, capabilities: try await client.probeCapabilities())
        return WorkspaceService(connection: connection)
    }
}
