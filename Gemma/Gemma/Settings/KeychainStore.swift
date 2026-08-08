import Foundation
import Security

/// Minimal Keychain wrapper for API keys (generic password items, one per account).
struct KeychainStore {
    static let shared = KeychainStore()
    private let service = "lambert-dev-group.Gemma.apiKeys"

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
    }

    func get(account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
           let data = out as? Data,
           let str = String(data: data, encoding: .utf8),
           !str.isEmpty {
            return str
        }
        if let cloudKey = NSUbiquitousKeyValueStore.default.string(forKey: account), !cloudKey.isEmpty {
            set(cloudKey, account: account)
            return cloudKey
        }
        if let fallback = UserDefaults.standard.string(forKey: "keychain_fallback.\(account)"), !fallback.isEmpty {
            return fallback
        }
        return nil
    }

    func set(_ value: String, account: String) {
        let data = Data(value.utf8)
        SecItemDelete(query(account) as CFDictionary)   // overwrite-safe
        var q = query(account)
        q[kSecValueData as String] = data
        SecItemAdd(q as CFDictionary, nil)
        UserDefaults.standard.set(value, forKey: "keychain_fallback.\(account)")
        NSUbiquitousKeyValueStore.default.set(value, forKey: account)
        NSUbiquitousKeyValueStore.default.synchronize()
    }

    func delete(account: String) {
        SecItemDelete(query(account) as CFDictionary)
        UserDefaults.standard.removeObject(forKey: "keychain_fallback.\(account)")
        NSUbiquitousKeyValueStore.default.removeObject(forKey: account)
        NSUbiquitousKeyValueStore.default.synchronize()
    }
}
