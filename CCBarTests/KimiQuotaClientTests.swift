import XCTest
@testable import CCBar

/// Kimi Code 凭据与额度客户端测试。全部用临时根目录与 URLProtocol 假网络，
/// 不读用户真实凭据、不发真实请求。
final class KimiQuotaClientTests: XCTestCase {
    private var tempHome: URL!

    override func setUpWithError() throws {
        tempHome = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        MockKimiURLProtocol.reset()
        try? FileManager.default.removeItem(at: tempHome)
    }

    // MARK: - 凭据加载

    func testLoadsNewVersionCredentials() throws {
        let jwt = try writeCredential(.new, userID: "user-abc")
        let session = KimiCredentials.load(homeDirectory: tempHome, environment: [:])
        XCTAssertEqual(session?.source, .kimiCode)
        XCTAssertEqual(session?.accessToken, jwt)
        XCTAssertEqual(session?.userID, "user-abc")
        XCTAssertEqual(session?.baseURL, KimiCredentials.defaultBaseURL)
        XCTAssertEqual(session?.oauthHost, KimiCredentials.defaultOAuthHost)
        XCTAssertNotNil(session?.credentialURL)
        XCTAssertEqual(
            session?.credentialURL?.path.hasSuffix("/.kimi-code/credentials/kimi-code.json"),
            true
        )
    }

    func testLoadsLegacyCredentialsWhenNewMissing() throws {
        let jwt = try writeCredential(.legacy, userID: "user-legacy")
        let session = KimiCredentials.load(homeDirectory: tempHome, environment: [:])
        XCTAssertEqual(session?.source, .legacyCLI)
        XCTAssertEqual(session?.accessToken, jwt)
        XCTAssertEqual(session?.userID, "user-legacy")
    }

    func testNewVersionTakesPriorityOverLegacy() throws {
        try writeCredential(.new, userID: "user-new")
        try writeCredential(.legacy, userID: "user-legacy")
        let session = KimiCredentials.load(homeDirectory: tempHome, environment: [:])
        XCTAssertEqual(session?.source, .kimiCode)
        XCTAssertEqual(session?.userID, "user-new")
    }

    func testEnvironmentOverridesRootDirectory() throws {
        let newOverride = tempHome.appendingPathComponent("override-new")
        let legacyOverride = tempHome.appendingPathComponent("override-legacy")
        try writeCredential(at: newOverride, userID: "user-env-new")
        try writeCredential(at: legacyOverride, userID: "user-env-old")

        var session = KimiCredentials.load(homeDirectory: tempHome, environment: [
            "KIMI_CODE_HOME": newOverride.path,
            "KIMI_SHARE_DIR": legacyOverride.path,
        ])
        XCTAssertEqual(session?.source, .kimiCode)
        XCTAssertEqual(session?.userID, "user-env-new")

        try FileManager.default.removeItem(at: newOverride.appendingPathComponent("credentials/kimi-code.json"))
        session = KimiCredentials.load(homeDirectory: tempHome, environment: [
            "KIMI_CODE_HOME": newOverride.path,
            "KIMI_SHARE_DIR": legacyOverride.path,
        ])
        XCTAssertEqual(session?.source, .legacyCLI)
        XCTAssertEqual(session?.userID, "user-env-old")
    }

    func testExpiredTokenStillLoads() throws {
        let past = Date(timeIntervalSince1970: 1_700_000_000)
        try writeCredential(
            .new,
            userID: "user-abc",
            expiresAt: past
        )
        let session = KimiCredentials.load(homeDirectory: tempHome, environment: [:])
        XCTAssertNotNil(session, "过期 token 也要能读出，刷新由调用方负责")
        XCTAssertEqual(session?.expiresAt, past)
    }

