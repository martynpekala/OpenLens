import Foundation
import CoreImage

#if canImport(Darwin)
import Darwin
#endif

// MARK: - Argument Parsing

struct Config {
    var serverURL: String = ""
    var username: String = "opencode"
    var password: String = ""
    var port: Int = 4096
    var serve: Bool = false
    var printSecretLink: Bool = false
}

func parseArguments() -> Config? {
    let args = CommandLine.arguments.dropFirst()
    var config = Config(password: ProcessInfo.processInfo.environment["OPENLENS_QR_PASSWORD"] ?? "")
    var positionalConsumed = false
    var iterator = args.makeIterator()

    while let arg = iterator.next() {
        switch arg {
        case "--user", "-u":
            guard let val = iterator.next() else {
                printError("Missing value for \(arg)")
                return nil
            }
            config.username = val
        case "--port":
            guard let val = iterator.next(), let port = Int(val) else {
                printError("Missing or invalid value for \(arg)")
                return nil
            }
            config.port = port
        case "--serve", "-s":
            config.serve = true
        case "--print-secret-link":
            config.printSecretLink = true
        case "--help", "-h":
            printUsage()
            exit(0)
        default:
            if arg.hasPrefix("-") {
                printError("Unknown option: \(arg)")
                return nil
            }
            if positionalConsumed {
                printError("Unexpected argument: \(arg)")
                return nil
            }
            config.serverURL = arg
            positionalConsumed = true
        }
    }

    // If no URL provided, auto-detect local IP
    if config.serverURL.isEmpty {
        guard let ip = detectLocalIP() else {
            printError("Could not detect local IP address. Please provide a server URL manually.")
            printUsage()
            return nil
        }
        config.serverURL = "\(ip):\(config.port)"
        printInfo("Auto-detected IP: \(ip)")
    }

    return config
}

func printUsage() {
    let usage = """
    Usage: openlens-qr [server-url] [options]

    Generate a QR code for quick OpenLens iOS app connection setup.
    If no server URL is given, your local IP is detected automatically.

    Arguments:
      [server-url]          Server address (e.g. 192.168.1.50:4096)
                            Optional — auto-detected if omitted

    Options:
      --serve, -s           Start OpenCode server, show QR when ready, then open TUI
      --port <number>       Port when using auto-detected IP (default: 4096)
      --user, -u <name>     Username (default: opencode)
      --print-secret-link   Print the full deep link, including password if set
      --help, -h            Show this help

    Environment:
      OPENLENS_QR_PASSWORD  Optional password included in the QR deep link
                            and used for serve mode

    Examples:
      openlens-qr                              # auto-detect IP, show QR only
      openlens-qr --serve                      # show QR + start OpenCode server & TUI
      OPENLENS_QR_PASSWORD=secret openlens-qr --serve
      OPENLENS_QR_PASSWORD=secret openlens-qr --print-secret-link
      openlens-qr --serve --port 3000          # QR + server on custom port
      openlens-qr 192.168.1.50:4096            # explicit address, QR only
    """
    print(usage)
}

func printError(_ message: String) {
    FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
}

func printInfo(_ message: String) {
    print("  \(message)")
}

// MARK: - Local IP Detection

func detectLocalIP() -> String? {
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
    defer { freeifaddrs(ifaddr) }

    var candidates: [(name: String, ip: String)] = []

    var current: UnsafeMutablePointer<ifaddrs>? = firstAddr
    while let ifa = current {
        let addr = ifa.pointee
        current = addr.ifa_next

        guard addr.ifa_addr?.pointee.sa_family == UInt8(AF_INET) else { continue }

        let flags = Int32(addr.ifa_flags)
        guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }

        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = getnameinfo(
            addr.ifa_addr, socklen_t(addr.ifa_addr!.pointee.sa_len),
            &hostname, socklen_t(hostname.count),
            nil, 0, NI_NUMERICHOST
        )
        guard result == 0 else { continue }

        let ip = String(cString: hostname)
        let name = String(cString: addr.ifa_name)

        guard !ip.hasPrefix("169.254.") else { continue }

        candidates.append((name: name, ip: ip))
    }

    if let en0 = candidates.first(where: { $0.name == "en0" }) { return en0.ip }
    if let en1 = candidates.first(where: { $0.name == "en1" }) { return en1.ip }
    if let en = candidates.first(where: { $0.name.hasPrefix("en") }) { return en.ip }

    return candidates.first?.ip
}

// MARK: - Deep Link Builder

func buildDeepLink(config: Config) -> String {
    var components = URLComponents()
    components.scheme = "openlens"
    components.host = "connect"
    components.queryItems = [
        URLQueryItem(name: "url", value: config.serverURL),
        URLQueryItem(name: "user", value: config.username),
        URLQueryItem(name: "pass", value: config.password),
    ]
    return components.url?.absoluteString ?? "openlens://connect?url=\(config.serverURL)"
}

