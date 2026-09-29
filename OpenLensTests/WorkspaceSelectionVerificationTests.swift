import Foundation
import Testing
@testable import OpenLens

struct WorkspaceSelectionVerificationTests {
    @MainActor
    @Test(arguments: [false, true])
    func verificationFlagsOnlyFoldersTheServerRefuses(v2: Bool) async throws {
        let active = "/Users/me/OpenLens"
        let listPath = v2 ? "/api/fs/list" : "/file"
        let emptyListing = OpenCodeContractTransport.Fixture(
            statusCode: 200,
            body: Data((v2 ? #"{"location":{"directory":"/Users/me/Scratch"},"data":[]}"# : "[]").utf8)
        )
        let refusal = v2
            ? OpenCodeContractTransport.Fixture(
                statusCode: 403,
                body: Data(#"{"_tag":"ForbiddenError","message":"Folder is not accessible"}"#.utf8)
            )
            : OpenCodeContractTransport.Fixture(statusCode: 404, body: Data())
        let serverFault = OpenCodeContractTransport.Fixture(statusCode: 500, body: Data())

        var routes: [String: OpenCodeContractTransport.Fixture] = [
            "/api/info": .init(statusCode: v2 ? 200 : 404, body: OpenCodeContractFixtures.v2InfoResponse),
            "/global/health": .init(statusCode: 200, body: OpenCodeContractFixtures.v1HealthResponse),
        ]
        let projects = Data(#"[{"id":"openlens","worktree":"/Users/me/OpenLens"},{"id":"api","worktree":"/Users/me/API"}]"#.utf8)
        if v2 {
            routes["/api/location"] = .init(statusCode: 200, body: Data(#"""
            {"directory":"/Users/me/OpenLens","project":{"id":"openlens","directory":"/Users/me/OpenLens"}}
            """#.utf8))
            routes["/api/project"] = .init(statusCode: 200, body: projects)
        } else {
            routes["/path"] = .init(statusCode: 200, body: Data(#"""
            {"home":"/Users/me","state":"/state","config":"/config","worktree":"/Users/me/OpenLens","directory":"/Users/me/OpenLens"}
            """#.utf8))
            routes["/project/current"] = .init(statusCode: 200, body: Data(#"{"id":"openlens","worktree":"/Users/me/OpenLens"}"#.utf8))
            routes["/project"] = .init(statusCode: 200, body: projects)
        }

        let transport = OpenCodeContractTransport(
            routes: routes,
            responder: { request in
                guard let url = request.url, url.path == listPath else { return nil }
                let directory = v2
                    ? URLComponents(url: url, resolvingAgainstBaseURL: false)?
                        .queryItems?.first { $0.name == "location[directory]" }?.value
                    : request.value(forHTTPHeaderField: "x-opencode-directory")
                switch directory {
                case "/Users/me/Scratch": return emptyListing
                case "/Users/me/Gone": return refusal
                case "/Users/me/Flaky": return serverFault
                // No fixture: the request fails like a dropped connection.
                default: return nil
                }
            }
        )
        let client = OpenCodeClient(
            baseURL: try #require(URL(string: "http://opencode.example.com")),
            contextDirectory: active,
            transport: transport
        )
        let capabilities = try await client.probeCapabilities()
        let service = WorkspaceService(connection: ConnectionManager(testClient: client, capabilities: capabilities))

        let remembered = [
            "/Users/me/OpenLens", "/Users/me/API",
            "/Users/me/Scratch", "/Users/me/Gone", "/Users/me/Flaky", "/Users/me/Offline",
        ]
        let snapshot = try await service.loadWorkspaceSelection(verifying: remembered)

        // Only an explicit refusal counts. A server fault or a dropped connection
        // is no evidence against the folder.
        #expect(snapshot.inaccessibleDirectories == ["/Users/me/Gone"])

        // Folders the server reported itself are not asked about again, and asking
        // never switches the active project.
        let requests = await transport.recordedRequests()
        let probed = Set(requests.filter { $0.path == listPath }.compactMap {
            v2 ? $0.queryItems["location[directory]"] : $0.headers["x-opencode-directory"]
        })
        #expect(probed == ["/Users/me/Scratch", "/Users/me/Gone", "/Users/me/Flaky", "/Users/me/Offline"])
        #expect(await client.currentContextDirectory() == active)

        let result = WorkspaceSelectionBuilder.makeOptions(
            snapshot: snapshot,
            recentDirectories: remembered,
            preferredDirectory: "/Users/me/Scratch"
        )
        let selected = result.options.first { $0.id == result.defaultOptionID }
        #expect(selected?.directory == "/Users/me/Scratch")
        #expect(result.options.filter { !$0.canCreateSession }.compactMap(\.directory) == ["/Users/me/Gone"])
        #expect(result.unavailablePreferredDirectory == nil)
    }

    @Test func onlyClientErrorsAboutTheFolderCountAsRefusals() throws {
        let payload = try JSONDecoder().decode(
            OpenCodeAPIErrorPayload.self,
            from: Data(#"{"_tag":"ForbiddenError","message":"Folder is not accessible"}"#.utf8)
        )

        #expect(WorkspaceService.isFolderRefusal(OpenCodeError.httpError(statusCode: 404)))
        #expect(WorkspaceService.isFolderRefusal(OpenCodeError.apiError(statusCode: 403, payload: payload)))

        // Credentials, throttling and server faults say nothing about the folder.
        #expect(!WorkspaceService.isFolderRefusal(OpenCodeError.httpError(statusCode: 401)))
        #expect(!WorkspaceService.isFolderRefusal(OpenCodeError.httpError(statusCode: 429)))
        #expect(!WorkspaceService.isFolderRefusal(OpenCodeError.httpError(statusCode: 500)))
        #expect(!WorkspaceService.isFolderRefusal(OpenCodeError.notConnected))
        #expect(!WorkspaceService.isFolderRefusal(URLError(.notConnectedToInternet)))
    }
}
