import Foundation
import Testing
@testable import OpenLens

struct ChatStreamRecorderTests {

    @Test func recordsOnlyTheActiveSessionAndAutoStopsWhenItReturnsIdle() {
        let startDate = Date(timeIntervalSince1970: 1_730_100_000)
        var recorder = ChatStreamRecorder(
            sessionID: "session-recorder-test",
            sessionTitle: "Recorder Test",
            projectName: "OpenLens",
            branch: "main",
            startedAt: startDate
        )

        #expect(recorder.record(OCEvent(type: "server.heartbeat", properties: nil), now: startDate.addingTimeInterval(0.1)) == nil)
        #expect(recorder.record(sessionStatusEvent(sessionID: "other-session", status: .busy), now: startDate.addingTimeInterval(0.2)) == nil)
        #expect(recorder.record(sessionStatusEvent(sessionID: "session-recorder-test", status: .busy), now: startDate.addingTimeInterval(0.5)) == nil)

        let completion = recorder.record(
            sessionStatusEvent(sessionID: "session-recorder-test", status: .idle),
            now: startDate.addingTimeInterval(1.0)
        )

        guard case .saved(let replay)? = completion else {
            Issue.record("Expected the recorder to finish with a saved replay.")
            return
        }

        #expect(replay.sessionID == "session-recorder-test")
        #expect(replay.eventCount == 2)
        #expect(replay.events.map(\.event.type) == ["session.status", "session.status"])
        #expect(replay.duration == 1.0)
    }

    @Test func discardsManualStopsWhenNoTurnStarted() {
        let startDate = Date(timeIntervalSince1970: 1_730_100_100)
        let recorder = ChatStreamRecorder(
            sessionID: "session-recorder-test",
            sessionTitle: "Recorder Test",
            projectName: "OpenLens",
            branch: "main",
            startedAt: startDate
        )

        let completion = recorder.stop()

        guard case .discardedEmpty = completion else {
            Issue.record("Expected the recorder to discard an empty capture.")
            return
        }
    }

    private func sessionStatusEvent(sessionID: String, status: OCSessionStatusType) -> OCEvent {
        OCEvent(
            type: "session.status",
            properties: AnyCodable([
                "sessionID": sessionID,
                "status": ["type": status.rawValue]
            ])
        )
    }
}
