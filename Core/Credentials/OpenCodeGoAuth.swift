import CryptoKit
import Foundation
import Security

nonisolated struct OpenCodeGoAuthSession: Sendable, Equatable {
    enum Source: String, Sendable, Equatable {
        case opencode = "opencode"
        case pi = "pi"
        case environment = "env"
        case manualKeychain = "keychain"

        var displayName: String {
            switch self {
            case .opencode: return "OpenCode"
            case .pi: return "Pi"
            case .environment: return "环境变量"
            case .manualKeychain: return "手动 API Key"
            }
        }
    }

    var apiKey: String
    var source: Source

    /// Go 没有可读的账号信息，用 key 的完整 SHA-256 摘要作为账号键：
    /// 只用于缓存绑定、切号判断和提醒去重，不展示、不写日志。摘要不可逆，不含 key 片段。
    var accountKey: String {
        SHA256.hash(data: Data(apiKey.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// OpenCode Go 的 API key 与 OpenCode / Pi 里 `opencode-go` provider 用的是同一个，
/// 只读这些文件，不写回。手动填写的 key 存在 cc-bar 自己的钥匙串项。
nonisolated enum OpenCodeGoAuth {
    private static let keychainService = "com.nanvon.ccbar.opencode-go"
    private static let keychainAccount = "primary"
    private static let providerKey = "opencode-go"

    static func load(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        preference: OpenCodeGoCredentialPreference = .automatic
    ) -> OpenCodeGoAuthSession? {
        if preference == .manual {
            if let manualKey = loadFromKeychain(), let key = sanitizeKey(manualKey) {
                return OpenCodeGoAuthSession(apiKey: key, source: .manualKeychain)
            }
            return nil
        }

        // 1. $XDG_DATA_HOME/opencode/auth.json，未设置时 ~/.local/share/opencode/auth.json
        if let key = readProviderKey(at: openCodeAuthURL(homeDirectory: homeDirectory, environment: environment)) {
            return OpenCodeGoAuthSession(apiKey: key, source: .opencode)
        }

        // 2. ~/.pi/agent/auth.json
        if let key = readProviderKey(at: homeDirectory.appendingPathComponent(".pi/agent/auth.json")) {
            return OpenCodeGoAuthSession(apiKey: key, source: .pi)
        }

        // 3. 环境变量 OPENCODE_API_KEY
        if let key = sanitizeKey(environment["OPENCODE_API_KEY"]) {
            return OpenCodeGoAuthSession(apiKey: key, source: .environment)
        }

        // 4. 自动降级读取 Keychain 手动配置
        if let manualKey = loadFromKeychain(), let key = sanitizeKey(manualKey) {
            return OpenCodeGoAuthSession(apiKey: key, source: .manualKeychain)
        }

        return nil
    }

    static func openCodeAuthURL(homeDirectory: URL, environment: [String: String]) -> URL {
        if let xdg = environment["XDG_DATA_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           xdg.hasPrefix("/") {
            return URL(fileURLWithPath: xdg).appendingPathComponent("opencode/auth.json")
        }
        return homeDirectory.appendingPathComponent(".local/share/opencode/auth.json")
    }

    private static func readProviderKey(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        if let entry = json[providerKey] as? [String: Any] {
            let candidate = entry["key"] as? String
                ?? entry["access"] as? String
                ?? entry["apiKey"] as? String
                ?? entry["token"] as? String
            return sanitizeKey(candidate)
        }
        return sanitizeKey(json[providerKey] as? String)
    }

    // MARK: - Keychain 存取

    static func loadFromKeychain() -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: keychainAccount,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func saveToKeychain(apiKey: String) -> Bool {
        guard let key = sanitizeKey(apiKey),
              let data = key.data(using: .utf8) else { return false }
        deleteFromKeychain()
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: keychainAccount,
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func deleteFromKeychain() -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: keychainAccount,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - Key 清洗

    /// 与 `CommandCodeAuth.sanitizeToken` 同一规则：去首尾空白，至少 10 个字符，只含可打印 ASCII。
    static func sanitizeKey(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 10 else { return nil }
        guard trimmed.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value <= 0x7E }) else {
            return nil
        }
        return trimmed
    }
}
