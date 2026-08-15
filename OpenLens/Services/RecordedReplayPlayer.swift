import Foundation

/// Immutable replay timing paired with its worker-prepared payload. Defining
/// this outside the main-actor player keeps the expensive preparation phase
/// entirely off the UI executor.
nonisolated private struct PreparedReplayEvent {
    let offset: TimeInterval
    let inboundEvent: SSEInboundEvent
}

@MainActor
final class RecordedReplayPlayer {
    enum PlaybackMode: String, Codable, Hashable, Sendable {
        case realtime
        case fast

        var displayName: String {
            switch self {
            case .realtime:
                "Realtime"
            case .fast:
                "Fast"
            }
        }

        func adjustedDelay(for rawDelay: TimeInterval) -> TimeInterval {
            let normalized = max(rawDelay, 0)

            switch self {
            case .realtime:
                return normalized
            case .fast:
                return min(normalized, 0.03)
            }
        }
    }

    private let eventHandler: SSEEventHandler
    private var playTask: Task<Void, Never>?

    init(eventHandler: SSEEventHandler) {
        self.eventHandler = eventHandler
    }

    func play(_ replay: RecordedChatReplay, mode: PlaybackMode = .realtime) {
        stop()

        playTask = Task { [weak self] in
            guard let self else { return }
            defer { self.playTask = nil }

            // Prepare the complete capture in one worker task. Per-event
            // detached tasks made fast replay scheduling depend on executor
            // contention and could delay an otherwise immediate capture.
            let preparedEvents = await Task.detached(priority: .userInitiated) {
                replay.events.map { envelope in
                    PreparedReplayEvent(
                        offset: envelope.offset,
                        inboundEvent: SSEInboundEvent.prepare(envelope.event) ?? .raw(envelope.event)
                    )
                }
            }.value
            guard !Task.isCancelled else { return }

            var previousOffset: TimeInterval = 0
            for preparedEvent in preparedEvents {
                guard !Task.isCancelled else { return }

                let delay = mode.adjustedDelay(for: preparedEvent.offset - previousOffset)
                if delay > 0 {
                    try? await Task.sleep(for: .seconds(delay))
                }

                guard !Task.isCancelled else { return }
                eventHandler.handleInboundEvent(preparedEvent.inboundEvent)

                // A capture can contain many equal or near-equal offsets. In
                // that case there is no URLSession producer to suspend, so
                // wait for ChatClient's bounded render ring before advancing
                // to the next ordered event.
                guard await eventHandler.waitForStreamingRenderCapacity(),
                      !Task.isCancelled
                else { return }
                previousOffset = preparedEvent.offset
            }
        }
    }

    func stop() {
        playTask?.cancel()
        playTask = nil
    }
}
