import AppKit
import Darwin
import XCTest
import os
@testable import CCBar

@MainActor
final class KimiQuotaIntegrationTests: XCTestCase {
    func testProviderParticipatesInAllThreeDisplaysAndRefreshPlan() throws {
        let provider = try XCTUnwrap(QuotaProviderDescriptor.descriptor(for: .kimi))
        XCTAssertEqual(provider.app.usageApp, .kimi)
        XCTAssertTrue(provider.supportsMenuBar)
        XCTAssertTrue(provider.supportsFloatingHUD)
        XCTAssertEqual(provider.logoName, "kimi")
        XCTAssertFalse(ServiceOrderItem.usageOnlyApps.contains(.kimi))
        XCTAssertTrue(QuotaRefreshPlan.make(showCodex: false, showClaude: false, showCursor: false,
                                           showKimi: true, hasVisibleImported: false).refreshKimi)
        XCTAssertFalse(QuotaRefreshPlan.make(showCodex: false, showClaude: false, showCursor: false,
                                            hasVisibleImported: false).refreshKimi)
    }

    func testUsageOnlyPreferenceMigratesToSingleQuotaAndUsageService() throws {
        let suite = "kimi-settings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["kimi", "codex"], forKey: "ccbar.settings.serviceOrder.v1")
        defaults.set(try JSONEncoder().encode(["kimi": true]), forKey: "ccbar.settings.usageServiceVisibility.v1")
        let settings = SettingsStore(defaults: defaults)
        XCTAssertEqual(settings.orderedServices.first, .quota(.kimi))
        XCTAssertEqual(settings.orderedServices.filter { $0.rawValue == "kimi" }.count, 1)
        XCTAssertTrue(settings.isProviderEnabled(.kimi))
        XCTAssertTrue(settings.visibleUsageApps.contains(.kimi))
        settings.setServiceEnabled(false, for: .kimi)
        XCTAssertFalse(settings.visibleUsageApps.contains(.kimi))
        XCTAssertFalse(settings.effectiveMenuBarVisibility(for: .kimi))
    }

    func testFailureRetainsSnapshotAndManualRefreshHonors429Backoff() async {
        let state = AppState()
        let auth = account()
        state.kimiAccount = auth
        let previous = snapshot(used: 0.25)
        state.kimiQuota = previous
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let fetch: @Sendable (KimiAuthSession) async -> Result<QuotaSnapshot, QuotaError> = { _ in
            calls.withLock { $0 += 1 }
            return .failure(.http(429, "too many requests"))
        }
        await state.loadKimiQuota(reason: .userInitiated, fetch: fetch, refresh: { a, _ in .success(a) })
        XCTAssertEqual(state.kimiQuota, previous)
        XCTAssertTrue(state.kimiRefreshState.backoffUntil.map { $0 > Date() } == true)
        await state.loadKimiQuota(reason: .userInitiated, fetch: fetch, refresh: { a, _ in .success(a) })
        XCTAssertEqual(calls.withLock { $0 }, 1)
        XCTAssertEqual(state.kimiQuota, previous)
        XCTAssertFalse(state.kimiRefreshState.inFlight)
        XCTAssertTrue(state.quotaHistory.lastSamples.isEmpty, "429 与退避不能写入伪样本")
        XCTAssertTrue(state.quotaHistory.events.isEmpty)
        XCTAssertTrue(state.quotaCycles.records.isEmpty)
    }

