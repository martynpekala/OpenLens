import Foundation

enum OpenLensQRLaunchClientError: LocalizedError {
    case packageNotFound
    case scriptCreationFailed
    case terminalLaunchFailed(String)

    var errorDescription: String? {
        switch self {
        case .packageNotFound:
            return "Could not locate Tools/openlens-qr. Rebuild the app from this repository checkout or set OPENLENS_QR_PACKAGE_PATH."
        case .scriptCreationFailed:
            return "The app could not prepare the launch script for your default terminal app."
        case let .terminalLaunchFailed(details):
            return details.isEmpty ? "The app could not open your default terminal app." : details
        }
    }
}

struct OpenLensQRLaunchClient {
    private let bundle: Bundle
    private let fileManager: FileManager

    init(bundle: Bundle = .main, fileManager: FileManager = .default) {
        self.bundle = bundle
        self.fileManager = fileManager
    }

    func packageURL() throws -> URL {
        for candidateURL in packageCandidates() {
            if isValidPackageDirectory(candidateURL) {
                return candidateURL
            }
        }

        throw OpenLensQRLaunchClientError.packageNotFound
    }

    func launch(packageURL: URL, workingDirectory: URL) throws {
        let scriptURL = try writeLaunchScript(packageURL: packageURL, workingDirectory: workingDirectory)

        let process = Process()
        let outputPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [scriptURL.path]
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw OpenLensQRLaunchClientError.terminalLaunchFailed(message)
        }
    }

    private func packageCandidates() -> [URL] {
        var candidates: [URL] = []
        var seenPaths = Set<String>()

        func appendCandidate(path: String) {
            guard !path.isEmpty else {
                return
            }

            let normalizedPath = URL(fileURLWithPath: path, isDirectory: true)
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .path

            guard seenPaths.insert(normalizedPath).inserted else {
                return
            }

            candidates.append(URL(fileURLWithPath: normalizedPath, isDirectory: true))
        }

        if let configuredPath = ProcessInfo.processInfo.environment["OPENLENS_QR_PACKAGE_PATH"], !configuredPath.isEmpty {
            appendCandidate(path: configuredPath)
        }

        if let configuredPath = bundle.object(forInfoDictionaryKey: "OpenLensQRPackagePath") as? String, !configuredPath.isEmpty {
            appendCandidate(path: configuredPath)
        }

        var currentPath = bundle.bundleURL.resolvingSymlinksInPath().deletingLastPathComponent().path
        for _ in 0..<16 {
            appendCandidate(path: (currentPath as NSString).appendingPathComponent("Tools/openlens-qr"))

            let parentPath = (currentPath as NSString).deletingLastPathComponent
            if parentPath.isEmpty || parentPath == currentPath {
                break
            }

            currentPath = parentPath
        }

        return candidates
    }

    private func isValidPackageDirectory(_ url: URL) -> Bool {
        let packageManifestURL = url.appendingPathComponent("Package.swift")
        return fileManager.fileExists(atPath: packageManifestURL.path)
    }

    private func buildShellCommand(packageURL: URL, workingDirectory: URL) -> String {
        let packagePath = escapeForShell(packageURL.path)
        let workingPath = escapeForShell(workingDirectory.path)

        return [
            "cd \(packagePath)",
            "xcrun swift build -c release",
            "BIN_DIR=\"$(xcrun swift build -c release --show-bin-path)\"",
            "cd \(workingPath)",
            "\"$BIN_DIR/openlens-qr\" --serve",
        ].joined(separator: " && ")
    }

    private func writeLaunchScript(packageURL: URL, workingDirectory: URL) throws -> URL {
        let scriptDirectoryURL = fileManager.temporaryDirectory.appendingPathComponent("openlens-qr-menubar-launch", isDirectory: true)
        try fileManager.createDirectory(at: scriptDirectoryURL, withIntermediateDirectories: true)

        let scriptURL = scriptDirectoryURL.appendingPathComponent("launch-openlens-qr.command")
        let scriptContents = [
            "#!/bin/zsh",
            "set -euo pipefail",
            buildShellCommand(packageURL: packageURL, workingDirectory: workingDirectory),
        ].joined(separator: "\n") + "\n"

        guard let scriptData = scriptContents.data(using: .utf8) else {
            throw OpenLensQRLaunchClientError.scriptCreationFailed
        }

        try scriptData.write(to: scriptURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    private func escapeForShell(_ string: String) -> String {
        "'\(string.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }
}
