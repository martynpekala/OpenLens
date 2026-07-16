import Foundation
import Security
import ServiceManagement

final class OpenCodeProcess: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.openlens.remote.opencode")
    private var process: Process?
    private var shouldRun = false
    private var restartAttempt = 0
    private var workspaceURL: URL?
    var onRunningChange: (@Sendable (Bool) -> Void)?
    var onError: (@Sendable (Error) -> Void)?

    let password: String

    init() throws {
        if let data = AgentKeychain.load(account: "opencode_password_v1"),
           let value = String(data: data, encoding: .utf8) {
            password = value
        } else {
            var bytes = Data(count: 32)
            let status = bytes.withUnsafeMutableBytes { buffer in
                SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
            }
            guard status == errSecSuccess else { throw RemoteAgentError.keychainFailure }
            let value = bytes.base64EncodedString()
            guard AgentKeychain.save(Data(value.utf8), account: "opencode_password_v1") else {
                throw RemoteAgentError.keychainFailure
            }
            password = value
        }
    }

    func start(workspaceURL: URL?) {
        queue.async { [self] in
            self.workspaceURL = workspaceURL
            shouldRun = true
            launchIfNeeded()
        }
    }

    func stop() {
        queue.async { [self] in
            shouldRun = false
            process?.terminationHandler = nil
            process?.terminate()
            process = nil
            restartAttempt = 0
            notify(false)
        }
    }

    private func launchIfNeeded() {
        guard shouldRun, process?.isRunning != true else { return }
        do {
            let executable = try Self.executableURL()
            let process = Process()
            process.executableURL = executable
            process.arguments = [
                "serve",
                "--port", String(RemoteProtocolVersion.openCodePort),
                "--hostname", "127.0.0.1",
            ]
            process.currentDirectoryURL = workspaceURL ?? FileManager.default.homeDirectoryForCurrentUser
            var environment = ProcessInfo.processInfo.environment
            environment["OPENCODE_SERVER_USERNAME"] = "opencode"
            environment["OPENCODE_SERVER_PASSWORD"] = password
            process.environment = environment
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { [weak self] _ in
                self?.queue.async { self?.processTerminated() }
            }
            try process.run()
            self.process = process
            restartAttempt = 0
            notify(true)
        } catch {
            notify(false)
            notifyError(error)
            scheduleRestart()
        }
    }

    private func processTerminated() {
        process = nil
        notify(false)
        scheduleRestart()
    }

    private func scheduleRestart() {
        guard shouldRun else { return }
        restartAttempt += 1
        let delay = min(pow(2, Double(restartAttempt - 1)), 30)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.launchIfNeeded()
        }
    }

    private func notify(_ running: Bool) {
        let callback = onRunningChange
        DispatchQueue.main.async { callback?(running) }
    }

    private func notifyError(_ error: Error) {
        let callback = onError
        DispatchQueue.main.async { callback?(error) }
    }

    private static func executableURL() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        let candidates = [
            environment["OPENCODE_PATH"],
            "/opt/homebrew/bin/opencode",
            "/usr/local/bin/opencode",
            "/usr/bin/opencode",
        ].compactMap { $0 }
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw RemoteAgentError.openCodeNotFound
        }
        return URL(fileURLWithPath: path)
    }
}

final class TunnelRunner: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.openlens.remote.cloudflared")
    private var process: Process?
    private var shouldRun = false
    private var restartAttempt = 0
    private var connectorToken: String?
    private var tokenFileURL: URL?
    var onRunningChange: (@Sendable (Bool) -> Void)?
    var onError: (@Sendable (Error) -> Void)?

    func start(connectorToken: String) {
        queue.async { [self] in
            self.connectorToken = connectorToken
            shouldRun = true
            launchIfNeeded()
        }
    }

    func stop() {
        queue.async { [self] in
            shouldRun = false
            connectorToken = nil
            process?.terminationHandler = nil
            process?.terminate()
            process = nil
            removeTokenFile()
            restartAttempt = 0
            notify(false)
        }
    }

    private func launchIfNeeded() {
        guard shouldRun, process?.isRunning != true, let connectorToken else { return }
        do {
            let tokenFileURL = try makeTokenFile(containing: connectorToken)
            let process = Process()
            process.executableURL = try Self.executableURL()
            process.arguments = ["tunnel", "run", "--token-file", tokenFileURL.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { [weak self] _ in
                self?.queue.async { self?.processTerminated() }
            }
            try process.run()
            self.process = process
            self.tokenFileURL = tokenFileURL
            restartAttempt = 0
            notify(true)
        } catch {
            removeTokenFile()
            notify(false)
            notifyError(error)
            scheduleRestart()
        }
    }

    private func processTerminated() {
        process = nil
        removeTokenFile()
        notify(false)
        scheduleRestart()
    }

    private func scheduleRestart() {
        guard shouldRun else { return }
        restartAttempt += 1
        let delay = min(pow(2, Double(restartAttempt - 1)), 30)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.launchIfNeeded()
        }
    }

    private func notify(_ running: Bool) {
        let callback = onRunningChange
        DispatchQueue.main.async { callback?(running) }
    }

    private func notifyError(_ error: Error) {
        let callback = onError
        DispatchQueue.main.async { callback?(error) }
    }

    private func makeTokenFile(containing token: String) throws -> URL {
        removeTokenFile()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("openlens-cloudflared-\(UUID().uuidString).token")
        do {
            try Data(token.utf8).write(to: url, options: [.atomic, .withoutOverwriting])
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: url.path
            )
            tokenFileURL = url
            return url
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw RemoteAgentError.tokenFileFailure
        }
    }

    private func removeTokenFile() {
        guard let tokenFileURL else { return }
        try? FileManager.default.removeItem(at: tokenFileURL)
        self.tokenFileURL = nil
    }

    private static func executableURL(bundle: Bundle = .main) throws -> URL {
        let architecture = ProcessInfo.processInfo.machineArchitecture
        if let bundled = bundle.url(forResource: "cloudflared-\(architecture)", withExtension: nil),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
#if DEBUG
        let developmentCandidates = [
            "/opt/homebrew/bin/cloudflared",
            "/usr/local/bin/cloudflared",
        ]
        if let path = developmentCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: path)
        }
#endif
        throw RemoteAgentError.cloudflaredNotBundled
    }
}

enum RemoteAgentLifecycle {
    static var launchesAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setLaunchesAtLogin(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } else if SMAppService.mainApp.status == .enabled {
            try SMAppService.mainApp.unregister()
        }
    }
}

private extension ProcessInfo {
    var machineArchitecture: String {
#if arch(arm64)
        "arm64"
#elseif arch(x86_64)
        "amd64"
#else
        "unsupported"
#endif
    }
}
