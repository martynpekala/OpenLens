import Foundation
import Network

/// Discovers OpenCode servers on the local network using Bonjour/mDNS.
/// OpenCode publishes as `_http._tcp.` with name `opencode-<port>`.
@MainActor @Observable
final class BonjourDiscovery {
    var discoveredServers: [DiscoveredServer] = []
    var isSearching: Bool = false
    var lastErrorMessage: String?
    private(set) var hasSearched: Bool = false

    private var browser: NWBrowser?
    private var stopWorkItem: DispatchWorkItem?

    struct DiscoveredServer: Identifiable, Hashable, Sendable {
        let id: String
        let name: String
        let host: String
        let port: Int

        var url: String {
            let hostForURL: String
            if host.contains(":") {
                let escapedScope = host.replacingOccurrences(of: "%", with: "%25")
                hostForURL = "[\(escapedScope)]"
            } else {
                hostForURL = host
            }
            return "http://\(hostForURL):\(port)"
        }
    }

    func startBrowsing() {
        // Cancel any previously scheduled auto-stop so a rapid restart
        // is not killed by a stale callback from the previous scan.
        stopWorkItem?.cancel()
        stopWorkItem = nil

        // If already searching, tear down the old browser first
        if isSearching {
            browser?.cancel()
            browser = nil
        }

        hasSearched = true
        isSearching = true
        discoveredServers = []
        lastErrorMessage = nil

        let params = NWParameters()
        params.includePeerToPeer = true

        let browser = NWBrowser(for: .bonjour(type: "_http._tcp.", domain: "local."), using: params)

        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    self?.isSearching = true
                case .failed(let error):
                    self?.lastErrorMessage = "mDNS discovery failed: \(error.localizedDescription)"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                        self?.isSearching = false
                    }
                case .cancelled:
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                        self?.isSearching = false
                    }
                default:
                    break
                }
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                self?.handleResults(results)
            }
        }

        browser.start(queue: .main)
        self.browser = browser

        // Auto-stop after 10 seconds (cancellable on restart)
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.stopBrowsing()
            }
        }
        stopWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
    }

    func stopBrowsing() {
        stopWorkItem?.cancel()
        stopWorkItem = nil
        browser?.cancel()
        browser = nil
        isSearching = false
    }

    private func handleResults(_ results: Set<NWBrowser.Result>) {
        for result in results {
            if case .service(let name, let type, let domain, _) = result.endpoint {
                // Only care about opencode services
                guard name.localizedCaseInsensitiveContains("opencode") else { continue }

                // Resolve the service to get host/port
                resolveService(name: name, type: type, domain: domain)
            }
        }
    }

    private func resolveService(name: String, type: String, domain: String) {
        let connection = NWConnection(
            to: .service(name: name, type: type, domain: domain, interface: nil),
            using: .tcp
        )

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if let endpoint = connection.currentPath?.remoteEndpoint,
                   case .hostPort(let host, let port) = endpoint
                {
                    let hostStr: String
                    switch host {
                    case .ipv4(let addr):
                        hostStr = "\(addr)"
                    case .ipv6(let addr):
                        hostStr = "\(addr)"
                    case .name(let name, _):
                        hostStr = name
                    @unknown default:
                        hostStr = "\(host)"
                    }

                    let server = DiscoveredServer(
                        id: name,
                        name: name,
                        host: Self.sanitizeHost(hostStr),
                        port: Int(port.rawValue)
                    )

                    Task { @MainActor in
                        if !(self?.discoveredServers.contains(where: { $0.id == server.id }) ?? true) {
                            self?.discoveredServers.append(server)
                        }
                    }
                }
                connection.cancel()

            case .failed, .cancelled, .waiting:
                // Cancel the connection to prevent leaks in non-ready states
                connection.cancel()

            default:
                break
            }
        }

        connection.start(queue: .global())
    }

    nonisolated private static func sanitizeHost(_ host: String) -> String {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)

        if let percentIndex = trimmed.firstIndex(of: "%") {
            let prefix = String(trimmed[..<percentIndex])
            if isIPv4Address(prefix) {
                return prefix
            }
        }

        return trimmed
    }

    nonisolated private static func isIPv4Address(_ value: String) -> Bool {
        let parts = value.split(separator: ".")
        guard parts.count == 4 else { return false }

        for part in parts {
            guard let octet = Int(part), (0...255).contains(octet) else {
                return false
            }
        }

        return true
    }
}