    func testRevokedTombstoneRejected() throws {
        try writeCredentialRaw(.new, #"{"access_token": "", "refresh_token": "", "expires_at": 0}"#)
        XCTAssertNil(KimiCredentials.load(homeDirectory: tempHome, environment: [:]))
    }

    func testBlankAndNewlineTokensRejected() throws {
        try writeCredentialRaw(.new, #"{"access_token": "   "}"#)
        XCTAssertNil(KimiCredentials.load(homeDirectory: tempHome, environment: [:]))

        try writeCredentialRaw(.new, #"{"access_token": "kimi-access\n-token-123456"}"#)
        XCTAssertNil(KimiCredentials.load(homeDirectory: tempHome, environment: [:]))
    }

    func testAccountKeyIsStablePerUserAndOpaquePerKey() throws {
        try writeCredential(.new, userID: "user-abc")
        let first = KimiCredentials.load(homeDirectory: tempHome, environment: [:])
        try FileManager.default.removeItem(at: tempHome.appendingPathComponent(".kimi-code/credentials/kimi-code.json"))
        // 换一个 token（不同 exp）但 user_id 相同：账号键不变（JWT 身份优先）。
        let secondJWT = try makeJWT(payload: ["user_id": "user-abc", "sub": "user-abc", "exp": 1_900_000_111])
        try writeCredentialRaw(.new, """
        {"access_token": "\(secondJWT)", "refresh_token": "kimi-refresh-token-123456", "expires_at": 1893456000}
        """)
        let second = KimiCredentials.load(homeDirectory: tempHome, environment: [:])

        XCTAssertNotEqual(first?.accessToken, second?.accessToken, "fixture 确实换了 token")
        XCTAssertEqual(first?.accountKey, second?.accountKey)
        XCTAssertEqual(first?.accountKey.count, 64)
        XCTAssertFalse(first?.accountKey.contains("user-abc") ?? true)

        // 无 JWT 身份时不崩溃，退化为完整摘要。
        let opaque = KimiAuthSession(
            accessToken: "kimi-access-token-123456",
            refreshToken: nil,
            expiresAt: nil,
            credentialURL: nil,
            homeDirectory: tempHome,
            baseURL: KimiCredentials.defaultBaseURL,
            oauthHost: KimiCredentials.defaultOAuthHost,
            userID: nil,
            source: .apiKey
        )
        XCTAssertEqual(opaque.accountKey.count, 64)
        XCTAssertNotEqual(opaque.accountKey, second?.accountKey)
    }

    func testIdentityFallsBackToRefreshTokenJWT() throws {
        // access_token 不是 JWT 时尝试 refresh_token 的 payload。
        let refreshPayload = try XCTUnwrap(makeJWT(payload: ["user_id": "user-from-refresh", "exp": 1_900_000_000]))
        try writeCredentialRaw(.new, """
        {"access_token": "opaque-not-a-jwt-1234567890", "refresh_token": "\(refreshPayload)", "expires_at": 1900000000}
        """)
        let session = KimiCredentials.load(homeDirectory: tempHome, environment: [:])
        XCTAssertEqual(session?.userID, "user-from-refresh")
        XCTAssertEqual(session?.accessToken, "opaque-not-a-jwt-1234567890")
    }

    // MARK: - 官方 host 约束

    func testOfficialBaseURLWhitelist() throws {
        // 官方 .com / .ai 都接受。
        try writeConfig(baseURL: "https://api.kimi.com/coding/v1")
        try writeCredential(.new, userID: "user-abc")
        var session = KimiCredentials.load(homeDirectory: tempHome, environment: [:])
        XCTAssertEqual(session?.baseURL, KimiCredentials.defaultBaseURL)

        try writeConfig(baseURL: "https://api.kimi.ai/coding/v1")
        session = KimiCredentials.load(homeDirectory: tempHome, environment: [:])
        XCTAssertEqual(session?.baseURL, KimiCredentials.globalBaseURL)
        XCTAssertEqual(session?.oauthHost, KimiCredentials.globalOAuthHost)
    }

    func testCustomBaseURLFallsBackToOfficial() throws {
        // 自定义第三方主机：连接回落官方默认地址，凭据不会配给它。
        try writeConfig(baseURL: "https://evil.example.com/coding/v1")
        try writeCredential(.new, userID: "user-abc")
        let session = KimiCredentials.load(homeDirectory: tempHome, environment: [:])
        XCTAssertEqual(session?.baseURL, KimiCredentials.defaultBaseURL)
    }

    func testCustomBaseURLProviderApiKeyNotUsed() throws {
        // base_url 不可信时，该 provider 段配置的 api_key 也不能用（那是第三方 key）。
        try writeConfig(baseURL: "https://evil.example.com/coding/v1", apiKey: "sk-evil-third-party-key")
        XCTAssertNil(KimiCredentials.load(homeDirectory: tempHome, environment: [:]))
    }

    func testOfficialProviderApiKeyUsedWhenNoCredentialFile() throws {
        // 官方 provider 段配了 api_key 且没有凭据文件：按 API key 来源使用。
        try writeConfig(baseURL: "https://api.kimi.com/coding/v1", apiKey: "sk-kimi-official-key")
        let session = KimiCredentials.load(homeDirectory: tempHome, environment: [:])
        XCTAssertEqual(session?.source, .apiKey)
        XCTAssertEqual(session?.accessToken, "sk-kimi-official-key")
        XCTAssertEqual(session?.baseURL, KimiCredentials.defaultBaseURL)
    }

    func testThirdPartyProviderApiKeyNeverTreatedAsKimi() throws {
        // 其他 provider 的 api_key 与 Kimi 无关。
        let toml = """
        [providers."managed:kimi-code"]
        base_url = "https://api.kimi.com/coding/v1"

        [providers.openai]
        api_key = "sk-openai-unrelated-key"
        """
        try writeConfigRaw(toml)
        XCTAssertNil(KimiCredentials.load(homeDirectory: tempHome, environment: [:]))
    }

    func testCustomOAuthHostRejected() throws {
        try writeConfig(
            baseURL: "https://api.kimi.com/coding/v1",
            oauthHost: "https://auth.evil.example.com"
        )
        try writeCredential(.new, userID: "user-abc")
        let session = KimiCredentials.load(homeDirectory: tempHome, environment: [:])
        XCTAssertEqual(session?.oauthHost, KimiCredentials.defaultOAuthHost)
    }

    func testOAuthKeySelectsCredentialFile() throws {
        // config 里的 oauth key 决定读哪个凭据文件。
        let toml = """
        [providers."managed:kimi-code"]
        base_url = "https://api.kimi.com/coding/v1"
        oauth = { storage = "file", key = "oauth/kimi-code-env-work" }
        """
        try writeConfigRaw(toml)
        try writeCredential(.new, userID: "user-abc", profile: "kimi-code-env-work")
        let session = KimiCredentials.load(homeDirectory: tempHome, environment: [:])
        XCTAssertEqual(session?.userID, "user-abc")
        XCTAssertEqual(
            session?.credentialURL?.path.hasSuffix("/credentials/kimi-code-env-work.json"),
            true
        )
    }

    func testOAuthKeyTraversalRejected() throws {
        // 目录穿越的 key 不可静默选择另一个账号。
        let toml = """
        [providers."managed:kimi-code"]
        base_url = "https://api.kimi.com/coding/v1"
        oauth = { storage = "file", key = "oauth/../../evil" }
        """
        try writeConfigRaw(toml)
        try writeCredential(.new, userID: "user-abc")
        let session = KimiCredentials.load(homeDirectory: tempHome, environment: [:])
        XCTAssertNil(session, "Invalid OAuth profile must not select the default account")
    }

    func testCredentialStorageNameRules() {
        XCTAssertEqual(KimiCredentials.credentialStorageName(forOAuthKey: "kimi-code"), "kimi-code")
        XCTAssertEqual(KimiCredentials.credentialStorageName(forOAuthKey: "oauth/kimi-code"), "kimi-code")
        XCTAssertEqual(KimiCredentials.credentialStorageName(forOAuthKey: "oauth/kimi-code-env-x"), "kimi-code-env-x")
        XCTAssertNil(KimiCredentials.credentialStorageName(forOAuthKey: "oauth/"))
        XCTAssertNil(KimiCredentials.credentialStorageName(forOAuthKey: "oauth/../up"))
        XCTAssertNil(KimiCredentials.credentialStorageName(forOAuthKey: "a/b"))
        XCTAssertNil(KimiCredentials.credentialStorageName(forOAuthKey: ".hidden"))
        XCTAssertNil(KimiCredentials.credentialStorageName(forOAuthKey: "oauth/.."))
        XCTAssertNil(KimiCredentials.credentialStorageName(forOAuthKey: "oauth/a b"))
    }

    // MARK: - 额度解析

    func testParsesAllFourWindows() throws {
        let snapshot = try XCTUnwrap(KimiQuotaClient.parse(root: usages(
            limit5h: ["used_ratio": 0.2, "reset_time": "2026-10-25T04:00:00Z"],
            limit7d: ["used_ratio": 0.55, "reset_time": "2026-10-27T00:00:00Z"],
            monthTotal: ["used_ratio": "0.3", "reset_time": "2026-11-01T00:00:00Z"],
            monthCode: ["used_ratio": 0.75]
        )))
        XCTAssertEqual(snapshot.app, .kimi)

        let primary = try XCTUnwrap(snapshot.primaryLimit)
        XCTAssertEqual(primary.id, "kimi-five-hour")
        XCTAssertEqual(primary.kind, .fiveHour)
        XCTAssertEqual(primary.displayName, "5HOUR")
        XCTAssertEqual(primary.window.usedPercent, 20)
        XCTAssertEqual(primary.window.remainingPercent, 80)
        XCTAssertEqual(primary.window.windowSeconds, 18_000)
        XCTAssertNotNil(primary.window.resetsAt)

        let secondary = try XCTUnwrap(snapshot.secondaryLimit)
        XCTAssertEqual(secondary.id, "kimi-weekly")
        XCTAssertEqual(secondary.kind, .weekly)
        XCTAssertEqual(secondary.window.usedPercent, 55, accuracy: 0.0001)
        XCTAssertEqual(secondary.window.windowSeconds, 604_800)

        XCTAssertEqual(snapshot.auxiliaryLimits.map(\.id), ["kimi-monthly-total", "kimi-monthly-code"])
        XCTAssertEqual(snapshot.auxiliaryLimits.map(\.displayName), ["MONTHLY", "CODE MONTHLY"])
        XCTAssertEqual(snapshot.auxiliaryLimits.first?.window.usedPercent, 30, "字符串数字也接受")
        XCTAssertEqual(snapshot.auxiliaryLimits.first?.window.windowSeconds, nil, "月窗口不硬编码天数")
        XCTAssertEqual(snapshot.auxiliaryLimits.last?.window.usedPercent, 75)
    }

    func testStringNumberAndBoolAndBadRatioRejected() throws {
        let snapshot = try XCTUnwrap(KimiQuotaClient.parse(root: usages(
            limit5h: ["used_ratio": "0.4"],
            limit7d: ["used_ratio": true],
            monthTotal: ["used_ratio": 1.5],
            monthCode: ["used_ratio": -0.1]
        )))
        XCTAssertEqual(snapshot.primaryLimit?.window.usedPercent, 40)
        XCTAssertNil(snapshot.secondaryLimit, "bool 不能当比例")
        XCTAssertTrue(snapshot.auxiliaryLimits.isEmpty, ">1 与负数窗口丢弃，不伪造")

        // 坏比例的单窗口被丢弃；配一个有效窗口锚定 snapshot，主条顺延到它。
        let nanString = try XCTUnwrap(KimiQuotaClient.parse(root: usages(
            limit5h: ["used_ratio": "abc"],
            monthCode: ["used_ratio": 0.2]
        )))
        XCTAssertEqual(nanString.primaryLimit?.id, "kimi-monthly-code", "非数字比例窗口丢弃")

        let infinite = try XCTUnwrap(KimiQuotaClient.parse(root: usages(
            limit5h: ["used_ratio": "1e999"],
            monthCode: ["used_ratio": 0.2]
        )))
        XCTAssertEqual(infinite.primaryLimit?.id, "kimi-monthly-code", "非有限值拒绝")

        let overOne = try XCTUnwrap(KimiQuotaClient.parse(root: usages(
            limit5h: ["used_ratio": 2],
            monthCode: ["used_ratio": 0.2]
        )))
        XCTAssertEqual(overOne.primaryLimit?.id, "kimi-monthly-code", ">1 比例拒绝")
    }

    func testMissingWindowsAndMonthlyOnlyPrimary() throws {
        // 只缺 5h：weekly 升主条。
        let noFiveHour = try XCTUnwrap(KimiQuotaClient.parse(root: usages(
            limit7d: ["used_ratio": 0.1],
            monthTotal: ["used_ratio": 0.2]
        )))
        XCTAssertEqual(noFiveHour.primaryLimit?.id, "kimi-weekly")
        XCTAssertEqual(noFiveHour.secondaryLimit?.id, "kimi-monthly-total")
        XCTAssertTrue(noFiveHour.auxiliaryLimits.isEmpty)

        // 只有月度：monthTotal 做主条，monthCode 补 secondary。
        let monthlyOnly = try XCTUnwrap(KimiQuotaClient.parse(root: usages(
            monthTotal: ["used_ratio": 0.6],
            monthCode: ["used_ratio": 0.9, "reset_time": "2026-11-01T00:00:00Z"]
        )))
        XCTAssertEqual(monthlyOnly.primaryLimit?.id, "kimi-monthly-total")
        XCTAssertEqual(monthlyOnly.primaryLimit?.kind, .unknown)
        XCTAssertEqual(monthlyOnly.primaryLimit?.displayName, "MONTHLY")
        XCTAssertEqual(monthlyOnly.secondaryLimit?.id, "kimi-monthly-code")

        // 全缺：nil。
        XCTAssertNil(KimiQuotaClient.parse(root: usages()))
        XCTAssertNil(KimiQuotaClient.parse(root: [:]))
        XCTAssertNil(KimiQuotaClient.parse(root: ["usages": "unexpected"]))
        XCTAssertNil(KimiQuotaClient.parse(root: usages(limit5h: [:])))
    }

    func testCodeDataWrapperAndNormalizedForm() throws {
        // 明确的 code/data 包装。
        let wrapped = try XCTUnwrap(KimiQuotaClient.parse(root: [
            "code": 0,
            "data": usages(limit5h: ["used_ratio": 0.25, "reset_time": "2026-10-25T04:00:00Z"]),
        ]))
        XCTAssertEqual(wrapped.primaryLimit?.window.usedPercent, 25)

        // 官方规范化形态（camelCase + kind ok）。
        let normalized = try XCTUnwrap(KimiQuotaClient.parse(root: [
            "kind": "ok",
            "quota": [
                "usages": [
                    "limit5h": ["usedRatio": 0.5, "resetAt": "2026-10-25T04:00:00Z"],
                    "limit7d": ["usedRatio": 0.1, "resetAt": "2026-10-27T00:00:00Z"],
                    "monthTotal": ["usedRatio": 0.3],
                    "monthCode": ["usedRatio": 0.8],
                ],
            ],
        ]))
        XCTAssertEqual(normalized.primaryLimit?.id, "kimi-five-hour")
        XCTAssertEqual(normalized.primaryLimit?.window.usedPercent, 50)
        XCTAssertEqual(normalized.secondaryLimit?.window.usedPercent, 10)
        XCTAssertEqual(normalized.auxiliaryLimits.map(\.id), ["kimi-monthly-total", "kimi-monthly-code"])

        // kind != ok 不取数。
        XCTAssertNil(KimiQuotaClient.parse(root: ["kind": "error", "message": "nope"]))
    }

    func testBoosterWalletNotTreatedAsPercent() {
        // 只有 boosterWallet 没有 usages：不算有效窗口。
        XCTAssertNil(KimiQuotaClient.parse(root: [
            "usages": [:],
            "boosterWallet": ["balanceCents": 500],
        ]))
    }

    // MARK: - fetch 与请求构造

    func testFetchSendsBearerAndParsesResponse() async throws {
        let session = makeAuthSession()
        MockKimiURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/coding/v1/usages")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer kimi-access-token-123456")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertEqual(request.timeoutInterval, 10)
            let body = try JSONSerialization.data(withJSONObject: self.usages(
                limit5h: ["used_ratio": 0.2, "reset_time": "2026-10-25T04:00:00Z"],
                limit7d: ["used_ratio": 0.5]
            ))
            return (self.httpResponse(status: 200), body)
        }

        let result = await KimiQuotaClient.fetch(auth: session, session: mockSession())
        guard case .success(let snapshot) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertEqual(snapshot.primaryLimit?.window.usedPercent, 20)
        XCTAssertEqual(snapshot.secondaryLimit?.window.usedPercent, 50)
    }

    func testFetchHTTPErrorStatus() async throws {
        let session = makeAuthSession()

        MockKimiURLProtocol.handler = { _ in
            (self.httpResponse(status: 429), Data("rate limited".utf8))
        }
        let rateLimited = await KimiQuotaClient.fetch(auth: session, session: mockSession())
        guard case .failure(let tooMany) = rateLimited else {
            return XCTFail("expected failure")
        }
        XCTAssertTrue(tooMany.isRateLimited)

        MockKimiURLProtocol.handler = { _ in
            (self.httpResponse(status: 401), Data(#"{"error":"unauthorized"}"#.utf8))
        }
        let unauthorized = await KimiQuotaClient.fetch(auth: session, session: mockSession())
        guard case .failure(let authError) = unauthorized else {
            return XCTFail("expected failure")
        }
        XCTAssertTrue(authError.isAuthFailure)
    }

    func testFetchTransportFailure() async throws {
        let session = makeAuthSession()
        MockKimiURLProtocol.handler = { _ in
            throw URLError(.timedOut)
        }
        let result = await KimiQuotaClient.fetch(auth: session, session: mockSession())
        guard case .failure(let error) = result else {
            return XCTFail("expected failure")
        }
        XCTAssertTrue(error.isNetworkFailure)
    }

    func testFetchDecodeFailureOnEmptyWindows() async throws {
        let session = makeAuthSession()
        MockKimiURLProtocol.handler = { _ in
            let body = try JSONSerialization.data(withJSONObject: ["usages": [:]])
            return (self.httpResponse(status: 200), body)
        }
        let result = await KimiQuotaClient.fetch(auth: session, session: mockSession())
        guard case .failure(let error) = result else {
            return XCTFail("expected failure")
        }
        if case .decode = error {} else {
            XCTFail("expected decode error, got \(error)")
        }
    }

    func testFetchUsesOfficialBaseURLFromAuth() async throws {
        let session = KimiAuthSession(
            accessToken: "kimi-access-token-123456",
            refreshToken: nil,
            expiresAt: nil,
            credentialURL: nil,
            homeDirectory: tempHome,
            baseURL: KimiCredentials.globalBaseURL,
            oauthHost: KimiCredentials.globalOAuthHost,
            userID: "user-abc",
            source: .kimiCode
        )
        MockKimiURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "api.kimi.ai")
            let body = try JSONSerialization.data(withJSONObject: self.usages(limit5h: ["used_ratio": 0.1]))
            return (self.httpResponse(status: 200), body)
        }
        let result = await KimiQuotaClient.fetch(auth: session, session: mockSession())
        guard case .success(let snapshot) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertEqual(snapshot.app, .kimi)
    }

    func testFetchUserInfo() async throws {
        let session = makeAuthSession()
        MockKimiURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/coding/v1/me")
            let body = try JSONSerialization.data(withJSONObject: [
                "user_id": "user-abc",
                "email": "a@example.com",
                "nickname": "Tester",
                "user_level_name": "Pro",
            ])
            return (self.httpResponse(status: 200), body)
        }
        let info = await KimiQuotaClient.fetchUserInfo(auth: session, session: mockSession())
        XCTAssertEqual(info, KimiUserInfo(
            userID: "user-abc",
            email: "a@example.com",
            nickname: "Tester",
            userLevelName: "Pro"
        ))
    }

