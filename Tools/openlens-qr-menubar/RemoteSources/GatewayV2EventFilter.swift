import Foundation

/// Frames the global v2 stream before forwarding any bytes to a paired client.
/// Only complete, bounded records with an approved canonical location escape.
final class GatewayV2EventFilter {
    private let registry: WorkspaceRegistry
    private var line = Data()
    private var lines: [String] = []
    private var recordBytes = 0
    private var afterCR = false

    init(registry: WorkspaceRegistry) { self.registry = registry }

    func append(_ bytes: Data) throws -> [Data] {
        var output: [Data] = []
        for byte in bytes {
            if afterCR {
                afterCR = false
                if byte == 10 { continue }
            }
            recordBytes += 1
            guard recordBytes <= RemoteProtocolVersion.maximumWireMessageBytes else {
                throw RemoteProtocolError.messageTooLarge
            }
            if byte == 10 || byte == 13 {
                afterCR = byte == 13
                guard let text = String(data: line, encoding: .utf8) else { throw RemoteProtocolError.invalidRequest }
                line.removeAll(keepingCapacity: true)
                if text.isEmpty {
                    if let event = try filteredRecord() { output.append(event) }
                    lines.removeAll(keepingCapacity: true)
                    recordBytes = 0
                } else {
                    lines.append(text)
                }
            } else {
                line.append(byte)
            }
        }
        return output
    }

    private func filteredRecord() throws -> Data? {
        let data = lines.compactMap { line -> String? in
            guard line.hasPrefix("data:") else { return nil }
            let value = line.dropFirst(5)
            return String(value.first == " " ? value.dropFirst() : value)
        }.joined(separator: "\n")
        guard !data.isEmpty else { return nil }
        var value = try JSONSerialization.jsonObject(with: Data(data.utf8), options: .fragmentsAllowed)
        if let encoded = value as? String {
            value = try JSONSerialization.jsonObject(with: Data(encoded.utf8))
        }
        guard let event = value as? [String: Any], let type = event["type"] as? String else {
            throw RemoteProtocolError.invalidRequest
        }
        let safeEvent: [String: Any]
        if type == "server.connected" || type == "server.heartbeat" {
            // Global liveness must not expose server paths or unrelated payloads.
            safeEvent = ["type": type, "data": [:] as [String: String]]
        } else {
            guard let location = event["location"] as? [String: Any],
                  let directory = location["directory"] as? String,
                  registry.isAllowed(directory) else { return nil }
            safeEvent = event
        }
        var output = Data("event: message\ndata: ".utf8)
        output.append(try JSONSerialization.data(withJSONObject: safeEvent))
        output.append(Data("\n\n".utf8))
        return output
    }
}
