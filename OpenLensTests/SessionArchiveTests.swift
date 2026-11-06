import Foundation
import Testing
@testable import OpenLens

@MainActor
struct SessionArchiveTests {
    // MARK: - Model

    @Test func archivedStateDecodesFromTheServerTimestamp() throws {
        let archived = try decodeSession(#"{"id":"ses_1","title":"Done","time":{"created":1000,"updated":2000,"archived":2500}}"#)
        #expect(archived.isArchived)

        let active = try decodeSession(#"{"id":"ses_1","title":"Active","time":{"created":1000,"updated":2000}}"#)
        #expect(!active.isArchived)
        #expect(archived != active)
    }

    @Test func viewedMarkerMergesKeepTheArchiveTimestamp() {
        let session = OCSession(
            id: "ses_1",
            title: "Done",
            time: .init(created: 1000, updated: 2000, idle: 1900, viewed: 100, archived: 2500)
        )

        let merged = session.withViewedMarker(2000)
        #expect(merged.isArchived)
        #expect(merged.time.archived == 2500)
        #expect(merged.time.viewed == 2000)
    }

    @Test func rootSessionsExcludeArchivedEntries() {
        let active = listedSession("ses_active")
        let archived = OCSession(
            id: "ses_archived",
            title: "Filed away",
            time: .init(created: 1000, updated: 3000, archived: 3500)
        )
        let child = OCSession(
            id: "ses_child",
            parentID: "ses_active",
            title: "Child",
            time: .init(created: 1000, updated: 1500)
        )

        #expect(SessionsService.rootSessions(in: [active, archived, child]) == [active])
    }

    // MARK: - Client contract

    @Test func v2ArchiveUsesTheSessionPatchRoute() async throws {
        let transport = SessionArchiveTransport(responses: [
            .init(statusCode: 200, body: OpenCodeContractFixtures.v2InfoResponse),
            .init(statusCode: 204, body: Data()),
        ])
        let client = OpenCodeClient(
            baseURL: try #require(URL(string: "https://opencode.example.com")),
            contextDirectory: "/workspace/OpenLens",
            transport: transport
        )
        _ = try await client.probeCapabilities()

        try await client.setSessionArchived(id: "ses_1", archived: true)

        let requests = transport.recordedRequests()
        #expect(requests.map(\.path) == ["/api/info", "/api/session/ses_1"])
        #expect(requests[1].method == "PATCH")
        #expect(requests[1].queryItems["location[directory]"] == nil)
        #expect(try bodyObject(requests[1])["archived"] as? Bool == true)
    }

    @Test func legacyConnectionsCannotArchiveSessions() async throws {
        let transport = SessionArchiveTransport(responses: [])
        let client = OpenCodeClient(
            baseURL: try #require(URL(string: "https://opencode.example.com")),
            transport: transport
        )

        await #expect(throws: OpenCodeError.self) {
            try await client.setSessionArchived(id: "ses_1", archived: true)
        }
        #expect(transport.recordedRequests().isEmpty)
    }

    // MARK: - Service

    @Test func archivingRequiresTheServerToConfirmTheArchiveState() async throws {
        let transport = SessionArchiveTransport(responses: [
            .init(statusCode: 200, body: OpenCodeContractFixtures.v2InfoResponse),
            .init(statusCode: 204, body: Data()),
            .init(statusCode: 200, body: sessionEnvelope(id: "ses_1", archived: 2500)),
        ])
        let service = try await makeService(transport)

        try await service.archiveSession(listedSession("ses_1"))

        let requests = transport.recordedRequests()
        #expect(requests.map(\.path) == ["/api/info", "/api/session/ses_1", "/api/session/ses_1"])
        #expect(requests[1].method == "PATCH")
        #expect(requests[2].method == "GET")
        #expect(service.archiveMutationCount == 1)
    }

    @Test func silentlyIgnoredArchiveMutationsFailInsteadOfHidingTheRow() async throws {
        let transport = SessionArchiveTransport(responses: [
            .init(statusCode: 200, body: OpenCodeContractFixtures.v2InfoResponse),
            .init(statusCode: 204, body: Data()),
            .init(statusCode: 200, body: sessionEnvelope(id: "ses_1", archived: nil)),
        ])
        let service = try await makeService(transport)

        await #expect(throws: OpenCodeError.self) {
            try await service.archiveSession(listedSession("ses_1"))
        }
        #expect(service.archiveMutationCount == 0)
    }

