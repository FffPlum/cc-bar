import CryptoKit
import Foundation
import Security

nonisolated struct ManagedKeychainError: Error, Equatable, Sendable {
    let status: OSStatus

    var requiresUserRetry: Bool {
        [errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed, errSecNotAvailable].contains(status)
    }

    @MainActor static var pausedMessage: String {
        tr("Keychain access paused. Retry in Settings → Services & Accounts.",
           "钥匙串访问已暂停，请到“设置 → 服务与账号”重试")
    }
}

nonisolated protocol ManagedKeychainBackend: Sendable {
    func read(service: String, account: String) -> Result<Data, ManagedKeychainError>
    func write(_ data: Data, service: String, account: String) -> OSStatus
    func remove(service: String, account: String) -> OSStatus
}

/// Only for credentials owned and mutated by CCBar. CLI / other apps' credentials
/// must keep their existing external-change detection instead of using this cache.
nonisolated final class CachedManagedKeychain: @unchecked Sendable {
    private let service: String
    private let backend: any ManagedKeychainBackend
    private let defaults: UserDefaults?
    private let lock = NSLock()
    private var cache: [String: Result<Data, ManagedKeychainError>] = [:]

    init(service: String, backend: any ManagedKeychainBackend = SystemManagedKeychain(),
         defaults: UserDefaults? = .standard) {
        self.service = service
        self.backend = backend
        self.defaults = defaults
    }

    func load(account: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[account] { return try? cached.get() }
        if defaults?.bool(forKey: pauseKey(account)) == true {
            cache[account] = .failure(ManagedKeychainError(status: errSecAuthFailed))
            return nil
        }
        let result = backend.read(service: service, account: account)
        cache[account] = result
        if case .failure(let error) = result, error.requiresUserRetry {
            defaults?.set(true, forKey: pauseKey(account))
        }
        return try? result.get()
    }

    func isAccessBlocked(account: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if case .failure(let error) = cache[account], error.requiresUserRetry { return true }
        return defaults?.bool(forKey: pauseKey(account)) == true
    }

    /// Only an explicit per-account user action may clear a failed read.
    func retryAccess(account: String) {
        lock.lock()
        defer { lock.unlock() }
        if case .failure = cache[account] { cache[account] = nil }
        defaults?.removeObject(forKey: pauseKey(account))
    }

    func save(_ data: Data, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if case .success(let previous) = cache[account], previous == data { return }
        let status = backend.write(data, service: service, account: account)
        guard status == errSecSuccess else {
            let error = ManagedKeychainError(status: status)
            cache[account] = .failure(error)
            if error.requiresUserRetry { defaults?.set(true, forKey: pauseKey(account)) }
            throw error
        }
        cache[account] = .success(data)
        defaults?.removeObject(forKey: pauseKey(account))
    }

    func delete(account: String) {
        lock.lock()
        defer { lock.unlock() }
        let status = backend.remove(service: service, account: account)
        let error = ManagedKeychainError(status: status == errSecSuccess ? errSecItemNotFound : status)
        cache[account] = .failure(error)
        if error.requiresUserRetry { defaults?.set(true, forKey: pauseKey(account)) }
        else { defaults?.removeObject(forKey: pauseKey(account)) }
    }

    private func pauseKey(_ account: String) -> String {
        let digest = SHA256.hash(data: Data((service + ":" + account).utf8))
            .map { String(format: "%02x", $0) }.joined()
        return "ccbar.keychain.paused." + digest
    }
}

nonisolated struct SystemManagedKeychain: ManagedKeychainBackend {
    func read(service: String, account: String) -> Result<Data, ManagedKeychainError> {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return .failure(ManagedKeychainError(status: status == errSecSuccess ? errSecDecode : status))
        }
        return .success(data)
    }

    func write(_ data: Data, service: String, account: String) -> OSStatus {
        let query = baseQuery(service: service, account: account)
        let attributes: [String: Any] = [kSecValueData as String: data,
                                       kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard status == errSecItemNotFound else { return status }
        return SecItemAdd(query.merging(attributes, uniquingKeysWith: { _, new in new }) as CFDictionary, nil)
    }

    func remove(service: String, account: String) -> OSStatus {
        SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
    }

    private func baseQuery(service: String, account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
}
