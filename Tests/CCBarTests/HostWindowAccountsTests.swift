import Foundation
import XCTest
@testable import CCBar

@MainActor
final class HostWindowAccountsTests: XCTestCase {
    func testSnapshotUsesSharedOpaqueIDsAndHidesPrivateMetadata() async throws {
        let fixture = try AccountsFixture()
        defer { fixture.cleanup() }
        fixture.settings.privacyMode = true
        fixture.state.codexAccount = CodexAccount(email: "primary@example.invalid", planType: "plus", accountId: "private-primary", chatgptUserId: "private-primary-user", lastRefresh: nil, expiredGuess: false, rawClaimKeys: [], accessToken: "private-access-token", refreshToken: "private-refresh-token", idToken: "private-id-token")
        fixture.state.importedCodexAccounts = [ImportedCodexAccount(id: "private-account:user", alias: "private alias", email: "private@example.com", planType: "plus", visibleInPopover: true, addedAt: Date())]
        fixture.state.kimiManagedAccounts = [KimiManagedAccount(id: "private-kimi", region: .china, userID: "private-user", nickname: "private nickname", email: "kimi@example.com", userLevelName: "pro")]
        fixture.state.kimiDeviceLoginInProgress = true
        fixture.state.kimiDeviceAuthorization = KimiDeviceAuthorization(region: .china, userCode: "private-user-code", deviceCode: "private-device-code", verificationURL: URL(string: "https://example.invalid/private-verification")!, expiresAt: Date().addingTimeInterval(60), interval: 5)
        fixture.state.deepSeekAccounts = [DeepSeekAccount(id: "private-deepseek", name: "private name", kind: .account, credentialFingerprint: "private fingerprint", sourceApplication: "dsh")]
        fixture.state.deepSeekBalances["private-deepseek"] = DeepSeekBalance(wallets: [], isAvailable: true, fetchedAt: Date(), credentialFingerprint: "private-balance-fingerprint")
        let service = fixture.service()
        let snapshot = try await service.handle("quota.accounts", params: [:])
        if let output = ProcessInfo.processInfo.environment["CCBAR_WINDOW_ACCOUNTS_FIXTURE_OUTPUT"] {
            try JSONEncoder().encode(snapshot).write(to: URL(fileURLWithPath: output), options: .atomic)
        }
        let json = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        for secret in ["primary@example.invalid", "private-primary", "private-access-token", "private-refresh-token", "private-id-token", "private-account", "private alias", "private@example.com", "private-kimi", "private-user", "private nickname", "kimi@example.com", "private-device-code", "private-verification", "private-deepseek", "private name", "private fingerprint", "private-balance-fingerprint"] {
            XCTAssertFalse(json.contains(secret), "Snapshot leaked \(secret)")
        }
        XCTAssertTrue(json.contains(HostWindowUsageService.quotaAccountID(service: "codex", kind: "imported", rawID: "private-account:user")))
        XCTAssertTrue(json.contains(HostWindowUsageService.quotaAccountID(service: "kimi", kind: "imported", rawID: "private-kimi")))
        XCTAssertTrue(json.contains("quota.codex.primary"))
        XCTAssertTrue(json.contains("sourceOwned"))
        XCTAssertTrue(fixture.calls.isEmpty)
    }