func buildDisplayDeepLink(config: Config) -> String {
    guard !config.password.isEmpty else {
        return buildDeepLink(config: config)
    }

    var components = URLComponents()
    components.scheme = "openlens"
    components.host = "connect"
    components.queryItems = [
        URLQueryItem(name: "url", value: config.serverURL),
        URLQueryItem(name: "user", value: config.username),
        URLQueryItem(name: "pass", value: "****"),
    ]

    return components.url?.absoluteString ?? "openlens://connect?url=\(config.serverURL)"
}

// MARK: - QR Code Generation via CoreImage

func generateQRBitmap(from string: String) -> [[Bool]]? {
    guard let data = string.data(using: .utf8),
          let filter = CIFilter(name: "CIQRCodeGenerator") else {
        return nil
    }

    filter.setValue(data, forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")

    guard let ciImage = filter.outputImage else { return nil }

    let context = CIContext()
    guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }

    let width = cgImage.width
    let height = cgImage.height

    guard let dataProvider = cgImage.dataProvider,
          let pixelData = dataProvider.data else { return nil }

    let ptr = CFDataGetBytePtr(pixelData)!
    let bytesPerRow = cgImage.bytesPerRow
    let bytesPerPixel = cgImage.bitsPerPixel / 8

    var bitmap: [[Bool]] = []
    for y in 0..<height {
        var row: [Bool] = []
        for x in 0..<width {
            let offset = y * bytesPerRow + x * bytesPerPixel
            let value = ptr[offset]
            row.append(value < 128)
        }
        bitmap.append(row)
    }

    return bitmap
}

// MARK: - Terminal Renderer

func renderToTerminal(_ bitmap: [[Bool]]) {
    let height = bitmap.count
    let width = bitmap.isEmpty ? 0 : bitmap[0].count
    let border = 2

    var row = -border
    while row < height + border {
        var line = ""
        for col in -border..<(width + border) {
            let y1 = row
            let y2 = row + 1

            let top = (col >= 0 && col < width && y1 >= 0 && y1 < height) ? bitmap[y1][col] : false
            let bottom = (col >= 0 && col < width && y2 >= 0 && y2 < height) ? bitmap[y2][col] : false

            switch (top, bottom) {
            case (false, false): line += "\u{2588}"
            case (true, false):  line += "\u{2584}"
            case (false, true):  line += "\u{2580}"
            case (true, true):   line += " "
            }
        }
        print(line)
        row += 2
    }
}

// MARK: - Serve Mode

/// Find the `opencode` binary in PATH.
func findOpenCode() -> String? {
    guard let pathEnv = ProcessInfo.processInfo.environment["PATH"] else { return nil }
    let dirs = pathEnv.split(separator: ":").map(String.init)
    for dir in dirs {
        let candidate = (dir as NSString).appendingPathComponent("opencode")
        if FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
    }
    return nil
}

// MARK: - Port Polling

