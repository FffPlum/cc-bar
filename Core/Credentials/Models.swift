import Foundation

enum CredentialSource: String, Sendable {
    case file
    case keychain
    /// Claude Desktop 的 Electron token 缓存。只借用其中的 access_token，
    /// 永不读取 / 使用其 refresh_token，详见 `ClaudeDesktopAuth`。
    case desktop
}

struct CodexAccount: Sendable, Equatable {
    var email: String?
    var planType: String?
    var accountId: String?
    var chatgptUserId: String?
    var lastRefresh: Date?
    var expiredGuess: Bool
    var rawClaimKeys: [String]
    /// 仅内存使用，不打印 / 不持久化到 UserDefaults
    var accessToken: String?
    var refreshToken: String?
    var idToken: String?
    /// auth.json 走 `personal_access_token`（Codex 工作区访问令牌）时为 true。
    /// 该令牌是不透明字符串、无 exp / refresh，取数时跳过 OAuth 续期，
    /// 身份（email/plan/account_id）由 `wham/usage` 响应回填。
    var isPersonalAccessToken: Bool = false
}

struct ClaudeAccount: Sendable, Equatable {
    var source: CredentialSource
    var email: String?
    /// 来自 `~/.claude.json` 的 `oauthAccount`，用于和 Claude Desktop 的凭据缓存
    /// 做账号比对——两边同属一个账号才允许借用 Desktop 的 access_token。
    var accountUuid: String?
    var organizationUuid: String?
    /// 本地凭据里记录的套餐，只在签发 / 刷新 token 时写入，可能落后于实际订阅；
    /// 展示优先用 `/api/oauth/profile` 的结果（`AppState.claudePlanName`）。
    var subscriptionType: String?
    var expiresAt: Date?
    var expiredGuess: Bool
    /// 仅内存使用，不打印 / 不持久化到 UserDefaults
    var accessToken: String?
    var refreshToken: String?
    /// CLI 凭据里的 `rateLimitTier`，区分 Max 5x / 20x。
    var rateLimitTier: String? = nil

    /// 本地凭据推出的套餐名，profile 查询失败时兜底。
    var localPlanName: String? {
        Self.planName(type: subscriptionType, rateLimitTier: rateLimitTier)
    }

    /// `pro` / `claude_pro` → `Pro`；Max 按 `rateLimitTier` 细分为 `Max 5x` / `Max 20x`。
    nonisolated static func planName(type: String?, rateLimitTier: String?) -> String? {
        var base = type?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if base.hasPrefix("claude_") { base.removeFirst("claude_".count) }
        guard !base.isEmpty else { return nil }
        if base == "max" {
            let tier = rateLimitTier?.lowercased() ?? ""
            if tier.contains("max_20x") { return "Max 20x" }
            if tier.contains("max_5x") { return "Max 5x" }
            return "Max"
        }
        return base.capitalized
    }
}

enum CredentialError: Error, CustomStringConvertible {
    case fileNotFound(String)
    case invalidJSON(String)
    case keychainUnavailable(String)
    case decodeFailed(String)

    var description: String {
        switch self {
        case .fileNotFound(let p): return "file not found: \(p)"
        case .invalidJSON(let p): return "invalid JSON at: \(p)"
        case .keychainUnavailable(let m): return "keychain unavailable: \(m)"
        case .decodeFailed(let m): return "decode failed: \(m)"
        }
    }
}
