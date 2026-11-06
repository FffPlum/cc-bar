import Foundation
import Testing
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
struct QuotaManagementAccountTests {
    @Test func globalRefreshDiscoversDisabledAccountsBeforeRefreshingQuota() async throws {
        let fixture = try AccountsFixture()
        defer { fixture.cleanup() }
        fixture.settings.setProviderEnabled(false, for: .kimi)
        let host = fixture.service()
        let before = try accountRows(host.accountsJSON())
        #expect(before["quota.kimi.primary"]?["quotaManagement"] == .null)
        let auth = kimiAccount(source: .kimiCode, directory: fixture.directory)
        let state = fixture.state
        fixture.onDiscover = { state.kimiAccount = auth }
        let result = try await host.handle("window.quota.refresh", params: [:])
        let after = try accountRows(result)
        #expect(fixture.calls == ["discover", "refresh"])
        #expect(after["quota.kimi.primary"]?["quotaManagement"] == management("kimi", isDefault: true))
        #expect(after["quota.kimi.primary"]?["enabled"] == .bool(false))
        #expect(!fixture.settings.isProviderEnabled(.kimi))
    }

    @Test func individualAccountRefreshDoesNotRescanOtherLogins() async throws {
        let fixture = try AccountsFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.service().handle("window.quota.refresh", params: ["id": .string("quota.codex.primary")])
        #expect(fixture.calls == ["refresh"])
    }

    @Test func addedAccountsDoNotCreateDefaultAccounts() throws {
        let fixture = try AccountsFixture()
        defer { fixture.cleanup() }
        fixture.state.importedCodexAccounts = [
            ImportedCodexAccount(id: "oauth", alias: "Imported", email: nil, planType: nil, visibleInPopover: true, addedAt: Date()),
            ImportedCodexAccount(id: "pat", alias: "PAT", email: nil, planType: nil, visibleInPopover: true, addedAt: Date(), isPersonalAccessToken: true)
        ]
        fixture.state.kimiManagedAccounts = [KimiManagedAccount(id: "managed", region: .china, userID: "kimi-user")]
        fixture.state.deepSeekAccounts = [
            DeepSeekAccount(id: "source", name: "DSH", kind: .account, credentialFingerprint: "source", sourceApplication: "dsh"),
            DeepSeekAccount(id: "manual", name: "Manual", kind: .account, credentialFingerprint: "manual"),
            DeepSeekAccount(id: "key", name: "Key", kind: .apiKey, credentialFingerprint: "key")
        ]
        let host = fixture.service()
        let result = host.accountsJSON()
        let rows = try accountRows(result)
        #expect(rows["quota.codex.primary"]?["detected"] == .bool(true))
        #expect(rows["quota.codex.primary"]?["quotaManagement"] == .null)
        #expect(rows["quota.kimi.primary"]?["detected"] == .bool(true))
        #expect(rows["quota.kimi.primary"]?["quotaManagement"] == .null)
        #expect(rows["quota.cursor.primary"]?["quotaManagement"] == .null)
        #expect(rows[HostWindowAccountsService.accountID("codex", raw: "oauth")]?["quotaManagement"] == management("chatgpt", isDefault: false))
        #expect(rows[HostWindowAccountsService.accountID("codex", raw: "pat")]?["quotaManagement"] == .null)
        #expect(rows[HostWindowAccountsService.accountID("kimi", raw: "managed")]?["quotaManagement"] == management("kimi", isDefault: false))
        #expect(rows[HostWindowAccountsService.accountID("deepSeek", raw: "source")]?["quotaManagement"] == management("deepseekHarness", isDefault: true))
        #expect(rows[HostWindowAccountsService.accountID("deepSeek", raw: "manual")]?["quotaManagement"] == management("deepseekHarness", isDefault: false))
        #expect(rows[HostWindowAccountsService.accountID("deepSeek", raw: "key")] == nil)
        #expect(field(result, "serviceOrder") == .array(host.providers.map { .string($0.app.rawValue) }))
        #expect(fixture.calls.isEmpty)
    }

    @Test(arguments: [false, true])
    func primaryCodexRequiresOAuth(personalAccessToken: Bool) throws {
        let fixture = try AccountsFixture()
        defer { fixture.cleanup() }
        fixture.state.codexAccount = codexAccount(personalAccessToken: personalAccessToken)
        let rows = try accountRows(fixture.service().accountsJSON())
        let primary = try #require(rows["quota.codex.primary"])
        #expect(primary["current"] == .bool(true))
        #expect(primary["quotaManagement"] == (personalAccessToken ? .null : management("chatgpt", isDefault: true)))
        #expect(primary["name"] == .string("person@example.invalid"))
        #expect(primary["subtitle"] == .string("Plus"))
    }

