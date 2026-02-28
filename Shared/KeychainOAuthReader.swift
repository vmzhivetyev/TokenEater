import Foundation

enum KeychainOAuthReader {
    struct OAuthCredentials {
        let accessToken: String
    }

    private static let claudeCodeItem = KeychainItem(service: "Claude Code-credentials", account: "")
    private static let cacheItem = KeychainItem(service: "TokenEater-cached-oauth", account: "accessToken")

    /// Fast path: returns the cached token without touching Claude Code's keychain.
    /// Falls back to `readFromClaudeCodeKeychain()` on a cache miss.
    static func cachedToken() -> OAuthCredentials? {
        if let data = cacheItem.read(),
           let token = String(data: data, encoding: .utf8),
           !token.isEmpty {
            return OAuthCredentials(accessToken: token)
        }
        return readFromClaudeCodeKeychain()
    }

    /// Clears the cached token so the next `cachedToken()` call re-reads from Claude Code's keychain.
    static func invalidateCache() {
        cacheItem.delete()
    }

    // MARK: - Private

    /// Reads the token directly from Claude Code's keychain item.
    /// - Warning: May trigger a macOS keychain access prompt to the user.
    ///   Prefer `cachedToken()` for routine access.
    private static func readFromClaudeCodeKeychain() -> OAuthCredentials? {
        guard let sourceData = claudeCodeItem.read(),
              let json = try? JSONSerialization.jsonObject(with: sourceData) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.isEmpty
        else {
            cacheItem.delete()
            return nil
        }

        updateCacheIfNeeded(token: token, sourceData: sourceData)
        return OAuthCredentials(accessToken: token)
    }

    private static func updateCacheIfNeeded(token: String, sourceData: Data) {
        guard let tokenData = token.data(using: .utf8) else { return }
        if cacheItem.read() == tokenData { return }
        cacheItem.write(tokenData)
    }
}
