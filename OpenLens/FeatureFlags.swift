import Foundation

enum FeatureFlags {
    static let debugFeaturesKey = "debugFeaturesEnabled"

    static var debugFeaturesDefault: Bool {
#if DEBUG
        false
#else
        false
#endif
    }

    static var debugFeaturesEnabled: Bool {
#if DEBUG
        UserDefaults.standard.object(forKey: debugFeaturesKey) as? Bool ?? debugFeaturesDefault
#else
        false
#endif
    }
}