    @Test(arguments: [false, true])
    func primaryKimiRequiresOAuth(apiKey: Bool) throws {
        let fixture = try AccountsFixture()
        defer { fixture.cleanup() }
        fixture.state.kimiAccount = kimiAccount(source: apiKey ? .apiKey : .kimiCode, directory: fixture.directory)
        fixture.state.kimiNickname = "  "
        fixture.state.kimiEmail = "kimi@example.invalid"
        let rows = try accountRows(fixture.service().accountsJSON())
        let primary = try #require(rows["quota.kimi.primary"])
        #expect(primary["current"] == .bool(true))
        #expect(primary["quotaManagement"] == (apiKey ? .null : management("kimi", isDefault: true)))
        #expect(primary["name"] == .string("kimi@example.invalid"))
    }

    @Test func claudeAuthorizationCanBeRecoveredWithoutAnAccessibleAccount() throws {
        let fixture = try AccountsFixture()
        defer { fixture.cleanup() }
        fixture.state.claudeDesktopAccessDenied = true
        let rows = try accountRows(fixture.service().accountsJSON())
        let primary = try #require(rows["quota.claude.primary"])
        #expect(primary["current"] == .bool(false))
        #expect(primary["authorizationRequired"] == .string("claudeDesktop"))
        #expect(primary["quotaManagement"] == management("claude", isDefault: true))
        #expect(primary["name"] == .string("Claude Code"))
        fixture.state.claudeDesktopAccessDenied = false
        fixture.state.claudeAccount = ClaudeAccount(source: .file, email: " ", accountUuid: "claude-user", organizationUuid: nil, subscriptionType: "pro", expiresAt: nil, expiredGuess: false, accessToken: nil, refreshToken: nil)
        let signedIn = try accountRows(fixture.service().accountsJSON())["quota.claude.primary"]
        #expect(signedIn?["name"] == .string("Claude Code"))
        #expect(signedIn?["subtitle"] == .string("Pro"))
        #expect(signedIn?["quotaManagement"] == management("claude", isDefault: true))
    }

    @Test func mirrorsStayManuallyAddedAndPrimaryNamesRespectPrivacy() throws {
        let fixture = try AccountsFixture()
        defer { fixture.cleanup() }
        fixture.state.codexAccount = codexAccount(personalAccessToken: false)
        fixture.state.importedCodexAccounts = [ImportedCodexAccount(id: "account:user", alias: "Mirror", email: "person@example.invalid", planType: "plus", visibleInPopover: true, addedAt: Date())]
        fixture.state.kimiAccount = kimiAccount(source: .kimiCode, directory: fixture.directory)
        fixture.state.kimiNickname = "Kimi nickname"
        fixture.state.kimiManagedAccounts = [KimiManagedAccount(id: "mirror", region: .china, userID: "kimi-user")]
        fixture.state.antigravityAccount = AntigravityAccount(email: " ", displayName: "Gravity name", planType: "Pro", accessToken: nil, refreshToken: nil, expiryDate: nil, idToken: nil)
        let host = fixture.service()
        let rows = try accountRows(host.accountsJSON())
        let codex = try #require(rows[HostWindowAccountsService.accountID("codex", raw: "account:user")])
        let kimi = try #require(rows[HostWindowAccountsService.accountID("kimi", raw: "mirror")])
        #expect(codex["quotaManagement"] == management("chatgpt", isDefault: false))
        #expect(codex["subtitle"] == .string("Plus"))
        #expect(kimi["current"] == .bool(true))
        #expect(kimi["quotaManagement"] == management("kimi", isDefault: false))
        #expect(rows["quota.kimi.primary"]?["name"] == .string("Kimi nickname"))
        #expect(rows["quota.antigravity.primary"]?["name"] == .string("Gravity name"))
        #expect(rows["quota.antigravity.primary"]?["quotaManagement"] == management("antigravity", isDefault: true))
        fixture.settings.privacyMode = true
        let json = String(decoding: try JSONEncoder().encode(host.accountsJSON()), as: UTF8.self)
        #expect(!json.contains("person@example.invalid"))
        #expect(!json.contains("Kimi nickname"))
        #expect(!json.contains("Gravity name"))
        fixture.state.kimiAccount = nil
        let signedOut = try accountRows(host.accountsJSON())
        #expect(signedOut["quota.kimi.primary"]?["name"] == .string("Kimi Code"))
        #expect(signedOut["quota.kimi.primary"]?["quotaManagement"] == .null)
    }

