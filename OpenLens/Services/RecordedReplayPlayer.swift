import Foundation

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

            var previousOffset: TimeInterval = 0
            for envelope in replay.events {
                guard !Task.isCancelled else { return }

                let delay = mode.adjustedDelay(for: envelope.offset - previousOffset)
                if delay > 0 {
                    try? await Task.sleep(for: .seconds(delay))
                }

                guard !Task.isCancelled else { return }
                eventHandler.handleEvent(envelope.event)
                previousOffset = envelope.offset
            }
        }
    }

    func stop() {
        playTask?.cancel()
        playTask = nil
    }
}
