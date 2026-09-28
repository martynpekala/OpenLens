import Foundation

enum AppPreferenceKeys {
    static let accentColor = "accentColor"
    static let autoReconnect = "autoReconnect"
    static let hapticsEnabled = "hapticsEnabled"
    static let liveActivitiesEnabled = "liveActivitiesEnabled"
    static let quickModelAssignments = "quickModelAssignments"
    static let showThinking = "showThinking"
}

enum AppPreferences {
    static var hapticsEnabled: Bool {
        UserDefaults.standard.object(forKey: AppPreferenceKeys.hapticsEnabled) as? Bool ?? true
    }

    static var liveActivitiesEnabled: Bool {
        UserDefaults.standard.object(forKey: AppPreferenceKeys.liveActivitiesEnabled) as? Bool ?? true
    }

    static func quickModelAssignments(
        userDefaults: UserDefaults = .standard
    ) -> [ModelQuickAction: QuickModelAssignment] {
        guard let data = userDefaults.data(forKey: AppPreferenceKeys.quickModelAssignments),
              let encoded = try? JSONDecoder().decode([String: QuickModelAssignment].self, from: data) else {
            return [:]
        }

        return encoded.reduce(into: [:]) { assignments, entry in
            guard let action = ModelQuickAction(rawValue: entry.key) else { return }
            assignments[action] = entry.value
        }
    }

    static func saveQuickModelAssignments(
        _ assignments: [ModelQuickAction: QuickModelAssignment],
        userDefaults: UserDefaults = .standard
    ) {
        let encoded = assignments.reduce(into: [String: QuickModelAssignment]()) { result, entry in
            result[entry.key.rawValue] = entry.value
        }

        guard let data = try? JSONEncoder().encode(encoded) else { return }
        userDefaults.set(data, forKey: AppPreferenceKeys.quickModelAssignments)
    }
}
