import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import OpenLens

/// Screenshots and photos attached to v2 prompts: images are prepared on the
/// phone into model-readable data URIs, the complete request is validated
/// against the prompt body limit, and retries resend identical bytes.
@MainActor
struct V2PromptImageAttachmentTests {

    // MARK: - Preparation

    @Test func aSmallScreenshotIsSentAsItsOriginalPNG() throws {
        let png = TestImage.encoded(width: 300, height: 600, type: .png)

        let image = try PromptImagePreparer.prepare(png, maximumBytes: 1_000_000)

        #expect(image.mime == "image/png")
        #expect(image.data == png)
        #expect(image.dataURI == "data:image/png;base64,\(png.base64EncodedString())")
        #expect(image.name.hasSuffix(".png"))
    }

    @Test func iOSOnlyFormatsAreExportedAsJPEG() throws {
        let tiff = TestImage.encoded(width: 400, height: 300, type: .tiff)

        let image = try PromptImagePreparer.prepare(tiff, maximumBytes: 1_000_000)

        #expect(image.mime == "image/jpeg")
        #expect(image.data.starts(with: [0xFF, 0xD8, 0xFF]))
        #expect(image.name.hasSuffix(".jpg"))
        #expect(image.pixelWidth == 400 && image.pixelHeight == 300)
    }

    @Test func photosAreReencodedWithoutTheirLocation() throws {
        let gps: [CFString: Any] = [
            kCGImagePropertyGPSLatitude: 51.5,
            kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 0.12,
            kCGImagePropertyGPSLongitudeRef: "W",
        ]
        let jpeg = TestImage.encoded(
            width: 200, height: 200, type: .jpeg,
            properties: [kCGImagePropertyGPSDictionary: gps]
        )
        #expect(TestImage.properties(of: jpeg)[kCGImagePropertyGPSDictionary] != nil)

        let image = try PromptImagePreparer.prepare(jpeg, maximumBytes: 1_000_000)

        #expect(image.mime == "image/jpeg")
        #expect(TestImage.properties(of: image.data)[kCGImagePropertyGPSDictionary] == nil)
    }

    @Test func largeImagesAreScaledToTheModelLimitAndByteBudget() throws {
        let png = TestImage.encoded(width: 3_000, height: 1_500, type: .png, noisy: true)

        let image = try PromptImagePreparer.prepare(png, maximumBytes: 300_000)

        #expect(max(image.pixelWidth, image.pixelHeight) <= PromptImagePreparer.maximumPixelDimension)
        #expect(image.data.count <= 300_000)
        #expect(image.mime == "image/jpeg")
    }

