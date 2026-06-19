import Foundation
import Security

/// Thin wrapper over the Keychain for string secrets (generic-password items).
/// One item per `account` within a `service`. Used for the OpenRouter API key
/// (account `"openrouter:<serverID>"`) and the Firecrawl key (account `"firecrawl"`).
struct KeychainStore {
    let service: String

    init(service: String = "com.peregrine.modelodos") {
        self.service = service
    }

    /// Returns the stored string for `account`, or nil if absent.
    func get(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Stores `value` for `account`, overwriting any existing item.
    /// Passing nil deletes the item.
    func set(_ value: String?, account: String) {
        guard let value, let data = value.data(using: .utf8) else {
            delete(account: account)
            return
        }
        let query = baseQuery(account: account)
        let attrs = [kSecValueData as String: data] as CFDictionary
        let status = SecItemUpdate(query as CFDictionary, attrs)
        if status == errSecItemNotFound {
            var add = baseQuery(account: account)
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    private func delete(account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }

    private func baseQuery(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}
