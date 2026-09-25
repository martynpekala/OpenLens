import Foundation
import Testing
@testable import OpenLens

private func makeActiveSSEConnection(
    protocolVersion: OpenCodeProtocol = .v1
) -> (client: SSEClient, session: URLSession, task: URLSessionDataTask) {
    let url = URL(string: "http://127.0.0.1:1/event")!
    let session = URLSession(configuration: .ephemeral)
    let task = session.dataTask(with: url)
    let client = SSEClient(
        baseURL: URL(string: "http://127.0.0.1:1")!,
        protocolVersion: protocolVersion
    )
    client.installActiveConnectionForTesting(session: session, task: task)
    return (client, session, task)
}

private func toolUpdateRecord(partID: String, status: String = "running") -> String {
    "data: {\"type\":\"message.part.updated\",\"properties\":{\"part\":{\"id\":\"\(partID)\",\"sessionID\":\"session\",\"messageID\":\"message\",\"type\":\"tool\",\"tool\":\"bash\",\"state\":{\"status\":\"\(status)\"}}}}"
}

private func heartbeatRecord(sequence: Int) -> String {
    "data: {\"type\":\"server.heartbeat\",\"properties\":{\"sequence\":\(sequence)}}"
}

private func messageUpdateRecord(messageID: String, summary: String? = nil) -> String {
    let summaryField = summary.map { ",\"summary\":\"\($0)\"" } ?? ""
    return "data: {\"type\":\"message.updated\",\"properties\":{\"info\":{\"id\":\"\(messageID)\",\"sessionID\":\"session\",\"role\":\"assistant\"\(summaryField)}}}"
}

private func textDeltaRecord(partID: String, text: String) -> String {
    "data: {\"type\":\"message.part.delta\",\"properties\":{\"sessionID\":\"session\",\"messageID\":\"message\",\"partID\":\"\(partID)\",\"field\":\"text\",\"delta\":\"\(text)\"}}"
}

private func textPartSnapshotRecord(partID: String, text: String) -> String {
    "data: {\"type\":\"message.part.updated\",\"properties\":{\"part\":{\"id\":\"\(partID)\",\"sessionID\":\"session\",\"messageID\":\"message\",\"type\":\"text\",\"text\":\"\(text)\"}}}"
}

struct SSEClientHTTPStatusTests {

    @MainActor
    @Test func v2FramingAcceptsSplitMultilineDataAndIgnoresUnknownEvents() async {
        let connection = makeActiveSSEConnection(protocolVersion: .v2)
        var synchronizationGaps: [SSEClient.SynchronizationGap] = []
        connection.client.onSynchronizationGap = { synchronizationGaps.append($0) }

        // The bytes, record, and JSON object are each split independently.
        // Future event names deliberately have no reducer and must remain safe.
        let firstChunk = "event: future.event\r\ndata: {\"first\": 1,\r\n"
        let secondChunk = "data: \"second\": 2}\r\n\r\n"
        connection.client.receiveDataForTesting(
            session: connection.session,
            task: connection.task,
            data: Data(firstChunk.utf8)
        )
        connection.client.receiveDataForTesting(
            session: connection.session,
            task: connection.task,
            data: Data(secondChunk.utf8)
        )

        try? await Task.sleep(for: .milliseconds(40))
        #expect(synchronizationGaps.isEmpty)
    }

    @MainActor
    @Test func v2DecodeFailureAndDisconnectReportSynchronizationGaps() async {
        let decodeConnection = makeActiveSSEConnection(protocolVersion: .v2)
        var decodeGaps: [SSEClient.SynchronizationGap] = []
        decodeConnection.client.onSynchronizationGap = { decodeGaps.append($0) }
        decodeConnection.client.receiveDataForTesting(
            session: decodeConnection.session,
            task: decodeConnection.task,
            data: Data("event: session.updated\ndata: not-json\n\n".utf8)
        )

        try? await Task.sleep(for: .milliseconds(40))
        #expect(decodeGaps == [.decodeFailure])

        let malformedUpdateConnection = makeActiveSSEConnection(protocolVersion: .v2)
        var malformedUpdateGaps: [SSEClient.SynchronizationGap] = []
        malformedUpdateConnection.client.onSynchronizationGap = { malformedUpdateGaps.append($0) }
        malformedUpdateConnection.client.receiveDataForTesting(
            session: malformedUpdateConnection.session,
            task: malformedUpdateConnection.task,
            data: Data("event: message.part.delta\ndata: {\"sessionID\":\"session\"}\n\n".utf8)
        )

        try? await Task.sleep(for: .milliseconds(40))
        #expect(malformedUpdateGaps == [.decodeFailure])

        let disconnectConnection = makeActiveSSEConnection(protocolVersion: .v2)
        var disconnectGaps: [SSEClient.SynchronizationGap] = []
        disconnectConnection.client.onSynchronizationGap = { disconnectGaps.append($0) }
        disconnectConnection.client.completeForTesting(
            session: disconnectConnection.session,
            task: disconnectConnection.task
        )

        try? await Task.sleep(for: .milliseconds(40))
        #expect(disconnectGaps == [.disconnected])
    }