    func testPreviewNeverReturnsTokensAndInvalidMutationsHaveNoSideEffects() async throws {
        let fixture = try AccountsFixture()
        defer { fixture.cleanup() }
        let service = fixture.service()
        let payload = #"{"tokens":{"access_token":"secret-access-token","refresh_token":"secret-refresh-token","account_id":"raw-account"}}"#
        let preview = try await service.handle("codex.preview", params: ["payload": .string(payload)])
        let json = String(decoding: try JSONEncoder().encode(preview), as: UTF8.self)
        XCTAssertFalse(json.contains("secret-access-token"))
        XCTAssertFalse(json.contains("secret-refresh-token"))
        XCTAssertEqual(field(preview, "kind"), .string("oauth"))
        await expectError("invalid_params") {
            try await service.handle("quota.updateAccount", params: ["id": .string("quota.codex.primary"), "patch": .object(["enabled": .bool(false), "showInMenuBar": .string("false")])])
        }
        await expectError("not_found") { try await service.handle("codex.delete", params: ["id": .string("raw-account")]) }
        await expectError("invalid_params") { try await service.handle("codex.delete", params: ["id": .string("quota.codex.primary")]) }
        await expectError("invalid_params") { try await service.handle("authorizations.grantAccess", params: ["kind": .string("arbitrary")]) }
        await expectError("invalid_params") { try await service.handle("quota.reorder", params: ["serviceOrder": .array([.string("codex"), .string("codex")])]) }
        XCTAssertTrue(fixture.calls.isEmpty)
        _ = try await service.handle("quota.updateAccount", params: ["id": .string("quota.codex.primary"), "patch": .object(["enabled": .bool(true)])])
        XCTAssertEqual(fixture.calls, ["update", "floating.sync", "refresh"])
    }

    func testImportReportsPartialFailureWithoutEchoingCredentialErrors() async throws {
        let fixture = try AccountsFixture()
        defer { fixture.cleanup() }
        let payload = #"[{"tokens":{"access_token":"secret-1","account_id":"one"}},{"tokens":{"access_token":"secret-2","account_id":"two"}}]"#
        fixture.failSecondImport = true
        let result = try await fixture.service().handle("codex.import", params: ["payload": .string(payload), "visibleInPopover": .bool(true)])
        XCTAssertEqual(field(result, "imported"), .number(1))
        XCTAssertEqual(field(result, "failed"), .number(1))
        let text = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        XCTAssertFalse(text.contains("secret-"))
        XCTAssertFalse(text.contains("private-error"))
        XCTAssertEqual(fixture.calls, ["import:one", "import:two"])
    }

    func testResetCreditsAndReorderValidateIdentityAndPreserveUsageOnlyPositions() async throws {
        let fixture = try AccountsFixture()
        defer { fixture.cleanup() }
        let service = fixture.service()
        let result = try await service.handle("quota.resetCredits", params: ["id": .string("quota.codex.primary")])
        XCTAssertEqual(field(result, "availableCount"), .number(2))
        XCTAssertEqual(field(result, "accountID"), .string("quota.codex.primary"))
        await expectError("invalid_params") { try await service.handle("quota.resetCredits", params: ["id": .string("quota.kimi.primary")]) }
        let before = fixture.settings.orderedServices
        let order = service.providers.reversed().map { HostJSON.string($0.app.rawValue) }
        _ = try await service.handle("quota.reorder", params: ["serviceOrder": .array(order)])
        for (index, item) in before.enumerated() {
            if case .usage = item { XCTAssertEqual(fixture.settings.orderedServices[index], item) }
        }
        XCTAssertEqual(fixture.settings.orderedProviders.filter { !$0.app.usesAPIKey }.map { $0.app.rawValue }, order.compactMap { if case .string(let value) = $0 { return value }; return nil })
        XCTAssertEqual(fixture.calls, ["credits"])
    }

    func testDeepSeekProgressNotifiesAndDisposedAuthorizationCannotFinish() async throws {
        let fixture = try AccountsFixture()
        defer { fixture.cleanup() }
        fixture.pauseDeepSeek = true
        let (started, signal) = AsyncStream<Void>.makeStream()
        fixture.deepSeekStarted = { signal.yield(()) }
        let service = fixture.service()
        var changes = 0
        service.didChange = { changes += 1 }
        let result = try await service.handle("deepseek.startAuthorization", params: ["name": .string("Test account")])
        XCTAssertEqual(field(result, "started"), .bool(true))
        let task = try XCTUnwrap(service.deepSeekTask)
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()
        XCTAssertEqual(changes, 2)
        fixture.deepSeekStateChanged?()
        XCTAssertEqual(changes, 3)
        service.invalidate()
        fixture.deepSeekStateChanged?()
        XCTAssertEqual(changes, 3)
        fixture.resumeDeepSeek()
        await task.value
        XCTAssertEqual(fixture.calls, ["deepseek.start", "deepseek.cancel"])
        XCTAssertNil(service.deepSeekTask)
        XCTAssertNil(service.deepSeekError)
        XCTAssertEqual(changes, 3)
        signal.finish()
    }

