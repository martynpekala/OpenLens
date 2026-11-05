import SwiftUI

enum AppTab: String, CaseIterable, Identifiable {
    case chat
    case micro
    case review
    case workspace
    case settings

    var id: String { rawValue }

    /// Whether this tab's navigation survives a server switch.
    ///
    /// Settings is the app's own surface -- preferences, and the servers list itself -- not a
    /// view onto one server, so switching server must not yank you off the screen you switched
    /// from. Every other tab shows one server's work, so its stack is that server's.
    ///
    /// Note this is about the *path*, which is a different axis from view identity: Chat's path
    /// is per-server (each server remembers its open session) while its view identity is
    /// constant (the list itself survives a switch). See `scopeID(for:activeServerID:)`.
    var keepsNavigationAcrossServers: Bool { self == .settings }

    var title: String {
        switch self {
        case .chat: "Sessions"
        case .micro: "Micro"
        case .review: "Review"
        case .workspace: "Workspace"
        case .settings: "Settings"
        }
    }

    var icon: String {
        switch self {
        case .chat: "message"
        case .micro: "command"
        case .review: "magnifyingglass.circle"
        case .workspace: "folder"
        case .settings: "gearshape"
        }
    }
}
