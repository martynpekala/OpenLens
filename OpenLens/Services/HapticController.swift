import UIKit

/// Centralized haptic feedback controller.
/// Encapsulates haptic generators and one-shot logic so callers don't manage UIKit state.
@MainActor
final class HapticController {

    // MARK: - Generators

    private let lightImpact = UIImpactFeedbackGenerator(style: .light)
    private let notification = UINotificationFeedbackGenerator()

    /// Whether the first-response haptic has already fired for the current turn.
    private var hasPlayedFirstResponse = false

    init() {}

    // MARK: - API

    /// Prepare the light-impact generator (call just before a turn starts).
    func prepareForResponse() {
        hasPlayedFirstResponse = false
        guard AppPreferences.hapticsEnabled else { return }
        lightImpact.prepare()
    }

    /// Fire a light impact once per turn (first streamed token).
    func playFirstResponseIfNeeded() {
        guard AppPreferences.hapticsEnabled else { return }
        guard !hasPlayedFirstResponse else { return }
        hasPlayedFirstResponse = true
        lightImpact.impactOccurred()
    }

    /// Fire a light impact unconditionally (e.g. step completion).
    func playStepCompletion() {
        guard AppPreferences.hapticsEnabled else { return }
        lightImpact.impactOccurred()
    }

    /// Fire a warning notification (e.g. permission request).
    func playWarning() {
        guard AppPreferences.hapticsEnabled else { return }
        notification.notificationOccurred(.warning)
    }
}