    @Test func unreadableOrOversizedImagesFailWithActionableErrors() throws {
        #expect(throws: PromptAttachmentError.unsupportedImage) {
            try PromptImagePreparer.prepare(Data("%PDF-1.7".utf8), maximumBytes: 1_000_000)
        }
        let noisy = TestImage.encoded(width: 2_000, height: 2_000, type: .png, noisy: true)
        #expect(throws: PromptAttachmentError.imageTooLarge) {
            try PromptImagePreparer.prepare(noisy, maximumBytes: 500)
        }
        #expect(PromptAttachmentError.unsupportedImage.errorDescription?.contains("PNG") == true)
    }

    // MARK: - Transport

    @Test func imagesAreAdmittedAsDataURIFiles() async throws {
        let server = ImagePromptFakeServer()
        let api = try await Self.makeClient(server: server)
        let image = try Self.screenshot()

        _ = try await api.sendPromptAsync(sessionID: "ses_1", text: "What is this?", messageID: "msg_1", attachments: [.image(image)])

        let body = try #require(await server.promptRequests.first?.json)
        let files = try #require(body["files"] as? [[String: Any]])
        #expect(body["text"] as? String == "What is this?")
        #expect(files.count == 1)
        #expect(files.first?["uri"] as? String == image.dataURI)
        #expect(files.first?["name"] as? String == image.name)
    }

    @Test func aPromptOverTheBodyLimitIsRejectedBeforeSending() async throws {
        let server = ImagePromptFakeServer()
        let api = try await Self.makeClient(server: server)
        // Base64 and JSON escaping grow these raw bytes past the 2 MiB body.
        let raw = Data((0..<1_600_000).map { UInt8(truncatingIfNeeded: $0 &* 2_654_435_761 >> 7) })
        let image = PromptImageAttachment(data: raw, mime: "image/png", name: "big.png", pixelWidth: 1, pixelHeight: 1)

        await #expect(throws: PromptAttachmentError.promptTooLarge) {
            try await api.queuePrompt(sessionID: "ses_1", text: "Big", messageID: "msg_1", attachments: [.image(image)])
        }
        #expect(await server.promptRequests.isEmpty)
        #expect(!OpenCodeClient.requestMayHaveReachedServer(PromptAttachmentError.promptTooLarge))
    }

    // MARK: - History

    @Test func historyImagesAreProjectedOntoTheUserMessage() throws {
        let png = TestImage.encoded(width: 10, height: 10, type: .png)
        let json = #"""
        {"id":"msg_1","type":"user","time":{"created":1},"text":"From desktop",
         "files":[{"data":"\#(png.base64EncodedString())","mime":"image/png","source":{"type":"inline"},"name":"shot.png"},
                  {"data":"aGk=","mime":"text/plain","source":{"type":"uri","uri":"file:///notes.txt"},"name":"notes.txt"}]}
        """#
        let message = try JSONDecoder().decode(OCV2SessionMessage.self, from: Data(json.utf8))

        let projected = try #require(message.asMessage(sessionID: "ses_1"))
        let chat = MessagesService.convert(projected)

        #expect(chat.content == "From desktop")
        #expect(chat.imageAttachments.count == 1)
        let attachment = try #require(chat.imageAttachments.first)
        #expect(attachment.mime == "image/png")
        #expect(attachment.filename == "shot.png")
        #expect(attachment.url == "data:image/png;base64,\(png.base64EncodedString())")
        #expect(chat.fileAttachments.map(\.filename) == ["notes.txt"])
    }

    // MARK: - Chat

    @Test func anImagePromptShowsTheImageOnTheSentRow() async throws {
        let server = ImagePromptFakeServer()
        let chat = try await Self.openChat(server: server)
        let image = try Self.screenshot()

        chat.inputText = "Look"
        chat.addComposerAttachment(.image(image))
        chat.send()
        try await Self.waitUntil { await server.promptRequests.count == 1 }

        #expect(chat.composerImages.isEmpty)
        let row = try #require(chat.messages.last { $0.role == .user })
        #expect(row.imageAttachments.map(\.url) == [image.dataURI])
    }

    @Test func aPickedPhotoIsPreparedIntoTheComposer() async throws {
        let server = ImagePromptFakeServer()
        let chat = try await Self.openChat(server: server)

        await chat.attachComposerImage(data: TestImage.encoded(width: 300, height: 200, type: .tiff))

        #expect(chat.composerImages.map(\.mime) == ["image/jpeg"])
        #expect(chat.isPreparingComposerImage == false)
        #expect(chat.errorMessage == nil)
    }

    @Test func aPhotoThePickerCannotLoadShowsAnActionableError() async throws {
        let server = ImagePromptFakeServer()
        let chat = try await Self.openChat(server: server)

        await chat.attachComposerImage(data: nil)

        #expect(chat.composerImages.isEmpty)
        #expect(chat.errorMessage == PromptAttachmentError.unsupportedImage.errorDescription)
    }

    @Test func aModelWithoutImageInputRejectsBeforeSending() async throws {
        let server = ImagePromptFakeServer(inputMedia: ["text"])
        let chat = try await Self.openChat(server: server)
        let image = try Self.screenshot()

        chat.inputText = "Look"
        chat.addComposerAttachment(.image(image))
        chat.send()

        #expect(chat.errorMessage == PromptAttachmentError.modelDoesNotAcceptImages(modelName: "Claude A").errorDescription)
        #expect(chat.inputText == "Look")
        #expect(chat.composerImages == [image])
        #expect(chat.messages.isEmpty)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await server.promptRequests.isEmpty)
    }

    @Test func aTooLargePromptIsRejectedBeforeAnyRowIsShown() async throws {
        let server = ImagePromptFakeServer()
        let chat = try await Self.openChat(server: server)
        let raw = Data(repeating: 0xAB, count: 900_000)
        let first = PromptImageAttachment(data: raw, mime: "image/png", name: "a.png", pixelWidth: 1, pixelHeight: 1)
        let second = PromptImageAttachment(data: raw, mime: "image/png", name: "b.png", pixelWidth: 1, pixelHeight: 1)

        chat.inputText = "Two"
        chat.addComposerAttachment(.image(first))
        chat.addComposerAttachment(.image(second))
        chat.send()

        #expect(chat.errorMessage == PromptAttachmentError.promptTooLarge.errorDescription)
        #expect(chat.composerImages.count == 2)
        #expect(chat.messages.isEmpty)
    }

    @Test func anUncertainImagePromptIsRetriedWithIdenticalContent() async throws {
        let server = ImagePromptFakeServer()
        let chat = try await Self.openChat(server: server)
        await server.dropNextPrompts(1)
        let image = try Self.screenshot()

        chat.inputText = "Look"
        chat.addComposerAttachment(.image(image))
        chat.send()
        try await Self.waitUntil { chat.promptSubmissions.first?.state == .uncertain }

        // The composer is restored with the same text and image for retry.
        #expect(chat.inputText == "Look")
        #expect(chat.composerImages == [image])

        chat.send()
        try await Self.waitUntil { await server.promptRequests.count == 2 }

        let bodies = await server.promptRequests.map { $0.json as NSDictionary }
        #expect(bodies[0] == bodies[1])
        #expect(bodies[0]["id"] != nil)
        #expect(chat.promptSubmissions.count == 1)
    }

    @Test func changingTheImagesOfAnUncertainPromptIsNewWork() async throws {
        let server = ImagePromptFakeServer()
        let chat = try await Self.openChat(server: server)
        await server.dropNextPrompts(1)

        chat.inputText = "Look"
        chat.addComposerAttachment(.image(try Self.screenshot()))
        chat.send()
        try await Self.waitUntil { chat.promptSubmissions.first?.state == .uncertain }

        chat.removeComposerAttachment(id: try #require(chat.composerImages.first?.id))
        chat.send()
        try await Self.waitUntil { await server.promptRequests.count == 2 }

        let requests = await server.promptRequests.map(\.json)
        #expect(requests[0]["id"] as? String != requests[1]["id"] as? String)
        #expect(requests[1]["files"] == nil)
    }

    @Test func aRejectedImagePromptRestoresTheComposerImages() async throws {
        let server = ImagePromptFakeServer()
        let chat = try await Self.openChat(server: server)
        await server.rejectNextPrompts(1)
        let image = try Self.screenshot()

        chat.inputText = "Look"
        chat.addComposerAttachment(.image(image))
        chat.send()
        try await Self.waitUntil { chat.promptSubmissions.first?.state == .failed }

        #expect(chat.inputText == "Look")
        #expect(chat.composerImages == [image])
    }

    // MARK: - Helpers

    private static func screenshot() throws -> PromptImageAttachment {
        try PromptImagePreparer.prepare(TestImage.encoded(width: 120, height: 240, type: .png), maximumBytes: 1_000_000)
    }

    private static func makeClient(server: ImagePromptFakeServer) async throws -> OpenCodeClient {
        let api = OpenCodeClient(baseURL: URL(string: "https://example.com")!, transport: server)
        _ = try await api.probeCapabilities()
        return api
    }

    private static func openChat(server: ImagePromptFakeServer) async throws -> ChatClient {
        let api = OpenCodeClient(baseURL: URL(string: "https://example.com")!, transport: server)
        let connection = ConnectionManager(testClient: api, capabilities: try await api.probeCapabilities())
        let chat = ChatClient(
            connection: connection, liveActivity: TestLiveActivityProvider(),
            sessionsService: SessionsService(connection: connection), messagesService: MessagesService(connection: connection),
            providersService: ProvidersService(connection: connection), questionService: QuestionService(connection: connection),
            savedConnectionsStore: SavedConnectionsStore(initialConnections: []), recordedReplayStore: RecordedReplayStore()
        )
        await chat.loadProviders()
        await chat.loadSession(OCSession(id: "ses_1", title: "Session", time: .init(created: 0, updated: 0)))
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

// MARK: - Test images

private enum TestImage {
    static func encoded(
        width: Int,
        height: Int,
        type: UTType,
        noisy: Bool = false,
        properties: [CFString: Any] = [:]
    ) -> Data {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if noisy, let pixels = context.data?.assumingMemoryBound(to: UInt32.self) {
            var seed: UInt32 = 2_463_534_242
            for index in 0..<(context.bytesPerRow / 4 * height) {
                seed ^= seed << 13
                seed ^= seed >> 17
                seed ^= seed << 5
                pixels[index] = seed
            }
        }
        let image = context.makeImage()!
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        CGImageDestinationFinalize(destination)
        return output as Data
    }

    static func properties(of data: Data) -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return [:]
        }
        return properties
    }
}

// MARK: - Fake server

private actor ImagePromptFakeServer: OpenCodeTransport {
    struct Request: Sendable {
        let path: String
        let body: Data

        var json: [String: Any] {
            (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        }
    }

    private let inputMedia: [String]
    private var droppedPrompts = 0
    private var rejectedPrompts = 0
    private(set) var requests: [Request] = []

    init(inputMedia: [String] = ["text", "image"]) {
        self.inputMedia = inputMedia
    }

    var promptRequests: [Request] { requests.filter { $0.path.hasSuffix("/prompt") } }

    func dropNextPrompts(_ count: Int) { droppedPrompts = count }
    func rejectNextPrompts(_ count: Int) { rejectedPrompts = count }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url!
        let path = url.path
        requests.append(Request(path: path, body: request.httpBody ?? Data()))

        func respond(_ status: Int, _ json: String = "") -> (Data, URLResponse) {
            (Data(json.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }

        let location = #""location":{"directory":"/workspace","project":{"id":"p","directory":"/workspace"}}"#
        let media = inputMedia.map { "\"\($0)\"" }.joined(separator: ",")
        let model = #"{"id":"claude-a","providerID":"anthropic","name":"Claude A","capabilities":{"tools":true,"input":[\#(media)],"output":["text"]}}"#
        switch path {
        case "/api/session/ses_1/prompt":
            if droppedPrompts > 0 {
                droppedPrompts -= 1
                throw URLError(.timedOut)
            }
            if rejectedPrompts > 0 {
                rejectedPrompts -= 1
                return respond(400, #"{"_tag":"InvalidRequestError","message":"Rejected"}"#)
            }
            let id = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])?["id"] as? String ?? "msg"
            return respond(200, #"{"data":{"id":"\#(id)","sessionID":"ses_1","time":{"created":1},"type":"user","payload":{"text":""},"delivery":"steer"}}"#)
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
            return respond(200, #"{"data":{"id":"ses_1","title":"Session","time":{"created":0,"updated":0}}}"#)
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
        ImagePromptUnusedStream()
    }
}

private final class ImagePromptUnusedStream: OpenCodeEventStream, @unchecked Sendable {
    func start() {}
    func suspend() {}
    func resume() {}
    func cancel() {}
}
