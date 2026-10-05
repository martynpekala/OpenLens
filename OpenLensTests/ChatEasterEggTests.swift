import Foundation
import Testing
@testable import OpenLens

struct ChatEasterEggTests {

    @MainActor
    @Test func controllerStartsInStandardMode() {
        let controller = ChatEasterEggController(launchArguments: [])

        #expect(controller.visualMode == .standard)
    }

    @MainActor
    @Test func controllerPreservesInitialMode() {
        let controller = ChatEasterEggController(
            initialMode: .retro,
            launchArguments: []
        )

        #expect(controller.visualMode == .retro)
    }

    @MainActor
    @Test func debugLaunchArgumentStartsInRetroMode() {
        let controller = ChatEasterEggController(
            initialMode: .standard,
            launchArguments: [ChatEasterEggController.debugRetroLaunchArgument]
        )

#if DEBUG
        #expect(controller.visualMode == .retro)
#else
        #expect(controller.visualMode == .standard)
#endif
    }
}