    private func codexAccount(personalAccessToken: Bool) -> CodexAccount {
        CodexAccount(email: "person@example.invalid", planType: "plus", accountId: "account", chatgptUserId: "user", lastRefresh: nil, expiredGuess: false, rawClaimKeys: [], accessToken: "fixture-token", refreshToken: nil, idToken: nil, isPersonalAccessToken: personalAccessToken)
    }

    private func kimiAccount(source: KimiAuthSession.Source, directory: URL) -> KimiAuthSession {
        KimiAuthSession(accessToken: "fixture-token", refreshToken: nil, expiresAt: nil, credentialURL: nil, homeDirectory: directory, baseURL: KimiCredentials.defaultBaseURL, oauthHost: KimiCredentials.defaultOAuthHost, userID: "kimi-user", source: source)
    }

    private func management(_ provider: String, isDefault: Bool) -> HostJSON {
        .object(["provider": .string(provider), "isDefault": .bool(isDefault)])
    }

    private func field(_ value: HostJSON, _ key: String) -> HostJSON? {
        guard case .object(let object) = value else { return nil }
        return object[key]
    }

    private func accountRows(_ result: HostJSON) throws -> [String: [String: HostJSON]] {
        guard case .array(let values) = field(result, "accounts") else {
            Issue.record("Missing accounts array")
            return [:]
        }
        return try Dictionary(uniqueKeysWithValues: values.map { value in
            let id = try #require(field(value, "id"))
            guard case .string(let key) = id, case .object(let row) = value else {
                throw HostError(code: "invalid_fixture", message: "Invalid account row")
            }
            return (key, row)
        })
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
    var onDiscover: (() -> Void)?
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
            discoverAccounts: { self.calls.append("discover"); self.onDiscover?() },
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

@MainActor
struct QuotaDestinationTests {
    @Test func migrationPreservesOldPopoverSelectionAndDoesNotRepeatAfterRelaunch() throws {
        let suite = "QuotaDestinationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "ccbar.settings.separateAuthorizations.v1")
        let oldSettings = [
            "codex": ProviderDisplaySettings(enabled: false, menuBar: true, floatingHUD: true),
            "claude": ProviderDisplaySettings(enabled: true, menuBar: false, floatingHUD: false)
        ]
        defaults.set(try JSONEncoder().encode(oldSettings), forKey: "ccbar.settings.providerDisplaySettings.v1")
        let settings = SettingsStore(defaults: defaults)
        #expect(settings.providerDisplaySettings[.codex] == ProviderDisplaySettings(enabled: false, menuBar: false, floatingHUD: false))
        #expect(settings.providerDisplaySettings[.claude] == ProviderDisplaySettings(enabled: true, menuBar: false, floatingHUD: true))
        #expect(defaults.bool(forKey: "ccbar.settings.quotaDestinations.v1"))

        settings.setProviderShownInMenuBar(true, for: .claude)
        settings.setProviderShownInFloatingHUD(false, for: .claude)
        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.effectiveMenuBarVisibility(for: .claude))
        #expect(!reloaded.effectiveFloatingVisibility(for: .claude))
        #expect(!reloaded.isProviderEnabled(.codex))
    }

    @Test func eachDestinationCanEnableAnAccountIndependentlyAndLegacyEnableRestoresVisibility() throws {
        let fixture = try AccountsFixture()
        defer { fixture.cleanup() }
        let settings = fixture.settings
        settings.setProviderEnabled(false, for: .codex)
        #expect(!settings.isProviderEnabled(.codex))
        settings.setProviderShownInMenuBar(true, for: .codex)
        #expect(settings.isProviderEnabled(.codex))
        #expect(settings.effectiveMenuBarVisibility(for: .codex))
        #expect(!settings.effectiveFloatingVisibility(for: .codex))
        settings.setProviderShownInMenuBar(false, for: .codex)
        #expect(!settings.isProviderEnabled(.codex))
        settings.setProviderShownInFloatingHUD(true, for: .codex)
        #expect(settings.isProviderEnabled(.codex))
        #expect(!settings.effectiveMenuBarVisibility(for: .codex))
        #expect(settings.effectiveFloatingVisibility(for: .codex))
        settings.setProviderEnabled(false, for: .codex)
        #expect(!settings.effectiveMenuBarVisibility(for: .codex))
        #expect(!settings.effectiveFloatingVisibility(for: .codex))
        settings.setProviderEnabled(true, for: .codex)
        #expect(settings.effectiveMenuBarVisibility(for: .codex))
        #expect(settings.effectiveFloatingVisibility(for: .codex))
    }

    @Test(arguments: ["showInMenuBar", "showInFloatingHUD"])
    func enablingEitherDestinationRefreshesWithoutAnEnabledPatch(field: String) async throws {
        let fixture = try AccountsFixture()
        defer { fixture.cleanup() }
        fixture.settings.setProviderEnabled(false, for: .codex)
        let host = fixture.service()
        _ = try await host.handle("quota.updateAccount", params: [
            "id": .string("quota.codex.primary"), "patch": .object([field: .bool(true)])
        ])
        #expect(fixture.calls == ["update", "floating.sync", "refresh"])
        fixture.calls.removeAll()
        _ = try await host.handle("quota.updateAccount", params: [
            "id": .string("quota.codex.primary"), "patch": .object([field: .bool(false)])
        ])
        #expect(fixture.calls == ["update", "floating.sync"])
    }

    @Test func livePrimaryMutationsKeepTheOtherDestinationAndReturnEffectiveState() async throws {
        let fixture = try AccountsFixture()
        defer { fixture.cleanup() }
        fixture.settings.setProviderEnabled(false, for: .codex)
        let host = liveService(fixture)
        let id = "quota.codex.primary"
        for (field, value, menuBar, floating) in [
            ("showInMenuBar", true, true, false),
            ("showInFloatingHUD", true, true, true),
            ("showInMenuBar", false, false, true),
            ("showInFloatingHUD", false, false, false)
        ] {
            let result = try await host.handle("quota.updateAccount", params: ["id": .string(id), "patch": .object([field: .bool(value)])])
            let row = try accountRow(result, id: id)
            #expect(row["showInMenuBar"] == .bool(menuBar))
            #expect(row["showInFloatingHUD"] == .bool(floating))
            #expect(row["enabled"] == .bool(menuBar || floating))
        }
        #expect(fixture.calls == ["floating.sync", "refresh", "floating.sync", "refresh", "floating.sync", "floating.sync"])
    }

    @Test(arguments: ["kimi", "deepSeek"])
    func managedFloatingMutationsPersistBothSurfacesWithoutChangingMenuBar(service: String) async throws {
        let fixture = try AccountsFixture()
        defer { fixture.cleanup() }
        fixture.state.accountPersistenceDirectory = fixture.directory
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        let rawID = "managed"
        fixture.state.kimiManagedAccounts = [KimiManagedAccount(id: rawID, region: .china, userID: "kimi-user", visibleInPopover: false, showInMenuBar: true, showInFloatingHUD: false)]
        fixture.state.deepSeekAccounts = [DeepSeekAccount(id: rawID, name: "DeepSeek", kind: .account, credentialFingerprint: "fixture", visibleInPopover: false, showInMenuBar: true, showInFloatingHUD: false)]
        let id = HostWindowAccountsService.accountID(service, raw: rawID)
        let host = liveService(fixture)
        for visible in [true, false] {
            let result = try await host.handle("quota.updateAccount", params: ["id": .string(id), "patch": .object(["showInFloatingHUD": .bool(visible)])])
            let row = try accountRow(result, id: id)
            #expect(row["showInFloatingHUD"] == .bool(visible))
            #expect(row["showInMenuBar"] == .bool(true))
            #expect(row["enabled"] == .bool(true))
            if service == "kimi" {
                let saved = try #require(KimiManagedAccountStore.loadAll(from: fixture.directory.appendingPathComponent("kimi_subscription_accounts.json")).first)
                #expect(saved.visibleInPopover == visible)
                #expect(saved.showInFloatingHUD == visible)
                #expect(saved.showInMenuBar)
            } else {
                let saved = try #require(DeepSeekAccountStore.load(from: fixture.directory.appendingPathComponent("deepseek_accounts.json")).first)
                #expect(saved.visibleInPopover == visible)
                #expect(saved.showInFloatingHUD == visible)
                #expect(saved.showInMenuBar)
            }
        }
        let result = try await host.handle("quota.updateAccount", params: ["id": .string(id), "patch": .object(["showInMenuBar": .bool(false)])])
        #expect(try accountRow(result, id: id)["enabled"] == .bool(false))
    }

    private func liveService(_ fixture: AccountsFixture) -> HostWindowAccountsService {
        var actions = HostWindowAccountsActions.live(state: fixture.state, settings: fixture.settings)
        actions.refresh = { _ in fixture.calls.append("refresh") }
        actions.syncFloating = { fixture.calls.append("floating.sync") }
        return HostWindowAccountsService(state: fixture.state, settings: fixture.settings, actions: actions)
    }

    private func accountRow(_ result: HostJSON, id: String) throws -> [String: HostJSON] {
        guard case .object(let root) = result, case .array(let accounts) = root["accounts"] else {
            throw HostError(code: "invalid_fixture", message: "Missing accounts array")
        }
        return try #require(accounts.compactMap { value -> [String: HostJSON]? in
            guard case .object(let row) = value, row["id"] == .string(id) else { return nil }
            return row
        }.first)
    }
}
