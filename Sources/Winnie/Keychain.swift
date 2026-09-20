import Foundation
import Security

@MainActor
enum Keychain {
    private static let service = "local.winnie.pet"
    private static let account = "anthropic-api-key"

    /// Every read of the secret can raise a macOS permission prompt, so it is
    /// read at most once per launch and kept in memory afterwards.
    private static var cached: String?

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// Asks only for the item's attributes, which never triggers the prompt.
    static var hasAPIKey: Bool {
        if let cached { return !cached.isEmpty }
        var query = baseQuery
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    static func loadAPIKey() -> String {
        if let cached { return cached }
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        let key = (item as? Data).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        // A denied prompt is not cached, so the next message can ask again.
        if status == errSecSuccess || status == errSecItemNotFound { cached = key }
        return key
    }

    static func saveAPIKey(_ key: String) {
        SecItemDelete(baseQuery as CFDictionary)
        cached = key
        guard !key.isEmpty else { return }
        var query = baseQuery
        query[kSecValueData as String] = Data(key.utf8)
        SecItemAdd(query as CFDictionary, nil)
    }
}
