import SwiftUI
import Testing
@testable import OpenLens

struct AccentColorPreferenceTests {

    @MainActor
    private func onAccentColor(forHex hex: String) -> Color {
        let suiteName = "AccentColorPreferenceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(hex, forKey: AppPreferenceKeys.accentColor)
        return AccentColorPreference(userDefaults: defaults).onAccentColor
    }

    @MainActor
    @Test(arguments: ["007AFF", "FF9500", "34C759", "AF52DE", "FF3B30"])
    func midToneAccentsKeepWhiteForeground(hex: String) {
        #expect(onAccentColor(forHex: hex) == .white)
    }

    @MainActor
    @Test(arguments: ["FFFFFF", "FFE600", "F2F2F7"])
    func paleAccentsUseDarkForeground(hex: String) {
        #expect(onAccentColor(forHex: hex) != .white)
    }
}