    func test401RenewsOnceAndSuccessfulRetryStoresQuota() async {
        let state = AppState()
        let original = account()
        var updated = original
        updated.accessToken = "fixture-updated-access-token"
        let renewed = updated
        state.kimiAccount = original
        let counts = OSAllocatedUnfairLock(initialState: (fetch: 0, forces: [Bool]()))
        let expected = snapshot(used: 0.4)
        await state.loadKimiQuota(reason: .userInitiated, fetch: { auth in
            counts.withLock { $0.fetch += 1 }
            return auth.accessToken == renewed.accessToken ? .success(expected) : .failure(.http(401, "expired"))
        }, refresh: { auth, force in
            counts.withLock { $0.forces.append(force) }
            return .success(force ? renewed : auth)
        })
        XCTAssertEqual(counts.withLock { $0.fetch }, 2)
        XCTAssertEqual(counts.withLock { $0.forces }, [false, true])
        XCTAssertEqual(state.kimiQuota, expected)
        XCTAssertEqual(state.kimiAccount?.accessToken, renewed.accessToken)
        XCTAssertNil(state.kimiQuotaError)
        XCTAssertFalse(state.kimiRefreshState.inFlight)
    }

    func testSuccessfulRefreshRecordsStandardHistoryAndCyclesOnly() async {
        let state = AppState()
        let auth = account()
        state.kimiAccount = auth
        let expected = standardSnapshot(fiveHourUsed: 20, weeklyUsed: 40)
        await state.loadKimiQuota(reason: .userInitiated, fetch: { _ in .success(expected) }, refresh: { a, _ in .success(a) })

        let key = QuotaHistoryAccountKey.kimiPrimary(accountKey: auth.accountKey)
        XCTAssertEqual(key, auth.accountKey, "历史身份直接复用凭据稳定 accountKey")
        XCTAssertEqual(state.kimiQuota, expected)
        let samples = state.quotaHistory.lastSamples.values.filter { $0.accountKey == key }
        XCTAssertEqual(samples.count, 2)
        XCTAssertEqual(Set(samples.map(\.limitKind)), [.fiveHour, .weekly])
        XCTAssertTrue(samples.allSatisfy { $0.app == .kimi && $0.kind.rawValue == "kimiPrimary" })
        XCTAssertEqual(state.quotaCycles.records.count, 2, "月窗口不伪造标准周期")
        XCTAssertEqual(Set(state.quotaCycles.records.map(\.limitKind)), [.fiveHour, .weekly])
        XCTAssertTrue(state.quotaCycles.records.allSatisfy {
            $0.accountKey == key && $0.app == .kimi && $0.source == .api
        })
        XCTAssertEqual(state.quotaCycles.accountSegments.count, 1)
        XCTAssertEqual(state.quotaCycles.accountSegments.first?.accountKey, key)
    }

    func testSuccessfulSamplesAndCyclesAreSeparatedByAccountSwitch() async {
        let state = AppState()
        let first = account(user: "fixture-first")
        let second = account(user: "fixture-second")
        let firstSnapshot = standardSnapshot(fiveHourUsed: 20, weeklyUsed: 40)
        let secondSnapshot = standardSnapshot(fiveHourUsed: 60, weeklyUsed: 70)
        state.kimiAccount = first
        await state.loadKimiQuota(
            reason: .userInitiated,
            fetch: { _ in .success(firstSnapshot) },
            refresh: { a, _ in .success(a) }
        )
        let firstKey = QuotaHistoryAccountKey.kimiPrimary(accountKey: first.accountKey)

        state.kimiAccount = second
        state.kimiQuota = nil
        await state.loadKimiQuota(
            reason: .userInitiated,
            fetch: { _ in .success(secondSnapshot) },
            refresh: { a, _ in .success(a) }
        )
        let secondKey = QuotaHistoryAccountKey.kimiPrimary(accountKey: second.accountKey)
        XCTAssertNotEqual(firstKey, secondKey)
        XCTAssertEqual(Set(state.quotaHistory.lastSamples.values.map(\.accountKey)), [firstKey, secondKey])
        XCTAssertEqual(state.quotaHistory.lastSamples.values.filter {
            $0.accountKey == firstKey && $0.limitKind == .fiveHour
        }.first?.remainingPercent, 80)
        XCTAssertEqual(state.quotaHistory.lastSamples.values.filter {
            $0.accountKey == secondKey && $0.limitKind == .fiveHour
        }.first?.remainingPercent, 40)
        XCTAssertTrue(state.quotaHistory.events.isEmpty, "切号不能制造额度变化事件")
        XCTAssertEqual(Set(state.quotaCycles.records.map(\.accountKey)), [firstKey, secondKey])
        XCTAssertEqual(state.quotaCycles.records.count, 4)
        XCTAssertEqual(state.quotaCycles.accountSegments.last?.accountKey, secondKey)
        XCTAssertNotNil(state.quotaCycles.accountSegments.first?.endAt)
    }

