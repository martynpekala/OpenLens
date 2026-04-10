import Foundation
import Security
import os

/// Keychain wrapper for storing sensitive data.
/// Supports both simple String values and Codable objects (encoded as JSON Data).
enum KeychainService {

    private static let serviceName = Bundle.main.bundleIdentifier ?? "com.openlens"
    private static let logger = Logger(subsystem: serviceName, category: "Keychain")

    // MARK: - String API (backward-compatible)

    @discardableResult
    static func save(key: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        return saveData(key: key, data: data)
    }

    static func load(key: String) -> String? {
        guard let data = loadData(key: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(key: String) {
        let query = baseQuery(key: key)
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            logger.warning("Keychain delete failed for '\(key, privacy: .public)': \(status)")
        }
    }

    // MARK: - Codable API

    @discardableResult
    static func saveCodable<T: Encodable>(_ value: T, key: String) -> Bool {
        do {
            let data = try JSONEncoder().encode(value)
            return saveData(key: key, data: data)
        } catch {
            logger.error("Keychain encode failed for '\(key, privacy: .public)': \(error, privacy: .public)")
            return false
        }
    }

    static func loadCodable<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = loadData(key: key) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            logger.error("Keychain decode failed for '\(key, privacy: .public)': \(error, privacy: .public)")
            return nil
        }
    }

    // MARK: - Raw Data API

    @discardableResult
    static func saveData(key: String, data: Data) -> Bool {
        // Delete existing item first (upsert pattern)
        let deleteQuery = baseQuery(key: key)
        SecItemDelete(deleteQuery as CFDictionary)

        var addQuery = baseQuery(key: key)
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            logger.error("Keychain save failed for '\(key, privacy: .public)': \(status)")
            return false
        }
        return true
    }

    static func loadData(key: String) -> Data? {
        var query = baseQuery(key: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return data
    }

    // MARK: - Helpers

    private static func baseQuery(key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: serviceName,
        ]
    }
}
