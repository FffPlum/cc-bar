import Foundation
import Security

struct CommandCodeAuthSession: Sendable, Equatable {
    enum Source: String, Sendable, Equatable {
        case commandCodeCLI = "commandcode"
        case pi = "pi"
        case opencode = "opencode"
        case environment = "env"
        case manualKeychain = "keychain"

        var displayName: String {
            switch self {
            case .commandCodeCLI: return "Command Code CLI"
            case .pi: return "Pi"
            case .opencode: return "OpenCode"
            case .environment: return "环境变量"
            case .manualKeychain: return "手动 API Key"
            }
        }
    }

    var accessToken: String
    var source: Source
    var login: String?
    var name: String?
    var email: String?
    var orgID: String?
    var planType: String?
    /// whoami 回填的稳定身份，仅用于通知；既有额度缓存账号键保持原规则。
    var userID: String? = nil

    var accountKey: String {
        if let orgID, !orgID.isEmpty {
            return "org:\(orgID):\(login ?? email ?? "user")"
        }
        if let login, !login.isEmpty {
            return "user:\(login)"
        }
        if let email, !email.isEmpty {
            return "email:\(email)"
        }
        let prefix = String(accessToken.prefix(8))
        let suffix = String(accessToken.suffix(6))
        return "token:\(prefix)...\(suffix)"
    }
}

enum CommandCodeAuth {
    private static let keychainService = "com.fffplum.ccbar.command-code"
    private static let keychainAccount = "primary"
    private static let legacy = CachedManagedKeychain(service: keychainService)
    private static let credentials = PrivateCredentialFileStore(directory:
        ImportedCodexStore.fileURL().deletingLastPathComponent()
            .appendingPathComponent("command-code_credentials", isDirectory: true))

    static func load(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        preference: CommandCodeCredentialPreference = .automatic
    ) -> CommandCodeAuthSession? {
        if preference == .manual {
            if let manualKey = loadStoredKey(), let token = sanitizeToken(manualKey) {
                return CommandCodeAuthSession(accessToken: token, source: .manualKeychain)
            }
            return nil
        }

        // 1. ~/.commandcode/auth.json
        if let session = loadFromCommandCodeCLI(homeDirectory: homeDirectory) {
            return session
        }

        // 2. ~/.pi/agent/auth.json
        if let session = loadFromPi(homeDirectory: homeDirectory) {
            return session
        }

        // 3. ~/.local/share/opencode/auth.json
        if let session = loadFromOpenCode(homeDirectory: homeDirectory) {
            return session
        }

        // 4. 环境变量 COMMAND_CODE_API_KEY / COMMANDCODE_API_KEY
        if let session = loadFromEnvironment() {
            return session
        }

        // 5. 自动降级读取 CCBar 手动配置
        if let manualKey = loadStoredKey(), let token = sanitizeToken(manualKey) {
            return CommandCodeAuthSession(accessToken: token, source: .manualKeychain)
        }

        return nil
    }

    private static func loadFromCommandCodeCLI(homeDirectory: URL) -> CommandCodeAuthSession? {
        let path = homeDirectory.appendingPathComponent(".commandcode/auth.json")
        return readTokenFile(at: path, source: .commandCodeCLI)
    }

    private static func loadFromPi(homeDirectory: URL) -> CommandCodeAuthSession? {
        let path = homeDirectory.appendingPathComponent(".pi/agent/auth.json")
        return readProviderKey(at: path, providerKeys: ["commandcode", "command-code"], source: .pi)
    }

    private static func loadFromOpenCode(homeDirectory: URL) -> CommandCodeAuthSession? {
        let path = homeDirectory.appendingPathComponent(".local/share/opencode/auth.json")
        return readProviderKey(at: path, providerKeys: ["command-code", "commandcode"], source: .opencode)
    }

    private static func loadFromEnvironment() -> CommandCodeAuthSession? {
        if let key = ProcessInfo.processInfo.environment["COMMAND_CODE_API_KEY"],
           let token = sanitizeToken(key) {
            return CommandCodeAuthSession(accessToken: token, source: .environment)
        }
        if let key = ProcessInfo.processInfo.environment["COMMANDCODE_API_KEY"],
           let token = sanitizeToken(key) {
            return CommandCodeAuthSession(accessToken: token, source: .environment)
        }
        return nil
    }

    private static func readTokenFile(at url: URL, source: CommandCodeAuthSession.Source) -> CommandCodeAuthSession? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        if let token = sanitizeToken(json["access"] as? String ?? json["access_token"] as? String ?? json["apiKey"] as? String ?? json["token"] as? String) {
            return CommandCodeAuthSession(accessToken: token, source: source)
        }
        return nil
    }

    private static func readProviderKey(
        at url: URL,
        providerKeys: [String],
        source: CommandCodeAuthSession.Source
    ) -> CommandCodeAuthSession? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        for key in providerKeys {
            if let target = json[key] as? [String: Any] {
                let candidate = target["access"] as? String
                    ?? target["access_token"] as? String
                    ?? target["key"] as? String
                    ?? target["apiKey"] as? String
                    ?? target["token"] as? String
                if let token = sanitizeToken(candidate) {
                    return CommandCodeAuthSession(accessToken: token, source: source)
                }
            }
            if let token = sanitizeToken(json[key] as? String) {
                return CommandCodeAuthSession(accessToken: token, source: source)
            }
        }
        return nil
    }

    // MARK: - CCBar 管理的凭据

    static func loadStoredKey() -> String? {
        guard let data = credentials.load(accountID: keychainAccount,
            legacy: { legacy.load(account: keychainAccount) },
            validate: { String(data: $0, encoding: .utf8).flatMap { sanitizeToken($0) } != nil }) else { return nil }
        return String(data: data, encoding: .utf8)
    }
    @discardableResult
    static func saveStoredKey(apiKey: String) -> Bool {
        guard let key = sanitizeToken(apiKey) else { return false }
        do { try credentials.save(Data(key.utf8), accountID: keychainAccount); return true }
        catch { return false }
    }
    @discardableResult
    static func deleteStoredKey() -> Bool { credentials.delete(accountID: keychainAccount) }
    static func retryLegacyAccess() { legacy.retryAccess(account: keychainAccount) }

    // MARK: - Token 清洗

    static func sanitizeToken(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 10 else { return nil }
        guard trimmed.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value <= 0x7E }) else {
            return nil
        }
        return trimmed
    }
}