    func testResponseForReplacedAccountIsDiscarded() async {
        let state = AppState()
        state.kimiAccount = account()
        let replacement = account(user: "another-fixture-user")
        let stale = snapshot(used: 0.99)
        await state.loadKimiQuota(reason: .userInitiated, fetch: { _ in
            await MainActor.run { state.kimiAccount = replacement }
            return .success(stale)
        }, refresh: { auth, _ in .success(auth) })
        XCTAssertNil(state.kimiQuota)
        XCTAssertEqual(state.kimiAccount?.accountKey, replacement.accountKey)
        XCTAssertTrue(state.quotaHistory.lastSamples.isEmpty)
        XCTAssertTrue(state.quotaCycles.records.isEmpty)
    }

    func testCachedKimiWindowsRoundTripAndMonthlyAlertsRemainDistinct() throws {
        let quota = try XCTUnwrap(KimiQuotaClient.parse(root: ["usages": [
            "limit_5h": ["used_ratio": 0.95], "limit_7d": ["used_ratio": 0.96],
            "limit_month_total": ["used_ratio": 0.97], "limit_month_code": ["used_ratio": 0.98],
        ]]))
        var payload = QuotaCachePayload()
        payload.kimi = QuotaCacheRecord(snapshot: quota, source: .api, updatedAt: Date(), accountID: "fixture-account")
        let decoded = try JSONDecoder().decode(QuotaCachePayload.self, from: JSONEncoder().encode(payload))
        XCTAssertEqual(decoded.kimi, payload.kimi)
        let limits = QuotaAlertPolicy.limits(in: quota, preferences: QuotaAlertPreferences())
        XCTAssertEqual(Set(limits.map(\.id)).count, 4)
        XCTAssertNotEqual(QuotaAlertPolicy.windowKey(limits[2], app: .kimi),
                          QuotaAlertPolicy.windowKey(limits[3], app: .kimi))
    }

    func testCachedObservationsKeepSampleTimeAndRejectStaleOrMismatchedAccount() {
        let state = AppState()
        let auth = account()
        state.kimiAccount = auth
        let sampledAt = Date().addingTimeInterval(-60)
        let original = standardSnapshot(fiveHourUsed: 20, weeklyUsed: 40, now: sampledAt)
        let cached = QuotaCacheRecord(snapshot: original, source: .api, updatedAt: sampledAt, accountID: auth.accountKey)
        state.recordCachedKimiQuotaObservations(cached)
        XCTAssertEqual(state.quotaHistory.lastSamples.count, 2)
        XCTAssertTrue(state.quotaHistory.lastSamples.values.allSatisfy { $0.sampledAt == sampledAt })
        XCTAssertEqual(state.quotaCycles.records.count, 2)
        XCTAssertTrue(state.quotaCycles.records.allSatisfy { $0.lastSampleAt == sampledAt && $0.source == .cache })

        let history = state.quotaHistory
        let cycles = state.quotaCycles
        var wrongAccount = cached
        wrongAccount.accountID = "other-account"
        wrongAccount.updatedAt = sampledAt.addingTimeInterval(60)
        state.recordCachedKimiQuotaObservations(wrongAccount)
        XCTAssertEqual(state.quotaHistory, history)
        XCTAssertEqual(state.quotaCycles, cycles)

        let newerAt = sampledAt.addingTimeInterval(30)
        let newer = standardSnapshot(fiveHourUsed: 60, weeklyUsed: 70, now: sampledAt)
        state.quotaHistory = QuotaHistoryStore.record(
            payload: history, accountKey: auth.accountKey, app: .kimi, kind: .kimiPrimary,
            snapshot: newer, sampledAt: newerAt
        )
        let newerHistory = state.quotaHistory
        state.recordCachedKimiQuotaObservations(cached)
        XCTAssertEqual(state.quotaHistory, newerHistory, "旧缓存不能让历史样本倒退或制造额度回升")
        XCTAssertEqual(state.quotaCycles, cycles)

        state.quotaHistory = history
        state.quotaCycles = QuotaCycleStore.record(
            payload: cycles, accountKey: auth.accountKey, app: .kimi,
            snapshot: newer, source: .api, sampledAt: newerAt
        )
        let newerCycles = state.quotaCycles
        state.recordCachedKimiQuotaObservations(cached)
        XCTAssertEqual(state.quotaHistory, history)
        XCTAssertEqual(state.quotaCycles, newerCycles, "较新的周期也不能被旧缓存覆盖")
    }

