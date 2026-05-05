import Foundation

#if canImport(Darwin)
import Darwin
#endif

enum OpenLensQRPayloadClientError: LocalizedError {
    case ipDetectionFailed

    var errorDescription: String? {
        switch self {
        case .ipDetectionFailed:
            return "Could not determine the local IP address for the QR code preview."
        }
    }
}

struct OpenLensQRPayloadClient {
    private let defaults: UserDefaults
    private let payloadKey = "OpenLensQRMenubar.lastGeneratedQRPayload"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> OpenLensQRPayloadModel? {
        guard let data = defaults.data(forKey: payloadKey) else {
            return nil
        }

        return try? JSONDecoder().decode(OpenLensQRPayloadModel.self, from: data)
    }

    @discardableResult
    func generateAndSave(port: Int = 4096, username: String = "opencode") throws -> OpenLensQRPayloadModel {
        guard let ipAddress = detectLocalIP() else {
            throw OpenLensQRPayloadClientError.ipDetectionFailed
        }

        let serverURL = "\(ipAddress):\(port)"
        let payload = OpenLensQRPayloadModel(
            deepLink: buildDeepLink(serverURL: serverURL, username: username),
            serverURL: serverURL,
            username: username,
            generatedAt: Date()
        )

        if let data = try? JSONEncoder().encode(payload) {
            defaults.set(data, forKey: payloadKey)
        }

        return payload
    }

    private func buildDeepLink(serverURL: String, username: String) -> String {
        var components = URLComponents()
        components.scheme = "openlens"
        components.host = "connect"
        components.queryItems = [
            URLQueryItem(name: "url", value: serverURL),
            URLQueryItem(name: "user", value: username),
            URLQueryItem(name: "pass", value: ""),
        ]

        return components.url?.absoluteString ?? "openlens://connect?url=\(serverURL)"
    }

    private func detectLocalIP() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddress = ifaddr else {
            return nil
        }

        defer { freeifaddrs(ifaddr) }

        var candidates: [(name: String, ip: String)] = []
        var current = firstAddress

        while true {
            let address = current.pointee

            guard address.ifa_addr?.pointee.sa_family == UInt8(AF_INET) else {
                guard let next = address.ifa_next else {
                    break
                }
                current = next
                continue
            }

            let flags = Int32(address.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else {
                guard let next = address.ifa_next else {
                    break
                }
                current = next
                continue
            }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                address.ifa_addr,
                socklen_t(address.ifa_addr!.pointee.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            )

            if result == 0 {
                let ipAddress = String(cString: hostname)
                let name = String(cString: address.ifa_name)
                if !ipAddress.hasPrefix("169.254.") {
                    candidates.append((name: name, ip: ipAddress))
                }
            }

            guard let next = address.ifa_next else {
                break
            }
            current = next
        }

        if let en0 = candidates.first(where: { $0.name == "en0" }) { return en0.ip }
        if let en1 = candidates.first(where: { $0.name == "en1" }) { return en1.ip }
        if let en = candidates.first(where: { $0.name.hasPrefix("en") }) { return en.ip }

        return candidates.first?.ip
    }
}
