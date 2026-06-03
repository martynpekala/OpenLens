import Foundation

enum AppPreferenceKeys {
    static let autoReconnect = "autoReconnect"
    static let hapticsEnabled = "hapticsEnabled"
    static let liveActivitiesEnabled = "liveActivitiesEnabled"
    static let showThinking = "showThinking"
}

enum AppPreferences {
    static var hapticsEnabled: Bool {
        UserDefaults.standard.object(forKey: AppPreferenceKeys.hapticsEnabled) as? Bool ?? true
    }

    static var liveActivitiesEnabled: Bool {
        UserDefaults.standard.object(forKey: AppPreferenceKeys.liveActivitiesEnabled) as? Bool ?? true
    }
}
