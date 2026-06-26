import Foundation
import Security

/// Thin wrapper over the Keychain for string secrets (generic-password items).
/// One item per `account` within a `service`. Used for the OpenRouter API key
/// (account `"openrouter:<serverID>"`) and the Firecrawl key (account `"firecrawl"`).
///
/// All new items are written to the data-protection keychain
/// (`kSecUseDataProtectionKeychain = true`), which does not tie access to the
/// app's code signature. This avoids macOS password prompts on every debug build.
/// Reads fall back to the legacy keychain and migrate items automatically.
struct KeychainStore {
    let service: String

    // Fork-local service name keeps this app's secrets separate from the original
    // Modelo app's keychain items (mirrors the ModeloDos store-folder separation).
    init(service: String = "com.peregrine.modelodos") {
        self.service = service
    }

    /// Returns the stored string for `account`, or nil if absent.
    /// Migrates legacy-keychain items to the data-protection keychain on first read.
    func get(account: String) -> String? {
        if let value = readItem(account: account, dataProtection: true) { return value }
        // Legacy fallback: migrate to data-protection keychain on success.
        if let value = readItem(account: account, dataProtection: false) {
            set(value, account: account)
            return value
        }
        return nil
    }

    /// Stores `value` for `account` in the data-protection keychain, overwriting any
    /// existing item. Passing nil deletes the item from both keychains.
    func set(_ value: String?, account: String) {
        guard let value, let data = value.data(using: .utf8) else {
            delete(account: account)
            return
        }
        var query = baseQuery(account: account, dataProtection: true)
        let attrs = [kSecValueData as String: data] as CFDictionary
        let status = SecItemUpdate(query as CFDictionary, attrs)
        if status == errSecItemNotFound {
            query[kSecValueData as String] = data
            // Accessible after first device unlock — no repeated password prompts.
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(query as CFDictionary, nil)
        }
    }

    private func delete(account: String) {
        SecItemDelete(baseQuery(account: account, dataProtection: true) as CFDictionary)
        SecItemDelete(baseQuery(account: account, dataProtection: false) as CFDictionary)
    }

    private func readItem(account: String, dataProtection: Bool) -> String? {
        var query = baseQuery(account: account, dataProtection: dataProtection)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func baseQuery(account: String, dataProtection: Bool) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if dataProtection {
            q[kSecUseDataProtectionKeychain as String] = true
        }
        return q
    }
}
