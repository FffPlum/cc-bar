import XCTest
@testable import CCBar

@MainActor
final class KimiManagedAccountTests: XCTestCase {
    func testRegionBindsSubscriptionAndOAuthHosts() {
        XCTAssertEqual(KimiRegion.china.baseURL.host, "api.kimi.com")
        XCTAssertEqual(KimiRegion.china.oauthHost.host, "auth.kimi.com")
        XCTAssertEqual(KimiRegion.global.baseURL.host, "api.kimi.ai")
        XCTAssertEqual(KimiRegion.global.oauthHost.host, "auth.kimi.ai")
        XCTAssertTrue(KimiDeviceAuthorizationClient.isTrusted(
            URL(string: "https://auth.kimi.ai/device?code=abc")!, region: .global
        ))
        XCTAssertFalse(KimiDeviceAuthorizationClient.isTrusted(
            URL(string: "https://auth.kimi.com/device?code=abc")!, region: .global
        ))
        XCTAssertFalse(KimiDeviceAuthorizationClient.isTrusted(
            URL(string: "https://auth.kimi.ai.evil.example/device")!, region: .global
        ))
    }

    func testDeviceAuthorizationAcceptsOfficialWebHosts() async throws {
        let session = oauthSession()
        defer { KimiManagedOAuthProtocol.handler = nil; session.invalidateAndCancel() }
        let now = Date()

        for region in [KimiRegion.china, .global] {
            let domain = region == .china ? "kimi.com" : "kimi.ai"
            let otherDomain = region == .china ? "kimi.ai" : "kimi.com"
            let verificationURL = "https://www.\(domain)/device?code=CODE"
            KimiManagedOAuthProtocol.handler = { request in
                XCTAssertEqual(request.url?.absoluteString, "https://auth.\(domain)/api/oauth/device_authorization")
                let json = #"{"user_code":"CODE","device_code":"DEVICE","verification_uri_complete":""#
                    + verificationURL + #"","expires_in":600,"interval":5}"#
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data(json.utf8))
            }

            let authorization = try await KimiDeviceAuthorizationClient.request(region: region, now: now, session: session)
            XCTAssertEqual(authorization.verificationURL.absoluteString, verificationURL)
            XCTAssertEqual(authorization.expiresAt, now.addingTimeInterval(600))
            XCTAssertTrue(KimiDeviceAuthorizationClient.isTrusted(
                URL(string: "https://www.\(domain):443/device")!, region: region
            ))
            XCTAssertFalse(KimiDeviceAuthorizationClient.isTrusted(
                URL(string: "http://www.\(domain)/device")!, region: region
            ))
            XCTAssertFalse(KimiDeviceAuthorizationClient.isTrusted(
                URL(string: "https://www.\(domain):8443/device")!, region: region
            ))
            XCTAssertFalse(KimiDeviceAuthorizationClient.isTrusted(
                URL(string: "https://www.\(otherDomain)/device")!, region: region
            ))
        }
    }

    func testDeviceLoginAutomaticallyOpensBrowserAndShowsCancellation() async throws {
        let (state, root) = try isolatedState()
        defer { try? FileManager.default.removeItem(at: root) }
        let authorization = KimiDeviceAuthorization(
            region: .china,
            userCode: "CODE",
            deviceCode: "DEVICE",
            verificationURL: URL(string: "https://www.kimi.com/device?code=CODE")!,
            expiresAt: Date().addingTimeInterval(600),
            interval: 5
        )
        let browserOpened = expectation(description: "official authorization page opened")
        state.startKimiDeviceLogin(
            region: .china,
            requestAuthorization: { _ in authorization },
            openAuthorization: { url in
                XCTAssertEqual(url, authorization.verificationURL)
                state.cancelKimiDeviceLogin(showCancellation: true)
                browserOpened.fulfill()
            }
        )

        await fulfillment(of: [browserOpened], timeout: 1)
        XCTAssertFalse(state.kimiDeviceLoginInProgress)
        XCTAssertNil(state.kimiDeviceAuthorization)
        XCTAssertNil(state.kimiDeviceLoginID)
        XCTAssertNil(state.kimiDeviceLoginTask)
        XCTAssertEqual(state.kimiDeviceLoginError, KimiDeviceAuthorizationError.cancelled.userMessage)
        XCTAssertEqual(KimiDeviceAuthorizationError.denied.userMessage, KimiDeviceAuthorizationError.cancelled.userMessage)
        XCTAssertTrue(state.kimiManagedAccounts.isEmpty)
    }

    func testDevicePollingAddsFiveSecondsAfterSlowDown() async throws {
        let authorization = KimiDeviceAuthorization(
            region: .china,
            userCode: "CODE",
            deviceCode: "DEVICE",
            verificationURL: URL(string: "https://auth.kimi.com/device")!,
            expiresAt: Date().addingTimeInterval(600),
            interval: 5
        )
        let results: [KimiDeviceAuthorizationClient.PollResult] = [
            .slowDown,
            .pending,
            .success(KimiManagedTokens(accessToken: "access-token-123", refreshToken: "refresh-token-123", expiresAt: nil)),
        ]
        let sleeps = Locked<[TimeInterval]>([])
        let index = Locked(0)
        let tokens = try await KimiDeviceLoginRunner.run(
            authorization: authorization,
            poll: { _ in
                let current = index.withLock { value -> Int in
                    defer { value += 1 }
                    return value
                }
                return results[current]
            },
            sleep: { seconds in sleeps.withLock { $0.append(seconds) } }
        )
        XCTAssertEqual(tokens.accessToken, "access-token-123")
        XCTAssertEqual(sleeps.withLock { $0 }, [5, 10, 10])
    }

    func testCancelledDevicePollingDoesNotReturnCredentials() async {
        let authorization = KimiDeviceAuthorization(
            region: .global,
            userCode: "CODE",
            deviceCode: "DEVICE",
            verificationURL: URL(string: "https://auth.kimi.ai/device")!,
            expiresAt: Date().addingTimeInterval(600),
            interval: 5
        )
        let task = Task {
            try await KimiDeviceLoginRunner.run(
                authorization: authorization,
                poll: { _ in .pending },
                sleep: { _ in try Task.checkCancellation() }
            )
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled login must not succeed")
        } catch {
            XCTAssertEqual(error as? KimiDeviceAuthorizationError, .cancelled)
        }
    }

    func testMetadataRoundTripAndIdentityDeduplication() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("accounts.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let first = KimiManagedAccount(id: "one", region: .china, userID: "user", nickname: "昵称")
        let duplicate = KimiManagedAccount(id: "two", region: .china, userID: "user")
        let otherRegion = KimiManagedAccount(id: "three", region: .global, userID: "user")
        try KimiManagedAccountStore.saveAll([first, otherRegion], to: url)
        XCTAssertEqual(KimiManagedAccountStore.loadAll(from: url), [first, otherRegion])
        XCTAssertEqual(KimiManagedAccount.deduplicated([first, duplicate, otherRegion]).map(\.id), ["one", "three"])
    }

    func testManagedRefreshUsesMatchingRegionAndRotatesOnlyAppTokenStore() async throws {
        let store = TestKimiTokenStore(tokens: KimiManagedTokens(
            accessToken: "old-access-token",
            refreshToken: "old-refresh-token",
            expiresAt: Date().addingTimeInterval(-60)
        ))
        let account = KimiManagedAccount(id: "managed", region: .global, userID: "user")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KimiManagedOAuthProtocol.self]
        let session = URLSession(configuration: configuration)
        KimiManagedOAuthProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "auth.kimi.ai")
            let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
            XCTAssertTrue(body.contains("refresh_token=old-refresh-token"))
            let data = Data(#"{"access_token":"new-access-token","refresh_token":"new-refresh-token","expires_in":3600}"#.utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }
        defer { KimiManagedOAuthProtocol.handler = nil }
        let result = await KimiManagedTokenRefresher.ensureFresh(
            account: account,
            tokenStore: store,
            session: session,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        guard case .success(let tokens) = result else { return XCTFail("Refresh failed") }
        XCTAssertEqual(tokens.accessToken, "new-access-token")
        XCTAssertEqual(store.tokens?.refreshToken, "new-refresh-token")
        XCTAssertEqual(store.savedIDs, ["managed"])
    }
    func testCancelledLoginCannotSaveLateProfileOrClearNewLogin() async throws {
        let (state, root) = try isolatedState()
        defer { try? FileManager.default.removeItem(at: root) }
        let oldID = UUID()
        let newID = UUID()
        state.kimiDeviceLoginID = oldID
        do {
            try await state.completeKimiDeviceLogin(
                region: .china, tokens: regressionTokens(), loginID: oldID,
                profile: { _ in
                    await MainActor.run {
                        state.cancelKimiDeviceLogin()
                        state.kimiDeviceLoginID = newID
                        state.kimiDeviceLoginInProgress = true
                    }
                    return KimiUserInfo(userID: "late-user", nickname: "Late")
                }, refreshAfterSave: false
            )
            XCTFail("A cancelled flow must not save credentials")
        } catch { XCTAssertEqual(error as? KimiDeviceAuthorizationError, .cancelled) }
        XCTAssertTrue(state.kimiManagedAccounts.isEmpty)
        XCTAssertEqual(state.kimiDeviceLoginID, newID)
        XCTAssertTrue(state.kimiDeviceLoginInProgress)
    }

    func testRepeatedLoginDeduplicatesWithinRegionAndKeepsRegionsSeparate() async throws {
        let (state, root) = try isolatedState()
        defer { try? FileManager.default.removeItem(at: root) }
        let previous = SettingsStore.shared.isProviderEnabled(.kimi)
        defer { SettingsStore.shared.setServiceEnabled(previous, for: .kimi) }
        for region in [KimiRegion.china, .china, .global] {
            let loginID = UUID()
            state.kimiDeviceLoginID = loginID
            try await state.completeKimiDeviceLogin(
                region: region, tokens: regressionTokens(), loginID: loginID,
                profile: { _ in KimiUserInfo(userID: "same-user", nickname: "Name", userLevelName: "Allegretto") },
                refreshAfterSave: false
            )
        }
        XCTAssertEqual(state.kimiManagedAccounts.count, 2)
        XCTAssertEqual(Set(state.kimiManagedAccounts.map(\.region)), [.china, .global])
        XCTAssertNil(state.kimiAccount, "App sign-in must not replace the CLI account")
        XCTAssertEqual(KimiManagedAccountStore.loadAll(from: root.appendingPathComponent("kimi_subscription_accounts.json")).count, 2)
    }

    func testLoginMetadataFailureRollsBackCredentialsAndInMemoryAccount() async throws {
        let (state, root) = try isolatedState()
        defer { try? FileManager.default.removeItem(at: root) }
        let blocker = root.appendingPathComponent("not-a-directory")
        try Data("block".utf8).write(to: blocker)
        state.accountPersistenceDirectory = blocker
        let store = RegressionKimiStore()
        state.kimiTokenStore = store
        let loginID = UUID()
        state.kimiDeviceLoginID = loginID
        do {
            try await state.completeKimiDeviceLogin(
                region: .global, tokens: regressionTokens(), loginID: loginID,
                profile: { _ in KimiUserInfo(userID: "user") }, refreshAfterSave: false
            )
            XCTFail("Metadata failure must fail sign-in")
        } catch { }
        XCTAssertTrue(state.kimiManagedAccounts.isEmpty)
        XCTAssertTrue(store.values.withLock { $0.isEmpty })
    }

    func testReloginRejectsDifferentIdentity() async throws {
        let (state, root) = try isolatedState()
        defer { try? FileManager.default.removeItem(at: root) }
        state.kimiManagedAccounts = [KimiManagedAccount(id: "existing", region: .global, userID: "original")]
        let loginID = UUID()
        state.kimiDeviceLoginID = loginID
        do {
            try await state.completeKimiDeviceLogin(
                region: .global, tokens: regressionTokens(), loginID: loginID, replacing: "existing",
                profile: { _ in KimiUserInfo(userID: "other") }, refreshAfterSave: false
            )
            XCTFail("Re-login must not change account identity")
        } catch { XCTAssertEqual(error as? KimiDeviceAuthorizationError, .differentAccount) }
        XCTAssertEqual(state.kimiManagedAccounts.first?.userID, "original")
    }

    func testTokenRefreshCannotRecreateDeletedCredentials() async throws {
        let store = RegressionKimiStore()
        let account = KimiManagedAccount(id: "deleted", region: .china, userID: "user")
        try store.save(regressionTokens(expired: true), accountID: account.id)
        let session = oauthSession()
        KimiManagedOAuthProtocol.handler = { request in
            store.delete(accountID: account.id)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600}"#.utf8))
        }
        defer { KimiManagedOAuthProtocol.handler = nil; session.invalidateAndCancel() }
        let result = await KimiManagedTokenRefresher.ensureFresh(account: account, tokenStore: store, session: session)
        guard case .failure = result else { return XCTFail("Deleted credentials cannot be refreshed") }
        XCTAssertNil(store.load(accountID: account.id))
    }

    func testTokenRefreshCannotOverwriteNewLoginCredentials() async throws {
        let store = RegressionKimiStore()
        let account = KimiManagedAccount(id: "changed", region: .global, userID: "user")
        try store.save(regressionTokens(expired: true), accountID: account.id)
        let newer = KimiManagedTokens(accessToken: "new-login-access", refreshToken: "new-login-refresh", expiresAt: nil)
        let session = oauthSession()
        KimiManagedOAuthProtocol.handler = { request in
            try store.save(newer, accountID: account.id)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"access_token":"stale-access","refresh_token":"stale-refresh","expires_in":3600}"#.utf8))
        }
        defer { KimiManagedOAuthProtocol.handler = nil; session.invalidateAndCancel() }
        let result = await KimiManagedTokenRefresher.ensureFresh(account: account, tokenStore: store, session: session)
        guard case .success(let adopted) = result else { return XCTFail("Expected newer credentials") }
        XCTAssertEqual(adopted, newer)
        XCTAssertEqual(store.load(accountID: account.id), newer)
    }

    func testDeletedManagedAccountRejectsLateQuotaWithoutWritingCache() async throws {
        let (state, root) = try isolatedState()
        defer { try? FileManager.default.removeItem(at: root) }
        let previous = SettingsStore.shared.isProviderEnabled(.kimi)
        SettingsStore.shared.setServiceEnabled(true, for: .kimi)
        defer { SettingsStore.shared.setServiceEnabled(previous, for: .kimi) }
        let account = KimiManagedAccount(id: "remove", region: .china, userID: "user")
        state.kimiManagedAccounts = [account]
        try state.kimiTokenStore.save(regressionTokens(), accountID: account.id)
        await state.loadKimiManagedQuota(account: account, reason: .userInitiated, fetch: { _ in
            await MainActor.run { state.removeKimiManagedAccount(id: account.id) }
            return .success(Self.regressionSnapshot())
        }, profile: { _ in nil })
        XCTAssertTrue(state.kimiManagedAccounts.isEmpty)
        XCTAssertNil(state.kimiManagedQuotas[account.id])
        XCTAssertTrue(KimiManagedQuotaCache.load(from: root.appendingPathComponent("kimi_subscription_quota_cache.json")).isEmpty)
    }

    func testManaged429KeepsSnapshotAndDoesNotBlockAnotherAccount() async throws {
        let (state, root) = try isolatedState()
        defer { try? FileManager.default.removeItem(at: root) }
        let previous = SettingsStore.shared.isProviderEnabled(.kimi)
        SettingsStore.shared.setServiceEnabled(true, for: .kimi)
        defer { SettingsStore.shared.setServiceEnabled(previous, for: .kimi) }
        let first = KimiManagedAccount(id: "first", region: .china, userID: "one")
        let second = KimiManagedAccount(id: "second", region: .global, userID: "two")
        state.kimiManagedAccounts = [first, second]
        for account in [first, second] { try state.kimiTokenStore.save(regressionTokens(), accountID: account.id) }
        let snapshot = Self.regressionSnapshot()
        state.kimiManagedQuotas[first.id] = snapshot
        let calls = Locked(0)
        let failing: @Sendable (KimiAuthSession) async -> Result<QuotaSnapshot, QuotaError> = { _ in
            calls.withLock { $0 += 1 }
            return .failure(.http(429, "too many requests"))
        }
        await state.loadKimiManagedQuota(account: first, reason: .userInitiated, fetch: failing, profile: { _ in nil })
        await state.loadKimiManagedQuota(account: first, reason: .userInitiated, fetch: failing, profile: { _ in nil })
        await state.loadKimiManagedQuota(account: second, reason: .userInitiated,
                                         fetch: { _ in .success(snapshot) }, profile: { _ in nil })
        XCTAssertEqual(calls.withLock { $0 }, 1)
        XCTAssertEqual(state.kimiManagedQuotas[first.id], snapshot)
        XCTAssertNotNil(state.kimiManagedQuotas[second.id])
        XCTAssertFalse(state.kimiManagedRefreshStates[first.id]?.inFlight ?? true)
        XCTAssertTrue(state.quotaCycles.records.isEmpty, "Managed accounts cannot duplicate local subscription estimates")
    }

    func testManagedFreeLegacyResponseRefreshSucceedsAndClearsDecodeError() async throws {
        let (state, root) = try isolatedState()
        defer { try? FileManager.default.removeItem(at: root) }
        let previous = SettingsStore.shared.isProviderEnabled(.kimi)
        SettingsStore.shared.setServiceEnabled(true, for: .kimi)
        defer { SettingsStore.shared.setServiceEnabled(previous, for: .kimi) }

        let account = KimiManagedAccount(id: "legacy-free", region: .china, userID: "free-user")
        state.kimiManagedAccounts = [account]
        try state.kimiTokenStore.save(regressionTokens(), accountID: account.id)

        // 旧版响应：顶层 usage 是周额度；limits[] 中 300 分钟窗口的 detail 是 5 小时额度。
        let legacyRoot: [String: Any] = [
            "usage": ["limit": 100, "used": 25, "remaining": 75, "resetTime": "2026-10-27T00:00:00Z"],
            "limits": [
                [
                    "window": ["duration": 300, "timeUnit": "TIME_UNIT_MINUTE"],
                    "detail": [
                        "limit": 200,
                        "used": 80,
                        "remaining": 120,
                        "resetTime": "2026-10-25T04:00:00Z",
                    ],
                ],
            ],
        ]
        guard let snapshot = KimiQuotaClient.parse(root: legacyRoot, fetchedAt: Date(timeIntervalSince1970: 1_800_000_000)) else {
            return XCTFail("Legacy usage + limits response must parse into a snapshot")
        }

        let decodeMessage = QuotaError.decode("missing usage windows").userMessage
        state.kimiManagedErrors[account.id] = decodeMessage
        var failedState = QuotaRefreshState()
        failedState.lastError = decodeMessage
        state.kimiManagedRefreshStates[account.id] = failedState

        await state.loadKimiManagedQuota(account: account, reason: .userInitiated,
                                         fetch: { _ in .success(snapshot) }, profile: { _ in nil })

        let stored = state.kimiManagedQuotas[account.id]
        XCTAssertEqual(stored?.primaryLimit?.kind, .fiveHour)
        XCTAssertEqual(stored?.secondaryLimit?.kind, .weekly)
        XCTAssertEqual(stored?.fiveHourLimit?.window.usedPercent ?? 0, 40, accuracy: 0.001)
        XCTAssertEqual(stored?.weeklyLimit?.window.usedPercent ?? 0, 25, accuracy: 0.001)
        XCTAssertEqual(stored?.fiveHourLimit?.window.windowSeconds, 18_000)
        XCTAssertEqual(stored?.weeklyLimit?.window.windowSeconds, 604_800)

        XCTAssertNil(state.kimiManagedErrors[account.id], "Successful refresh clears the previous decode error")
        XCTAssertNil(state.kimiManagedRefreshStates[account.id]?.lastError)
        XCTAssertEqual(state.kimiManagedSources[account.id], .api)
        XCTAssertEqual(state.kimiManagedRefreshStates[account.id]?.source, .api)
        XCTAssertNotNil(state.kimiManagedRefreshStates[account.id]?.lastSuccessAt)
        XCTAssertFalse(state.kimiManagedRefreshStates[account.id]?.inFlight ?? true)
    }

    func testFreeEmptyQuotaRefreshKeepsProfileAndClearsFailure() async throws {
        let (state, root) = try isolatedState()
        defer { try? FileManager.default.removeItem(at: root) }
        let previous = SettingsStore.shared.isProviderEnabled(.kimi)
        SettingsStore.shared.setServiceEnabled(true, for: .kimi)
        defer { SettingsStore.shared.setServiceEnabled(previous, for: .kimi) }
        let account = KimiManagedAccount(id: "empty-free", region: .china, userID: "free-user")
        state.kimiManagedAccounts = [account]
        try state.kimiTokenStore.save(regressionTokens(), accountID: account.id)
        state.kimiManagedErrors[account.id] = QuotaError.decode("missing usage windows").userMessage
        var failedState = QuotaRefreshState()
        failedState.lastError = state.kimiManagedErrors[account.id]
        state.kimiManagedRefreshStates[account.id] = failedState

        let session = oauthSession()
        defer { KimiManagedOAuthProtocol.handler = nil; session.invalidateAndCancel() }
        KimiManagedOAuthProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "api.kimi.com")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-access")
            let body = request.url?.lastPathComponent == "me"
                ? #"{"user_id":"free-user","nickname":"Free nickname","user_level_name":"Free"}"#
                : "{}"
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let fetch: @Sendable (KimiAuthSession) async -> Result<QuotaSnapshot, QuotaError> = {
            await KimiQuotaClient.fetch(auth: $0, session: session)
        }
        await state.loadKimiManagedQuota(account: account, reason: .userInitiated, fetch: fetch,
            profile: { await KimiQuotaClient.fetchUserInfo(auth: $0, session: session) })

        XCTAssertNil(state.kimiManagedErrors[account.id])
        XCTAssertNil(state.kimiManagedRefreshStates[account.id]?.lastError)
        XCTAssertNotNil(state.kimiManagedRefreshStates[account.id]?.lastSuccessAt)
        XCTAssertFalse(state.kimiManagedRefreshStates[account.id]?.inFlight ?? true)
        XCTAssertEqual(state.kimiManagedAccounts.first?.nickname, "Free nickname")
        XCTAssertEqual(state.kimiManagedAccounts.first?.userLevelName, "Free")
        XCTAssertEqual(state.kimiManagedQuotas[account.id]?.isEmptyKimiQuota, true)
        XCTAssertEqual(state.kimiManagedQuotas[account.id]?.planType, "Free")
        XCTAssertTrue(state.quotaCycles.records.isEmpty)

        // 一小时内限频 /me 时，下一次空额度刷新仍保留套餐与昵称。
        await state.loadKimiManagedQuota(account: account, reason: .userInitiated, fetch: fetch,
            profile: { _ in XCTFail("Profile should be throttled"); return nil })
        XCTAssertEqual(state.kimiManagedQuotas[account.id]?.planType, "Free")
        let restored = KimiManagedQuotaCache.load(from: root.appendingPathComponent("kimi_subscription_quota_cache.json"))
        XCTAssertEqual(restored[account.id]?.snapshot.isEmptyKimiQuota, true)
        XCTAssertEqual(restored[account.id]?.snapshot.planType, "Free")

        // 后续损坏响应仍报错并保留成功的空快照，不能误填成 0% 或无限。
        let snapshot = state.kimiManagedQuotas[account.id]
        KimiManagedOAuthProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             Data(#"{"usages":{"limit_5h":{}}}"#.utf8))
        }
        await state.loadKimiManagedQuota(account: account, reason: .userInitiated, fetch: fetch, profile: { _ in nil })
        XCTAssertNotNil(state.kimiManagedErrors[account.id])
        XCTAssertEqual(state.kimiManagedQuotas[account.id], snapshot)
    }

    func testMoonshotKeyChangeInvalidatesInFlightBalanceAndRestartCache() async throws {
        let (state, root) = try isolatedState()
        defer { try? FileManager.default.removeItem(at: root) }
        try await state.saveMoonshotAccount(id: nil, name: "API", region: .global, apiKey: "old-api-key", refreshAfterSave: false)
        let old = try XCTUnwrap(state.moonshotAccounts.first)
        await state.loadMoonshotBalance(account: old, reason: .userInitiated, fetch: { _, _ in
            try? await state.saveMoonshotAccount(id: old.id, name: "API", region: .global,
                                               apiKey: "new-api-key", refreshAfterSave: false)
            return .success(MoonshotBalance(available: 99, cash: 99, voucher: 0, currencyCode: "USD", fetchedAt: Date()))
        })
        XCTAssertNil(state.moonshotBalances[old.id])
        XCTAssertFalse(state.moonshotRefreshStates[old.id]?.inFlight ?? false)
        let current = try XCTUnwrap(state.moonshotAccounts.first)
        XCTAssertNotEqual(current.keyFingerprint, old.keyFingerprint)
        await state.loadMoonshotBalance(account: current, reason: .userInitiated, fetch: { _, key in
            XCTAssertEqual(key, "new-api-key")
            return .success(MoonshotBalance(available: 12, cash: 12, voucher: 0, currencyCode: "USD", fetchedAt: Date()))
        })
        XCTAssertEqual(state.moonshotBalances[old.id]?.available, 12)
        state.moonshotBalances = [:]
        state.loadMoonshotAccounts()
        XCTAssertEqual(state.moonshotBalances[old.id]?.available, 12)
    }

    func testMoonshotDeletedAccountRejectsLateBalanceAnd429RespectsManualRefresh() async throws {
        let (state, root) = try isolatedState()
        defer { try? FileManager.default.removeItem(at: root) }
        try await state.saveMoonshotAccount(id: nil, name: "API", region: .china, apiKey: "test-api-key-valid", refreshAfterSave: false)
        let account = try XCTUnwrap(state.moonshotAccounts.first)
        let calls = Locked(0)
        let fetch: @Sendable (MoonshotAccount, String) async -> Result<MoonshotBalance, QuotaError> = { _, _ in
            calls.withLock { $0 += 1 }
            return .failure(.http(429, "too many requests"))
        }
        await state.loadMoonshotBalance(account: account, reason: .userInitiated, fetch: fetch)
        await state.loadMoonshotBalance(account: account, reason: .userInitiated, fetch: fetch)
        XCTAssertEqual(calls.withLock { $0 }, 1)
        state.moonshotRefreshStates[account.id] = nil
        await state.loadMoonshotBalance(account: account, reason: .userInitiated, fetch: { _, _ in
            await MainActor.run { state.removeMoonshotAccount(id: account.id) }
            return .success(MoonshotBalance(available: 5, cash: 5, voucher: 0, currencyCode: "CNY", fetchedAt: Date()))
        })
        XCTAssertTrue(state.moonshotBalances.isEmpty)
        XCTAssertTrue(state.moonshotAccounts.isEmpty)
    }

    func testMoonshotSaveFailureRollsBackKeyAndAccount() async throws {
        let (state, root) = try isolatedState()
        defer { try? FileManager.default.removeItem(at: root) }
        let blocker = root.appendingPathComponent("file")
        try Data().write(to: blocker)
        state.accountPersistenceDirectory = blocker
        let store = RegressionMoonshotStore()
        state.moonshotAPIKeyStore = store
        do {
            try await state.saveMoonshotAccount(id: nil, name: "API", region: .china, apiKey: "test-api-key-valid", refreshAfterSave: false)
            XCTFail("Expected metadata failure")
        } catch { }
        XCTAssertTrue(state.moonshotAccounts.isEmpty)
        XCTAssertTrue(store.values.withLock { $0.isEmpty })
    }

    func testMoonshotRegionChangeRequiresNewKeyAndPrivacyHidesNickname() async throws {
        let (state, root) = try isolatedState()
        defer { try? FileManager.default.removeItem(at: root) }
        try await state.saveMoonshotAccount(id: nil, name: "API", region: .china, apiKey: "test-api-key-valid", refreshAfterSave: false)
        let account = try XCTUnwrap(state.moonshotAccounts.first)
        do {
            try await state.saveMoonshotAccount(id: account.id, name: "API", region: .global, apiKey: "", refreshAfterSave: false)
            XCTFail("Region changes must require an explicit matching key")
        } catch { }
        XCTAssertEqual(state.moonshotAccounts.first?.region, .china)
        let oldPrivacy = SettingsStore.shared.privacyMode
        SettingsStore.shared.privacyMode = true
        defer { SettingsStore.shared.privacyMode = oldPrivacy }
        let managed = KimiManagedAccount(id: "privacy", region: .china, userID: "id", nickname: "Private Name", userLevelName: "Allegretto")
        XCTAssertEqual(state.kimiManagedSubtitle(managed), "Allegretto")
    }

    func testOversizedDevicePollingIntervalIsRejected() async {
        let authorization = KimiDeviceAuthorization(region: .china, userCode: "CODE", deviceCode: "DEVICE",
            verificationURL: URL(string: "https://auth.kimi.com/device")!, expiresAt: Date().addingTimeInterval(600), interval: 1e30)
        do {
            _ = try await KimiDeviceLoginRunner.run(authorization: authorization, poll: { _ in .pending })
            XCTFail("Invalid intervals must not reach nanosecond conversion")
        } catch { XCTAssertEqual(error as? KimiDeviceAuthorizationError, .invalidResponse) }
    }

    func testAppOnlyAccountKeepsStatusComponentsWhenFetchFails() {
        let state = AppState()
        let previous = SettingsStore.shared.showServiceStatus
        SettingsStore.shared.showServiceStatus = true
        defer { SettingsStore.shared.showServiceStatus = previous }
        state.kimiManagedAccounts = [KimiManagedAccount(id: "app-only", region: .global, userID: "user")]
        state.kimiServiceStatus = ServiceStatus(indicator: .none, description: nil, updatedAt: nil, fetchedAt: Date(),
            components: [ServiceStatusComponent(id: "code", name: "K3", indicator: .none)])
        state.kimiServiceStatusUnreachable = true
        XCTAssertTrue(state.hasKimiSubscriptionAccount)
        XCTAssertNil(state.kimiAccount)
        XCTAssertEqual(state.displayedKimiServiceStatus?.indicator, .unknown)
        XCTAssertEqual(state.displayedKimiServiceStatus?.components.count, 1)
        XCTAssertTrue(state.displayedKimiServiceStatus?.isStale ?? false)
    }

    private func isolatedState() throws -> (AppState, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccbar-accounts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let state = AppState()
        state.accountPersistenceDirectory = root
        state.kimiTokenStore = RegressionKimiStore()
        state.moonshotAPIKeyStore = RegressionMoonshotStore()
        return (state, root)
    }

    private func regressionTokens(expired: Bool = false) -> KimiManagedTokens {
        KimiManagedTokens(accessToken: "test-access", refreshToken: "test-refresh", expiresAt: expired ? Date().addingTimeInterval(-60) : nil)
    }

    nonisolated private static func regressionSnapshot() -> QuotaSnapshot {
        KimiQuotaClient.parse(root: ["usages": ["limit_5h": ["used_ratio": 0.25]]])!
    }

    private func oauthSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KimiManagedOAuthProtocol.self]
        return URLSession(configuration: configuration)
    }

}

