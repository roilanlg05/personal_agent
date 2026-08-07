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
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func set(_ value: String, account: String) {
        let data = Data(value.utf8)
        SecItemDelete(query(account) as CFDictionary)   // overwrite-safe
        var q = query(account)
        q[kSecValueData as String] = data
        SecItemAdd(q as CFDictionary, nil)
    }

    func delete(account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}
