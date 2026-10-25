import CryptoKit
import Foundation

/// 本机 Kimi Code CLI 的登录态，只读不写：凭据是 CLI 自己写到
/// `credentials/<profile>.json` 的 OAuth token，cc-bar 读取后只发给官方 endpoint。
/// 用户也可能在 config.toml 的 `providers."managed:kimi-code"` 段直接配置官方 API key。
nonisolated struct KimiAuthSession: Sendable, Equatable {
    enum Source: String, Sendable {
        case kimiCode
        case legacyCLI
        case apiKey

        var displayName: String {
            switch self {
            case .kimiCode: return "Kimi Code"
            case .legacyCLI: return "Kimi 旧版 CLI"
            case .apiKey: return "API Key"
            }
        }
    }

    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    /// 读取的凭据文件位置；API key 来源为 nil。
    var credentialURL: URL?
    var homeDirectory: URL
    /// 只可能是官方地址，见 `KimiCredentials` 的白名单校验。
    var baseURL: URL
    var oauthHost: URL
    /// JWT payload 的 user_id / sub，仅内存使用，不展示、不写日志。
    var userID: String?
    var source: Source

    /// 稳定身份键：JWT 可用 `baseURL.host + userID` 稳定区分账号；API key 或
    /// 不透明 token 没有可读身份，只能以密钥完整 SHA-256 摘要区分。
    /// 摘要不可逆、不含密钥片段，只用于缓存绑定与切号判断。
    var accountKey: String {
        if let userID, !userID.isEmpty, let host = baseURL.host {
            return Self.digest(host + userID)
        }
        return Self.digest(accessToken)
    }

    private static func digest(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Kimi Code 凭据加载。新版根目录 `$KIMI_CODE_HOME`（默认 `~/.kimi-code`），
/// 旧版 `$KIMI_SHARE_DIR`（默认 `~/.kimi`），均可用环境变量覆写。
///
/// 安全边界：
/// - 只接受官方 base_url `https://api.kimi.com/coding/v1` / `https://api.kimi.ai/coding/v1`
///   和官方 OAuth host `auth.kimi.com` / `auth.kimi.ai`；config 里的自定义第三方主机
///   一律不接受，已读凭据绝不发往非官方地址，第三方 provider 的 api_key 也不当成 Kimi key。
/// - OAuth key 只取 `credentials/` 下的安全 basename，禁止目录穿越。
/// - token 过期不视为无效（刷新由调用方负责）；被撤销 tombstone（空 token）、
///   空白或含换行的 token 直接拒绝。
/// - 不刷新、不写回 token，不访问钥匙串。
nonisolated enum KimiCredentials {
    static let defaultBaseURL = URL(string: "https://api.kimi.com/coding/v1")!
    static let globalBaseURL = URL(string: "https://api.kimi.ai/coding/v1")!
    static let defaultOAuthHost = URL(string: "https://auth.kimi.com")!
    static let globalOAuthHost = URL(string: "https://auth.kimi.ai")!

    /// config.toml 的 `providers."managed:kimi-code"` 段中我们关心的字段。
    private struct ManagedProviderConfig {
        var baseURLString: String?
        var apiKey: String?
        var oauthStorage: String?
        var oauthKey: String?
        var oauthHostString: String?
    }

    static func load(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> KimiAuthSession? {
        // 1. 新版 Kimi Code
        let newRoot = rootDirectory(
            envVar: "KIMI_CODE_HOME",
            defaultPath: ".kimi-code",
            homeDirectory: homeDirectory,
            environment: environment
        )
        if let session = loadFromRoot(newRoot, homeDirectory: homeDirectory, source: .kimiCode) {
            return session
        }

        // 2. 旧版 CLI
        let legacyRoot = rootDirectory(
            envVar: "KIMI_SHARE_DIR",
            defaultPath: ".kimi",
            homeDirectory: homeDirectory,
            environment: environment
        )
        if let session = loadFromRoot(legacyRoot, homeDirectory: homeDirectory, source: .legacyCLI) {
            return session
        }

        return nil
    }

    // MARK: - 根目录

    private static func rootDirectory(
        envVar: String,
        defaultPath: String,
        homeDirectory: URL,
        environment: [String: String]
    ) -> URL {
        if let override = environment[envVar]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty, override.hasPrefix("/") {
            return URL(fileURLWithPath: override)
        }
        return homeDirectory.appendingPathComponent(defaultPath)
    }

    // MARK: - 单个根目录的加载

    private static func loadFromRoot(
        _ root: URL,
        homeDirectory: URL,
        source: KimiAuthSession.Source
    ) -> KimiAuthSession? {
        let config = parseConfigFile(at: root.appendingPathComponent("config.toml"))

        // base_url：官方或缺省 → 采用；自定义第三方主机 → 不接受，连接回落官方默认
        // 地址（已读凭据绝不发往非官方主机）。凭据文件里的 OAuth token 是官方
        // 签发的，照常读取；只有该 provider 段的 api_key 属于第三方时不采用。
        let configuredBase = officialBaseURL(from: config?.baseURLString)
        let providerKeyTrusted = config?.baseURLString == nil || configuredBase != nil
        let baseURL = configuredBase ?? defaultBaseURL
        let oauthHost = officialOAuthHost(from: config?.oauthHostString)
            ?? (baseURL == globalBaseURL ? globalOAuthHost : defaultOAuthHost)

        // 1. OAuth 凭据文件。storage 明确不是 "file"（如 keychain）时本就读不到，跳过。
        let fileStorage = config?.oauthStorage == nil || config?.oauthStorage == "file"
        if fileStorage {
            guard let storageName = config?.oauthKey.map(credentialStorageName(forOAuthKey:)) ?? .some("kimi-code") else { return nil }
            let credentialURL = root.appendingPathComponent("credentials/\(storageName).json")
            if let parsed = readCredentialFile(at: credentialURL) {
                return KimiAuthSession(
                    accessToken: parsed.accessToken,
                    refreshToken: parsed.refreshToken,
                    expiresAt: parsed.expiresAt,
                    credentialURL: credentialURL,
                    homeDirectory: homeDirectory,
                    baseURL: baseURL,
                    oauthHost: oauthHost,
                    userID: parsed.userID,
                    source: source
                )
            }
        }

        // 2. 该 provider 段的官方 API key。base_url 是第三方主机时这个 key 也属于
        // 第三方，不能当成 Kimi key 发给官方（其他 provider 段的 api_key 本来就不会被读到）。
        if providerKeyTrusted, let key = sanitizeToken(config?.apiKey) {
            return KimiAuthSession(
                accessToken: key,
                refreshToken: nil,
                expiresAt: nil,
                credentialURL: nil,
                homeDirectory: homeDirectory,
                baseURL: baseURL,
                oauthHost: oauthHost,
                userID: nil,
                source: .apiKey
            )
        }

        return nil
    }

    // MARK: - 凭据文件

    private struct ParsedCredentialFile {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date?
        var userID: String?
    }

    private static func readCredentialFile(at url: URL) -> ParsedCredentialFile? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        // tombstone（撤销后 CLI 写回的空 token）和空白 / 含换行的 token 都拒绝。
        guard let accessToken = sanitizeToken(json["access_token"] as? String) else { return nil }

        var userID = jwtUserID(accessToken)
        if userID == nil, let refresh = sanitizeToken(json["refresh_token"] as? String) {
            userID = jwtUserID(refresh)
        }

        return ParsedCredentialFile(
            accessToken: accessToken,
            refreshToken: sanitizeToken(json["refresh_token"] as? String),
            // 过期不拒绝；expires_at 是 Unix 秒，缺失或 0 视为未知。
            expiresAt: unixSeconds(json["expires_at"]).map { Date(timeIntervalSince1970: $0) },
            userID: userID
        )
    }

    static func jwtUserID(_ token: String) -> String? {
        guard let payload = JWT.decodePayload(token) else { return nil }
        if let id = payload["user_id"] as? String, !id.isEmpty { return id }
        if let number = payload["user_id"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return number.stringValue
        }
        if let id = payload["sub"] as? String, !id.isEmpty { return id }
        return nil
    }

    private static func unixSeconds(_ value: Any?) -> Double? {
        let number: Double?
        if let nsNumber = value as? NSNumber, CFGetTypeID(nsNumber) != CFBooleanGetTypeID() {
            number = nsNumber.doubleValue
        } else if let string = value as? String {
            number = Double(string)
        } else {
            return nil
        }
        guard let number, number.isFinite, number > 0 else { return nil }
        return number
    }

    // MARK: - 官方地址白名单

    /// 只接受两个官方 coding endpoint，按 origin(lowercased) + 去尾斜杠的路径比较。
    private static func officialBaseURL(from raw: String?) -> URL? {
        guard let raw, !raw.isEmpty, let url = URL(string: raw),
              url.scheme?.lowercased() == "https", let host = url.host?.lowercased()
        else { return nil }
        var path = url.path
        while path.hasSuffix("/") { path.removeLast() }
        if host == "api.kimi.com", path == "/coding/v1" { return defaultBaseURL }
        if host == "api.kimi.ai", path == "/coding/v1" { return globalBaseURL }
        return nil
    }

    private static func officialOAuthHost(from raw: String?) -> URL? {
        guard let raw, !raw.isEmpty, let url = URL(string: raw),
              url.scheme?.lowercased() == "https", let host = url.host?.lowercased()
        else { return nil }
        switch host {
        case "auth.kimi.com": return defaultOAuthHost
        case "auth.kimi.ai": return globalOAuthHost
        default: return nil
        }
    }

    // MARK: - OAuth key → 凭据文件 basename

    /// 与 CLI 的 `resolveKimiTokenStorageName` + `validateProfileName` 对齐：
    /// "kimi-code" / "oauth/kimi-code" → "kimi-code"；"oauth/<name>" → <name>（含
    /// env- 槽位）；其余按原样。只允许字母、数字、`_` `.` `-`，禁止 `.`/`..` 与
    /// 路径分隔符，目录穿越的 key 一律拒绝。
    static func credentialStorageName(forOAuthKey key: String) -> String? {
        let name: String
        if key == "kimi-code" || key == "oauth/kimi-code" {
            name = "kimi-code"
        } else if key.hasPrefix("oauth/"), key.count > 6 {
            name = String(key.dropFirst(6))
        } else if !key.contains("/") && !key.hasPrefix(".") {
            name = key
        } else {
            return nil
        }
        guard name != ".", name != "..", !name.contains("/"), !name.contains("\\") else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_.-"))
        guard name.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return name
    }

    // MARK: - Token 清洗

    /// 与 `CommandCodeAuth.sanitizeToken` 同规则：去首尾空白、至少 10 字符、
    /// 只含可打印 ASCII（自然拒绝含换行的 token）。
    static func sanitizeToken(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 10 else { return nil }
        guard trimmed.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value <= 0x7E }) else {
            return nil
        }
        return trimmed
    }

    // MARK: - config.toml 解析

    /// 只解析 `providers."managed:kimi-code"` 段及其 oauth 子段，不引入 TOML 依赖。
    private static func parseConfigFile(at url: URL) -> ManagedProviderConfig? {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else { return nil }

        var config = ManagedProviderConfig()
        var matched = false
        var section: [String] = []

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = stripComment(from: String(rawLine)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("[") && line.hasSuffix("]") {
                let header = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                section = parseKeyPath(header)
                continue
            }

            guard let eq = line.firstIndex(of: "=") else { continue }
            guard let key = parseKey(String(line[..<eq])) else { continue }
            let rawValue = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)

            switch section {
            case ["providers", "managed:kimi-code"]:
                matched = true
                if key == "base_url" {
                    config.baseURLString = parseStringValue(rawValue)
                } else if key == "api_key" {
                    config.apiKey = parseStringValue(rawValue)
                } else if key == "oauth" {
                    let table = parseInlineTable(rawValue)
                    if let storage = table["storage"] { config.oauthStorage = storage }
                    if let oauthKey = table["key"] { config.oauthKey = oauthKey }
                    if let oauthHost = table["oauth_host"] { config.oauthHostString = oauthHost }
                }
            case ["providers", "managed:kimi-code", "oauth"]:
                matched = true
                guard let value = parseStringValue(rawValue) else { continue }
                if key == "storage" {
                    config.oauthStorage = value
                } else if key == "key" {
                    config.oauthKey = value
                } else if key == "oauth_host" {
                    config.oauthHostString = value
                }
            default:
                continue
            }
        }

        return matched ? config : nil
    }

    /// 去掉 `#` 注释（字符串字面量内的 `#` 保留）。
    private static func stripComment(from line: String) -> String {
        var inBasic = false
        var inLiteral = false
        var escaped = false
        for (index, ch) in line.enumerated() {
            if escaped { escaped = false; continue }
            if inBasic && ch == "\\" { escaped = true; continue }
            if ch == "\"", !inLiteral { inBasic.toggle() }
            else if ch == "'", !inBasic { inLiteral.toggle() }
            else if ch == "#", !inBasic, !inLiteral { return String(line.prefix(index)) }
        }
        return line
    }

    /// 解析 `[a."b.c".d]` 形式的节路径，引号内的 `.` 不分段。
    private static func parseKeyPath(_ header: String) -> [String] {
        var segments: [String] = []
        var current = ""
        var inBasic = false
        var inLiteral = false
        var index = header.startIndex
        while index < header.endIndex {
            let ch = header[index]
            if inLiteral {
                if ch == "'" { inLiteral = false } else { current.append(ch) }
            } else if inBasic {
                if ch == "\\" {
                    let next = header.index(after: index)
                    if next < header.endIndex {
                        current.append(header[next])
                        index = next
                    }
                } else if ch == "\"" {
                    inBasic = false
                } else {
                    current.append(ch)
                }
            } else if ch == "\"" {
                inBasic = true
            } else if ch == "'" {
                inLiteral = true
            } else if ch == "." {
                segments.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(ch)
            }
            index = header.index(after: index)
        }
        segments.append(current.trimmingCharacters(in: .whitespaces))
        return segments
    }

    /// 解析 `key` 部分：裸键或带引号的键。
    private static func parseKey(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("\"") || trimmed.hasPrefix("'") {
            return parseStringValue(trimmed)
        }
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 解析字符串值：支持基本字符串（含常见转义）与字面量字符串。
    private static func parseStringValue(_ raw: String) -> String? {
        guard let first = raw.first else { return nil }
        if first == "\"" {
            var result = ""
            var index = raw.index(after: raw.startIndex)
            while index < raw.endIndex {
                let ch = raw[index]
                if ch == "\\" {
                    let next = raw.index(after: index)
                    guard next < raw.endIndex else { return nil }
                    switch raw[next] {
                    case "\"": result.append("\"")
                    case "\\": result.append("\\")
                    case "n": result.append("\n")
                    case "t": result.append("\t")
                    case "r": result.append("\r")
                    default: result.append(raw[next])
                    }
                    index = raw.index(after: next)
                    continue
                }
                if ch == "\"" { return result }
                result.append(ch)
                index = raw.index(after: index)
            }
            return nil
        }
        if first == "'" {
            let body = raw.dropFirst()
            guard let end = body.firstIndex(of: "'") else { return nil }
            return String(body[..<end])
        }
        return nil
    }

    /// 解析内联表 `oauth = { storage = "file", key = "oauth/kimi-code" }`。
    private static func parseInlineTable(_ raw: String) -> [String: String] {
        var table: [String: String] = [:]
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}") else { return table }
        for pair in splitTopLevelCommas(String(trimmed.dropFirst().dropLast())) {
            guard let eq = pair.firstIndex(of: "=") else { continue }
            guard let key = parseKey(String(pair[..<eq])) else { continue }
            let value = parseStringValue(String(pair[pair.index(after: eq)...]).trimmingCharacters(in: .whitespaces))
            table[key] = value ?? ""
        }
        return table
    }

    /// 按顶层逗号切分（字符串字面量内的逗号不切）。
    private static func splitTopLevelCommas(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var inBasic = false
        var inLiteral = false
        for ch in text {
            if ch == "\"", !inLiteral { inBasic.toggle() }
            else if ch == "'", !inBasic { inLiteral.toggle() }
            if ch == ",", !inBasic, !inLiteral {
                parts.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { parts.append(current) }
        return parts
    }
}