private final class TestKimiTokenStore: KimiTokenStore, @unchecked Sendable {
    var tokens: KimiManagedTokens?
    var savedIDs: [String] = []
    init(tokens: KimiManagedTokens?) { self.tokens = tokens }
    func load(accountID: String) -> KimiManagedTokens? { tokens }
    func save(_ tokens: KimiManagedTokens, accountID: String) throws {
        self.tokens = tokens
        savedIDs.append(accountID)
    }
    func delete(accountID: String) { tokens = nil }
}

private nonisolated final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

private final class KimiManagedOAuthProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            var forwarded = request
            if forwarded.httpBody == nil, let stream = forwarded.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var body = Data()
                var buffer = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    body.append(contentsOf: buffer.prefix(count))
                }
                forwarded.httpBody = body
            }
            let (response, data) = try Self.handler!(forwarded)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}


private final class RegressionKimiStore: KimiTokenStore, @unchecked Sendable {
    let values = Locked<[String: KimiManagedTokens]>([:])
    func load(accountID: String) -> KimiManagedTokens? { values.withLock { $0[accountID] } }
    func save(_ tokens: KimiManagedTokens, accountID: String) throws { values.withLock { $0[accountID] = tokens } }
    func delete(accountID: String) { values.withLock { $0[accountID] = nil } }
}

private final class RegressionMoonshotStore: MoonshotAPIKeyStore, @unchecked Sendable {
    let values = Locked<[String: String]>([:])
    func load(accountID: String) -> String? { values.withLock { $0[accountID] } }
    func save(_ key: String, accountID: String) throws { values.withLock { $0[accountID] = key } }
    func delete(accountID: String) { values.withLock { $0[accountID] = nil } }
}
