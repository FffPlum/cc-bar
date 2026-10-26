import CryptoKit
import Foundation
import Security

nonisolated enum KimiRegion: String, Codable, Sendable, CaseIterable, Identifiable {
    case china
    case global

    var id: String { rawValue }
    var baseURL: URL { self == .china ? KimiCredentials.defaultBaseURL : KimiCredentials.globalBaseURL }
    var oauthHost: URL { self == .china ? KimiCredentials.defaultOAuthHost : KimiCredentials.globalOAuthHost }

    @MainActor var displayName: String {
        self == .china ? tr("China (.com)", "国内 (.com)") : tr("Overseas (.ai)", "海外 (.ai)")
    }
}

nonisolated struct KimiManagedAccount: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var region: KimiRegion
    var userID: String
    var nickname: String?
    var email: String?
    var userLevelName: String?
    var visibleInPopover = true
    var showInMenuBar = false
    var showInFloatingHUD = false

    var identity: String { "\(region.rawValue):\(userID)" }

    func auth(tokens: KimiManagedTokens, homeDirectory: URL) -> KimiAuthSession {
        KimiAuthSession(
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            expiresAt: tokens.expiresAt,
            credentialURL: nil,
            homeDirectory: homeDirectory,
            baseURL: region.baseURL,
            oauthHost: region.oauthHost,
            userID: userID,
            source: .appManaged
        )
    }
}

nonisolated struct KimiManagedTokens: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date?
}

nonisolated protocol KimiTokenStore: Sendable {
    func load(accountID: String) -> KimiManagedTokens?
    func save(_ tokens: KimiManagedTokens, accountID: String) throws
    func delete(accountID: String)
}

nonisolated struct KimiKeychainStore: KimiTokenStore {
    static let service = "com.cc-bar.kimi.subscriptions"

    func load(accountID: String) -> KimiManagedTokens? {
        var query = baseQuery(accountID: accountID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let tokens = try? JSONDecoder().decode(KimiManagedTokens.self, from: data)
        else { return nil }
        return tokens
    }

    func save(_ tokens: KimiManagedTokens, accountID: String) throws {
        let data = try JSONEncoder().encode(tokens)
        let status = SecItemUpdate(
            baseQuery(accountID: accountID) as CFDictionary,
            [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock] as CFDictionary
        )
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw ImportedCodexStore.KeychainError.unexpected(status) }
        var query = baseQuery(accountID: accountID)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw ImportedCodexStore.KeychainError.unexpected(addStatus) }
    }

    func delete(accountID: String) {
        SecItemDelete(baseQuery(accountID: accountID) as CFDictionary)
    }

    private func baseQuery(accountID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: accountID,
        ]
    }
}

nonisolated enum KimiManagedAccountStore {
    private struct Payload: Codable {
        var version = 1
        var accounts: [KimiManagedAccount]
    }

    static func loadAll(from url: URL = fileURL()) -> [KimiManagedAccount] {
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.version == 1
        else { return [] }
        return payload.accounts
    }

    static func saveAll(_ accounts: [KimiManagedAccount], to url: URL = fileURL()) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Payload(accounts: accounts)).write(to: url, options: .atomic)
    }

    static func fileURL() -> URL {
        ImportedCodexStore.fileURL().deletingLastPathComponent().appendingPathComponent("kimi_subscription_accounts.json")
    }
}

extension KimiManagedAccount {
    static func deduplicated(_ accounts: [KimiManagedAccount]) -> [KimiManagedAccount] {
        var seen = Set<String>()
        return accounts.filter { seen.insert($0.identity).inserted }
    }

    static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
