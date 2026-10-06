import Foundation
import Testing
@testable import OpenLens

/// Text files from the phone and references to files in the session's
/// folder on the server, attached to v2 prompts. Phone content travels as a
/// `data:` URI; a repository reference is a `file:` URI the server reads.
@MainActor
struct V2PromptFileAttachmentTests {

    // MARK: - Model

    @Test func aUTF8TextFileIsSentInlineAsPlainText() throws {
        let file = try PromptTextFileAttachment(data: Data("let x = 1\n".utf8), name: "main.swift")

        #expect(file.promptFile.uri == "data:text/plain;charset=utf-8;base64,\(Data("let x = 1\n".utf8).base64EncodedString())")
        #expect(file.promptFile.name == "main.swift")
        #expect(file.text == "let x = 1\n")
    }

    @Test func filesThatAreNotUTF8TextAreRefused() {
        #expect(throws: PromptAttachmentError.unsupportedTextFile(name: "logo.png")) {
            try PromptTextFileAttachment(data: Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01]), name: "logo.png")
        }
        #expect(throws: PromptAttachmentError.unsupportedTextFile(name: "latin1.txt")) {
            try PromptTextFileAttachment(data: Data([0x63, 0x61, 0x66, 0xE9]), name: "latin1.txt")
        }
    }

    @Test func aRepositoryReferenceIsAFileURIWithItsLineRange() throws {
        let reference = try ServerFileReference(
            path: "/workspace/app/Sources/My File.swift",
            sessionDirectory: "/workspace/app",
            lines: .init(start: 12, end: 20)
        )

        #expect(reference.uri == "file:///workspace/app/Sources/My%20File.swift?start=12&end=20")
        #expect(reference.displayName == "My File.swift:12–20")
        #expect(reference.promptFile.name == "My File.swift:12–20")

        let fromLine = try ServerFileReference(path: "/workspace/app/a.txt", sessionDirectory: "/workspace/app/", lines: .init(start: 5))
        #expect(fromLine.uri == "file:///workspace/app/a.txt?start=5")
        #expect(fromLine.displayName == "a.txt:5–end")

        let whole = try ServerFileReference(path: "/workspace/app/a.txt", sessionDirectory: "/workspace/app")
        #expect(whole.uri == "file:///workspace/app/a.txt")
    }

    @Test func referencesOutsideTheSessionFolderAreRefused() {
        let invalidPaths = [
            "/workspace/other/a.txt",
            "/workspace/application/a.txt",
            "/workspace/app/../secrets.txt",
            "/workspace/app/./a.txt",
            "/workspace/app",
            "workspace/app/a.txt",
            "file:///workspace/app/a.txt",
            "https://example.com/a.txt",
            "/var/mobile/Containers/Data/Application/X/Documents/a.txt",
            "/workspace/app/a\\b.txt",
        ]
        for path in invalidPaths {
            #expect(throws: PromptAttachmentError.fileOutsideSession, "\(path)") {
                try ServerFileReference(path: path, sessionDirectory: "/workspace/app")
            }
        }
    }

    @Test func lineRangesMustStartAtOneAndNotRunBackwards() {
        #expect(throws: PromptAttachmentError.invalidLineRange) { try ServerFileReference.LineRange(start: 0) }
        #expect(throws: PromptAttachmentError.invalidLineRange) { try ServerFileReference.LineRange(start: 20, end: 12) }
        #expect((try? ServerFileReference.LineRange(start: 7, end: 7))?.label == "7")
    }

    // MARK: - Transport

    @Test func phoneTextAndServerReferencesAreAdmittedAsDistinctURIs() async throws {
        let server = FilePromptFakeServer()
        let api = try await Self.makeClient(server: server)
        let text = try PromptTextFileAttachment(data: Data("notes".utf8), name: "notes.md")
        let reference = try ServerFileReference(path: "/workspace/app/README.md", sessionDirectory: "/workspace/app", lines: .init(start: 1, end: 3))

        _ = try await api.sendPromptAsync(
            sessionID: "ses_1", text: "Read these", messageID: "msg_1",
            attachments: [.textFile(text), .serverFile(reference)]
        )

        let files = try #require(await server.promptRequests.first?.json["files"] as? [[String: Any]])
        #expect(files.map { $0["uri"] as? String } == [text.dataURI, "file:///workspace/app/README.md?start=1&end=3"])
        #expect(files.map { $0["name"] as? String } == ["notes.md", "README.md:1–3"])
    }

    @Test func aServerAttachmentErrorIsADefinitiveRejection() async throws {
        let server = FilePromptFakeServer()
        let api = try await Self.makeClient(server: server)
        await server.rejectNextPromptAttachment("Unable to read attachment: file:///workspace/app/gone.txt")

        await #expect(throws: PromptAttachmentError.rejected("Unable to read attachment: file:///workspace/app/gone.txt")) {
            try await api.sendPromptAsync(sessionID: "ses_1", text: "Hi", messageID: "msg_1")
        }
        #expect(!OpenCodeClient.requestMayHaveReachedServer(PromptAttachmentError.rejected("x")))
    }

    @Test func attachmentsRequireOpenCode2() async throws {
        let api = OpenCodeClient(baseURL: URL(string: "https://example.com")!)
        let file = try PromptTextFileAttachment(data: Data("x".utf8), name: "x.txt")

        await #expect(throws: PromptAttachmentError.attachmentsRequireV2) {
            try await api.sendPromptAsync(sessionID: "ses_1", text: "Hi", attachments: [.textFile(file)])
        }
        await #expect(throws: PromptAttachmentError.attachmentsRequireV2) {
            try await api.readFileContent(path: "README.md", directory: "/workspace/app")
        }
    }

    @Test func aServerLineRangeErrorIsADefinitiveRejection() async throws {
        let server = FilePromptFakeServer()
        let chat = try await Self.openChat(server: server)
        await server.rejectNextPromptAttachment("Invalid line range for file:///workspace/app/README.md")

        chat.attachComposerServerFile(relativePath: "README.md", lines: try .init(start: 900, end: 950))
        chat.inputText = "Read"
        chat.send()
        try await Self.waitUntil { chat.promptSubmissions.first?.state == .failed }

        let rejection = try #require(PromptAttachmentError.rejected("Invalid line range for file:///workspace/app/README.md").errorDescription)
        #expect(chat.errorMessage?.hasSuffix(rejection) == true)
        #expect(chat.composerAttachments.count == 1)
        #expect(await server.promptRequests.count == 1)
    }

    // MARK: - Repository browsing

    @Test func repositoryEntriesAreListedAndReadInsideTheSessionFolder() async throws {
        let server = FilePromptFakeServer()
        let api = try await Self.makeClient(server: server)
        let service = WorkspaceService(connection: ConnectionManager(testClient: api, capabilities: try await api.probeCapabilities()))

        let entries = try await service.loadRepositoryEntries(at: "", in: "/workspace/app")
        let text = try await service.readRepositoryFile(at: "Sources/main.swift", in: "/workspace/app")

        #expect(entries.map(\.path) == ["Sources", "README.md"])
        #expect(entries.map(\.isDirectory) == [true, false])
        #expect(text == "print(1)\nprint(2)\n")
        let list = try #require(await server.requests.first { $0.url.path == "/api/fs/list" }?.url)
        let read = try #require(await server.requests.first { $0.url.path.hasPrefix("/api/fs/read") }?.url)
        #expect(Self.query(list, "location[directory]") == "/workspace/app")
        #expect(Self.query(read, "location[directory]") == "/workspace/app")
        #expect(read.path == "/api/fs/read/Sources/main.swift")
    }

    @Test func aBinaryRepositoryFileCannotBeReferencedByLine() async throws {
        let server = FilePromptFakeServer()
        let api = try await Self.makeClient(server: server)
        let service = WorkspaceService(connection: ConnectionManager(testClient: api, capabilities: try await api.probeCapabilities()))

        await #expect(throws: OpenCodeError.self) {
            try await service.readRepositoryFile(at: "logo.png", in: "/workspace/app")
        }
    }

    // MARK: - History

    @Test func attachedFilesStayIntelligibleAfterHistoryReload() throws {
        let json = #"""
        {"id":"msg_1","type":"user","time":{"created":1},"text":"Review",
         "files":[{"data":"bm90ZXM=","mime":"text/plain","source":{"type":"inline"},"name":"notes.md"},
                  {"data":"bGluZQ==","mime":"text/plain","source":{"type":"uri","uri":"file:///workspace/app/a.swift?start=2&end=4"},"name":"a.swift:2–4"}]}
        """#
        let message = try JSONDecoder().decode(OCV2SessionMessage.self, from: Data(json.utf8))

        let chat = MessagesService.convert(try #require(message.asMessage(sessionID: "ses_1")))

        #expect(chat.imageAttachments.isEmpty)
        #expect(chat.fileAttachments.map(\.filename) == ["notes.md", "a.swift:2–4"])
        #expect(chat.fileAttachments.map(\.url) == [
            "data:text/plain;base64,bm90ZXM=",
            "file:///workspace/app/a.swift?start=2&end=4",
        ])
    }

    // MARK: - Chat

    @Test func aTextFileFromFilesIsSubmittedWithThePromptAndShownOnTheRow() async throws {
        let server = FilePromptFakeServer()
        let chat = try await Self.openChat(server: server)

        chat.attachComposerTextFile(data: Data("# Notes".utf8), name: "notes.md")
        chat.inputText = "Summarize"
        chat.send()
        try await Self.waitUntil { await server.promptRequests.count == 1 }

        #expect(chat.composerAttachments.isEmpty)
        let files = try #require(await server.promptRequests.first?.json["files"] as? [[String: Any]])
        #expect(files.first?["uri"] as? String == "data:text/plain;charset=utf-8;base64,\(Data("# Notes".utf8).base64EncodedString())")
        let row = try #require(chat.messages.last { $0.role == .user })
        #expect(row.fileAttachments.map(\.filename) == ["notes.md"])
    }

    @Test func aBinaryFileFromFilesIsRefusedWithAnActionableError() async throws {
        let chat = try await Self.openChat(server: FilePromptFakeServer())

        chat.attachComposerTextFile(data: Data([0xFF, 0x00, 0x10]), name: "archive.zip")

        #expect(chat.composerAttachments.isEmpty)
        #expect(chat.errorMessage == PromptAttachmentError.unsupportedTextFile(name: "archive.zip").errorDescription)
    }

    @Test func pickedFilesThatCannotBeReadOrCannotFitSayWhy() async throws {
        let chat = try await Self.openChat(server: FilePromptFakeServer())
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let huge = folder.appendingPathComponent("huge.log")
        try Data(repeating: UInt8(ascii: "a"), count: OpenCodeClient.maximumPromptBodyBytes + 1).write(to: huge)
        let large = folder.appendingPathComponent("large.log")
        try Data(repeating: UInt8(ascii: "a"), count: 1_800_000).write(to: large)
        let notes = folder.appendingPathComponent("notes.md")
        try Data("# Notes".utf8).write(to: notes)

        chat.attachComposerTextFile(at: folder.appendingPathComponent("missing.txt"))
        #expect(chat.errorMessage == PromptAttachmentError.unreadableFile(name: "missing.txt").errorDescription)
        chat.attachComposerTextFile(at: huge)
        #expect(chat.errorMessage == PromptAttachmentError.textFileTooLarge(name: "huge.log").errorDescription)
        // Fits on disk, but not once encoded into the request.
        chat.attachComposerTextFile(at: large)
        #expect(chat.errorMessage == PromptAttachmentError.textFileTooLarge(name: "large.log").errorDescription)
        #expect(chat.composerAttachments.isEmpty)

        chat.attachComposerTextFile(at: notes)
        #expect(chat.composerAttachments.map(\.promptFile.name) == ["notes.md"])
    }

    @Test func aRepositoryReferenceResolvesInsideTheSessionFolder() async throws {
        let server = FilePromptFakeServer()
        let chat = try await Self.openChat(server: server)

        chat.attachComposerServerFile(relativePath: "Sources/main.swift", lines: try .init(start: 2, end: 2))
        chat.inputText = "Explain line 2"
        chat.send()
        try await Self.waitUntil { await server.promptRequests.count == 1 }

        let files = try #require(await server.promptRequests.first?.json["files"] as? [[String: Any]])
        #expect(files.first?["uri"] as? String == "file:///workspace/app/Sources/main.swift?start=2&end=2")
        let row = try #require(chat.messages.last { $0.role == .user })
        #expect(row.fileAttachments.map(\.filename) == ["main.swift:2"])
        #expect(row.fileAttachments.first?.url?.hasPrefix("file:") == true)
    }

    @Test func aRepositoryReferenceCannotEscapeTheSessionFolder() async throws {
        let chat = try await Self.openChat(server: FilePromptFakeServer())

        chat.attachComposerServerFile(relativePath: "../other/secret.txt")
        #expect(chat.errorMessage == PromptAttachmentError.fileOutsideSession.errorDescription)
        chat.errorMessage = nil
        chat.attachComposerServerFile(relativePath: "/etc/hosts")
        #expect(chat.errorMessage == PromptAttachmentError.fileOutsideSession.errorDescription)
        #expect(chat.composerAttachments.isEmpty)
    }

    @Test func aRejectedAttachmentRestoresTheComposerWithoutDuplicateWork() async throws {
        let server = FilePromptFakeServer()
        let chat = try await Self.openChat(server: server)
        await server.rejectNextPromptAttachment("Unable to read attachment: file:///workspace/app/gone.txt")

        chat.attachComposerServerFile(relativePath: "gone.txt")
        let attachments = chat.composerAttachments
        chat.inputText = "Read"
        chat.send()
        try await Self.waitUntil { chat.promptSubmissions.first?.state == .failed }

        let rejection = try #require(PromptAttachmentError.rejected("Unable to read attachment: file:///workspace/app/gone.txt").errorDescription)
        #expect(chat.errorMessage?.hasSuffix(rejection) == true)
        #expect(chat.inputText == "Read")
        #expect(chat.composerAttachments == attachments)
        // A definitive rejection is never reconciled against the server.
        #expect(await server.requests.allSatisfy { !$0.url.path.hasPrefix("/api/session/ses_1/message/") })
    }

    @Test func anUncertainPromptWithFilesIsRetriedWithIdenticalContent() async throws {
        let server = FilePromptFakeServer()
        let chat = try await Self.openChat(server: server)
        await server.dropNextPrompts(1)

        chat.attachComposerTextFile(data: Data("notes".utf8), name: "notes.md")
        chat.attachComposerServerFile(relativePath: "README.md", lines: try .init(start: 1, end: 5))
        chat.inputText = "Compare"
        chat.send()
        try await Self.waitUntil { chat.promptSubmissions.first?.state == .uncertain }
        #expect(chat.composerAttachments.count == 2)

        chat.send()
        try await Self.waitUntil { await server.promptRequests.count == 2 }

        let bodies = await server.promptRequests.map { $0.json as NSDictionary }
        #expect(bodies[0] == bodies[1])
        #expect(chat.promptSubmissions.count == 1)
    }

    @Test func combinedAttachmentsMustFitTheRequestLimit() async throws {
        let chat = try await Self.openChat(server: FilePromptFakeServer())
        let large = Data(repeating: UInt8(ascii: "a"), count: 1_000_000)

        chat.attachComposerTextFile(data: large, name: "a.txt")
        chat.attachComposerTextFile(data: large, name: "b.txt")

        #expect(chat.composerAttachments.map(\.id).count == 1)
        #expect(chat.errorMessage == PromptAttachmentError.promptTooLarge.errorDescription)
    }

    @Test func textFilesDoNotRequireAnImageModel() async throws {
        let server = FilePromptFakeServer(inputMedia: ["text"])
        let chat = try await Self.openChat(server: server)

        chat.attachComposerTextFile(data: Data("x".utf8), name: "x.txt")
        chat.inputText = "Read"
        chat.send()
        try await Self.waitUntil { await server.promptRequests.count == 1 }

        #expect(chat.errorMessage == nil)
    }

    // MARK: - Helpers

    private static func query(_ url: URL, _ name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }

    private static func makeClient(server: FilePromptFakeServer) async throws -> OpenCodeClient {
        let api = OpenCodeClient(baseURL: URL(string: "https://example.com")!, transport: server)
        _ = try await api.probeCapabilities()
        return api
    }

    private static func openChat(server: FilePromptFakeServer) async throws -> ChatClient {
        let api = OpenCodeClient(baseURL: URL(string: "https://example.com")!, transport: server)
        let connection = ConnectionManager(testClient: api, capabilities: try await api.probeCapabilities())
        let chat = ChatClient(
            connection: connection, liveActivity: LiveActivityManager(),
            sessionsService: SessionsService(connection: connection), messagesService: MessagesService(connection: connection),
            providersService: ProvidersService(connection: connection), questionService: QuestionService(connection: connection),
            savedConnectionsStore: SavedConnectionsStore(initialConnections: []), recordedReplayStore: RecordedReplayStore()
        )
        await chat.loadProviders()
        await chat.loadSession(OCSession(id: "ses_1", directory: "/workspace/app", title: "Session", time: .init(created: 0, updated: 0)))
        return chat
    }

    private static func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
        for _ in 0..<300 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for condition")
    }
}

// MARK: - Fake server

private actor FilePromptFakeServer: OpenCodeTransport {
    struct Request: Sendable {
        let url: URL
        let body: Data

        var json: [String: Any] {
            (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        }
    }

    private let inputMedia: [String]
    private var droppedPrompts = 0
    private var attachmentRejection: String?
    private(set) var requests: [Request] = []

    init(inputMedia: [String] = ["text", "image"]) {
        self.inputMedia = inputMedia
    }

    var promptRequests: [Request] { requests.filter { $0.url.path.hasSuffix("/prompt") } }

    func dropNextPrompts(_ count: Int) { droppedPrompts = count }
    func rejectNextPromptAttachment(_ message: String) { attachmentRejection = message }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url!
        let path = url.path
        requests.append(Request(url: url, body: request.httpBody ?? Data()))

        func respond(_ status: Int, _ body: String = "", contentType: String = "application/json") -> (Data, URLResponse) {
            respondData(status, Data(body.utf8), contentType: contentType)
        }
        func respondData(_ status: Int, _ data: Data, contentType: String) -> (Data, URLResponse) {
            (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": contentType])!)
        }

        let location = #""location":{"directory":"/workspace/app","project":{"id":"p","directory":"/workspace/app"}}"#
        let media = inputMedia.map { "\"\($0)\"" }.joined(separator: ",")
        let model = #"{"id":"claude-a","providerID":"anthropic","name":"Claude A","capabilities":{"tools":true,"input":[\#(media)],"output":["text"]}}"#
        switch path {
        case "/api/session/ses_1/prompt":
            if droppedPrompts > 0 {
                droppedPrompts -= 1
                throw URLError(.timedOut)
            }
            if let message = attachmentRejection {
                attachmentRejection = nil
                return respond(400, #"{"_tag":"InvalidRequestError","message":"\#(message)","field":"files"}"#)
            }
            let id = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])?["id"] as? String ?? "msg"
            return respond(200, #"{"data":{"id":"\#(id)","sessionID":"ses_1","time":{"created":1},"type":"user","payload":{"text":""},"delivery":"steer"}}"#)
        case "/api/fs/list":
            return respond(200, #"{\#(location),"data":[{"path":"README.md","type":"file"},{"path":"Sources/","type":"directory"},{"path":".git/","type":"directory"}]}"#)
        case "/api/fs/read/Sources/main.swift":
            return respond(200, "print(1)\nprint(2)\n", contentType: "text/plain")
        case "/api/fs/read/logo.png":
            return respondData(200, Data([0x89, 0x50, 0x4E, 0x47, 0xFF, 0xFE]), contentType: "image/png")
        case "/api/info":
            return respond(200, #"{"version":"2.0.23"}"#)
        case "/api/model":
            return respond(200, #"{\#(location),"data":[\#(model)]}"#)
        case "/api/model/default":
            return respond(200, #"{\#(location),"data":\#(model)}"#)
        case "/api/provider":
            return respond(200, #"{\#(location),"data":[{"id":"anthropic","name":"Anthropic"}]}"#)
        case "/api/session/active":
            return respond(200, #"{"data":{}}"#)
        case "/api/session/ses_1":
            return respond(200, #"{"data":{"id":"ses_1","title":"Session","time":{"created":0,"updated":0},\#(location)}}"#)
        case "/api/session/ses_1/inbox":
            return respond(200, #"{"data":[]}"#)
        case "/api/session/ses_1/message":
            return respond(200, #"{"data":[],"cursor":{"next":null}}"#)
        case "/api/session/ses_1/permission", "/api/session/ses_1/form":
            return respond(200, #"{"data":[]}"#)
        default:
            if path.hasPrefix("/api/session/ses_1/message/") {
                return respond(404, #"{"_tag":"MessageNotFoundError","message":"Message not found"}"#)
            }
            return respond(404)
        }
    }

    nonisolated func makeEventStream(
        request: URLRequest,
        deliveryQueue: DispatchQueue,
        callbacks: OpenCodeEventStreamCallbacks
    ) -> any OpenCodeEventStream {
        FilePromptUnusedStream()
    }
}

private final class FilePromptUnusedStream: OpenCodeEventStream, @unchecked Sendable {
    func start() {}
    func suspend() {}
    func resume() {}
    func cancel() {}
}
