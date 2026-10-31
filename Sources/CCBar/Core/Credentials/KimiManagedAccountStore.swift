import CryptoKit
import Darwin
import Foundation
import Security

nonisolated enum KimiRegion: String, Codable, Sendable, CaseIterable, Identifiable {
    case china
    case global

    var id: String { rawValue }
    var baseURL: URL { self == .china ? KimiCredentials.defaultBaseURL : KimiCredentials.globalBaseURL }
    var oauthHost: URL { self == .china ? KimiCredentials.defaultOAuthHost : KimiCredentials.globalOAuthHost }

    @MainActor var displayName: String {
        self == .china ? tr("China edition", "国内版") : tr("Global edition", "海外版")
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
    func isAccessBlocked(accountID: String) -> Bool
    func retryAccess(accountID: String)
    func acquireRefreshLease(accountID: String) async throws -> KimiRefreshLease?
}

extension KimiTokenStore {
    func isAccessBlocked(accountID: String) -> Bool { false }
    func retryAccess(accountID: String) {}
    func acquireRefreshLease(accountID: String) async throws -> KimiRefreshLease? { nil }
}

nonisolated struct KimiKeychainStore: KimiTokenStore {
    static let service = "com.cc-bar.kimi.subscriptions"

    private static let shared = CachedManagedKeychain(service: service)
    private let keychain: CachedManagedKeychain

    init() { keychain = Self.shared }
    init(keychain: CachedManagedKeychain) { self.keychain = keychain }

    func load(accountID: String) -> KimiManagedTokens? {
        guard let data = keychain.load(account: accountID) else { return nil }
        return try? JSONDecoder().decode(KimiManagedTokens.self, from: data)
    }

    func save(_ tokens: KimiManagedTokens, accountID: String) throws {
        try keychain.save(JSONEncoder().encode(tokens), account: accountID)
    }

    func delete(accountID: String) { keychain.delete(account: accountID) }
    func isAccessBlocked(accountID: String) -> Bool { keychain.isAccessBlocked(account: accountID) }
    func retryAccess(accountID: String) { keychain.retryAccess(account: accountID) }

}

/// A process-wide lease for one managed account's refresh-token rotation.
nonisolated final class KimiRefreshLease: @unchecked Sendable {
    private let descriptor: Int32
    init(descriptor: Int32) { self.descriptor = descriptor }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}

/// CCBar-owned private credentials; never writes to another application's storage.
/// Kimi subscription tokens remain separate from the CLI's own configuration.
nonisolated struct KimiFileTokenStore: KimiTokenStore {
    private let files: PrivateCredentialFileStore
    private let legacy: any KimiTokenStore

    init(directory: URL = KimiManagedAccountStore.fileURL().deletingLastPathComponent()
        .appendingPathComponent("kimi_subscription_credentials", isDirectory: true),
         legacy: any KimiTokenStore = KimiKeychainStore()) {
        files = PrivateCredentialFileStore(directory: directory)
        self.legacy = legacy
    }
    func load(accountID: String) -> KimiManagedTokens? {
        guard let data = files.load(accountID: accountID, legacy: {
            guard let value = legacy.load(accountID: accountID) else { return nil }
            return try? JSONEncoder().encode(value)
        }, validate: { (try? JSONDecoder().decode(KimiManagedTokens.self, from: $0)) != nil }) else { return nil }
        return try? JSONDecoder().decode(KimiManagedTokens.self, from: data)
    }
    func save(_ tokens: KimiManagedTokens, accountID: String) throws {
        try files.save(JSONEncoder().encode(tokens), accountID: accountID)
    }
    func delete(accountID: String) { files.delete(accountID: accountID) }
    func isAccessBlocked(accountID: String) -> Bool {
        !files.hasLocalState(accountID: accountID) && legacy.isAccessBlocked(accountID: accountID)
    }
    func retryAccess(accountID: String) { legacy.retryAccess(accountID: accountID) }
    func acquireRefreshLease(accountID: String) async throws -> KimiRefreshLease? {
        try await files.acquireRefreshLease(accountID: accountID)
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