    func testOfficialFaviconCanBecomeTransparentMenuBarTemplate() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Logos/kimi.ico")
        let image = try XCTUnwrap(NSImage(contentsOf: url))
        let mask = try XCTUnwrap(MenuBarLogo.monochromeFavicon(image))
        XCTAssertTrue(mask.isTemplate)
        let cgImage = try XCTUnwrap(mask.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        var minAlpha: CGFloat = 1
        var maxAlpha: CGFloat = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                let alpha = bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0
                minAlpha = min(minAlpha, alpha)
                maxAlpha = max(maxAlpha, alpha)
            }
        }
        XCTAssertLessThan(minAlpha, 0.01)
        XCTAssertGreaterThan(maxAlpha, 0.9)
    }

    func testRefreshRotatesAtomicallyUnderOfficialLockAndPreservesUnknownFields() async throws {
        let env = try UsageTestEnvironment(name: "kimi-oauth-refresh")
        let auth = try writeCredential(in: env, expired: true)
        let refreshedToken = try token(user: "fixture-user", suffix: "new")
        let lock = auth.credentialURL!.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("oauth/kimi-code.lock")
        let session = mockSession { request in
            XCTAssertTrue(FileManager.default.fileExists(atPath: lock.path))
            XCTAssertEqual(request.url?.absoluteString, "https://auth.kimi.com/api/oauth/token")
            let form = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
            XCTAssertTrue(form.contains("grant_type=refresh_token"))
            return (200, try JSONSerialization.data(withJSONObject: [
                "access_token": refreshedToken, "refresh_token": "new-refresh-fixture-token", "expires_in": 3600,
            ]))
        }
        let result = await KimiTokenRefresher.ensureFresh(auth: auth, session: session)
        guard case .success(let updated) = result else { return XCTFail("refresh failed") }
        XCTAssertEqual(updated.accessToken, refreshedToken)
        XCTAssertEqual(updated.accountKey, auth.accountKey)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lock.path))
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: auth.credentialURL!)) as! [String: Any]
        XCTAssertEqual(json["fixture_extra"] as? String, "keep")
        let attrs = try FileManager.default.attributesOfItem(atPath: auth.credentialURL!.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testRefresh429PreservesCredentialBytesAndReleasesLock() async throws {
        let env = try UsageTestEnvironment(name: "kimi-oauth-backoff")
        let auth = try writeCredential(in: env, expired: true)
        let original = try Data(contentsOf: auth.credentialURL!)
        let session = mockSession { _ in (429, Data("{}".utf8)) }
        let result = await KimiTokenRefresher.ensureFresh(auth: auth, session: session)
        guard case .failure(let error) = result else { return XCTFail("expected rate limit") }
        XCTAssertTrue(error.quotaError?.isRateLimited == true)
        XCTAssertEqual(try Data(contentsOf: auth.credentialURL!), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: auth.credentialURL!
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("oauth/kimi-code.lock").path))
    }

    func testExternalRotationIsAdoptedWithoutAnotherRefreshRequest() async throws {
        let env = try UsageTestEnvironment(name: "kimi-oauth-adopt")
        let initial = try writeCredential(in: env, expired: true)
        let current = try writeCredential(in: env, expired: false)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let session = mockSession { _ in calls.withLock { $0 += 1 }; return (500, Data()) }
        let result = await KimiTokenRefresher.ensureFresh(auth: initial, force: true, session: session)
        guard case .success(let adopted) = result else { return XCTFail("adoption failed") }
        XCTAssertEqual(adopted.accessToken, current.accessToken)
        XCTAssertEqual(calls.withLock { $0 }, 0)
    }

    func testActiveCLILockBlocksRefreshAndStaleLockCanRecover() async throws {
        let env = try UsageTestEnvironment(name: "kimi-oauth-lock")
        let auth = try writeCredential(in: env, expired: true)
        let lock = auth.credentialURL!.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("oauth/kimi-code.lock")
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: true)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let newToken = try token(user: "fixture-user", suffix: "new")
        let session = mockSession { _ in
            calls.withLock { $0 += 1 }
            return (200, try JSONSerialization.data(withJSONObject: [
                "access_token": newToken, "refresh_token": "new-refresh-fixture-token", "expires_in": 3600,
            ]))
        }
        let blocked = await KimiTokenRefresher.ensureFresh(auth: auth, session: session, lockWait: 0.05)
        guard case .failure(.busy) = blocked else { return XCTFail("active CLI lock was ignored") }
        XCTAssertEqual(calls.withLock { $0 }, 0)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: lock.path)
        let recovered = await KimiTokenRefresher.ensureFresh(auth: auth, session: session, lockWait: 0.2)
        guard case .success = recovered else { return XCTFail("stale lock was not recovered") }
        XCTAssertEqual(calls.withLock { $0 }, 1)
    }

    func testLegacyRefreshRespectsPythonCLIFlock() async throws {
        let env = try UsageTestEnvironment(name: "kimi-legacy-flock")
        let original = try writeCredential(in: env, expired: true)
        var auth = original
        auth.source = .legacyCLI
        let lock = auth.credentialURL!.deletingPathExtension().appendingPathExtension("lock")
        let fd = open(lock.path, O_CREAT | O_RDWR, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { _ = flock(fd, LOCK_UN); close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let newToken = try token(user: "fixture-user", suffix: "legacy-renewed")
        let session = mockSession { _ in
            calls.withLock { $0 += 1 }
            return (200, try JSONSerialization.data(withJSONObject: [
                "access_token": newToken, "refresh_token": "renewed-refresh-fixture-token", "expires_in": 3600,
            ]))
        }
        let blocked = await KimiTokenRefresher.ensureFresh(auth: auth, session: session, lockWait: 0.05)
        guard case .failure(.busy) = blocked else { return XCTFail("Python CLI lock ignored") }
        XCTAssertEqual(calls.withLock { $0 }, 0)
        _ = flock(fd, LOCK_UN)
        let renewed = await KimiTokenRefresher.ensureFresh(auth: auth, session: session)
        guard case .success = renewed else { return XCTFail("legacy refresh failed") }
        XCTAssertEqual(calls.withLock { $0 }, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lock.path), "Official flock files remain in place")
    }

    func testRevokedRefreshTokenRequiresLoginAndPreservesFile() async throws {
        let env = try UsageTestEnvironment(name: "kimi-invalid-grant")
        let auth = try writeCredential(in: env, expired: true)
        let before = try Data(contentsOf: auth.credentialURL!)
        let session = mockSession { _ in (400, Data(#"{"error":"invalid_grant"}"#.utf8)) }
        let result = await KimiTokenRefresher.ensureFresh(auth: auth, session: session)
        guard case .failure(.loginRequired) = result else { return XCTFail("Expected sign-in guidance") }
        XCTAssertEqual(try Data(contentsOf: auth.credentialURL!), before)
    }

    func testFailureEnvelopeCannotBecomeSuccessfulQuota() {
        let windows: [String: Any] = ["limit_5h": ["used_ratio": 0.2]]
        XCTAssertNil(KimiQuotaClient.parse(root: ["kind": "error", "usages": windows]))
        XCTAssertNil(KimiQuotaClient.parse(root: ["code": 401, "data": ["usages": windows]]))
    }

    private func account(user: String = "fixture-user") -> KimiAuthSession {
        KimiAuthSession(accessToken: "fixture-original-access-token", refreshToken: nil, expiresAt: nil,
                        credentialURL: nil, homeDirectory: URL(fileURLWithPath: "/tmp/kimi-quota-fixture"),
                        baseURL: KimiCredentials.defaultBaseURL, oauthHost: KimiCredentials.defaultOAuthHost,
                        userID: user, source: .apiKey)
    }

    private func snapshot(used: Double) -> QuotaSnapshot {
        KimiQuotaClient.parse(root: ["usages": ["limit_5h": ["used_ratio": used]]])!
    }

    private func standardSnapshot(
        fiveHourUsed: Double,
        weeklyUsed: Double,
        now: Date = Date()
    ) -> QuotaSnapshot {
        func limit(id: String, kind: QuotaLimitKind, name: String, used: Double, seconds: Int) -> QuotaLimit {
            QuotaLimit(
                id: id,
                kind: kind,
                displayName: name,
                window: QuotaWindow(
                    usedPercent: used,
                    resetsAt: now.addingTimeInterval(TimeInterval(seconds)),
                    windowSeconds: seconds
                ),
                isActive: true
            )
        }
        return QuotaSnapshot(
            app: .kimi,
            primaryLimit: limit(id: "kimi-five-hour", kind: .fiveHour, name: "5HOUR", used: fiveHourUsed, seconds: 18_000),
            secondaryLimit: limit(id: "kimi-weekly", kind: .weekly, name: "WEEKLY", used: weeklyUsed, seconds: 604_800),
            auxiliaryLimits: [QuotaLimit(
                id: "kimi-monthly-total",
                kind: .unknown,
                displayName: "MONTHLY",
                window: QuotaWindow(usedPercent: 90, resetsAt: now.addingTimeInterval(30 * 86_400), windowSeconds: nil),
                isActive: nil
            )],
            planType: nil,
            fetchedAt: now
        )
    }

    private func token(user: String, suffix: String) throws -> String {
        func b64(_ data: Data) -> String {
            data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        return b64(Data("{}".utf8)) + "." + b64(try JSONSerialization.data(withJSONObject: ["user_id": user, "jti": suffix])) + ".fixture"
    }

    private func writeCredential(in env: UsageTestEnvironment, expired: Bool) throws -> KimiAuthSession {
        let url = env.root.appendingPathComponent(".kimi-code/credentials/kimi-code.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: [
            "access_token": try token(user: "fixture-user", suffix: expired ? "old" : "external"),
            "refresh_token": "old-refresh-fixture-token", "expires_at": Date().addingTimeInterval(expired ? -3600 : 3600).timeIntervalSince1970,
            "fixture_extra": "keep",
        ]).write(to: url)
        return try XCTUnwrap(KimiCredentials.load(homeDirectory: env.root, environment: [:]))
    }

    private func mockSession(_ handler: @escaping @Sendable (URLRequest) throws -> (Int, Data)) -> URLSession {
        KimiRefreshMock.handler.withLock { $0 = handler }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [KimiRefreshMock.self]
        return URLSession(configuration: config)
    }
}

private final class KimiRefreshMock: URLProtocol, @unchecked Sendable {
    static let handler = OSAllocatedUnfairLock<(@Sendable (URLRequest) throws -> (Int, Data))?>(initialState: nil)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let callback = Self.handler.withLock { $0 }
            var captured = request
            if captured.httpBody == nil, let stream = captured.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var body = Data()
                var bytes = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&bytes, maxLength: bytes.count)
                    guard count > 0 else { break }
                    body.append(contentsOf: bytes.prefix(count))
                }
                captured.httpBody = body
            }
            let (status, data) = try XCTUnwrap(callback)(captured)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
