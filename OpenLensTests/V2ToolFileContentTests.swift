import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import OpenLens

/// Files returned by v2 tools (`Tool.FileContent`): kept alongside text from
/// history and the event stream, bounded by `ToolResultFileBudget`, and
/// opened only from approved locations.
@MainActor
struct V2ToolFileContentTests {

    // MARK: - History

    @Test func historyToolResultsKeepTheirFilesAlongsideText() throws {
        let step = try #require(try Self.historySteps(Self.recordedHistory).first)

        #expect(step.label.isEmpty == false)
        #expect(step.isError == false)
        #expect(step.files.count == 1)
        let file = try #require(step.files.first)
        #expect(file.title == "shot.png")
        #expect(file.mime == "image/png")
        #expect(file.kind == .image)
        #expect(file.source == .dataURI(Self.pngDataURI))
        #expect(file.isInspectable)
    }

    @Test func aFailedToolKeepsItsPartialOutputAndFiles() throws {
        let steps = try Self.historySteps(Self.recordedHistory)
        let failed = try #require(steps.last)

        #expect(failed.isError)
        #expect(failed.outputPreview == "Browser closed")
        #expect(failed.partialOutputPreview == "Captured before the crash")
        #expect(failed.files.map(\.title) == ["partial.png"])
        #expect(failed.files.first?.source == .dataURI(Self.pngDataURI))
    }

    // MARK: - Stream