    func testFetchUserInfoFailureReturnsNil() async throws {
        let session = makeAuthSession()
        MockKimiURLProtocol.handler = { _ in
            (self.httpResponse(status: 500), Data())
        }
        let info = await KimiQuotaClient.fetchUserInfo(auth: session, session: mockSession())
        XCTAssertNil(info, "/me 失败不阻止额度展示")
    }

    func testModelDisplayNameOnlyRemovesExactLeadingKimiCodePrefix() {
        XCTAssertEqual(ModelDisplayName.text("kimi-code/k3.1-pro"), "k3.1-pro")
        XCTAssertEqual(ModelDisplayName.text("kimi-code/"), "")
        XCTAssertEqual(ModelDisplayName.text("Kimi-Code/k3"), "Kimi-Code/k3")
        XCTAssertEqual(ModelDisplayName.text("other/kimi-code/k3"), "other/kimi-code/k3")
        XCTAssertEqual(ModelDisplayName.list(["kimi-code/k3", "kimi-code/k3"]), ["k3", "k3"])
    }

    // MARK: - Helpers

    private enum CredentialRoot {
        case new
        case legacy
    }

    private func writeCredential(
        _ root: CredentialRoot,
        userID: String,
        expiresAt: Date? = nil,
        profile: String = "kimi-code"
    ) throws -> String {
        let expires = expiresAt.map { String(Int($0.timeIntervalSince1970)) } ?? "1893456000"
        // user_id 只从 JWT payload 取；fixture 构造一个带 user_id/sub 的假 JWT。
        let jwt = try makeJWT(payload: ["user_id": userID, "sub": userID, "exp": 1_900_000_000])
        try writeCredentialRaw(
            root,
            """
            {"access_token": "\(jwt)", "refresh_token": "kimi-refresh-token-123456", \
            "expires_at": \(expires), "expires_in": 3600, "scope": "coding", "token_type": "Bearer"}
            """,
            profile: profile
        )
        return jwt
    }

