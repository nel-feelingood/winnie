import Foundation
import Security

/// Winnie's secrets in the macOS Keychain, one generic-password item per account name.
@MainActor
enum Keychain {
    enum Account: String {
        case anthropicKey = "anthropic-api-key"
        case googleClientID = "google-client-id"
        case googleClientSecret = "google-client-secret"
        case googleRefreshToken = "google-refresh-token"
        case telegramBotToken = "telegram-bot-token"
    }

    private static let service = "local.winnie.pet"

    /// Every read of a secret can raise a macOS permission prompt, so each is read at
    /// most once per launch and kept in memory afterwards.
    private static var cache: [String: String] = [:]

    /// Status of the most recent failed read, for an honest error message.
    private(set) static var lastFailure: OSStatus?

    private static func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func has(_ account: Account) -> Bool { has(named: account.rawValue) }
    static func load(_ account: Account) -> String { load(named: account.rawValue) }
    static func save(_ value: String, for account: Account) { save(value, named: account.rawValue) }

    /// Asks only for the item's attributes, which never triggers the prompt.
    /// For secrets whose names are only known at run time, such as one token per connected app.
    static func has(named account: String) -> Bool {
        if let cached = cache[account] { return !cached.isEmpty }
        var query = baseQuery(account)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    static func load(named account: String) -> String {
        if let cached = cache[account] { return cached }
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        let value = (item as? Data).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        // A denied prompt is not cached, so the next attempt can ask again.
        if status == errSecSuccess || status == errSecItemNotFound {
            cache[account] = value
            lastFailure = nil
        } else {
            lastFailure = status
        }
        return value
    }

    static func save(_ value: String, named account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
        cache[account] = value
        guard !value.isEmpty else { return }
        var query = baseQuery(account)
        query[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(query as CFDictionary, nil)
    }

    static var hasAPIKey: Bool { has(.anthropicKey) }
    static func loadAPIKey() -> String { load(.anthropicKey) }
    static func saveAPIKey(_ key: String) { save(key, for: .anthropicKey) }
}
