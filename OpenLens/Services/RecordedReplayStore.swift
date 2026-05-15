import Foundation
import os

final class RecordedReplayStore {
    enum StoreError: LocalizedError {
        case applicationSupportUnavailable
        case invalidReplayIdentifier
        case replayNotFound(String)
        case failedToLoadCaptures(Int)

        var errorDescription: String? {
            switch self {
            case .applicationSupportUnavailable:
                "Application Support is unavailable for recorded captures."
            case .invalidReplayIdentifier:
                "The recorded capture identifier is invalid."
            case .replayNotFound(let id):
                "The recorded capture “\(id)” could not be found."
            case .failedToLoadCaptures(let count):
                "Failed to load \(count) recorded capture\(count == 1 ? "" : "s")."
            }
        }
    }

    private let fileManager: FileManager
    private let baseDirectoryURL: URL?

    init(fileManager: FileManager = .default, baseDirectoryURL: URL? = nil) {
        self.fileManager = fileManager
        self.baseDirectoryURL = baseDirectoryURL
    }

    func saveReplay(_ replay: RecordedChatReplay) throws -> RecordedChatReplay.Descriptor {
        let url = try replayURL(id: replay.id, createDirectoryIfNeeded: true)
        let data = try Self.makeEncoder().encode(replay)
        try data.write(to: url, options: .atomic)
        return replay.descriptor
    }

    func listReplays() throws -> [RecordedChatReplay.Descriptor] {
        let directory = try storageDirectoryURL(createIfNeeded: false)
        guard fileManager.fileExists(atPath: directory.path) else { return [] }

        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension.lowercased() == "json" }

        var descriptors: [RecordedChatReplay.Descriptor] = []
        var failedCount = 0
        let decoder = Self.makeDecoder()

        for url in urls {
            do {
                let data = try Data(contentsOf: url)
                let descriptor = try decoder.decode(RecordedChatReplay.Descriptor.self, from: data)
                descriptors.append(descriptor)
            } catch {
                failedCount += 1
                Logger.chat.warning("Failed to decode recorded replay descriptor at \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        if descriptors.isEmpty, failedCount > 0 {
            throw StoreError.failedToLoadCaptures(failedCount)
        }

        return descriptors.sorted { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.id.localizedCaseInsensitiveCompare(rhs.id) == .orderedAscending
            }
            return lhs.createdAt > rhs.createdAt
        }
    }

    func loadReplay(id: String) throws -> RecordedChatReplay {
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else {
            throw StoreError.invalidReplayIdentifier
        }

        let url = try replayURL(id: trimmedID, createDirectoryIfNeeded: false)
        guard fileManager.fileExists(atPath: url.path) else {
            throw StoreError.replayNotFound(trimmedID)
        }

        let data = try Data(contentsOf: url)
        return try Self.makeDecoder().decode(RecordedChatReplay.self, from: data)
    }

    func loadReplay(_ descriptor: RecordedChatReplay.Descriptor) throws -> RecordedChatReplay {
        try loadReplay(id: descriptor.id)
    }

    func deleteReplay(id: String) throws {
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else {
            throw StoreError.invalidReplayIdentifier
        }

        let url = try replayURL(id: trimmedID, createDirectoryIfNeeded: false)
        guard fileManager.fileExists(atPath: url.path) else {
            throw StoreError.replayNotFound(trimmedID)
        }

        try fileManager.removeItem(at: url)
    }

    func deleteReplay(_ descriptor: RecordedChatReplay.Descriptor) throws {
        try deleteReplay(id: descriptor.id)
    }

    private func replayURL(id: String, createDirectoryIfNeeded: Bool) throws -> URL {
        let directory = try storageDirectoryURL(createIfNeeded: createDirectoryIfNeeded)
        return directory.appendingPathComponent(id).appendingPathExtension("json")
    }

    private func storageDirectoryURL(createIfNeeded: Bool) throws -> URL {
        let directory: URL
        if let baseDirectoryURL {
            directory = baseDirectoryURL
        } else {
            guard let applicationSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                throw StoreError.applicationSupportUnavailable
            }
            directory = applicationSupportURL.appendingPathComponent("ChatReplays", isDirectory: true)
        }

        if createIfNeeded {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        return directory
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
