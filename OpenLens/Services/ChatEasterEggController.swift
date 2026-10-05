import Foundation
import Observation

enum ChatVisualMode: Equatable, Sendable {
    case standard
    case retro

    var isRetro: Bool {
        self == .retro
    }
}

@MainActor @Observable
final class ChatEasterEggController {
    static let debugRetroLaunchArgument = "OPENLENS_RETRO_CHAT=1"

    private(set) var visualMode: ChatVisualMode

    init(
        initialMode: ChatVisualMode = .standard,
        launchArguments: [String] = ProcessInfo.processInfo.arguments
    ) {
#if DEBUG
        self.visualMode = launchArguments.contains(Self.debugRetroLaunchArgument) ? .retro : initialMode
#else
        self.visualMode = initialMode
#endif
    }
}
