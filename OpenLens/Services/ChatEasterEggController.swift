import CoreMotion
import Foundation
import Observation

enum ChatVisualMode: Equatable, Sendable {
    case standard
    case retro

    var isRetro: Bool {
        self == .retro
    }

    var toggled: ChatVisualMode {
        switch self {
        case .standard: .retro
        case .retro: .standard
        }
    }
}

struct ChatShakePolicy: Equatable, Sendable {
    static let `default` = ChatShakePolicy(
        accelerationMagnitudeThreshold: 2.45,
        cooldown: 1.0
    )

    let accelerationMagnitudeThreshold: Double
    let cooldown: TimeInterval

    func accelerationMagnitude(x: Double, y: Double, z: Double) -> Double {
        sqrt(x * x + y * y + z * z)
    }

    func shouldToggle(
        x: Double,
        y: Double,
        z: Double,
        now: Date,
        lastToggleDate: Date
    ) -> Bool {
        guard now.timeIntervalSince(lastToggleDate) >= cooldown else { return false }
        return accelerationMagnitude(x: x, y: y, z: z) >= accelerationMagnitudeThreshold
    }
}

@MainActor @Observable
final class ChatEasterEggController {
    static let debugRetroLaunchArgument = "OPENLENS_RETRO_CHAT=1"

    private(set) var visualMode: ChatVisualMode

    @ObservationIgnored private let motionManager = CMMotionManager()
    @ObservationIgnored private let policy: ChatShakePolicy
    @ObservationIgnored private var lastToggleDate: Date = .distantPast
    @ObservationIgnored private var isMonitoring = false

    init(
        initialMode: ChatVisualMode = .standard,
        policy: ChatShakePolicy? = nil,
        launchArguments: [String] = ProcessInfo.processInfo.arguments
    ) {
#if DEBUG
        self.visualMode = launchArguments.contains(Self.debugRetroLaunchArgument) ? .retro : initialMode
#else
        self.visualMode = initialMode
#endif
        self.policy = policy ?? ChatShakePolicy.default
    }

    func toggleVisualMode() {
        visualMode = visualMode.toggled
    }

    func startShakeMonitoring() {
        guard !isMonitoring else { return }
        guard motionManager.isAccelerometerAvailable else { return }

        isMonitoring = true
        motionManager.accelerometerUpdateInterval = 1.0 / 24.0
        motionManager.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
            guard let acceleration = data?.acceleration else { return }
            let x = acceleration.x
            let y = acceleration.y
            let z = acceleration.z

            Task { @MainActor [weak self] in
                self?.handleAcceleration(x: x, y: y, z: z, now: Date())
            }
        }
    }

    func stopShakeMonitoring() {
        guard isMonitoring else { return }
        motionManager.stopAccelerometerUpdates()
        isMonitoring = false
    }

    func handleAcceleration(x: Double, y: Double, z: Double, now: Date) {
        guard policy.shouldToggle(
            x: x,
            y: y,
            z: z,
            now: now,
            lastToggleDate: lastToggleDate
        ) else {
            return
        }

        lastToggleDate = now
        toggleVisualMode()
    }
}