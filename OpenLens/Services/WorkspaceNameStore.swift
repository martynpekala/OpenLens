import Foundation
import Observation

/// Stores user-assigned display names for workspace directories.
///
/// Names are keyed by normalized directory path, so the same folder shows the
/// same personalized name in the Sessions list, the chat header, and the
/// Workspace tab no matter which connection reported it. With no name
/// assigned, callers fall back to the folder's last path component.
@Observable
final class WorkspaceNameStore {

    private var namesByDirectory: [String: String]
    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.namesByDirectory = Self.loadNames(from: userDefaults)
    }

    /// The user-assigned name, if any. `nil` means no personalized name.
    func customName(forDirectory directory: String?) -> String? {
        guard let key = normalizedKey(directory) else { return nil }
        return namesByDirectory[key]?.nilIfBlank
    }

    /// The name to display: the personalized name when assigned, otherwise the
    /// folder's last path component.
    func displayName(forDirectory directory: String?) -> String? {
        guard let key = normalizedKey(directory) else { return nil }
        if let customName = namesByDirectory[key]?.nilIfBlank {
            return customName
        }
        return WorkspaceSelectionBuilder.displayName(for: key)
    }

    /// Assigns a personalized name. An empty or whitespace-only name removes
    /// the assignment so the default name is used again.
    func setCustomName(_ name: String?, forDirectory directory: String) {
        guard let key = normalizedKey(directory) else { return }

        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmedName.isEmpty {
            guard namesByDirectory[key] != nil else { return }
            namesByDirectory.removeValue(forKey: key)
        } else {
            guard namesByDirectory[key] != trimmedName else { return }
            namesByDirectory[key] = trimmedName
        }

        Self.saveNames(namesByDirectory, to: userDefaults)
    }

    private func normalizedKey(_ directory: String?) -> String? {
        WorkspaceSelectionBuilder.normalizedDirectory(directory)
    }

    private static func loadNames(from userDefaults: UserDefaults) -> [String: String] {
        guard let data = userDefaults.data(forKey: AppPreferenceKeys.workspaceCustomNames),
              let names = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return names
    }

    private static func saveNames(_ names: [String: String], to userDefaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(names) else { return }
        userDefaults.set(data, forKey: AppPreferenceKeys.workspaceCustomNames)
    }
}