    @Test func streamedToolResultsKeepTheirFilesThroughTheEventProjection() throws {
        var adapter = V2EventAdapter()
        let base: [String: Any] = ["sessionID": "ses_1", "assistantMessageID": "msg_1", "id": "call_1"]
        func event(_ type: String, _ extra: [String: Any]) -> [String: Any] {
            ["type": type, "data": base.merging(extra) { $1 }, "location": ["directory": "/work"]]
        }
        _ = try adapter.event(event("session.tool.input.started", ["name": "read"]), directory: "/work")
        _ = try adapter.event(event("session.tool.called", ["input": ["filePath": "/work/shot.png"], "executed": true]), directory: "/work")
        let success = try #require(try adapter.event(event("session.tool.success", [
            "content": [
                ["type": "text", "text": "Image read successfully"],
                ["type": "file", "uri": Self.pngDataURI, "mime": "image/png", "name": "/work/shot.png"],
            ],
            "executed": true,
        ]), directory: "/work"))

        let step = try #require(Self.steps(fromPartEvent: success).first)
        #expect(step.files.map(\.title) == ["shot.png"])
        #expect(step.files.first?.source == .dataURI(Self.pngDataURI))
    }

    @Test func aStreamedFailureKeepsItsPartialOutputAndFiles() throws {
        var adapter = V2EventAdapter()
        let base: [String: Any] = ["sessionID": "ses_1", "assistantMessageID": "msg_1", "id": "call_2"]
        func event(_ type: String, _ extra: [String: Any]) -> [String: Any] {
            ["type": type, "data": base.merging(extra) { $1 }, "location": ["directory": "/work"]]
        }
        _ = try adapter.event(event("session.tool.input.started", ["name": "browser"]), directory: "/work")
        let failed = try #require(try adapter.event(event("session.tool.failed", [
            "error": ["type": "unknown", "message": "Browser closed"],
            "content": [
                ["type": "text", "text": "Captured before the crash"],
                ["type": "file", "uri": Self.pngDataURI, "mime": "image/png", "name": "partial.png"],
            ],
            "executed": true,
        ]), directory: "/work"))

        let step = try #require(Self.steps(fromPartEvent: failed).first)
        #expect(step.isError)
        #expect(step.outputPreview == "Browser closed")
        #expect(step.partialOutputPreview == "Captured before the crash")
        #expect(step.files.map(\.title) == ["partial.png"])
    }

    // MARK: - Limits and unsupported results

    @Test func filesBeyondTheBudgetAreWithheldExplicitly() throws {
        let big = "data:image/png;base64," + String(repeating: "A", count: ToolResultFileBudget.maximumURIBytes)
        let content: [[String: Any]] = [
            ["type": "text", "text": "Many files"],
            ["type": "file", "uri": big, "mime": "image/png", "name": "huge.png"],
        ] + (1...5).map { ["type": "file", "uri": Self.pngDataURI, "mime": "image/png", "name": "small\($0).png"] }
        let state = try JSONDecoder().decode(
            OCToolState.self,
            from: JSONSerialization.data(withJSONObject: ["status": "completed", "content": content])
        )

        #expect(state.output == "Many files")
        #expect(state.files.count == ToolResultFileBudget.maximumFiles)
        #expect(state.omittedFileCount == 2)
        #expect(state.files.first?.uri == nil)
        #expect(state.files.first?.name == "huge.png")
        #expect(state.files.dropFirst().allSatisfy { $0.uri == Self.pngDataURI })

        let shown = ToolResultFile(file: try #require(state.files.first), id: "f")
        #expect(shown.source == .tooLarge)
        #expect(!shown.isInspectable)
        #expect(shown.unavailableReason == AppText.toolFileTooLarge)
    }

    @Test func unsupportedAndInaccessibleFilesStayExplicit() {
        let web = ToolResultFile(file: OCToolFile(uri: "https://example.com/a.png", mime: "image/png", name: "a.png"), id: "1")
        #expect(web.source == .unavailable)
        #expect(web.unavailableReason == AppText.toolFileUnavailable)

        let archive = ToolResultFile(file: OCToolFile(uri: "data:application/zip;base64,UEsDBA==", mime: "application/zip"), id: "2")
        #expect(archive.kind == .unsupported)
        #expect(archive.title == "application/zip")
        #expect(archive.unavailableReason == AppText.toolFileUnsupported("application/zip"))

        let notBase64 = ToolResultFile(file: OCToolFile(uri: "data:text/plain,hello", mime: "text/plain"), id: "3")
        #expect(notBase64.source == .unavailable)

        let serverFile = ToolResultFile(file: OCToolFile(uri: "file:///work/notes.md", mime: "text/markdown"), id: "4")
        #expect(serverFile.source == .serverPath("/work/notes.md"))
        #expect(serverFile.kind == .text)
        #expect(serverFile.isInspectable)
    }

    // MARK: - Opening files

    @Test func inlineFilesOpenAsImagesTextAndPDFs() async throws {
        let workspace = try await Self.workspace(server: OpenCodeContractTransport(routes: Self.v2Routes))

        let image = try await workspace.loadToolResultFile(
            ToolResultFile(file: OCToolFile(uri: Self.pngDataURI, mime: "image/png"), id: "1"), sessionDirectory: "/work"
        )
        guard case let .image(data) = image else { Issue.record("Expected an image"); return }
        #expect(data == Self.png)

        let text = try await workspace.loadToolResultFile(
            ToolResultFile(file: OCToolFile(uri: "data:text/plain;base64,aGVsbG8=", mime: "text/plain"), id: "2"), sessionDirectory: "/work"
        )
        guard case let .text(string) = text else { Issue.record("Expected text"); return }
        #expect(string == "hello")

        let pdf = try await workspace.loadToolResultFile(
            ToolResultFile(file: OCToolFile(uri: "data:application/pdf;base64,JVBERi0=", mime: "application/pdf"), id: "3"), sessionDirectory: "/work"
        )
        guard case .pdf = pdf else { Issue.record("Expected a PDF"); return }

        await #expect(throws: ToolResultFileError.tooLarge) {
            try await workspace.loadToolResultFile(
                ToolResultFile(file: OCToolFile(uri: nil, mime: "image/png"), id: "4"), sessionDirectory: "/work"
            )
        }
    }

    @Test func serverFilesOpenOnlyFromTheSessionFolder() async throws {
        let server = OpenCodeContractTransport(routes: Self.v2Routes.merging([
            "/api/fs/read/notes.md": .init(statusCode: 200, body: Data("# Notes".utf8), headers: ["Content-Type": "text/markdown"]),
        ]) { $1 })
        let workspace = try await Self.workspace(server: server)

        let content = try await workspace.loadToolResultFile(
            ToolResultFile(file: OCToolFile(uri: "file:///work/notes.md", mime: "text/markdown"), id: "1"), sessionDirectory: "/work"
        )
        guard case let .text(text) = content else { Issue.record("Expected text"); return }
        #expect(text == "# Notes")
        let read = try #require(await server.recordedRequests().last)
        #expect(read.queryItems["location[directory]"] == "/work")

        for uri in ["file:///etc/passwd", "file:///work/../etc/passwd", "file:///workspace/x.md"] {
            await #expect(throws: ToolResultFileError.outsideSession) {
                try await workspace.loadToolResultFile(
                    ToolResultFile(file: OCToolFile(uri: uri, mime: "text/plain"), id: uri), sessionDirectory: "/work"
                )
            }
        }
        await #expect(throws: ToolResultFileError.outsideSession) {
            try await workspace.loadToolResultFile(
                ToolResultFile(file: OCToolFile(uri: "file:///work/notes.md", mime: "text/plain"), id: "x"), sessionDirectory: nil
            )
        }
        #expect(await server.recordedPaths().filter { $0.hasPrefix("/api/fs/read") } == ["/api/fs/read/notes.md"])
    }

    // MARK: - Transport

    @Test func aRecordedToolResponseLoadsThroughTheClient() async throws {
        let big = "data:image/png;base64," + String(repeating: "A", count: ToolResultFileBudget.maximumURIBytes)
        let recorded = Self.history(tools: [
            Self.tool(id: "call_1", name: "read", content: [
                ["type": "text", "text": "Image read successfully"],
                ["type": "file", "uri": Self.pngDataURI, "mime": "image/png", "name": "/work/shot.png"],
                ["type": "file", "uri": big, "mime": "image/png", "name": "/work/huge.png"],
                ["type": "file", "uri": "https://example.com/x", "mime": "text/html"],
            ]),
        ])
        let steps = try await Self.loadSteps(transport: OpenCodeContractTransport(routes: Self.v2Routes.merging([
            "/api/session/ses_1/message": .init(statusCode: 200, body: recorded),
        ]) { $1 }))

        let step = try #require(steps.first)
        #expect(step.outputPreview?.contains("Image read successfully") == true)
        #expect(step.files.map(\.title) == ["shot.png", "huge.png", "text/html"])
        #expect(step.files.map(\.source) == [.dataURI(Self.pngDataURI), .tooLarge, .unavailable])
    }

    // MARK: - Fixtures

    private static let png: Data = {
        let context = CGContext(
            data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return output as Data
    }()

    private static var pngDataURI: String { "data:image/png;base64,\(png.base64EncodedString())" }

    private static var recordedHistory: Data {
        history(tools: [
            tool(id: "call_1", name: "read", content: [
                ["type": "text", "text": "Image read successfully"],
                ["type": "file", "uri": pngDataURI, "mime": "image/png", "name": "/work/shot.png"],
            ]),
            tool(id: "call_2", name: "browser", status: "error", content: [
                ["type": "text", "text": "Captured before the crash"],
                ["type": "file", "uri": pngDataURI, "mime": "image/png", "name": "partial.png"],
            ]),
        ])
    }

    private static func tool(id: String, name: String, status: String = "completed", content: [[String: Any]]) -> [String: Any] {
        var state: [String: Any] = ["status": status, "input": [:] as [String: Any], "content": content]
        if status == "error" { state["error"] = ["type": "unknown", "message": "Browser closed"] }
        return ["type": "tool", "id": id, "name": name, "state": state, "time": ["created": 1]]
    }

    private static func history(tools: [[String: Any]]) -> Data {
        let message: [String: Any] = [
            "id": "msg_1", "type": "assistant", "time": ["created": 1], "agent": "build",
            "model": ["id": "test", "providerID": "test"], "content": tools, "finish": "stop",
        ]
        return try! JSONSerialization.data(withJSONObject: ["data": [message], "cursor": ["next": NSNull()]])
    }

    private static let v2Routes: [String: OpenCodeContractTransport.Fixture] = [
        "/api/info": .init(statusCode: 200, body: OpenCodeContractFixtures.v2InfoResponse),
    ]

    private static func historySteps(_ page: Data) throws -> [ChatMessage.PersistedToolStep] {
        let envelope = try JSONSerialization.jsonObject(with: page) as! [String: Any]
        let messages = try JSONDecoder().decode(
            [OCV2SessionMessage].self,
            from: JSONSerialization.data(withJSONObject: envelope["data"]!)
        )
        return messages.compactMap { $0.asMessage(sessionID: "ses_1") }
            .flatMap { MessagesService.convert($0).persistedToolSteps }
    }

    private static func steps(fromPartEvent event: OCEvent) -> [ChatMessage.PersistedToolStep] {
        guard event.type == "message.part.updated",
              let properties = event.properties?.value as? [String: Any],
              let part = properties["part"],
              let message = try? JSONSerialization.data(withJSONObject: [
                  "info": ["id": "msg_1", "sessionID": "ses_1", "role": "assistant", "time": ["created": 1]],
                  "parts": [part],
              ]),
              let decoded = try? JSONDecoder().decode(OCMessageWithParts.self, from: message)
        else { return [] }
        return MessagesService.convert(decoded).persistedToolSteps
    }

    private static func loadSteps(transport: OpenCodeContractTransport) async throws -> [ChatMessage.PersistedToolStep] {
        let client = OpenCodeClient(baseURL: URL(string: "http://opencode.example.com")!, transport: transport)
        let connection = ConnectionManager(testClient: client, capabilities: try await client.probeCapabilities())
        return try await MessagesService(connection: connection).loadMessages(sessionID: "ses_1")
            .flatMap(\.persistedToolSteps)
    }

    private static func workspace(server: OpenCodeContractTransport) async throws -> WorkspaceService {
        let client = OpenCodeClient(baseURL: URL(string: "http://opencode.example.com")!, transport: server)
        let connection = ConnectionManager(testClient: client, capabilities: try await client.probeCapabilities())
        return WorkspaceService(connection: connection)
    }
}
