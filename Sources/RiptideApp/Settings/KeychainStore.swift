import Foundation
import Security

/// Thin wrapper over SecItem generic passwords. No error surface: a missing
/// key reads as nil and the settings UI treats empty as unconfigured.
struct KeychainStore {
    let service: String
    init(service: String = "com.northlab.riptide") { self.service = service }

    private func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func get(_ account: String) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func set(_ value: String, account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
        var add = baseQuery(account)
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    func delete(account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }
}