/// Wait for a TCP port to accept connections, with a timeout.
func waitForPort(_ port: Int, host: String = "127.0.0.1", timeoutSeconds: Int = 15) -> Bool {
    let deadline = Date().addingTimeInterval(Double(timeoutSeconds))
    while Date() < deadline {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else {
            usleep(200_000)
            continue
        }
        defer { close(sock) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr(host)

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(sock, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        if result == 0 {
            return true
        }
        usleep(200_000) // 200ms between attempts
    }
    return false
}

// MARK: - Serve Mode

/// Global PID for the serve process, used by signal handlers for cleanup.
nonisolated(unsafe) var serveProcessPID: pid_t = 0

/// Signal handler that kills the serve process and exits.
func cleanupServeAndExit(_ sig: Int32) {
    if serveProcessPID > 0 {
        kill(serveProcessPID, SIGTERM)
        // Give it a moment to shut down gracefully
        var status: Int32 = 0
        var waited: Int32 = 0
        for _ in 0..<10 {
            waited = waitpid(serveProcessPID, &status, WNOHANG)
            if waited != 0 { break }
            usleep(100_000) // 100ms
        }
        // Force kill if still alive
        if waited == 0 {
            kill(serveProcessPID, SIGKILL)
            waitpid(serveProcessPID, &status, 0)
        }
    }
    _exit(sig == SIGINT ? 130 : 143)
}

/// Start server first, show QR when ready, then attach TUI.
/// 1. Start `opencode serve` as a background process (server is live immediately)
/// 2. Wait for the port to accept connections
/// 3. Show QR code (user can scan it — server is already running!)
/// 4. Wait for Enter
/// 5. posix_spawn `opencode attach` as TUI child, parent waits and cleans up serve on exit
func startServeAndAttach(config: Config) -> Never {
    guard let opencodePath = findOpenCode() else {
        printError("'opencode' not found in PATH. Install it first: curl -fsSL https://opencode.ai/install | bash")
        exit(1)
    }

    // --- 1. Start the server in the background ---
    if !config.password.isEmpty {
        setenv("OPENCODE_SERVER_PASSWORD", config.password, 1)
    }

    let port = String(config.port)
    var servePID: pid_t = 0
    let serveArgs = [opencodePath, "serve", "--port", port, "--hostname", "0.0.0.0"]

    // Use posix_spawn so the server runs as a child process
    var serveArgsCStr = serveArgs.map { strdup($0)! } + [nil]
    defer { serveArgsCStr.forEach { if let p = $0 { free(p) } } }

    // Redirect serve stdout/stderr to /dev/null so it doesn't mess up QR display
    var fileActions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&fileActions)
    posix_spawn_file_actions_addopen(&fileActions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)
    posix_spawn_file_actions_addopen(&fileActions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
    // Also close stdin so serve doesn't try to read from terminal
    posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)

    let spawnResult = posix_spawn(&servePID, opencodePath, &fileActions, nil, &serveArgsCStr, environ)
    posix_spawn_file_actions_destroy(&fileActions)

    if spawnResult != 0 {
        printError("Failed to start opencode serve: \(String(cString: strerror(spawnResult)))")
        exit(1)
    }

    serveProcessPID = servePID
    signal(SIGINT, cleanupServeAndExit)
    signal(SIGTERM, cleanupServeAndExit)

    print()
    print("  Starting OpenCode server on port \(port)...")

    // --- 2. Wait for server to be ready ---
    if !waitForPort(config.port) {
        printError("Server did not start within timeout. Check opencode installation.")
        kill(servePID, SIGTERM)
        waitpid(servePID, nil, 0)
        exit(1)
    }

    print("  Server is ready!")
    print()

    // --- 3. Show QR code (server is live — scanning works!) ---
    let deepLink = buildDeepLink(config: config)
    guard let bitmap = generateQRBitmap(from: deepLink) else {
        printError("Failed to generate QR code")
        kill(servePID, SIGTERM)
        waitpid(servePID, nil, 0)
        exit(1)
    }

    printQROutput(config: config, deepLink: deepLink, bitmap: bitmap)

    print("  ✓ Server is running — you can scan the QR code now!")
    print("  Press Enter to open the TUI (QR will scroll away)...")
    print()

    // Wait for Enter
    _ = readLine()

    // --- 4. Spawn TUI as child, wait for it, then clean up serve ---
    // Use posix_spawn for `opencode attach` — it inherits stdin/stdout/stderr
    // by default, so the interactive TUI works.
    var tuiPID: pid_t = 0
    var attachArgs = [opencodePath, "attach", "http://127.0.0.1:\(port)", "--continue"]
    if !config.password.isEmpty {
        attachArgs += ["--password", config.password]
    }
    var attachArgsCStr = attachArgs.map { strdup($0)! } + [nil]
    defer { attachArgsCStr.forEach { if let p = $0 { free(p) } } }

    let tuiSpawnResult = posix_spawn(&tuiPID, opencodePath, nil, nil, &attachArgsCStr, environ)
    if tuiSpawnResult != 0 {
        printError("Failed to start TUI: \(String(cString: strerror(tuiSpawnResult)))")
        kill(servePID, SIGTERM)
        waitpid(servePID, nil, 0)
        exit(1)
    }

    // Parent: wait for TUI to exit, then kill serve
    signal(SIGINT, SIG_IGN) // Let TUI handle Ctrl+C
    var status: Int32 = 0
    waitpid(tuiPID, &status, 0)

    // TUI exited — clean up server
    kill(servePID, SIGTERM)
    var serveStatus: Int32 = 0
    var waited: Int32 = 0
    for _ in 0..<20 {
        waited = waitpid(servePID, &serveStatus, WNOHANG)
        if waited != 0 { break }
        usleep(100_000)
    }
    if waited == 0 {
        kill(servePID, SIGKILL)
        waitpid(servePID, &serveStatus, 0)
    }

    // Exit with same code as TUI
    let exitCode = (status >> 8) & 0xFF
    exit(exitCode)
}

// MARK: - Output

func printQROutput(config: Config, deepLink: String, bitmap: [[Bool]]) {
    let displayDeepLink = config.printSecretLink ? deepLink : buildDisplayDeepLink(config: config)

    print()
    print("  OpenLens QR Code")
    print("  Scan this with the OpenLens iOS app")
    print()

    renderToTerminal(bitmap)

    print()
    print("  Deep link: \(displayDeepLink)")
    if config.printSecretLink && !config.password.isEmpty {
        print("  Warning: full deep link includes the password")
    }
    print()
    print("  Server:   \(config.serverURL)")
    print("  User:     \(config.username)")
    if !config.password.isEmpty {
        print("  Password: ****")
    }
    print()
}

// MARK: - Main

guard let config = parseArguments() else {
    exit(1)
}

if config.serve {
    startServeAndAttach(config: config)
    // Never returns
}

// QR-only mode
let deepLink = buildDeepLink(config: config)

guard let bitmap = generateQRBitmap(from: deepLink) else {
    printError("Failed to generate QR code")
    exit(1)
}

printQROutput(config: config, deepLink: deepLink, bitmap: bitmap)
