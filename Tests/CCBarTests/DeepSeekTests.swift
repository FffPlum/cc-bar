import Foundation
import Testing
import os
@testable import CCBar

@Suite(.serialized)
@MainActor
struct DeepSeekTests {
    @Test func apiKeysDoNotParticipateInQuotaDisplays() {
        let key = DeepSeekAccount(id: "key", name: "Key", kind: .apiKey, credentialFingerprint: "key",
                                  visibleInPopover: true, showInMenuBar: true, showInFloatingHUD: true)
        let login = DeepSeekAccount(id: "login", name: "Login", kind: .account, credentialFingerprint: "login")
        #expect(!key.isVisible)
        #expect(login.isVisible)
    }

    @Test func apiBalancesKeepCurrenciesAndPrecision() throws {
        let result = try DeepSeekClient.parseAPI(Data(#"{"is_available":false,"balance_infos":[{"currency":"CNY","total_balance":"1.234567890123456789","granted_balance":"0.2","topped_up_balance":"1.034567890123456789"},{"currency":"USD","total_balance":"-0.01","granted_balance":"0","topped_up_balance":"-0.01"}]}"#.utf8))
        #expect(result.isAvailable == false)
        #expect(result.wallets.count == 2)
        #expect(result.wallets[0].total == Decimal(string: "1.234567890123456789"))
        #expect(result.wallets[1].total == Decimal(string: "-0.01"))
    }

    @Test func accountWalletsCombineOnlyMatchingCurrencies() throws {
        let result = try DeepSeekClient.parseAccount(Data(#"{"normal_wallets":[{"currency":"CNY","balance":"2.5"},{"currency":"USD","balance":"0E-16"}],"bonus_wallets":[{"currency":"CNY","balance":".5"},{"currency":"USD","balance":"1e-3"}]}"#.utf8))
        #expect(result.isAvailable == nil)
        #expect(result.wallets.first { $0.currency == "CNY" }?.total == 3)
        #expect(result.wallets.first { $0.currency == "USD" }?.granted == Decimal(string: "0.001"))
    }

    @Test(arguments: ["NaN", "Infinity", "1x", "", " 1", "1,000", "1e9999"])
    func malformedAmountsFail(_ value: String) {
        #expect(throws: (any Error).self) { try DeepSeekClient.decimal(value) }
    }

    @Test func emptyAndMalformedWalletsAreDistinct() throws {
        #expect(try DeepSeekClient.parseAccount(Data(#"{"normal_wallets":[],"bonus_wallets":[]}"#.utf8)).wallets.isEmpty)
        #expect(throws: (any Error).self) { try DeepSeekClient.parseAccount(Data(#"{"normal_wallets":[]}"#.utf8)) }
        #expect(throws: (any Error).self) { try DeepSeekClient.parseAPI(Data(#"{"is_available":true,"balance_infos":[]}"#.utf8)) }
        #expect(throws: (any Error).self) { try DeepSeekClient.validateCurrency("EUR") }
    }

    @Test func businessFailureNeverBecomesBalance() throws {
        #expect(throws: (any Error).self) { try DeepSeekClient.unwrapPlatform(Data(#"{"code":0,"data":{"biz_code":2,"biz_data":{}}}"#.utf8)) }
        do {
            _ = try DeepSeekClient.unwrapPlatform(Data(#"{"code":40003}"#.utf8))
            Issue.record("Expected authorization rejection")
        } catch let error as QuotaError { #expect(error.httpStatusCode == 401) }
    }

    @Test(arguments: ["http://platform.deepseek.com/dsh/authorize", "https://example.com/dsh/authorize", "https://platform.deepseek.com.evil.test/dsh/authorize", "https://user@platform.deepseek.com/dsh/authorize", "https://platform.deepseek.com/dsh/authorize#fragment", "https://platform.deepseek.com:444/dsh/authorize", "https://platform.deepseek.com/dsh/authorized"])
    func browserDestinationsAreRestricted(_ value: String) {
        #expect(throws: (any Error).self) { try DeepSeekClient.browserURL(value, path: "/dsh/authorize") }
    }

    @Test func cancelledAuthorizationCannotStartOrCommit() async throws {
        let authorization = DeepSeekAuthorization()
        authorization.cancel()
        #expect(throws: (any Error).self) { try authorization.validateForCommit() }
        do {
            _ = try await authorization.authorize()
            Issue.record("Cancelled authorization restarted")
        } catch { #expect(error is CancellationError) }
    }

    @Test func callbackRequiresMatchingStateAndSingleCode() {
        func callback(_ target: String, method: String = "GET") -> String? {
            DeepSeekAuthorization.callbackCode(request: "\(method) \(target) HTTP/1.1\r\nHost: localhost\r\n\r\n", expectedState: "expected")
        }
        #expect(callback("/oauth/callback?state=expected&code=valid") == "valid")
        #expect(callback("/oauth/callback?state=wrong&code=valid") == nil)
        #expect(callback("/oauth/callback?state=expected&state=expected&code=valid") == nil)
        #expect(callback("/oauth/callback?state=expected&code=valid&code=other") == nil)
        #expect(callback("/oauth/callback?state=expected&code=valid", method: "POST") == nil)
        #expect(callback("/other?state=expected&code=valid") == nil)
    }

    @Test func privateCredentialsNeverEnterMetadataAndDeleteStaysDeleted() throws {
        let (state, root) = try isolatedState()
        defer { try? FileManager.default.removeItem(at: root) }
        let account = try state.saveDeepSeekAccount(id: nil, name: "Test", kind: .apiKey, secret: "fixture-private-key")
        let metadata = try String(contentsOf: root.appendingPathComponent("deepseek_accounts.json"), encoding: .utf8)
        #expect(!metadata.contains("fixture-private-key"))
        #expect(state.deepSeekCredentialStore.load(id: account.id) == "fixture-private-key")
        let credentials = root.appendingPathComponent("credentials")
        for file in try FileManager.default.contentsOfDirectory(at: credentials, includingPropertiesForKeys: nil) {
            let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
            #expect(permissions == 0o600)
        }
        state.removeDeepSeekAccount(id: account.id)
        #expect(state.deepSeekCredentialStore.load(id: account.id) == nil)
        #expect(DeepSeekAccountStore.load(from: root.appendingPathComponent("deepseek_accounts.json")).isEmpty)
    }

    @Test func rateLimitRetainsSnapshotAndBlocksManualRefresh() async throws {
        let (state, root) = try isolatedState()
        defer { try? FileManager.default.removeItem(at: root) }
        let account = try state.saveDeepSeekAccount(id: nil, name: "Test", kind: .apiKey, secret: "fixture-key")
        let balance = DeepSeekBalance(wallets: [], fetchedAt: Date())
        state.deepSeekBalances[account.id] = balance
        await state.loadDeepSeekBalance(account: account, reason: .userInitiated) { _, _, _ in .failure(.http(429, "rate limited")) }
        await state.loadDeepSeekBalance(account: account, reason: .userInitiated) { _, _, _ in
            Issue.record("Manual refresh bypassed backoff")
            return .success(balance)
        }
        #expect(state.deepSeekBalances[account.id] == balance)
        #expect(state.deepSeekRefreshStates[account.id]?.inFlight == false)
        #expect(state.deepSeekRefreshStates[account.id]?.backoffUntil != nil)
    }

    @Test func replacedCredentialRejectsLateResponse() async throws {
        let (state, root) = try isolatedState()
        defer { try? FileManager.default.removeItem(at: root) }
        let account = try state.saveDeepSeekAccount(id: nil, name: "Test", kind: .apiKey, secret: "old-fixture")
        await state.loadDeepSeekBalance(account: account, reason: .userInitiated) { _, _, _ in
            await MainActor.run {
                _ = try? state.saveDeepSeekAccount(id: account.id, name: "New", kind: .apiKey, secret: "new-fixture")
            }
            return .success(DeepSeekBalance(wallets: [], fetchedAt: Date()))
        }
        #expect(state.deepSeekBalances[account.id] == nil)
        #expect(state.deepSeekCredentialStore.load(id: account.id) == "new-fixture")
    }

    @Test func deletedAccountRejectsLateResponse() async throws {
        let (state, root) = try isolatedState()
        defer { try? FileManager.default.removeItem(at: root) }
        let account = try state.saveDeepSeekAccount(id: nil, name: "Test", kind: .apiKey, secret: "fixture")
        await state.loadDeepSeekBalance(account: account, reason: .userInitiated) { _, _, _ in
            await MainActor.run { state.removeDeepSeekAccount(id: account.id) }
            return .success(DeepSeekBalance(wallets: [], fetchedAt: Date()))
        }
        #expect(state.deepSeekAccounts.isEmpty)
        #expect(state.deepSeekBalances.isEmpty)
    }

    @Test func authenticationHeadersStayOnTheirOwnEndpoints() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DeepSeekTestProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        DeepSeekTestProtocol.state.withLock { $0 = (nil, 200) }
        let keyAccount = DeepSeekAccount(id: "key", name: "Key", kind: .apiKey, credentialFingerprint: "unused")
        _ = await DeepSeekClient.fetch(account: keyAccount, secret: "key-fixture", metadata: .current, session: session)
        let keyRequest = try #require(DeepSeekTestProtocol.state.withLock { $0.0 })
        #expect(keyRequest.url?.absoluteString == "https://api.deepseek.com/user/balance")
        #expect(keyRequest.value(forHTTPHeaderField: "Authorization") == "Bearer key-fixture")
        #expect(keyRequest.value(forHTTPHeaderField: "x-dsh-auth-token") == nil)
        let account = DeepSeekAccount(id: "login", name: "Login", kind: .account, credentialFingerprint: "unused")
        _ = await DeepSeekClient.fetch(account: account, secret: "login-fixture", metadata: .current, session: session)
        let accountRequest = try #require(DeepSeekTestProtocol.state.withLock { $0.0 })
        #expect(accountRequest.url?.absoluteString == "https://platform.deepseek.com/api/v0/users/get_user_summary")
        #expect(accountRequest.value(forHTTPHeaderField: "x-dsh-auth-token") == "login-fixture")
        #expect(accountRequest.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(accountRequest.httpShouldHandleCookies == false)
    }

    @Test func serverErrorBodyCannotEchoSecretsIntoErrors() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DeepSeekTestProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        DeepSeekTestProtocol.state.withLock { $0 = (nil, 401) }
        let account = DeepSeekAccount(id: "key", name: "Key", kind: .apiKey, credentialFingerprint: "unused")
        let result = await DeepSeekClient.fetch(account: account, secret: "secret-echo", metadata: .current, session: session)
        guard case .failure(let error) = result else { Issue.record("Expected failure"); return }
        #expect(error.httpStatusCode == 401)
        #expect(!error.description.contains("secret-echo"))
    }

    private func isolatedState() throws -> (AppState, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let state = AppState()
        state.accountPersistenceDirectory = root
        state.deepSeekCredentialStore = DeepSeekFileStore(directory: root.appendingPathComponent("credentials"))
        return (state, root)
    }
}

nonisolated private final class DeepSeekTestProtocol: URLProtocol {
    static let state = OSAllocatedUnfairLock(initialState: (Optional<URLRequest>.none, 200))
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let capturedRequest = request
        let status = Self.state.withLock { $0.0 = capturedRequest; return $0.1 }
        let body = status == 401 ? "secret-echo" : request.url?.host == "api.deepseek.com"
            ? #"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"1","topped_up_balance":"1","granted_balance":"0"}]}"#
            : #"{"code":0,"data":{"biz_code":0,"biz_data":{"normal_wallets":[],"bonus_wallets":[]}}}"#
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
