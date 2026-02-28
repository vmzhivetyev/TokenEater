import Foundation
import Security

enum KeychainOAuthReader {
    struct OAuthCredentials {
        let accessToken: String
    }

    private static let cacheService = "TokenEater-cached-oauth"
    private static let cacheAccount = "accessToken"

    static func readClaudeCodeToken() -> OAuthCredentials? {
        // Read raw data from Claude Code's keychain item
        let sourceQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(sourceQuery as CFDictionary, &result)

        guard status == errSecSuccess,
              let sourceData = result as? Data,
              let json = try? JSONSerialization.jsonObject(with: sourceData) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.isEmpty
        else {
            deleteCachedToken()
            return nil
        }

        // Cache the token string in our own keychain item so subsequent
        // callers can skip parsing the Claude Code item entirely.
        cacheToken(token, sourceDataHash: sourceData.hashValue)

        return OAuthCredentials(accessToken: token)
    }

    /// Fast path: returns the cached token without touching Claude Code's keychain.
    /// Falls back to `readClaudeCodeToken()` on a cache miss.
    static func cachedToken() -> OAuthCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: cacheService,
            kSecAttrAccount as String: cacheAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty
        else {
            return readClaudeCodeToken()
        }
        return OAuthCredentials(accessToken: token)
    }

    // MARK: - Cache management

    /// Clears the cached token so the next `cachedToken()` call re-reads from Claude Code's keychain.
    static func invalidateCache() {
        deleteCachedToken()
    }

    // MARK: - Private helpers

    private static func cacheToken(_ token: String, sourceDataHash: Int) {
        guard let tokenData = token.data(using: .utf8) else { return }

        // Check if the cache already holds the same token to avoid redundant writes.
        let readQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: cacheService,
            kSecAttrAccount as String: cacheAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var existing: AnyObject?
        if SecItemCopyMatching(readQuery as CFDictionary, &existing) == errSecSuccess,
           let existingData = existing as? Data,
           existingData == tokenData {
            return // already cached — no write needed
        }

        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: cacheService,
            kSecAttrAccount as String: cacheAccount,
            kSecValueData as String: tokenData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        // Delete stale entry first, then add fresh one.
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: cacheService,
            kSecAttrAccount as String: cacheAccount,
        ] as CFDictionary)
        SecItemAdd(attrs as CFDictionary, nil)
    }

    private static func deleteCachedToken() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: cacheService,
            kSecAttrAccount as String: cacheAccount,
        ] as CFDictionary)
    }
}
