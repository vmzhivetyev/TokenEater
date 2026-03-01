import Foundation
import OSLog

private let logger = Logger(subsystem: "com.TokenEater", category: "KeychainOAuthReader")

enum KeychainOAuthReader {
    struct OAuthCredentials {
        let accessToken: String
    }

    private static let claudeCodeItem = KeychainItem(service: "Claude Code-credentials", account: NSUserName())
    private static let cacheItem = KeychainItem(service: "TokenEater-cached-oauth", account: "accessToken")

    /// Fast path: returns the cached token without touching Claude Code's keychain.
    /// Falls back to `readFromClaudeCodeKeychain()` on a cache miss.
    static func cachedToken() -> OAuthCredentials? {
        if let data = cacheItem.read(),
           let token = String(data: data, encoding: .utf8),
           !token.isEmpty {
            logger.debug("cachedToken: cache hit")
            return OAuthCredentials(accessToken: token)
        }
        logger.debug("cachedToken: cache miss, reading from Claude Code keychain")
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
        guard let sourceData = claudeCodeItem.read() else {
            logger.error("readFromClaudeCodeKeychain: keychain item not found (Claude Code not installed or not logged in?)")
            cacheItem.delete()
            return nil
        }
        guard let json = try? JSONSerialization.jsonObject(with: sourceData) as? [String: Any] else {
            logger.error("readFromClaudeCodeKeychain: failed to parse keychain data as JSON")
            cacheItem.delete()
            return nil
        }
        guard let oauth = json["claudeAiOauth"] as? [String: Any] else {
            logger.error("readFromClaudeCodeKeychain: 'claudeAiOauth' key missing, top-level keys: \(json.keys.joined(separator: ", "))")
            cacheItem.delete()
            return nil
        }
        guard let token = oauth["accessToken"] as? String, !token.isEmpty else {
            logger.error("readFromClaudeCodeKeychain: 'accessToken' missing or empty, oauth keys: \(oauth.keys.joined(separator: ", "))")
            cacheItem.delete()
            return nil
        }

        logger.debug("readFromClaudeCodeKeychain: token read successfully")
        updateCacheIfNeeded(token: token, sourceData: sourceData)
        return OAuthCredentials(accessToken: token)
    }

    private static func updateCacheIfNeeded(token: String, sourceData: Data) {
        guard let tokenData = token.data(using: .utf8) else { return }
        if cacheItem.read() == tokenData { return }
        cacheItem.write(tokenData)
    }
}