    func testInvalidationOnlyCancelsTheKimiLoginOwnedByThisWindow() async throws {
        let fixture = try AccountsFixture()
        defer { fixture.cleanup() }
        fixture.kimiLoginID = UUID()
        let service = fixture.service()
        let result = try await service.handle("kimi.startAuthorization", params: ["region": .string("china")])
        XCTAssertEqual(field(result, "started"), .bool(true))
        fixture.state.kimiDeviceLoginID = UUID() // A newer native authorization owns the shared state.
        service.invalidate()
        XCTAssertEqual(fixture.calls, ["kimi.start"])
        XCTAssertTrue(fixture.state.kimiDeviceLoginInProgress)
    }

    private func field(_ value: HostJSON, _ key: String) -> HostJSON? {
        guard case .object(let object) = value else { return nil }; return object[key]
    }
    private func expectError(_ code: String, operation: () async throws -> HostJSON) async {
        do { _ = try await operation(); XCTFail("Expected \(code)") }
        catch let error as HostError { XCTAssertEqual(error.code, code) }
        catch { XCTFail("Unexpected error \(error)") }
    }
}

@MainActor
private final class AccountsFixture {
    let suite = "HostWindowAccountsTests.\(UUID().uuidString)"
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let defaults: UserDefaults
    let settings: SettingsStore
    let state: AppState
    var calls: [String] = []
    var failSecondImport = false
    var kimiLoginID: UUID?
    var pauseDeepSeek = false
    var deepSeekStarted: (() -> Void)?
    var deepSeekStateChanged: (() -> Void)?
    var deepSeekContinuation: CheckedContinuation<Void, Never>?
    init() throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        settings = SettingsStore(defaults: defaults)
        state = AppState(authorizations: AuthorizationStore(directory: directory), applications: ApplicationStore(defaults: defaults))
    }
    func cleanup() { resumeDeepSeek(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
    func resumeDeepSeek() { deepSeekContinuation?.resume(); deepSeekContinuation = nil }
    func service() -> HostWindowAccountsService {
        let actions = HostWindowAccountsActions(
            refresh: { _ in self.calls.append("refresh") }, update: { _, _ in self.calls.append("update") },
            delete: { _ in self.calls.append("delete") }, retry: { _ in self.calls.append("retry") },
            resetCredits: { _ in self.calls.append("credits"); return .success(.init(availableCount: 2, credits: [.init(status: "available", title: "Full reset", grantedAt: nil, expiresAt: nil)])) },
            reorderImported: { _ in self.calls.append("reorder") },
            importOAuth: { account, _, _ in
                self.calls.append("import:\(account.id)")
                if self.failSecondImport && account.id == "two" { throw NSError(domain: "private-error-secret-2", code: 1) }
            },
            importPAT: { _, _ in self.calls.append("pat") }, keychainBlocked: { _ in false },
            startKimi: { _, _ in
                self.calls.append("kimi.start")
                if let id = self.kimiLoginID { self.state.kimiDeviceLoginID = id; self.state.kimiDeviceLoginInProgress = true }
            }, cancelKimi: { self.calls.append("kimi.cancel") },
            authorizeDeepSeek: { _, _, changed in
                self.calls.append("deepseek.start"); self.deepSeekStateChanged = changed; changed()
                if self.pauseDeepSeek {
                    await withCheckedContinuation { self.deepSeekContinuation = $0; self.deepSeekStarted?() }
                    try Task.checkCancellation()
                    self.calls.append("deepseek.commit")
                }
            }, cancelDeepSeek: { self.calls.append("deepseek.cancel") },
            renameDeepSeek: { _, _ in self.calls.append("deepseek.rename") }, grantAccess: { _ in self.calls.append("grant") },
            syncFloating: { self.calls.append("floating.sync") }
        )
        return HostWindowAccountsService(state: state, settings: settings, actions: actions)
    }
}
