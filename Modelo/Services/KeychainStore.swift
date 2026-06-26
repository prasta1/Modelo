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

    /// Pre-rename service name (`ModeloDos`). Items found here are migrated to the
    /// current service on first read so existing API keys survive the rename.
    private static let legacyService = "com.peregrine.modelodos"

    init(service: String = "com.peregrine.modelo") {
        self.service = service
    }

    /// Returns the stored string for `account`, or nil if absent. On a miss in the
    /// current service, falls back to the legacy keychain and the legacy service name,
    /// migrating any hit to the current service + data-protection keychain.
    func get(account: String) -> String? {
        if let value = readItem(account: account, service: service, dataProtection: true) { return value }
        // Fallbacks, in priority order — migrate on first success:
        //   1. current service, legacy keychain
        //   2. legacy service (ModeloDos), data-protection keychain
        //   3. legacy service (ModeloDos), legacy keychain
        let fallbacks: [(String, Bool)] = [
            (service, false),
            (Self.legacyService, true),
            (Self.legacyService, false)
        ]
        for (svc, dataProtection) in fallbacks {
            if let value = readItem(account: account, service: svc, dataProtection: dataProtection) {
                set(value, account: account)
                // Only remove the migrated source once the value is confirmed in the current
                // service's data-protection keychain. If that write failed (e.g. the
                // data-protection keychain is unavailable, as in an unsigned test process),
                // deleting the source would destroy the only copy. A leftover that survives
                // here is still cleared by delete(), which removes every location.
                if readItem(account: account, service: service, dataProtection: true) == value {
                    SecItemDelete(baseQuery(account: account, service: svc, dataProtection: dataProtection) as CFDictionary)
                }
                return value
            }
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
        var query = baseQuery(account: account, service: service, dataProtection: true)
        let attrs = [kSecValueData as String: data] as CFDictionary
        let status = SecItemUpdate(query as CFDictionary, attrs)
        if status == errSecSuccess { return }
        if status == errSecItemNotFound {
            query[kSecValueData as String] = data
            // Accessible after first device unlock — no repeated password prompts.
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            if SecItemAdd(query as CFDictionary, nil) == errSecSuccess { return }
        }
        // Data-protection keychain unavailable (e.g. unsigned test process); fall back
        // to the legacy keychain. get() already checks (service, dataProtection: false).
        var legacyQuery = baseQuery(account: account, service: service, dataProtection: false)
        let legacyStatus = SecItemUpdate(legacyQuery as CFDictionary, attrs)
        if legacyStatus == errSecItemNotFound {
            legacyQuery[kSecValueData as String] = data
            SecItemAdd(legacyQuery as CFDictionary, nil)
        }
    }

    private func delete(account: String) {
        // Clear the secret from every place get() might find it — current and legacy
        // service, data-protection and legacy keychain — so a cleared key stays cleared.
        SecItemDelete(baseQuery(account: account, service: service, dataProtection: true) as CFDictionary)
        SecItemDelete(baseQuery(account: account, service: service, dataProtection: false) as CFDictionary)
        SecItemDelete(baseQuery(account: account, service: Self.legacyService, dataProtection: true) as CFDictionary)
        SecItemDelete(baseQuery(account: account, service: Self.legacyService, dataProtection: false) as CFDictionary)
    }

    private func readItem(account: String, service: String, dataProtection: Bool) -> String? {
        var query = baseQuery(account: account, service: service, dataProtection: dataProtection)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func baseQuery(account: String, service: String, dataProtection: Bool) -> [String: Any] {
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
