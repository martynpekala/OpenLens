import Testing
@testable import OpenLens

/// Synchronous convenience for focused handler tests. Production intentionally
/// has no raw-event entry point: live SSE and recorded replay must prepare
/// payloads off MainActor before invoking the handler.
@MainActor
extension SSEEventHandler {
    func handleEvent(_ event: OCEvent) {
        handleInboundEvent(SSEInboundEvent.prepare(event) ?? .raw(event))
    }
}
