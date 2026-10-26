import Foundation
import Security

nonisolated struct MoonshotAccount: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var region: KimiRegion
    var visibleInPopover = true
    var showInMenuBar = false
    var showInFloatingHUD = false
    /// Non-secret cache binding; never persist the API key in metadata.
    var keyFingerprint: String? = nil

    var currencyCode: String { region == .china ? "CNY" : "USD" }
    var currencySymbol: String { region == .china ? "¥" : "$" }
    var balanceURL: URL {
        URL(string: region == .china
            ? "https://api.moonshot.cn/v1/users/me/balance"
            : "https://api.moonshot.ai/v1/users/me/balance")!
    }
}

nonisolated protocol MoonshotAPIKeyStore: Sendable {
    func load(accountID: String) -> String?
    func save(_ apiKey: String, accountID: String) throws
    func delete(accountID: String)
}

nonisolated struct MoonshotKeychainStore: MoonshotAPIKeyStore {
    static let service = "com.cc-bar.moonshot.api"

    func load(accountID: String) -> String? {
        var query = baseQuery(accountID: accountID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8)
        else { return nil }
        return key
    }

    func save(_ apiKey: String, accountID: String) throws {
        guard let data = apiKey.data(using: .utf8) else { return }
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
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service, kSecAttrAccount as String: accountID]
    }
}

nonisolated enum MoonshotAccountStore {
    private struct Payload: Codable {
        var version = 1
        var accounts: [MoonshotAccount]
    }

    static func loadAll(from url: URL = fileURL()) -> [MoonshotAccount] {
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.version == 1
        else { return [] }
        return payload.accounts
    }

    static func saveAll(_ accounts: [MoonshotAccount], to url: URL = fileURL()) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Payload(accounts: accounts)).write(to: url, options: .atomic)
    }

    static func fileURL() -> URL {
        ImportedCodexStore.fileURL().deletingLastPathComponent().appendingPathComponent("moonshot_api_accounts.json")
    }
}
