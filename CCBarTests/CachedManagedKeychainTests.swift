import os
import Security
import XCTest
@testable import CCBar

final class CachedManagedKeychainTests: XCTestCase {
    func testRepeatedAndConcurrentReadsHitKeychainOnlyOnce() {
        let backend = CountingManagedKeychain()
        backend.state.withLock { $0.data["test:a"] = Data("secret".utf8) }
        let cache = CachedManagedKeychain(service: "test", backend: backend, defaults: nil)
        DispatchQueue.concurrentPerform(iterations: 20) { _ in
            XCTAssertEqual(cache.load(account: "a"), Data("secret".utf8))
        }
        XCTAssertEqual(backend.state.withLock { $0.reads }, 1)
    }

    func testKimiSaveAndDeleteUpdateCacheWithoutRereadingSecrets() throws {
        let backend = CountingManagedKeychain()
        let cache = CachedManagedKeychain(service: "test", backend: backend, defaults: nil)
        let store = KimiKeychainStore(keychain: cache)
        let old = KimiManagedTokens(accessToken: "old", refreshToken: "old-refresh", expiresAt: nil)
        let next = KimiManagedTokens(accessToken: "next", refreshToken: "next-refresh", expiresAt: nil)
        backend.state.withLock { $0.data["test:a"] = try? JSONEncoder().encode(old) }
        XCTAssertEqual(store.load(accountID: "a"), old)
        try store.save(next, accountID: "a")
        XCTAssertEqual(store.load(accountID: "a"), next)
        store.delete(accountID: "a")
        XCTAssertNil(store.load(accountID: "a"))
        XCTAssertEqual(backend.state.withLock { $0.reads }, 1)
        XCTAssertNil(backend.state.withLock { $0.data["test:a"] })
    }

    func testDeniedCancelledAndLockedReadsPauseAcrossRestartUntilExplicitRetry() throws {
        for status in [errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed, errSecNotAvailable] {
            let suite = "ccbar-keychain-test-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let backend = CountingManagedKeychain()
            backend.state.withLock { $0.readStatus = status }
            let cache = CachedManagedKeychain(service: "test", backend: backend, defaults: defaults)
            for _ in 0..<10 { XCTAssertNil(cache.load(account: "a")) }
            XCTAssertTrue(cache.isAccessBlocked(account: "a"))
            XCTAssertEqual(backend.state.withLock { $0.reads }, 1)

            let restarted = CachedManagedKeychain(service: "test", backend: backend, defaults: defaults)
            XCTAssertNil(restarted.load(account: "a"))
            XCTAssertEqual(backend.state.withLock { $0.reads }, 1, "Relaunch must not prompt again")
            backend.state.withLock { $0.readStatus = nil; $0.data["test:a"] = Data("key".utf8) }
            restarted.retryAccess(account: "a")
            XCTAssertEqual(restarted.load(account: "a"), Data("key".utf8))
            XCTAssertFalse(restarted.isAccessBlocked(account: "a"))
            XCTAssertEqual(backend.state.withLock { $0.reads }, 2)
        }
    }

    func testDeniedWriteStopsSubsequentAutomaticReadsAndDoesNotCacheNewValue() throws {
        let backend = CountingManagedKeychain()
        let cache = CachedManagedKeychain(service: "test", backend: backend, defaults: nil)
        backend.state.withLock { $0.data["test:a"] = Data("old".utf8) }
        XCTAssertNotNil(cache.load(account: "a"))
        backend.state.withLock { $0.writeStatus = errSecUserCanceled }
        XCTAssertThrowsError(try cache.save(Data("new".utf8), account: "a"))
        XCTAssertNil(cache.load(account: "a"))
        XCTAssertTrue(cache.isAccessBlocked(account: "a"))
        XCTAssertEqual(backend.state.withLock { $0.reads }, 1)
        cache.retryAccess(account: "a")
        XCTAssertEqual(cache.load(account: "a"), Data("old".utf8))
    }

    func testMissingCredentialStaysMissingUntilSavedAndIdenticalSaveDoesNotWriteAgain() throws {
        let backend = CountingManagedKeychain()
        let cache = CachedManagedKeychain(service: "test", backend: backend, defaults: nil)
        XCTAssertNil(cache.load(account: "a"))
        XCTAssertNil(cache.load(account: "a"))
        XCTAssertFalse(cache.isAccessBlocked(account: "a"))
        try cache.save(Data("key".utf8), account: "a")
        try cache.save(Data("key".utf8), account: "a")
        XCTAssertEqual(cache.load(account: "a"), Data("key".utf8))
        XCTAssertEqual(backend.state.withLock { $0.reads }, 1)
        XCTAssertEqual(backend.state.withLock { $0.writes }, 1)
    }

    func testMoonshotServicesAndAccountsDoNotShareCachedSecrets() throws {
        let backend = CountingManagedKeychain()
        let first = MoonshotKeychainStore(keychain: CachedManagedKeychain(service: "one", backend: backend, defaults: nil))
        let second = MoonshotKeychainStore(keychain: CachedManagedKeychain(service: "two", backend: backend, defaults: nil))
        try first.save("one-key", accountID: "a")
        try second.save("two-key", accountID: "a")
        XCTAssertEqual(first.load(accountID: "a"), "one-key")
        XCTAssertEqual(second.load(accountID: "a"), "two-key")
        first.delete(accountID: "a")
        XCTAssertNil(first.load(accountID: "a"))
        XCTAssertEqual(second.load(accountID: "a"), "two-key")
        XCTAssertNil(first.load(accountID: "b"))
    }
}

nonisolated final class CountingManagedKeychain: ManagedKeychainBackend, @unchecked Sendable {
    struct State {
        var data: [String: Data] = [:]
        var reads = 0
        var writes = 0
        var readStatus: OSStatus?
        var writeStatus: OSStatus = errSecSuccess
    }
    let state = OSAllocatedUnfairLock(initialState: State())

    func read(service: String, account: String) -> Result<Data, ManagedKeychainError> {
        state.withLock {
            $0.reads += 1
            if let status = $0.readStatus { return .failure(ManagedKeychainError(status: status)) }
            guard let data = $0.data[service + ":" + account] else {
                return .failure(ManagedKeychainError(status: errSecItemNotFound))
            }
            return .success(data)
        }
    }
    func write(_ data: Data, service: String, account: String) -> OSStatus {
        state.withLock {
            $0.writes += 1
            guard $0.writeStatus == errSecSuccess else { return $0.writeStatus }
            $0.data[service + ":" + account] = data
            return errSecSuccess
        }
    }
    func remove(service: String, account: String) -> OSStatus {
        state.withLock { $0.data[service + ":" + account] = nil }
        return errSecSuccess
    }
}
