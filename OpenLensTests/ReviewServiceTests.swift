import Foundation
import Testing
@testable import OpenLens

@MainActor
struct ReviewServiceTests {
    private static let rangeKey = "/api/session/ses_1/diff?from=msg_1&to=msg_3"

    @Test func wholeSessionSpansEveryUpdateEvenWhenTheNewestOneChangedNothing() async throws {
        let (service, transport) = try await makeService(routes: [
            Self.rangeKey: .ok(#"{"data":[{"file":"A.swift","additions":5,"deletions":2},{"file":"B.swift","additions":3,"deletions":0}]}"#),
            "/api/session/ses_1/diff?from=msg_3": .ok(#"{"data":[]}"#),
            "/api/session/ses_1/diff?from=msg_2": .ok(#"{"data":[{"file":"B.swift","additions":3,"deletions":0}]}"#),
            "/api/session/ses_1/diff?from=msg_1": .ok(#"{"data":[{"file":"A.swift","additions":5,"deletions":2}]}"#),
        ])

        let snapshot = try await service.loadReview(sessionID: "ses_1")

        #expect(snapshot.workingTree.map(\.path) == ["A.swift", "B.swift"])
        #expect(snapshot.workingTree.map(\.additions) == [5, 3])
        // The update picker only lists turns that changed files.
        #expect(snapshot.changeSets.map(\.title) == ["Second", "First"])
        #expect(transport.recordedKeys().contains(Self.rangeKey))
    }

    @Test func wholeSessionFallsBackToTheNewestVersionOfEachUpdatedFileWhenTheRangeIsRejected() async throws {
        let (service, _) = try await makeService(routes: [
            Self.rangeKey: .status(400, #"{"_tag":"SessionDiffRangeError","message":"Range spans a location change"}"#),
            "/api/session/ses_1/diff?from=msg_3": .ok(#"{"data":[]}"#),
            "/api/session/ses_1/diff?from=msg_2": .ok(#"{"data":[{"file":"A.swift","additions":1,"deletions":1},{"file":"B.swift","additions":3,"deletions":0}]}"#),
            "/api/session/ses_1/diff?from=msg_1": .ok(#"{"data":[{"file":"A.swift","additions":5,"deletions":2}]}"#),
        ])

        let snapshot = try await service.loadReview(sessionID: "ses_1")

        #expect(snapshot.workingTree.map(\.path) == ["A.swift", "B.swift"])
        #expect(snapshot.workingTree.map(\.additions) == [1, 3])
    }

    @Test func serverFailuresOtherThanARejectedRangeStillFailTheReview() async throws {
        let (service, _) = try await makeService(routes: [
            Self.rangeKey: .status(500, #"{"_tag":"InternalError"}"#),
            "/api/session/ses_1/diff?from=msg_3": .ok(#"{"data":[]}"#),
            "/api/session/ses_1/diff?from=msg_2": .ok(#"{"data":[]}"#),
            "/api/session/ses_1/diff?from=msg_1": .ok(#"{"data":[]}"#),
        ])

        await #expect(throws: OpenCodeError.self) {
            try await service.loadReview(sessionID: "ses_1")
        }
    }

    @Test func sessionWithoutUserMessagesLoadsNoDiffs() async throws {
        let (service, transport) = try await makeService(routes: [:], messages: [])

        let snapshot = try await service.loadReview(sessionID: "ses_1")

        #expect(snapshot.workingTree.isEmpty)
        #expect(snapshot.changeSets.isEmpty)
        #expect(!transport.recordedKeys().contains { $0.hasPrefix("/api/session/ses_1/diff") })
    }

    private func makeService(
        routes: [String: ReviewTransport.Route],
        messages: [String] = ["First", "Second", "Third"]
    ) async throws -> (ReviewService, ReviewTransport) {
        let messageData = messages.enumerated().map { index, title in
            #"{"id":"msg_\#(index + 1)","type":"user","time":{"created":\#((index + 1) * 1000)},"text":"\#(title)"}"#
        }.joined(separator: ",")

        var allRoutes = routes
        allRoutes["/api/info"] = .init(statusCode: 200, body: OpenCodeContractFixtures.v2InfoResponse)
        allRoutes["/api/session/ses_1/message"] = .ok(#"{"data":[\#(messageData)],"cursor":{"next":null}}"#)

        let transport = ReviewTransport(routes: allRoutes)
        let client = OpenCodeClient(
            baseURL: try #require(URL(string: "https://opencode.example.com")),
            transport: transport
        )
        let capabilities = try await client.probeCapabilities()
        let connection = ConnectionManager(testClient: client, capabilities: capabilities)
        return (ReviewService(connection: connection), transport)
    }
}

/// Answers by route: the request path, plus the `from`/`to` query items that
/// scope a session diff. Anything unlisted is a 404.
nonisolated private final class ReviewTransport: OpenCodeTransport, @unchecked Sendable {
    struct Route: Sendable {
        let statusCode: Int
        let body: Data

        static func ok(_ json: String) -> Route {
            Route(statusCode: 200, body: Data(json.utf8))
        }

        static func status(_ statusCode: Int, _ json: String) -> Route {
            Route(statusCode: statusCode, body: Data(json.utf8))
        }
    }

    private let lock = NSLock()
    private let routes: [String: Route]
    private var keys: [String] = []

    init(routes: [String: Route]) {
        self.routes = routes
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = try #require(request.url)
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let scope = ["from", "to"].compactMap { name in
            queryItems.first { $0.name == name }?.value.map { "\(name)=\($0)" }
        }
        let key = scope.isEmpty ? url.path : "\(url.path)?\(scope.joined(separator: "&"))"

        lock.lock()
        keys.append(key)
        lock.unlock()

        let route = routes[key] ?? .status(404, #"{"error":"RouteNotFound"}"#)
        return (
            route.body,
            HTTPURLResponse(url: url, statusCode: route.statusCode, httpVersion: nil, headerFields: nil)!
        )
    }

    func makeEventStream(
        request: URLRequest,
        deliveryQueue: DispatchQueue,
        callbacks: OpenCodeEventStreamCallbacks
    ) -> any OpenCodeEventStream {
        UnusedReviewEventStream()
    }

    func recordedKeys() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return keys
    }
}

nonisolated private final class UnusedReviewEventStream: OpenCodeEventStream, @unchecked Sendable {
    func start() {}
    func suspend() {}
    func resume() {}
    func cancel() {}
}
