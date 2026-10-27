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
    func isAccessBlocked(accountID: String) -> Bool
    func retryAccess(accountID: String)
}

extension MoonshotAPIKeyStore {
    func isAccessBlocked(accountID: String) -> Bool { false }
    func retryAccess(accountID: String) {}
}

nonisolated struct MoonshotKeychainStore: MoonshotAPIKeyStore {
    static let service = "com.cc-bar.moonshot.api"

    private static let shared = CachedManagedKeychain(service: service)
    private let keychain: CachedManagedKeychain

    init() { keychain = Self.shared }
    init(keychain: CachedManagedKeychain) { self.keychain = keychain }

    func load(accountID: String) -> String? {
        guard let data = keychain.load(account: accountID) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func save(_ apiKey: String, accountID: String) throws {
        try keychain.save(Data(apiKey.utf8), account: accountID)
    }

    func delete(accountID: String) { keychain.delete(account: accountID) }
    func isAccessBlocked(accountID: String) -> Bool { keychain.isAccessBlocked(account: accountID) }
    func retryAccess(accountID: String) { keychain.retryAccess(account: accountID) }

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
