import Foundation
import Security

// MARK: - ImportedCodexStore
//
// 持久化"其他 Codex 账号"。
// - 元数据 → Application Support/CCBar/imported_codex_accounts.json (原子写,版本号兜底)。
// - Token 三件套 → CCBar 的用户私有文件；旧钥匙串项目首次读取后迁移。

nonisolated struct ImportedCodexTokens: Sendable, Equatable, Codable {
    var accessToken: String
    var refreshToken: String?
    var idToken: String?
}

enum ImportedCodexStore {
    nonisolated static let keychainService = "com.cc-bar.codex.imported"
    nonisolated private static let fileName = "imported_codex_accounts.json"
    nonisolated private static let bundleDirectory = "CCBar"

    // MARK: - 元数据 (JSON)

    nonisolated private struct Payload: Codable, Equatable {
        var version: Int = 1
        var accounts: [ImportedCodexAccount] = []
    }

    nonisolated static func loadAll() -> [ImportedCodexAccount] {
        let url = fileURL()
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(Payload.self, from: data),
              payload.version == 1
        else { return [] }
        return payload.accounts
    }

    nonisolated static func saveAll(_ accounts: [ImportedCodexAccount]) throws {
        let url = fileURL()
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(Payload(accounts: accounts))
        try data.write(to: url, options: [.atomic])
    }

    nonisolated static func fileURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support
            .appendingPathComponent(bundleDirectory, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    // MARK: - CCBar-managed credentials

    nonisolated private static let legacy = CachedManagedKeychain(service: keychainService)
    nonisolated private static let credentials = PrivateCredentialFileStore(
        directory: fileURL().deletingLastPathComponent().appendingPathComponent("imported_codex_credentials", isDirectory: true)
    )

    nonisolated static func loadTokens(accountId: String) -> ImportedCodexTokens? {
        guard let data = credentials.load(accountID: accountId, legacy: { legacy.load(account: accountId) },
            validate: { (try? JSONDecoder().decode(ImportedCodexTokens.self, from: $0)) != nil }) else { return nil }
        return try? JSONDecoder().decode(ImportedCodexTokens.self, from: data)
    }
    nonisolated static func saveTokens(_ tokens: ImportedCodexTokens, accountId: String) throws {
        try credentials.save(JSONEncoder().encode(tokens), accountID: accountId)
    }
    @discardableResult
    nonisolated static func saveTokensIfChanged(_ tokens: ImportedCodexTokens, accountId: String) throws -> Bool {
        if loadTokens(accountId: accountId) == tokens { return false }
        try saveTokens(tokens, accountId: accountId)
        return true
    }
    nonisolated static func deleteTokens(accountId: String) { credentials.delete(accountID: accountId) }
    nonisolated static func acquireRefreshLease(accountId: String) async throws -> KimiRefreshLease? {
        try await credentials.acquireRefreshLease(accountID: accountId)
    }
    nonisolated static func isLegacyAccessBlocked(accountId: String) -> Bool {
        !credentials.hasLocalState(accountID: accountId) && legacy.isAccessBlocked(account: accountId)
    }
    nonisolated static func retryLegacyAccess(accountId: String) { legacy.retryAccess(account: accountId) }

    enum KeychainError: Error, CustomStringConvertible {
        case unexpected(OSStatus)

        var description: String {
            switch self {
            case .unexpected(let s):
                let msg = SecCopyErrorMessageString(s, nil) as String? ?? "OSStatus \(s)"
                return "keychain: \(msg)"
            }
        }
    }
}