    private func writeCredential(
        at root: URL,
        userID: String
    ) throws {
        let jwt = try makeJWT(payload: ["user_id": userID, "sub": userID, "exp": 1_900_000_000])
        let directory = root.appendingPathComponent("credentials")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("""
        {"access_token": "\(jwt)", "refresh_token": "kimi-refresh-token-123456", \
        "expires_at": 1893456000, "expires_in": 3600, "scope": "coding", "token_type": "Bearer"}
        """.utf8).write(to: directory.appendingPathComponent("kimi-code.json"))
    }

    private func writeCredentialRaw(
        _ root: CredentialRoot,
        _ json: String,
        profile: String = "kimi-code"
    ) throws {
        let directory = tempHome.appendingPathComponent(
            (root == .new ? ".kimi-code" : ".kimi") + "/credentials"
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: directory.appendingPathComponent("\(profile).json"))
    }

    private func writeConfig(
        baseURL: String,
        apiKey: String? = nil,
        oauthHost: String? = nil
    ) throws {
        var toml = """
        [providers."managed:kimi-code"]
        base_url = "\(baseURL)"

        """
        if let apiKey {
            toml += "api_key = \"\(apiKey)\"\n"
        }
        if let oauthHost {
            toml += "oauth = { storage = \"file\", key = \"oauth/kimi-code\", oauth_host = \"\(oauthHost)\" }\n"
        }
        try writeConfigRaw(toml)
    }

