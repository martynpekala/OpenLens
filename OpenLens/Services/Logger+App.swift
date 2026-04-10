import os.log
import Foundation

extension Logger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.openlens"

    static let api = Logger(subsystem: subsystem, category: "API")
    static let sse = Logger(subsystem: subsystem, category: "SSE")
    static let sseHandler = Logger(subsystem: subsystem, category: "SSEHandler")
    static let connection = Logger(subsystem: subsystem, category: "Connection")
    static let providers = Logger(subsystem: subsystem, category: "Providers")
    static let chat = Logger(subsystem: subsystem, category: "Chat")
    static let liveActivity = Logger(subsystem: subsystem, category: "LiveActivity")
    static let debug = Logger(subsystem: subsystem, category: "Debug")
}
