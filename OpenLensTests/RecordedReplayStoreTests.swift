import Foundation
import Testing
@testable import OpenLens

struct RecordedReplayStoreTests {

    @Test func savesListsLoadsAndDeletesRecordedReplays() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let store = RecordedReplayStore(baseDirectoryURL: directoryURL)
        let replay = RecordedChatReplay(
            sessionID: "session-store-test",
            sessionTitle: "Recorded Store Test",
            projectName: "OpenLens",
            branch: "main",
            createdAt: Date(timeIntervalSince1970: 1_730_000_000),
            events: [
                .init(id: 0, offset: 0, event: sessionStatusEvent(sessionID: "session-store-test", status: .busy)),
                .init(id: 1, offset: 0.25, event: sessionStatusEvent(sessionID: "session-store-test", status: .idle))
            ]
        )

        let savedDescriptor = try store.saveReplay(replay)
        let listedDescriptors = try store.listReplays()
        let loadedReplay = try store.loadReplay(savedDescriptor)

        #expect(savedDescriptor.id == replay.id)
        #expect(savedDescriptor.eventCount == 2)
        #expect(listedDescriptors == [savedDescriptor])
        #expect(loadedReplay.sessionTitle == "Recorded Store Test")
        #expect(loadedReplay.events.count == 2)

        let exportedReplay = try decodeExportedReplay(try store.exportReplay(savedDescriptor))
        #expect(exportedReplay.id == replay.id)
        #expect(exportedReplay.events.count == 2)

        try store.deleteReplay(savedDescriptor)

        #expect(try store.listReplays().isEmpty)
    }

    @Test func exportsRecordedReplayAsJSONFile() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let store = RecordedReplayStore(baseDirectoryURL: directoryURL)
        let replay = RecordedChatReplay(
            sessionID: "session-export-test",
            sessionTitle: "Export Test",
            projectName: "OpenLens",
            branch: "capture-export",
            createdAt: Date(timeIntervalSince1970: 1_730_000_100),
            events: [
                .init(id: 0, offset: 0, event: sessionStatusEvent(sessionID: "session-export-test", status: .busy)),
                .init(id: 1, offset: 0.5, event: sessionStatusEvent(sessionID: "session-export-test", status: .idle))
            ]
        )

        let descriptor = try store.saveReplay(replay)
        let export = try store.exportReplay(descriptor)
        let exportedReplay = try decodeExportedReplay(export)

        #expect(export.filename == "\(replay.id).json")
        #expect(exportedReplay.sessionID == "session-export-test")
        #expect(exportedReplay.branch == "capture-export")
        #expect(exportedReplay.events.map(\.offset) == [0, 0.5])
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

    private func decodeExportedReplay(_ export: RecordedReplayExport) throws -> RecordedChatReplay {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RecordedChatReplay.self, from: export.data)
    }
}
