import Foundation

enum ConnectionMethod: String, Sendable {
    case manual
    case saved
    case bonjour
    case qr
    case deepLink = "deep_link"
    case autoReconnect = "auto_reconnect"
}