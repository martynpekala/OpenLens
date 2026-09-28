import Foundation
import Testing
@testable import OpenLens

struct WorkspaceFolderBrowserTests {
    @Test func folderListingResolvesBothProtocolsAndIncludesIgnoredFolders() {
        let entries = [
            OCWorkspaceFileEntry(name: "API", path: "API", absolute: nil, type: "directory", ignored: false),
            OCWorkspaceFileEntry(name: "Web", path: "Web", absolute: "/Users/me/Projects/Web", type: "directory", ignored: false),
            OCWorkspaceFileEntry(name: "Cache", path: "/Users/me/Projects/Cache", absolute: nil, type: "directory", ignored: true),
            OCWorkspaceFileEntry(name: "API", path: "API/", absolute: nil, type: "directory", ignored: false),
            OCWorkspaceFileEntry(name: ".", path: ".", absolute: nil, type: "directory", ignored: false),
            OCWorkspaceFileEntry(name: "README.md", path: "README.md", absolute: nil, type: "file", ignored: false),
        ]

        let folders = WorkspaceService.folderItems(from: entries, directory: "/Users/me/Projects")

        #expect(folders.map(\.name) == ["API", "Cache", "Web"])
        #expect(folders.map(\.path) == [
            "/Users/me/Projects/API", "/Users/me/Projects/Cache", "/Users/me/Projects/Web",
        ])
        #expect(folders.allSatisfy { $0.kind == .directory && $0.absolutePath == $0.path })
    }

    @MainActor
    @Test(arguments: [false, true])
    func browsingUsesAnIndependentDirectoryAndCreationUsesTheChosenFolder(v2: Bool) async throws {
        let newDirectory = "/Users/me/Projects/Weather & Maps"
        let listPath = v2 ? "/api/fs/list" : "/file"
        let sessionPath = v2 ? "/api/session" : "/session"
        let sessionJSON = #"{"id":"ses_new","directory":"/Users/me/Projects/Weather & Maps","title":"New project"}"#
        let transport = OpenCodeContractTransport(routes: [
            "/api/info": .init(statusCode: v2 ? 200 : 404, body: OpenCodeContractFixtures.v2InfoResponse),
            "/global/health": .init(statusCode: 200, body: OpenCodeContractFixtures.v1HealthResponse),
            listPath: .init(statusCode: 200, body: Data((v2
                ? #"{"location":{"directory":"/Users/me/Projects/Weather & Maps"},"data":[{"path":"Sources","type":"directory"}]}"#
                : #"[{"name":"Sources","path":"Sources","absolute":"/Users/me/Projects/Weather & Maps/Sources","type":"directory"}]"#).utf8)),
            sessionPath: .init(statusCode: 200, body: Data((v2 ? "{\"data\":\(sessionJSON)}" : sessionJSON).utf8)),
        ])
        let client = OpenCodeClient(
            baseURL: try #require(URL(string: "http://opencode.example.com")),
            contextDirectory: "/",
            transport: transport
        )
        let capabilities = try await client.probeCapabilities()
        let connection = ConnectionManager(testClient: client, capabilities: capabilities)
        let folders = try await WorkspaceService(connection: connection).loadFolders(in: newDirectory)

        #expect(folders.folders.map(\.path) == [newDirectory + "/Sources"])
        #expect(await client.currentContextDirectory() == "/")
        #expect(connection.selectedProjectDirectory == nil)

        let session = try await SessionsService(connection: connection).createSession(
            title: "New project", workspaceDirectory: folders.directory
        )
        #expect(session.directory == newDirectory)
        #expect(connection.selectedProjectDirectory == newDirectory)

        let requests = await transport.recordedRequests()
        let listing = try #require(requests.first { $0.path == listPath })
        #expect(listing.queryItems["path"] == ".")
        if v2 {
            #expect(listing.queryItems["location[directory]"] == newDirectory)
            #expect(listing.headers["x-opencode-directory"] == nil)
        } else {
            #expect(listing.headers["x-opencode-directory"] == newDirectory)
        }
    }

    @MainActor
    @Test func inaccessibleFolderSurfacesAnErrorWithoutChangingContext() async throws {
        let transport = OpenCodeContractTransport(routes: [
            "/api/info": .init(statusCode: 200, body: OpenCodeContractFixtures.v2InfoResponse),
            "/api/fs/list": .init(statusCode: 403, body: Data(#"{"_tag":"ForbiddenError","message":"Folder is not accessible"}"#.utf8)),
        ])
        let client = OpenCodeClient(
            baseURL: try #require(URL(string: "http://opencode.example.com")),
            contextDirectory: "/workspace/Current",
            transport: transport
        )
        let capabilities = try await client.probeCapabilities()
        let service = WorkspaceService(connection: ConnectionManager(testClient: client, capabilities: capabilities))
        await #expect(throws: OpenCodeError.self) {
            try await service.loadFolders(in: "/private")
        }
        #expect(await client.currentContextDirectory() == "/workspace/Current")
    }
}
