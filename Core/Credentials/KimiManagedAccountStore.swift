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
nonisolated struct PrivateCredentialFileStore: Sendable {
    private let directory: URL
    init(directory: URL) { self.directory = directory }

    func load(accountID: String, legacy: () -> Data?, validate: (Data) -> Bool) -> Data? {
        do {
            try prepareDirectory()
            let credential = url(accountID, suffix: "json")
            let marker = url(accountID, suffix: "migrated")
            if exists(credential) {
                guard let data = try? readSecure(credential), validate(data) else { return nil }
                if !exists(marker) { try writeSecure(Data(), to: marker) }
                return data
            }
            // A missing or damaged file after migration must never revive an old token.
            guard !exists(marker), let lease = try tryLease(accountID: accountID) else { return nil }
            defer { withExtendedLifetime(lease) {} }
            if exists(credential) { return loadExisting(credential, marker: marker, validate: validate) }
            guard !exists(marker), let data = legacy(), validate(data) else { return nil }
            try save(data, accountID: accountID)
            return data
        } catch { return nil }
    }

    private func loadExisting(_ credential: URL, marker: URL, validate: (Data) -> Bool) -> Data? {
        guard let data = try? readSecure(credential), validate(data) else { return nil }
        if !exists(marker), (try? writeSecure(Data(), to: marker)) == nil { return nil }
        return data
    }

    func save(_ data: Data, accountID: String) throws {
        try prepareDirectory()
        try writeSecure(data, to: url(accountID, suffix: "json"))
        try writeSecure(Data(), to: url(accountID, suffix: "migrated"))
    }

    @discardableResult
    func delete(accountID: String) -> Bool {
        do {
            try prepareDirectory()
            try writeSecure(Data(), to: url(accountID, suffix: "migrated"))
            let result = unlink(url(accountID, suffix: "json").path)
            if result != 0 && errno != ENOENT { throw posixError() }
            return true
        } catch {
            AppLog.error(.credentials, "Credential removal failed: \(Redact.error(error))")
            return false
        }
    }

    func hasLocalState(accountID: String) -> Bool {
        exists(url(accountID, suffix: "json")) || exists(url(accountID, suffix: "migrated"))
    }

    func acquireRefreshLease(accountID: String) async throws -> KimiRefreshLease? {
        try prepareDirectory()
        for _ in 0..<300 {
            try Task.checkCancellation()
            if let lease = try tryLease(accountID: accountID) { return lease }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw POSIXError(.ETIMEDOUT)
    }

    private func tryLease(accountID: String) throws -> KimiRefreshLease? {
        let fd = open(url(accountID, suffix: "lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw posixError() }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            if code == EWOULDBLOCK || code == EAGAIN { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return KimiRefreshLease(descriptor: fd)
    }

    private func url(_ accountID: String, suffix: String) -> URL {
        directory.appendingPathComponent(KimiManagedAccount.digest(accountID) + "." + suffix)
    }
    private func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }
    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid() else { throw POSIXError(.EACCES) }
        guard chmod(directory.path, 0o700) == 0 else { throw posixError() }
    }
    private func readSecure(_ url: URL) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw posixError() }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(), (info.st_mode & 0o077) == 0 else { throw POSIXError(.EACCES) }
        return try handle.readToEnd() ?? Data()
    }
    private func writeSecure(_ data: Data, to destination: URL) throws {
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw posixError() }
        defer { close(fd); unlink(temporary.path) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw posixError() }
                offset += written
            }
        }
        guard fsync(fd) == 0 else { throw posixError() }
        guard rename(temporary.path, destination.path) == 0 else { throw posixError() }
    }
    private func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}

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
