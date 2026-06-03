import Foundation
import Testing
@testable import OpenLens

struct ChatEasterEggTests {

    @MainActor
    @Test func controllerTogglesVisualModeInMemory() {
        let controller = ChatEasterEggController(
            initialMode: .standard,
            launchArguments: []
        )

        #expect(controller.visualMode == .standard)

        controller.toggleVisualMode()
        #expect(controller.visualMode == .retro)

        controller.toggleVisualMode()
        #expect(controller.visualMode == .standard)
    }

    @Test func shakePolicyRequiresThresholdAndCooldown() {
        let policy = ChatShakePolicy(
            accelerationMagnitudeThreshold: 2.4,
            cooldown: 1.0
        )
        let now = Date(timeIntervalSince1970: 100)

        #expect(!policy.shouldToggle(
            x: 0.2,
            y: 0.3,
            z: 1.0,
            now: now,
            lastToggleDate: .distantPast
        ))

        #expect(policy.shouldToggle(
            x: 2.5,
            y: 0,
            z: 0,
            now: now,
            lastToggleDate: .distantPast
        ))

        #expect(!policy.shouldToggle(
            x: 2.5,
            y: 0,
            z: 0,
            now: now,
            lastToggleDate: now.addingTimeInterval(-0.4)
        ))

        #expect(policy.shouldToggle(
            x: 2.5,
            y: 0,
            z: 0,
            now: now,
            lastToggleDate: now.addingTimeInterval(-1.1)
        ))
    }

    @MainActor
    @Test func controllerHandlesShakeUsingPolicy() {
        let controller = ChatEasterEggController(
            initialMode: .standard,
            policy: ChatShakePolicy(accelerationMagnitudeThreshold: 2.4, cooldown: 1.0),
            launchArguments: []
        )
        let now = Date(timeIntervalSince1970: 100)

        controller.handleAcceleration(x: 1.0, y: 0, z: 0, now: now)
        #expect(controller.visualMode == .standard)

        controller.handleAcceleration(x: 2.5, y: 0, z: 0, now: now)
        #expect(controller.visualMode == .retro)

        controller.handleAcceleration(x: 2.5, y: 0, z: 0, now: now.addingTimeInterval(0.2))
        #expect(controller.visualMode == .retro)

        controller.handleAcceleration(x: 2.5, y: 0, z: 0, now: now.addingTimeInterval(1.2))
        #expect(controller.visualMode == .standard)
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