    @Test func archivedSessionsAreHiddenFromTheActiveList() async throws {
        let transport = SessionArchiveTransport(responses: [
            .init(statusCode: 200, body: OpenCodeContractFixtures.v2InfoResponse),
            .init(statusCode: 200, body: listPage(
                activeID: "ses_active",
                activeUpdated: 3000,
                archivedID: "ses_archived",
                archivedUpdated: 4000
            )),
        ])
        let service = try await makeService(transport)

        let sessions = try await service.listSessions()

        #expect(sessions.map(\.id) == ["ses_active"])
    }

    // MARK: - Unarchive

    @Test func unarchivingRequiresTheServerToConfirmTheRestoredState() async throws {
        let transport = SessionArchiveTransport(responses: [
            .init(statusCode: 200, body: OpenCodeContractFixtures.v2InfoResponse),
            .init(statusCode: 204, body: Data()),
            .init(statusCode: 200, body: sessionEnvelope(id: "ses_1", archived: nil)),
        ])
        let service = try await makeService(transport)

        let restored = try await service.unarchiveSession(archivedSession("ses_1"))

        #expect(!restored.isArchived)
        let requests = transport.recordedRequests()
        #expect(requests.map(\.path) == ["/api/info", "/api/session/ses_1", "/api/session/ses_1"])
        #expect(requests[1].method == "PATCH")
        #expect(try bodyObject(requests[1])["archived"] as? Bool == false)
        #expect(requests[2].method == "GET")
    }

