import Foundation
import Security

final class KeychainHelper {
    static let shared = KeychainHelper()
    private init() {}

    /// Default accessibility used for all items written through this helper.
    /// `…ThisDeviceOnly` ensures items are NOT carried over in encrypted iCloud
    /// or device-to-device backups: tokens stay on the device they were entered
    /// on. This matches the privacy promise in README/SECURITY that secrets are
    /// kept only on the local device.
    private static let accessibility: CFString = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

    // MARK: - Public API (with error handling)

    /// Save data to Keychain with proper error handling
    /// - Returns: true on success, false on failure
    @discardableResult
    func save(_ data: Data, service: String, account: String) -> Bool {
        let query = [
            kSecValueData: data,
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrAccessible: Self.accessibility
        ] as [CFString: Any]

        let status = SecItemAdd(query as CFDictionary, nil)

        if status == errSecSuccess {
            return true
        } else if status == errSecDuplicateItem {
            // Item already exists. Update its data and (importantly) re-assert the
            // stricter accessibility attribute, in case it was previously written
            // with a less restrictive one (e.g. `kSecAttrAccessibleWhenUnlocked`).
            let searchQuery = [
                kSecAttrService: service,
                kSecAttrAccount: account,
                kSecClass: kSecClassGenericPassword
            ] as [CFString: Any]

            let attributesToUpdate = [
                kSecValueData: data,
                kSecAttrAccessible: Self.accessibility
            ] as [CFString: Any]

            let updateStatus = SecItemUpdate(searchQuery as CFDictionary, attributesToUpdate as CFDictionary)

            if updateStatus != errSecSuccess {
                #if DEBUG
                print("[Keychain] Failed to update item: OSStatus \(updateStatus)")
                #endif
                return false
            }
            return true
        } else {
            #if DEBUG
            print("[Keychain] Failed to save item: OSStatus \(status)")
            #endif
            return false
        }
    }

    func read(service: String, account: String) -> Data? {
        let query = [
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecClass: kSecClassGenericPassword,
            kSecReturnData: true
        ] as [CFString: Any]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecSuccess {
            return result as? Data
        } else if status != errSecItemNotFound {
            #if DEBUG
            print("[Keychain] Failed to read item: OSStatus \(status)")
            #endif
        }

        return nil
    }

    /// Delete item from Keychain
    /// - Returns: true on success or if item didn't exist, false on failure
    @discardableResult
    func delete(service: String, account: String) -> Bool {
        let query = [
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecClass: kSecClassGenericPassword
        ] as [CFString: Any]

        let status = SecItemDelete(query as CFDictionary)

        if status == errSecSuccess || status == errSecItemNotFound {
            return true
        } else {
            #if DEBUG
            print("[Keychain] Failed to delete item: OSStatus \(status)")
            #endif
            return false
        }
    }

    // MARK: - String Helpers

    @discardableResult
    func save(_ string: String, service: String, account: String) -> Bool {
        guard let data = string.data(using: .utf8) else {
            #if DEBUG
            print("[Keychain] Failed to convert string to data")
            #endif
            return false
        }
        return save(data, service: service, account: account)
    }

    func readString(service: String, account: String) -> String? {
        if let data = read(service: service, account: account) {
            return String(data: data, encoding: .utf8)
        }
        return nil
    }

    // MARK: - Migration

    /// One-time migration that re-saves any existing items at the stricter
    /// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` accessibility level.
    ///
    /// Items previously saved under `kSecAttrAccessibleWhenUnlocked` retain that
    /// attribute until updated. Reading + saving each known item triggers the
    /// `errSecDuplicateItem` branch in `save(...)` which now applies the new
    /// accessibility level via `SecItemUpdate`.
    ///
    /// Idempotent: safe to call on every launch. No-ops once items already use
    /// the stricter level (the `SecItemUpdate` simply re-asserts the same value).
    func migrateAccessibilityToThisDeviceOnly(service: String, accounts: [String]) {
        for account in accounts {
            guard let data = read(service: service, account: account) else { continue }
            _ = save(data, service: service, account: account)
        }
    }
}
