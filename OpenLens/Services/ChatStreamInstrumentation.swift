import Foundation
import os

enum ChatStreamInstrumentation {
    private static let log = OSLog(
        subsystem: Bundle.main.bundleIdentifier ?? "com.openlens",
        category: "ChatStream"
    )

    static func recordSSEReceive(byteCount: Int) {
        os_signpost(.event, log: log, name: "SSE Receive", "bytes %d", byteCount)
    }

    static func beginSSEDecode(byteCount: Int) -> OSSignpostID {
        let signpostID = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: "SSE Decode", signpostID: signpostID, "bytes %d", byteCount)
        return signpostID
    }

    static func endSSEDecode(_ signpostID: OSSignpostID) {
        os_signpost(.end, log: log, name: "SSE Decode", signpostID: signpostID)
    }

    static func recordCoalescedTextDelta(characterCount: Int) {
        os_signpost(.event, log: log, name: "SSE Text Delta Batch", "chars %d", characterCount)
    }

    /// The UI flush consumes a fixed number of pre-chunked strings. Counting
    /// the characters here would itself walk an untrusted payload on MainActor,
    /// so the trace records the bounded work unit instead.
    static func beginStreamingFlush(chunkCount: Int) -> OSSignpostID {
        let signpostID = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: "Streaming Flush", signpostID: signpostID, "chunks %d", chunkCount)
        return signpostID
    }

    static func endStreamingFlush(_ signpostID: OSSignpostID) {
        os_signpost(.end, log: log, name: "Streaming Flush", signpostID: signpostID)
    }

    static func recordScrollToBottom() {
        os_signpost(.event, log: log, name: "Scroll To Bottom")
    }

    static func beginMarkdownPrewarm(characterCount: Int) -> OSSignpostID {
        let signpostID = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: "Markdown Prewarm", signpostID: signpostID, "chars %d", characterCount)
        return signpostID
    }

    static func endMarkdownPrewarm(_ signpostID: OSSignpostID) {
        os_signpost(.end, log: log, name: "Markdown Prewarm", signpostID: signpostID)
    }
}