    private func writeConfigRaw(_ toml: String) throws {
        let directory = tempHome.appendingPathComponent(".kimi-code")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(toml.utf8).write(to: directory.appendingPathComponent("config.toml"))
    }

    private func makeJWT(payload: [String: Any]) throws -> String {
        let header = Data(#"{"alg":"RS256","typ":"JWT"}"#.utf8)
        let body = try JSONSerialization.data(withJSONObject: payload)
        return "\(base64url(header)).\(base64url(body)).fakesig"
    }

    private func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func makeAuthSession() -> KimiAuthSession {
        KimiAuthSession(
            accessToken: "kimi-access-token-123456",
            refreshToken: nil,
            expiresAt: nil,
            credentialURL: nil,
            homeDirectory: tempHome,
            baseURL: KimiCredentials.defaultBaseURL,
            oauthHost: KimiCredentials.defaultOAuthHost,
            userID: "user-abc",
            source: .kimiCode
        )
    }

    private func usages(
        limit5h: [String: Any]? = nil,
        limit7d: [String: Any]? = nil,
        monthTotal: [String: Any]? = nil,
        monthCode: [String: Any]? = nil
    ) -> [String: Any] {
        var usages: [String: Any] = [:]
        usages["limit_5h"] = limit5h
        usages["limit_7d"] = limit7d
        usages["limit_month_total"] = monthTotal
        usages["limit_month_code"] = monthCode
        return ["usages": usages]
    }

    private func httpResponse(status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: KimiCredentials.defaultBaseURL.appendingPathComponent("usages"),
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
    }

    private func mockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockKimiURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

// MARK: - 假网络

private final class MockKimiURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    static func reset() {
        handler = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