    @MainActor
    @Test func nativeV2FramesReachChatAndExcludeOtherLocations() async throws {
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: URL(string: "http://127.0.0.1:1")!)
        let stream = SSEClient(baseURL: URL(string: "http://127.0.0.1:1")!, protocolVersion: .v2, contextDirectory: "/workspace/allowed")
        stream.installActiveConnectionForTesting(session: session, task: task)
        let chat = ChatClient(demoMode: true)
        chat.currentSession = OCSession(id: "ses_live", title: "Live", time: .init(created: 0, updated: 0))
        let handler = SSEEventHandler(haptics: HapticController(), liveActivityTracker: LiveActivityTracker(liveActivity: LiveActivityManager()))
        handler.delegate = chat
        var events: [OCEvent] = []
        stream.onEvent = { events.append($0) }
        stream.onInboundEvent = { handler.handleInboundEvent($0) }
        let frames: [(String, [String: Any], String)] = [
            ("session.step.started", ["sessionID":"ses_live", "assistantMessageID":"msg_live", "agent":"build", "model":["id":"test","providerID":"test"], "started":1], "/workspace/allowed"),
            ("session.text.started", ["sessionID":"ses_live", "assistantMessageID":"msg_live", "ordinal":0], "/workspace/allowed"),
            ("session.text.delta", ["sessionID":"ses_live", "assistantMessageID":"msg_live", "ordinal":0, "delta":"Hello"], "/workspace/allowed"),
            ("session.text.delta", ["sessionID":"ses_live", "assistantMessageID":"msg_live", "ordinal":0, "delta":" SECRET"], "/workspace/foreign"),
            ("session.text.ended", ["sessionID":"ses_live", "assistantMessageID":"msg_live", "ordinal":0, "text":"Hello"], "/workspace/allowed"),
            ("session.tool.input.started", ["sessionID":"ses_live", "assistantMessageID":"msg_live", "id":"tool_1", "name":"bash"], "/workspace/allowed"),
            ("session.tool.called", ["sessionID":"ses_live", "assistantMessageID":"msg_live", "id":"tool_1", "input":["command":"pwd"], "executed":true], "/workspace/allowed"),
            ("session.tool.success", ["sessionID":"ses_live", "assistantMessageID":"msg_live", "id":"tool_1", "content":[["type":"text","text":"/workspace/allowed"]], "executed":true], "/workspace/allowed"),
            ("session.step.ended", ["sessionID":"ses_live", "assistantMessageID":"msg_live", "finish":"tool-calls", "cost":0], "/workspace/allowed"),
            ("session.step.started", ["sessionID":"ses_live", "assistantMessageID":"msg_next", "agent":"build", "model":["id":"test","providerID":"test"], "started":2], "/workspace/allowed"),
            ("session.reasoning.started", ["sessionID":"ses_live", "assistantMessageID":"msg_next", "ordinal":0], "/workspace/allowed"),
            ("session.reasoning.delta", ["sessionID":"ses_live", "assistantMessageID":"msg_next", "ordinal":0, "delta":"Thinking"], "/workspace/allowed"),
            ("session.reasoning.ended", ["sessionID":"ses_live", "assistantMessageID":"msg_next", "ordinal":0, "text":"Thinking"], "/workspace/allowed")
        ]
        for (type, payload, directory) in frames {
            let object: [String: Any] = ["id":"evt_1", "created":1, "type":type, "data":payload, "location":["directory":directory]]
            let json = try JSONSerialization.data(withJSONObject: object)
            var frame = Data("event: message\ndata: ".utf8)
            frame.append(json)
            frame.append(Data("\n\n".utf8))
            // Exercise arbitrary transport chunk boundaries too.
            stream.receiveDataForTesting(session: session, task: task, data: frame.prefix(13))
            stream.receiveDataForTesting(session: session, task: task, data: frame.dropFirst(13))
        }
        try await Task.sleep(for: .milliseconds(150))
        let message = try #require(chat.displayedMessages.first { $0.id == "msg_live" })
        let textRows = ChatTimeline.items(from: [message], showsThinking: true).compactMap { item -> String? in
            switch item.content {
            case .streamingAssistantText(_, let projection): return projection.copyText()
            case .assistantSegment(_, let segment):
                if case .text(let text) = segment.kind { return segment.streamingText?.copyText() ?? text }
                return nil
            default: return nil
            }
        }
        #expect(textRows == ["Hello"])
        #expect(chat.messages.contains { $0.id == "msg_live" && !$0.isStreaming })
        let next = try #require(chat.displayedMessages.first { $0.id == "msg_next" })
        #expect(next.parts.contains { $0.type == .reasoning })
        let tools = events.compactMap { event -> OCPart? in
            guard event.type == "message.part.updated",
                  let properties = event.properties?.value as? [String: Any],
                  let part = properties["part"],
                  let data = try? JSONSerialization.data(withJSONObject: part) else { return nil }
            return try? JSONDecoder().decode(OCPart.self, from: data)
        }.filter { $0.type == .tool }
        #expect(tools.last?.tool == "bash")
        #expect(tools.last?.state?.status == .completed)
        #expect(tools.last?.state?.output == "/workspace/allowed")
        #expect(!events.contains { String(describing: $0.properties?.value).contains("SECRET") })
        stream.disconnect()
    }

    @MainActor
    @Test func v2ConnectionAndLaterDecodeGapEachRequireRecovery() async throws {
        let connection = makeActiveSSEConnection(protocolVersion: .v2)
        var gaps: [SSEClient.SynchronizationGap] = []
        connection.client.onSynchronizationGap = { gaps.append($0) }
        connection.client.receiveResponseForTesting(
            session: connection.session, task: connection.task,
            response: HTTPURLResponse(url: URL(string: "http://127.0.0.1")!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
            completionHandler: { _ in }
        )
        try await Task.sleep(for: .milliseconds(40))
        #expect(gaps == [.reconnected])
        let generation = await connection.client.synchronizationGeneration()
        #expect(await connection.client.acknowledgeSynchronization(since: generation))
        connection.client.receiveDataForTesting(session: connection.session, task: connection.task, data: Data("data: invalid\n\n".utf8))
        try await Task.sleep(for: .milliseconds(40))
        #expect(gaps == [.reconnected, .decodeFailure])
        #expect(await connection.client.acknowledgeSynchronization(since: generation) == false)
        let current = await connection.client.synchronizationGeneration()
        #expect(await connection.client.acknowledgeSynchronization(since: current))
    }

    @Test func nativeV2InteractionsFailuresAndUnknownEventsKeepTheirMeaning() throws {
        var adapter = V2EventAdapter()
        func envelope(_ type: String, _ payload: [String: Any]) -> [String: Any] {
            ["type":type, "data":payload, "location":["directory":"/workspace"]]
        }
        func decode(_ value: [String: Any]) throws -> OCEvent? {
            try adapter.event(value, directory: "/workspace")
        }
        let permission = try #require(try decode(envelope("permission.asked", ["id":"per_1", "sessionID":"ses_1", "action":"shell", "resources":["pwd"]])))
        #expect(SSEPermissionAsked(event: permission)?.request?.id == "per_1")
        let form = try #require(try decode(envelope("form.created", ["form":["id":"frm_1", "sessionID":"ses_1", "title":"Continue?", "fields":[["key":"answer", "type":"boolean"]]]])))
        #expect(SSEFormCreated(event: form)?.form?.id == "frm_1")
        for type in ["session.execution.succeeded", "session.execution.failed", "session.execution.interrupted", "permission.replied"] {
            let event = try #require(try decode(envelope(type, ["sessionID":"ses_1"])))
            #expect(event.type == "session.reconcile")
            #expect((event.properties?.value as? [String: Any])?["sessionID"] as? String == "ses_1")
        }
        let unknown = try #require(try decode(envelope("session.text.future", ["sessionID":"ses_1"])))
        #expect(unknown.type == "session.text.future")
        let resolved = try #require(try decode(envelope("form.cancelled", ["sessionID":"ses_1", "id":"frm_1"])))
        #expect(SSEFormResolved(event: resolved)?.formID == "frm_1")
    }

    @Test func treats401AsTerminalAuthFailure() {
        #expect(isTerminalSSEHTTPStatus(401))
    }

    @Test func treats403AsTerminalAuthFailure() {
        #expect(isTerminalSSEHTTPStatus(403))
    }

    @Test func keepsReconnectableStatusesNonTerminal() {
        #expect(!isTerminalSSEHTTPStatus(200))
        #expect(!isTerminalSSEHTTPStatus(429))
        #expect(!isTerminalSSEHTTPStatus(500))
    }

    @Test func preparesMessageMetadataBeforeMainDelivery() {
        let event = OCEvent(
            type: "message.updated",
            properties: AnyCodable([
                "info": [
                    "id": "assistant-message",
                    "sessionID": "session",
                    "role": "assistant",
                    "cost": 0.42,
                    "modelID": "model",
                    "providerID": "provider",
                    "finish": "stop",
                    "parentID": "user-message"
                ]
            ])
        )

        guard let inboundEvent = SSEInboundEvent.prepare(event),
              case .messageUpdated(let update, let rawEvent) = inboundEvent
        else {
            Issue.record("Expected prepared message metadata")
            return
        }

        #expect(update.sessionID == "session")
        #expect(update.messageID == "assistant-message")
        #expect(update.role == "assistant")
        #expect(update.cost == 0.42)
        #expect(update.modelID == "model")
        #expect(update.providerID == "provider")
        #expect(update.finish == "stop")
        #expect(update.parentID == "user-message")
        #expect(rawEvent?.type == "message.updated")
    }

    @MainActor
    @Test func preparedRawPayloadRetentionIsOptIn() async {
        let connection = makeActiveSSEConnection()
        let client = connection.client
        var rawRetention: [Bool] = []
        var legacyRawTypes: [String] = []
        client.onInboundEvent = { event in
            guard case .messageUpdated(_, let rawEvent) = event else { return }
            rawRetention.append(rawEvent != nil)
        }

        client.receiveDataForTesting(
            session: connection.session,
            task: connection.task,
            data: Data((messageUpdateRecord(messageID: "without-raw") + "\n\n").utf8)
        )
        for _ in 0..<20 where rawRetention.count < 1 {
            try? await Task.sleep(for: .milliseconds(10))
        }

        // The compatibility callback is itself an opt-in for the original
        // payload, so older callers keep their raw-event behavior.
        client.onEvent = { event in
            legacyRawTypes.append(event.type)
        }
        client.receiveDataForTesting(
            session: connection.session,
            task: connection.task,
            data: Data((messageUpdateRecord(messageID: "legacy-raw") + "\n\n").utf8)
        )
        for _ in 0..<20 where rawRetention.count < 2 {
            try? await Task.sleep(for: .milliseconds(10))
        }

        client.onEvent = nil
        client.setRawEventRetentionEnabled(true)
        client.receiveDataForTesting(
            session: connection.session,
            task: connection.task,
            data: Data((messageUpdateRecord(messageID: "recorded-raw") + "\n\n").utf8)
        )
        for _ in 0..<20 where rawRetention.count < 3 {
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(rawRetention == [false, true, true])
        #expect(legacyRawTypes == ["message.updated"])
    }

    @MainActor
    @Test func largePreparedEventUsesByteBackpressureUntilMainDeliveryFinishes() async {
        let connection = makeActiveSSEConnection()
        let client = connection.client
        let largeSummary = String(repeating: "x", count: 768 * 1_024)
        var delivered = false
        var retainedRawPayload = true
        client.onInboundEvent = { event in
            guard case .messageUpdated(let update, let rawEvent) = event else { return }
            delivered = update.messageID == "large-message"
            retainedRawPayload = rawEvent != nil
        }

        client.receiveDataForTesting(
            session: connection.session,
            task: connection.task,
            data: Data((messageUpdateRecord(messageID: "large-message", summary: largeSummary) + "\n\n").utf8)
        )

        // The single record is below the complete-record limit but over the
        // byte watermark. It must keep the transport paused even after the
        // ring hands its one event to a MainActor ticket.
        #expect(client.isTransportPausedForTesting)
        #expect(client.outstandingMainDeliveryByteCountForTesting >= 512 * 1_024)

        for _ in 0..<40 where !delivered {
            try? await Task.sleep(for: .milliseconds(25))
        }

        #expect(delivered)
        #expect(!retainedRawPayload)
        #expect(!client.isTransportPausedForTesting)
        #expect(client.outstandingMainDeliveryByteCountForTesting == 0)
    }

    @MainActor
    @Test func consumerBackpressureHoldsMainDeliveryUntilTheRenderQueueDrains() async {
        let connection = makeActiveSSEConnection()
        let client = connection.client
        var deliveredPartIDs: [String] = []
        client.onInboundEvent = { event in
            guard case .partUpdated(let part, _, _, _) = event else { return }
            deliveredPartIDs.append(part.id)
        }

        client.setConsumerBackpressured(true)
        for _ in 0..<20 where !client.isConsumerBackpressuredForTesting {
            try? await Task.sleep(for: .milliseconds(10))
        }

        let expectedPartIDs = (0..<20).map { "consumer-gate-\($0)" }
        let payload = expectedPartIDs
            .map { toolUpdateRecord(partID: $0) + "\n\n" }
            .joined()
        client.receiveDataForTesting(
            session: connection.session,
            task: connection.task,
            data: Data(payload.utf8)
        )

        try? await Task.sleep(for: .milliseconds(40))
        #expect(client.isConsumerBackpressuredForTesting)
        #expect(client.isTransportPausedForTesting)
        #expect(deliveredPartIDs.isEmpty)

        client.setConsumerBackpressured(false)
        for _ in 0..<40 where deliveredPartIDs.count < expectedPartIDs.count {
            try? await Task.sleep(for: .milliseconds(15))
        }

        #expect(deliveredPartIDs == expectedPartIDs)
        #expect(!client.isConsumerBackpressuredForTesting)
        #expect(!client.isTransportPausedForTesting)
    }

    @MainActor
    @Test func coalescedTextDeltasPreservePartIDAndStaySeparatedByPart() async {
        let connection = makeActiveSSEConnection()
        let client = connection.client
        var events: [OCEvent] = []
        client.onEvent = { event in
            events.append(event)
        }

        let reasoningDelta = #"data: {"type":"message.part.delta","properties":{"sessionID":"session","messageID":"message","partID":"reasoning-part","field":"text","delta":"think"}}"#
        let textDelta = #"data: {"type":"message.part.delta","properties":{"sessionID":"session","messageID":"message","partID":"text-part","field":"text","delta":"answer"}}"#
        let payload = reasoningDelta + "\n\n" + textDelta + "\n\n"

        client.receiveDataForTesting(
            session: connection.session,
            task: connection.task,
            data: Data(payload.utf8)
        )

        try? await Task.sleep(for: .milliseconds(80))

        #expect(events.count == 2)
        #expect((events.first?.properties?.value as? [String: Any])?["partID"] as? String == "reasoning-part")
        #expect((events.last?.properties?.value as? [String: Any])?["partID"] as? String == "text-part")
    }

    @MainActor
    @Test func textDeltaCoalescerCapsFragmentCountBeforeItsTimedFlush() async {
        let connection = makeActiveSSEConnection()
        let client = connection.client
        var deliveredText: [String] = []
        client.onInboundEvent = { event in
            guard case .textDelta(let delta, _) = event else { return }
            deliveredText.append(delta.text)
        }

        // Each testing callback contains exactly one record, so the normal
        // multi-record callback flush cannot mask the fragment-count bound.
        // The 65th one-byte delta must flush the first 64-fragment group before
        // the 20 ms timer expires.
        let record = textDeltaRecord(partID: "fragment-cap", text: "x") + "\n\n"
        for _ in 0...64 {
            client.receiveDataForTesting(
                session: connection.session,
                task: connection.task,
                data: Data(record.utf8)
            )
        }

        for _ in 0..<40 where deliveredText.joined().utf8.count < 65 {
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(deliveredText.joined() == String(repeating: "x", count: 65))
        #expect(deliveredText.count >= 2)
        #expect(deliveredText.allSatisfy { $0.utf8.count <= 64 })
    }

    @MainActor
    @Test func oversizedTextDeltaIsSplitBeforeMainDeliveryAndStaysAheadOfToolBarrier() async {
        let connection = makeActiveSSEConnection()
        let client = connection.client
        let oversized = String(repeating: "x", count: 3 * 64 * 1_024 + 211)
        var deliveredText: [String] = []
        var deliveryOrder: [String] = []
        client.onInboundEvent = { event in
            switch event {
            case .textDelta(let delta, _):
                deliveredText.append(delta.text)
                deliveryOrder.append("text")

            case .partUpdated(let part, _, _, _) where part.id == "after-oversized-delta":
                deliveryOrder.append("tool")

            case .raw, .cold, .messageUpdated, .partUpdated:
                break
            }
        }

        let payload = [
            textDeltaRecord(partID: "oversized", text: oversized),
            toolUpdateRecord(partID: "after-oversized-delta"),
        ].joined(separator: "\n\n") + "\n\n"
        client.receiveDataForTesting(
            session: connection.session,
            task: connection.task,
            data: Data(payload.utf8)
        )

        // Completion must not discard suffix groups that were held behind the
        // first main-delivery ticket, nor the tool record still in the framed
        // transport buffer.
        client.completeForTesting(session: connection.session, task: connection.task)

        for _ in 0..<100 where deliveryOrder.last != "tool" {
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(deliveredText.joined() == oversized)
        #expect(deliveredText.allSatisfy { $0.utf8.count <= 64 * 1_024 })
        #expect(deliveryOrder.last == "tool")
        #expect(deliveryOrder.dropLast().allSatisfy { $0 == "text" })
        #expect(!client.isTransportPausedForTesting)
    }

    @MainActor
    @Test func deltasInvalidateTextSnapshotBaselineBeforeTheNextAuthoritativeSnapshot() async {
        let connection = makeActiveSSEConnection()
        let client = connection.client
        var events: [SSEInboundEvent] = []
        client.onInboundEvent = { events.append($0) }

        let initial = "Initial"
        let appended = " + delta"
        let complete = initial + appended
        let payload = [
            textPartSnapshotRecord(partID: "text-part", text: initial),
            textDeltaRecord(partID: "text-part", text: appended),
            textPartSnapshotRecord(partID: "text-part", text: complete),
        ].joined(separator: "\n\n") + "\n\n"
        client.receiveDataForTesting(
            session: connection.session,
            task: connection.task,
            data: Data(payload.utf8)
        )

        for _ in 0..<40 where events.count < 3 {
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(events.count == 3)
        guard case .partUpdated(let firstPart, _, _, _) = events[0],
              case .textDelta(let delta, _) = events[1],
              case .partUpdated(let finalPart, _, _, _) = events[2]
        else {
            Issue.record("Expected an initial snapshot, a delta, then an authoritative snapshot")
            return
        }
        #expect(firstPart.renderableText == initial)
        #expect(delta.text == appended)
        #expect(finalPart.renderableText == complete)
    }

    @MainActor
    @Test func oversizedTextSnapshotsBypassTheSuffixReductionCache() async {
        let connection = makeActiveSSEConnection()
        let client = connection.client
        var events: [SSEInboundEvent] = []
        client.onInboundEvent = { events.append($0) }

        let initial = String(repeating: "x", count: 257 * 1_024)
        let complete = initial + "!"
        client.receiveDataForTesting(
            session: connection.session,
            task: connection.task,
            data: Data((textPartSnapshotRecord(partID: "large-text", text: initial) + "\n\n").utf8)
        )
        for _ in 0..<80 where events.count < 1 {
            try? await Task.sleep(for: .milliseconds(10))
        }

        client.receiveDataForTesting(
            session: connection.session,
            task: connection.task,
            data: Data((textPartSnapshotRecord(partID: "large-text", text: complete) + "\n\n").utf8)
        )
        for _ in 0..<80 where events.count < 2 {
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(events.count == 2)
        guard case .partUpdated(let firstPart, _, _, _) = events[0],
              case .partUpdated(let finalPart, _, _, _) = events[1]
        else {
            Issue.record("Oversized snapshots should remain authoritative replacements")
            return
        }
        #expect(firstPart.renderableText == initial)
        #expect(finalPart.renderableText == complete)
    }

    @MainActor
    @Test func parsesCRLFSSERecordsWithoutChangingEventOrder() async {
        let connection = makeActiveSSEConnection()
        let client = connection.client
        var deliveryOrder: [String] = []
        client.onInboundEvent = { event in
            guard case .textDelta(let delta, _) = event else { return }
            deliveryOrder.append("\(delta.partID ?? "missing"):\(delta.text)")
        }

        let first = #"data: {"type":"message.part.delta","properties":{"sessionID":"session","messageID":"message","partID":"first-part","field":"text","delta":"first"}}"#
        let second = #"data: {"type":"message.part.delta","properties":{"sessionID":"session","messageID":"message","partID":"second-part","field":"text","delta":"second"}}"#

        let payloadBytes = Array((first + "\r\n\r\n" + second + "\r\n\r\n").utf8)
        let splitIndex = Array(first.utf8).count + 3 // Split \r\n\r | \n.
        client.receiveDataForTesting(
            session: connection.session,
            task: connection.task,
            data: Data(payloadBytes[..<splitIndex])
        )
        client.receiveDataForTesting(
            session: connection.session,
            task: connection.task,
            data: Data(payloadBytes[splitIndex...])
        )

        try? await Task.sleep(for: .milliseconds(80))

        #expect(deliveryOrder == ["first-part:first", "second-part:second"])
    }

    @MainActor
    @Test func preservesUTF8ScalarSplitAcrossTransportCallbacks() async {
        let connection = makeActiveSSEConnection()
        let client = connection.client
        let streamedText = "Zażółć 🚀"
        var deliveredText: String?
        client.onInboundEvent = { event in
            guard case .textDelta(let delta, _) = event else { return }
            deliveredText = delta.text
        }

        let record = "data: {\"type\":\"message.part.delta\",\"properties\":{\"sessionID\":\"session\",\"messageID\":\"message\",\"partID\":\"text-part\",\"field\":\"text\",\"delta\":\"\(streamedText)\"}}\n\n"
        let bytes = Array(record.utf8)
        guard let emojiStart = bytes.firstIndex(of: 0xF0) else {
            Issue.record("Expected the test payload to contain the emoji's UTF-8 lead byte")
            return
        }
        let splitIndex = emojiStart + 2 // In the middle of the four-byte scalar.

        client.receiveDataForTesting(
            session: connection.session,
            task: connection.task,
            data: Data(bytes[..<splitIndex])
        )
        client.receiveDataForTesting(
            session: connection.session,
            task: connection.task,
            data: Data(bytes[splitIndex...])
        )

        try? await Task.sleep(for: .milliseconds(80))

        #expect(deliveredText == streamedText)
    }

    @MainActor
    @Test func mainBackpressurePreservesEveryToolEventInFIFOOrder() async {
        let connection = makeActiveSSEConnection()
        let client = connection.client
        let expectedOrder = (0..<48).flatMap { index in
            ["tool-\(index):running", "tool-\(index):completed"]
        }
        var deliveryOrder: [String] = []
        client.onInboundEvent = { event in
            guard case .partUpdated(let part, _, _, _) = event,
                  part.type == .tool,
                  let status = part.state?.status
            else { return }
            deliveryOrder.append("\(part.id):\(status.rawValue)")
        }

        let payload = (0..<48)
            .flatMap { index in
                [
                    toolUpdateRecord(partID: "tool-\(index)", status: "running"),
                    toolUpdateRecord(partID: "tool-\(index)", status: "completed"),
                ]
            }
            .joined(separator: "\n\n") + "\n\n"
        client.receiveDataForTesting(
            session: connection.session,
            task: connection.task,
            data: Data(payload.utf8)
        )

        // MainActor is still occupied by this test, so the producer must have
        // suspended before it can enqueue an unbounded number of tool updates.
        #expect(client.isTransportPausedForTesting)

        for _ in 0..<40 {
            guard deliveryOrder.count < expectedOrder.count else { break }
            try? await Task.sleep(for: .milliseconds(25))
        }

        #expect(deliveryOrder == expectedOrder)
        #expect(!client.isTransportPausedForTesting)
    }

    @MainActor
    @Test func heartbeatQueuedBehindBackpressureSurvivesNaturalTransportCompletion() async {
        let connection = makeActiveSSEConnection()
        let client = connection.client
        var deliveredTools: [String] = []
        var deliveredHeartbeatSequences: [Int] = []
        client.onInboundEvent = { event in
            switch event {
            case .partUpdated(let part, _, _, _) where part.type == .tool:
                deliveredTools.append(part.id)

            case .raw(let raw) where raw.type == "server.heartbeat":
                if let properties = raw.properties?.value as? [String: Any],
                   let sequence = properties["sequence"] as? Int {
                    deliveredHeartbeatSequences.append(sequence)
                }

            case .raw, .cold, .messageUpdated, .partUpdated, .textDelta:
                break
            }
        }

        let tools = (0..<40)
            .map { toolUpdateRecord(partID: "tool-\($0)") }
            .joined(separator: "\n\n") + "\n\n"
        client.receiveDataForTesting(
            session: connection.session,
            task: connection.task,
            data: Data(tools.utf8)
        )
        #expect(client.isTransportPausedForTesting)

        client.receiveDataForTesting(
            session: connection.session,
            task: connection.task,
            data: Data((heartbeatRecord(sequence: 7) + "\n\n").utf8)
        )
        client.completeForTesting(session: connection.session, task: connection.task)

        for _ in 0..<40 {
            guard deliveredTools.count < 40 || deliveredHeartbeatSequences.isEmpty else { break }
            try? await Task.sleep(for: .milliseconds(25))
        }

        #expect(deliveredTools == (0..<40).map { "tool-\($0)" })
        #expect(deliveredHeartbeatSequences == [7])
    }

    @MainActor
    @Test func heartbeatsCollapseDuringMainBackpressureAndRefreshAfterDrain() async {
        let connection = makeActiveSSEConnection()
        let client = connection.client
        let expectedTools = (0..<80).map { "tool-\($0)" }
        var deliveredTools: [String] = []
        var deliveredHeartbeatSequences: [Int] = []
        client.onInboundEvent = { event in
            switch event {
            case .partUpdated(let part, _, _, _) where part.type == .tool:
                deliveredTools.append(part.id)

            case .raw(let raw) where raw.type == "server.heartbeat":
                if let properties = raw.properties?.value as? [String: Any],
                   let sequence = properties["sequence"] as? Int {
                    deliveredHeartbeatSequences.append(sequence)
                }

            case .raw, .cold, .messageUpdated, .partUpdated, .textDelta:
                break
            }
        }

        let toolPayload = (0..<80)
            .map { toolUpdateRecord(partID: "tool-\($0)") }
            .joined(separator: "\n\n") + "\n\n"
        client.receiveDataForTesting(
            session: connection.session,
            task: connection.task,
            data: Data(toolPayload.utf8)
        )
        #expect(client.isTransportPausedForTesting)

        let heartbeatPayload = (0..<100)
            .map(heartbeatRecord)
            .joined(separator: "\n\n") + "\n\n"
        client.receiveDataForTesting(
            session: connection.session,
            task: connection.task,
            data: Data(heartbeatPayload.utf8)
        )

        for _ in 0..<60 {
            guard deliveredTools.count < expectedTools.count || deliveredHeartbeatSequences.isEmpty else { break }
            try? await Task.sleep(for: .milliseconds(25))
        }

        #expect(deliveredTools == expectedTools)
        #expect(deliveredHeartbeatSequences == [99])
        #expect(!client.isTransportPausedForTesting)
    }

    @Test func cancelsAnOversizedUnterminatedRecordBeforeItCanGrowWithoutBound() {
        let connection = makeActiveSSEConnection()
        let oversizedRecord = Data(
            repeating: 0x61,
            count: 2 * 1_024 * 1_024 + 1
        )

        connection.client.receiveDataForTesting(
            session: connection.session,
            task: connection.task,
            data: oversizedRecord
        )

        #expect(connection.client.hasOversizedRecordCancellationForTesting)
    }

    @Test func cancelsAnOversizedCompleteRecordBeforeDecodingIt() {
        let connection = makeActiveSSEConnection()
        var oversizedRecord = Data("data: ".utf8)
        oversizedRecord.append(Data(repeating: 0x61, count: 2 * 1_024 * 1_024 + 1))
        oversizedRecord.append(Data("\n\n".utf8))

        connection.client.receiveDataForTesting(
            session: connection.session,
            task: connection.task,
            data: oversizedRecord
        )

        #expect(connection.client.hasOversizedRecordCancellationForTesting)
    }

    @MainActor
    @Test func coalescesConsecutiveReasoningSnapshotsBeforeMainDelivery() async {
        let connection = makeActiveSSEConnection()
        let client = connection.client
        var events: [SSEInboundEvent] = []
        client.onInboundEvent = { event in
            events.append(event)
        }

        let firstText = String(repeating: "first reasoning ", count: 600)
        let secondText = String(repeating: "second reasoning ", count: 600)
        let first = "data: {\"type\":\"message.part.updated\",\"properties\":{\"part\":{\"id\":\"reasoning-part\",\"sessionID\":\"session\",\"messageID\":\"message\",\"type\":\"reasoning\",\"text\":\"\(firstText)\"}}}"
        let second = "data: {\"type\":\"message.part.updated\",\"properties\":{\"part\":{\"id\":\"reasoning-part\",\"sessionID\":\"session\",\"messageID\":\"message\",\"type\":\"reasoning\",\"text\":\"\(secondText)\"}}}"

        client.receiveDataForTesting(
            session: connection.session,
            task: connection.task,
            data: Data((first + "\n\n" + second + "\n\n").utf8)
        )

        try? await Task.sleep(for: .milliseconds(80))

        #expect(events.count == 1)
        guard case .partUpdated(let part, let chunks, _, _) = events[0] else {
            Issue.record("Expected a prepared part snapshot")
            return
        }
        #expect(part.text == secondText)
        #expect((chunks?.count ?? 0) > 1)
    }

    @MainActor
    @Test func growingTextSnapshotsEmitOnlyTheSuffixAfterTheirFirstDelivery() async {
        let connection = makeActiveSSEConnection()
        let client = connection.client
        var events: [SSEInboundEvent] = []
        client.onInboundEvent = { event in
            events.append(event)
        }

        let initial = String(repeating: "initial text ", count: 500)
        let suffix = String(repeating: "suffix ", count: 400)
        let first = "data: {\"type\":\"message.part.updated\",\"properties\":{\"part\":{\"id\":\"text-part\",\"sessionID\":\"session\",\"messageID\":\"message\",\"type\":\"text\",\"text\":\"\(initial)\"}}}"
        let second = "data: {\"type\":\"message.part.updated\",\"properties\":{\"part\":{\"id\":\"text-part\",\"sessionID\":\"session\",\"messageID\":\"message\",\"type\":\"text\",\"text\":\"\(initial + suffix)\"}}}"

        client.receiveDataForTesting(
            session: connection.session,
            task: connection.task,
            data: Data((first + "\n\n" + second + "\n\n").utf8)
        )

        try? await Task.sleep(for: .milliseconds(100))

        #expect(events.count == 2)
        guard case .partUpdated(let firstPart, _, _, _) = events[0],
              case .textDelta(let delta, _) = events[1]
        else {
            Issue.record("Expected an initial snapshot followed by a suffix delta")
            return
        }
        #expect(firstPart.renderableText == initial)
        #expect(delta.text == suffix)
    }

    @MainActor
    @Test func idleStatusClearsTextSnapshotCacheForTheSession() async {
        let connection = makeActiveSSEConnection()
        let client = connection.client
        var events: [SSEInboundEvent] = []
        client.onInboundEvent = { events.append($0) }

        let initial = "Initial"
        let appended = " + delta"
        let complete = initial + appended
        let firstSnapshot = "data: {\"type\":\"message.part.updated\",\"properties\":{\"part\":{\"id\":\"text-part\",\"sessionID\":\"session\",\"messageID\":\"message\",\"type\":\"text\",\"text\":\"\(initial)\"}}}"
        let delta = "data: {\"type\":\"message.part.delta\",\"properties\":{\"sessionID\":\"session\",\"messageID\":\"message\",\"partID\":\"text-part\",\"field\":\"text\",\"delta\":\"\(appended)\"}}"
        let idle = #"data: {"type":"session.status","properties":{"sessionID":"session","status":{"type":"idle"}}}"#
        let nextTurnSnapshot = "data: {\"type\":\"message.part.updated\",\"properties\":{\"part\":{\"id\":\"text-part\",\"sessionID\":\"session\",\"messageID\":\"message\",\"type\":\"text\",\"text\":\"\(complete)\"}}}"

        client.receiveDataForTesting(
            session: connection.session,
            task: connection.task,
            data: Data(([firstSnapshot, delta, idle, nextTurnSnapshot].joined(separator: "\n\n") + "\n\n").utf8)
        )

        try? await Task.sleep(for: .milliseconds(100))

        #expect(events.count == 4)
        guard let finalEvent = events.last,
              case .partUpdated(let part, _, _, _) = finalEvent
        else {
            Issue.record("Expected the post-idle snapshot to be delivered as a fresh snapshot")
            return
        }
        #expect(part.renderableText == complete)
    }

    @MainActor
    @Test func toolStatusSnapshotsRemainSeparateOrderingBarriers() async {
        let connection = makeActiveSSEConnection()
        let client = connection.client
        var statuses: [OCToolStatus] = []
        client.onInboundEvent = { event in
            guard case .partUpdated(let part, _, _, _) = event,
                  let status = part.state?.status else { return }
            statuses.append(status)
        }

        let running = #"data: {"type":"message.part.updated","properties":{"part":{"id":"tool-part","sessionID":"session","messageID":"message","type":"tool","tool":"bash","state":{"status":"running"}}}}"#
        let completed = #"data: {"type":"message.part.updated","properties":{"part":{"id":"tool-part","sessionID":"session","messageID":"message","type":"tool","tool":"bash","state":{"status":"completed"}}}}"#

        client.receiveDataForTesting(
            session: connection.session,
            task: connection.task,
            data: Data((running + "\n\n" + completed + "\n\n").utf8)
        )

        try? await Task.sleep(for: .milliseconds(80))

        #expect(statuses == [.running, .completed])
    }

    @MainActor
    @Test func repeatedToolStatusSnapshotsCoalesceWhileMainIsBacklogged() async {
        let connection = makeActiveSSEConnection()
        let client = connection.client
        var statuses: [OCToolStatus] = []
        client.onInboundEvent = { event in
            guard case .partUpdated(let part, _, _, _) = event,
                  let status = part.state?.status else { return }
            statuses.append(status)
        }

        let running = #"data: {"type":"message.part.updated","properties":{"part":{"id":"tool-part","sessionID":"session","messageID":"message","type":"tool","tool":"bash","state":{"status":"running"}}}}"#
        let duplicateRunning = #"data: {"type":"message.part.updated","properties":{"part":{"id":"tool-part","sessionID":"session","messageID":"message","type":"tool","tool":"bash","state":{"status":"running","title":"Still running"}}}}"#
        let completed = #"data: {"type":"message.part.updated","properties":{"part":{"id":"tool-part","sessionID":"session","messageID":"message","type":"tool","tool":"bash","state":{"status":"completed"}}}}"#

        client.receiveDataForTesting(
            session: connection.session,
            task: connection.task,
            data: Data((running + "\n\n" + duplicateRunning + "\n\n" + completed + "\n\n").utf8)
        )

        try? await Task.sleep(for: .milliseconds(100))

        #expect(statuses == [.running, .completed])
    }

    @MainActor
    @Test func multiRecordCallbackKeepsTextAndToolBarriersInOneMainDelivery() async {
        let connection = makeActiveSSEConnection()
        let client = connection.client
        var deliveryOrder: [String] = []
        var scheduledNextMainTurn = false

        client.onInboundEvent = { event in
            if !scheduledNextMainTurn {
                scheduledNextMainTurn = true
                DispatchQueue.main.async {
                    deliveryOrder.append("next-main-turn")
                }
            }

            switch event {
            case .textDelta(let delta, _):
                deliveryOrder.append("text-\(delta.partID ?? "fallback")")

            case .partUpdated(let part, _, _, _):
                guard part.type == .tool, let status = part.state?.status else { return }
                deliveryOrder.append(status == .running ? "tool-running" : "tool-completed")

            case .raw, .cold, .messageUpdated:
                break
            }
        }

        let textA = #"data: {"type":"message.part.delta","properties":{"sessionID":"session","messageID":"message","partID":"text-a","field":"text","delta":"A"}}"#
        let textB = #"data: {"type":"message.part.delta","properties":{"sessionID":"session","messageID":"message","partID":"text-b","field":"text","delta":"B"}}"#
        let running = #"data: {"type":"message.part.updated","properties":{"part":{"id":"tool-part","sessionID":"session","messageID":"message","type":"tool","tool":"bash","state":{"status":"running"}}}}"#
        let completed = #"data: {"type":"message.part.updated","properties":{"part":{"id":"tool-part","sessionID":"session","messageID":"message","type":"tool","tool":"bash","state":{"status":"completed"}}}}"#

        client.receiveDataForTesting(
            session: connection.session,
            task: connection.task,
            data: Data(([textA, textB, running, completed].joined(separator: "\n\n") + "\n\n").utf8)
        )

        try? await Task.sleep(for: .milliseconds(100))

        // Yield through the dispatch queue once more. The continuation queued
        // by the first callback must run after the one ticket batch, but can
        // otherwise lose a scheduling race with this MainActor test task.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }

        // The continuation queued by the first event cannot run until the
        // whole ticket batch has delivered. A cascading per-event delivery
        // would place it between the first and later barriers instead.
        #expect(deliveryOrder == [
            "text-text-a",
            "text-text-b",
            "tool-running",
            "tool-completed",
            "next-main-turn",
        ])
    }

    @MainActor
    @Test func staleSessionCallbacksCannotMutateTheCurrentConnection() async {
        let current = makeActiveSSEConnection()
        let staleSession = URLSession(configuration: .ephemeral)
        let staleTask = staleSession.dataTask(with: URL(string: "http://127.0.0.1:1/event")!)
        var events: [SSEInboundEvent] = []
        current.client.onInboundEvent = { events.append($0) }
        let payload = #"data: {"type":"message.part.delta","properties":{"sessionID":"session","messageID":"message","field":"text","delta":"current"}}"# + "\n\n"

        // A stale data callback is ignored rather than joining the current
        // stream's mailbox.
        current.client.receiveDataForTesting(
            session: staleSession,
            task: staleTask,
            data: Data(payload.utf8)
        )
        try? await Task.sleep(for: .milliseconds(60))
        #expect(events.isEmpty)

        // A stale HTTP response must still complete its URLSession delegate
        // callback, but must not turn off reconnects for the active stream.
        let response = HTTPURLResponse(
            url: URL(string: "http://127.0.0.1:1/event")!,
            statusCode: 401,
            httpVersion: nil,
            headerFields: nil
        )!
        var responseDisposition: URLSession.ResponseDisposition?
        current.client.receiveResponseForTesting(
            session: staleSession,
            task: staleTask,
            response: response
        ) { responseDisposition = $0 }
        #expect(responseDisposition == .cancel)

        // Most importantly, a late completion for A must not clean up the
        // active B connection or schedule a reconnect over it.
        current.client.completeForTesting(session: staleSession, task: staleTask)
        current.client.receiveDataForTesting(
            session: current.session,
            task: current.task,
            data: Data(payload.utf8)
        )
        try? await Task.sleep(for: .milliseconds(80))
        #expect(events.count == 1)
    }

    @MainActor
    @Test func explicitDisconnectInvalidatesPreviouslyQueuedStateCallbacks() async {
        let connection = makeActiveSSEConnection()
        var stateCallbacks: [String] = []
        connection.client.onStateChange = { state in
            switch state {
            case .disconnected:
                stateCallbacks.append("disconnected")
            case .connecting:
                stateCallbacks.append("connecting")
            case .connected:
                stateCallbacks.append("connected")
            }
        }

        connection.client.updateStateForTesting(.connecting)
        connection.client.disconnect()

        try? await Task.sleep(for: .milliseconds(80))

        #expect(stateCallbacks == ["disconnected"])
    }

    @MainActor
    @Test func manualConnectCancelsAnAlreadyScheduledReconnect() {
        let connection = makeActiveSSEConnection()
        var connectionStarts = 0
        connection.client.setConnectionStartHandlerForTesting {
            connectionStarts += 1
        }

        // Completing the active stream schedules the normal backoff retry.
        connection.client.completeForTesting(session: connection.session, task: connection.task)
        #expect(connection.client.hasPendingReconnectForTesting)

        // A user-initiated connect must replace that retry, not leave a second
        // session waiting to start after the backoff delay.
        connection.client.connect()
        #expect(!connection.client.hasPendingReconnectForTesting)
        #expect(connectionStarts == 1)
    }
}
