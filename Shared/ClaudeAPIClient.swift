import Foundation
import OSLog

private let logger = Logger(subsystem: "com.TokenEater", category: "APIClient")

final class ClaudeAPIClient {
    static let shared = ClaudeAPIClient()

    private let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// Set by host app (from UserDefaults) or widget (from AppIntent)
    var proxyConfig: ProxyConfig?

    private var session: URLSession {
        guard let proxy = proxyConfig, proxy.enabled else { return .shared }
        let c = URLSessionConfiguration.default
        c.connectionProxyDictionary = [
            kCFNetworkProxiesSOCKSEnable as String: true,
            kCFNetworkProxiesSOCKSProxy as String: proxy.host,
            kCFNetworkProxiesSOCKSPort as String: proxy.port,
        ]
        return URLSession(configuration: c)
    }

    // MARK: - Auth

    var isConfigured: Bool {
        KeychainOAuthReader.cachedToken() != nil
    }

    // MARK: - Fetch Usage

    func fetchUsage() async throws -> UsageResponse {
        guard let oauth = KeychainOAuthReader.cachedToken() else {
            logger.error("fetchUsage: no token available")
            throw ClaudeAPIError.noToken
        }

        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(oauth.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        logger.debug("fetchUsage: sending request")
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            logger.error("fetchUsage: invalid response (not HTTP)")
            throw ClaudeAPIError.invalidResponse
        }

        logger.debug("fetchUsage: received status \(httpResponse.statusCode)")

        switch httpResponse.statusCode {
        case 200:
            let usage = try JSONDecoder().decode(UsageResponse.self, from: data)
            UsageLogger.shared.append(usage)
            logger.info("fetchUsage: success")
            return usage
        case 401, 403:
            logger.warning("fetchUsage: token expired (status \(httpResponse.statusCode))")
            KeychainOAuthReader.invalidateCache()
            throw ClaudeAPIError.tokenExpired
        default:
            logger.error("fetchUsage: unexpected status \(httpResponse.statusCode)")
            throw ClaudeAPIError.httpError(httpResponse.statusCode)
        }
    }

    // MARK: - Test Connection

    func testConnection() async -> ConnectionTestResult {
        guard let oauth = KeychainOAuthReader.cachedToken() else {
            logger.error("testConnection: no token available")
            return ConnectionTestResult(success: false, message: String(localized: "error.notoken"))
        }

        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(oauth.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        logger.debug("testConnection: sending request")

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                logger.error("testConnection: invalid response (not HTTP)")
                return ConnectionTestResult(success: false, message: String(localized: "error.invalidresponse.short"))
            }

            logger.debug("testConnection: received status \(httpResponse.statusCode)")

            if httpResponse.statusCode == 200 {
                guard let usage = try? JSONDecoder().decode(UsageResponse.self, from: data) else {
                    logger.error("testConnection: failed to decode UsageResponse (unsupported plan?)")
                    return ConnectionTestResult(success: false, message: String(localized: "error.unsupportedplan"))
                }
                let sessionPct = usage.fiveHour?.utilization ?? 0
                logger.info("testConnection: success, utilization=\(sessionPct, format: .fixed(precision: 1))%")
                return ConnectionTestResult(success: true, message: String(format: String(localized: "test.success"), Int(sessionPct)))
            } else if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                logger.warning("testConnection: token expired (status \(httpResponse.statusCode))")
                KeychainOAuthReader.invalidateCache()
                return ConnectionTestResult(success: false, message: String(format: String(localized: "test.expired"), httpResponse.statusCode))
            } else {
                logger.error("testConnection: unexpected status \(httpResponse.statusCode)")
                return ConnectionTestResult(success: false, message: String(format: String(localized: "test.http"), httpResponse.statusCode))
            }
        } catch {
            logger.error("testConnection: network error — \(error.localizedDescription)")
            return ConnectionTestResult(success: false, message: String(format: String(localized: "error.network"), error.localizedDescription))
        }
    }

}

// MARK: - Error

enum ClaudeAPIError: LocalizedError {
    case noToken
    case invalidResponse
    case tokenExpired
    case unsupportedPlan
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .noToken:
            return String(localized: "error.notoken")
        case .invalidResponse:
            return String(localized: "error.invalidresponse")
        case .tokenExpired:
            return String(localized: "error.tokenexpired")
        case .unsupportedPlan:
            return String(localized: "error.unsupportedplan")
        case .httpError(let code):
            return String(format: String(localized: "error.http"), code)
        }
    }
}

// MARK: - Test Result

struct ConnectionTestResult {
    let success: Bool
    let message: String
}
