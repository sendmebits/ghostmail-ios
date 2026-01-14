import Foundation
import Security

final class KeychainHelper {
    static let shared = KeychainHelper()
    private init() {}
    
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
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlocked
        ] as [CFString: Any]
        
        // Add item to keychain
        let status = SecItemAdd(query as CFDictionary, nil)
        
        if status == errSecSuccess {
            return true
        } else if status == errSecDuplicateItem {
            // Item already exists, update it
            let searchQuery = [
                kSecAttrService: service,
                kSecAttrAccount: account,
                kSecClass: kSecClassGenericPassword
            ] as [CFString: Any]
            
            let attributesToUpdate = [
                kSecValueData: data,
                kSecAttrAccessible: kSecAttrAccessibleWhenUnlocked
            ] as [CFString: Any]
            
            let updateStatus = SecItemUpdate(searchQuery as CFDictionary, attributesToUpdate as CFDictionary)
            
            if updateStatus != errSecSuccess {
                print("[Keychain] Failed to update item for \(account): OSStatus \(updateStatus)")
                return false
            }
            return true
        } else {
            print("[Keychain] Failed to save item for \(account): OSStatus \(status)")
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
            // Log unexpected errors (not "item not found" which is expected)
            print("[Keychain] Failed to read item for \(account): OSStatus \(status)")
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
            print("[Keychain] Failed to delete item for \(account): OSStatus \(status)")
            return false
        }
    }
    
    // MARK: - String Helpers
    
    @discardableResult
    func save(_ string: String, service: String, account: String) -> Bool {
        guard let data = string.data(using: .utf8) else {
            print("[Keychain] Failed to convert string to data for \(account)")
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
}