    @Test func unarchivingFailsWhenTheServerKeepsTheArchivedState() async throws {
        let transport = SessionArchiveTransport(responses: [
            .init(statusCode: 200, body: OpenCodeContractFixtures.v2InfoResponse),
            .init(statusCode: 204, body: Data()),
            .init(statusCode: 200, body: sessionEnvelope(id: "ses_1", archived: 2500)),
        ])
        let service = try await makeService(transport)

        await #expect(throws: OpenCodeError.self) {
            _ = try await service.unarchiveSession(archivedSession("ses_1"))
        }
    }

    // MARK: - Archived catalog

    @Test func theArchivedCatalogQueriesTheArchiveFilter() async throws {
        let transport = SessionArchiveTransport(responses: [
            .init(statusCode: 200, body: OpenCodeContractFixtures.v2InfoResponse),
            .init(statusCode: 200, body: archivedListPage(id: "ses_archived")),
        ])
        let service = try await makeService(transport)

        let archived = try await service.listArchivedSessions()

        #expect(archived.map(\.id) == ["ses_archived"])
        let requests = transport.recordedRequests()
        #expect(requests[1].method == "GET")
        #expect(requests[1].queryItems["archived"] == "true")
        #expect(requests[1].queryItems["order"] == "desc")
    }

    @Test func theArchivedCatalogConfirmsRowsAgainstTheCanonicalState() async throws {
        // Older v2 servers ignore the archived filter and return every
        // session; only rows the server marks archived reach the list.
        let transport = SessionArchiveTransport(responses: [
            .init(statusCode: 200, body: OpenCodeContractFixtures.v2InfoResponse),
            .init(statusCode: 200, body: listPage(
                activeID: "ses_active",
                activeUpdated: 3000,
                archivedID: "ses_archived",
                archivedUpdated: 4000
            )),
        ])
        let service = try await makeService(transport)

        let archived = try await service.listArchivedSessions()

        #expect(archived.map(\.id) == ["ses_archived"])
        #expect(archived.first?.isArchived == true)
    }

    @Test func legacyClientsSkipTheArchivedCatalogQuery() async throws {
        let transport = SessionArchiveTransport(responses: [])
        let client = OpenCodeClient(
            baseURL: try #require(URL(string: "https://opencode.example.com")),
            transport: transport
        )

        let archived = try await client.listArchivedSessions()

        #expect(archived.isEmpty)
        #expect(transport.recordedRequests().isEmpty)
    }

    // MARK: - Helpers

    private func decodeSession(_ json: String) throws -> OCSession {
        try JSONDecoder().decode(OCSession.self, from: Data(json.utf8))
    }

    private func listedSession(_ id: String) -> OCSession {
        OCSession(id: id, directory: "/workspace", title: "Listed \(id)", time: .init(created: 1000, updated: 2000))
    }

    private func archivedSession(_ id: String) -> OCSession {
        OCSession(
            id: id,
            directory: "/workspace",
            title: "Filed \(id)",
            time: .init(created: 1000, updated: 2000, archived: 2500)
        )
    }

    private func makeService(_ transport: SessionArchiveTransport) async throws -> SessionsService {
        let client = OpenCodeClient(
            baseURL: try #require(URL(string: "https://opencode.example.com")),
            transport: transport
        )
        let connection = ConnectionManager(testClient: client, capabilities: try await client.probeCapabilities())
        return SessionsService(connection: connection)
    }

    private func bodyObject(_ request: SessionArchiveTransport.RecordedRequest) throws -> [String: Any] {
        let data = try #require(request.body)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func sessionEnvelope(id: String, archived: Double?) -> Data {
        let archivedJSON = archived.map { ",\"archived\":\($0)" } ?? ""
        return Data(#"{"data":{"id":"\#(id)","title":"Filed","time":{"created":1000,"updated":2000\#(archivedJSON)}}}"#.utf8)
    }

    private func listPage(activeID: String, activeUpdated: Double, archivedID: String, archivedUpdated: Double) -> Data {
        Data(#"""
        {"data":[
            {"id":"\#(archivedID)","directory":"/workspace","title":"Filed away","time":{"created":900,"updated":\#(archivedUpdated),"archived":4500}},
            {"id":"\#(activeID)","directory":"/workspace","title":"Still active","time":{"created":900,"updated":\#(activeUpdated)}}
        ],"cursor":{"previous":null,"next":null}}
        """#.utf8)
    }

    private func archivedListPage(id: String) -> Data {
        Data(#"""
        {"data":[
            {"id":"\#(id)","directory":"/workspace","title":"Filed away","time":{"created":900,"updated":4000,"archived":4500}}
        ],"cursor":{"previous":null,"next":null}}
        """#.utf8)
    }
}

nonisolated private final class SessionArchiveTransport: OpenCodeTransport, @unchecked Sendable {
    struct Response: Sendable {
        let statusCode: Int
        let body: Data
    }

    struct RecordedRequest: Sendable {
        let method: String
        let path: String
        let queryItems: [String: String]
        let body: Data?
    }

    private let lock = NSLock()
    private var responses: [Response]
    private var requests: [RecordedRequest] = []

    init(responses: [Response]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = try #require(request.url)
        let queryItems = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .reduce(into: [String: String]()) { result, item in
                if let value = item.value {
                    result[item.name] = value
                }
            }
        let response: Response
        lock.lock()
        requests.append(
            .init(
                method: request.httpMethod ?? "GET",
                path: url.path,
                queryItems: queryItems,
                body: request.httpBody
            )
        )
        guard !responses.isEmpty else {
            lock.unlock()
            throw MissingSessionArchiveResponse()
        }
        response = responses.removeFirst()
        lock.unlock()

        return (
            response.body,
            HTTPURLResponse(url: url, statusCode: response.statusCode, httpVersion: nil, headerFields: nil)!
        )
    }

    func makeEventStream(
        request: URLRequest,
        deliveryQueue: DispatchQueue,
        callbacks: OpenCodeEventStreamCallbacks
    ) -> any OpenCodeEventStream {
        UnusedSessionArchiveEventStream()
    }

    func recordedRequests() -> [RecordedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
}

nonisolated private struct MissingSessionArchiveResponse: Error {}

nonisolated private final class UnusedSessionArchiveEventStream: OpenCodeEventStream, @unchecked Sendable {
    func start() {}
    func suspend() {}
    func resume() {}
    func cancel() {}
}
