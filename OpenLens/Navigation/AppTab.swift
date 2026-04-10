import SwiftUI

enum AppTab: String, CaseIterable, Identifiable {
    case chat
    case review
    case workspace
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chat: "Sessions"
        case .review: "Review"
        case .workspace: "Workspace"
        case .settings: "Settings"
        }
    }

    var icon: String {
        switch self {
        case .chat: "message"
        case .review: "doc.text.magnifyingglass"
        case .workspace: "folder.fill"
        case .settings: "gearshape.fill"
        }
    }
}
