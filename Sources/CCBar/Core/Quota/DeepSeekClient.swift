import Foundation

nonisolated struct DeepSeekWallet: Codable, Equatable, Identifiable, Sendable {
    var currency: String
    var total: Decimal
    var toppedUp: Decimal
    var granted: Decimal
    var id: String { currency }
}

nonisolated struct DeepSeekBalance: Codable, Equatable, Sendable {
    var wallets: [DeepSeekWallet]
    /// The API returns availability; the account endpoint does not.
    var isAvailable: Bool?
    var fetchedAt: Date
    var credentialFingerprint: String = ""
}

/// Never follow redirects with API keys, account tokens or PKCE material.
nonisolated final class DeepSeekRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

nonisolated enum DeepSeekClient {
    static let platform = "https://platform.deepseek.com"
    static let redirectPolicy = DeepSeekRedirectPolicy()

    struct ClientMetadata: Sendable {
        var locale: String
        var version: String
        var timezoneOffset: Int
        @MainActor static var current: Self {
            Self(locale: SettingsStore.shared.resolvedLanguage == .zh ? "zh_CN" : "en_US",
                 version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0",
                 timezoneOffset: TimeZone.current.secondsFromGMT())
        }
    }

    static func request(path: String, body: [String: String]? = nil, token: String? = nil,
                        metadata: ClientMetadata, session: URLSession? = nil) async throws -> Data {
        var request = URLRequest(url: URL(string: platform + path)!, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = try body.map { try JSONEncoder().encode($0) }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("", forHTTPHeaderField: "x-client-bundle-id")
        request.setValue("desktop-mac", forHTTPHeaderField: "x-client-platform")
        request.setValue(metadata.version, forHTTPHeaderField: "x-client-version")
        request.setValue(metadata.locale, forHTTPHeaderField: "x-client-locale")
        request.setValue(String(metadata.timezoneOffset), forHTTPHeaderField: "x-client-timezone-offset")
        if let token { request.setValue(token, forHTTPHeaderField: "x-dsh-auth-token") }
        return try unwrapPlatform(await send(request, session: session))
    }

    private struct Envelope: Decodable {
        var code: Int
        var data: Business?
        struct Business: Decodable { var biz_code: Int }
    }
    static func unwrapPlatform(_ data: Data) throws -> Data {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            throw QuotaError.decode("invalid DeepSeek envelope")
        }
        if envelope.code == 40003 { throw QuotaError.http(401, "DeepSeek authorization expired") }
        guard envelope.code == 0, envelope.data?.biz_code == 0,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["data"] as? [String: Any], let business = payload["biz_data"] else {
            throw QuotaError.decode("DeepSeek request rejected")
        }
        return try JSONSerialization.data(withJSONObject: business, options: .fragmentsAllowed)
    }

    static func send(_ original: URLRequest, session: URLSession? = nil) async throws -> Data {
        var request = original
        request.timeoutInterval = 30
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("cc-bar", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await NetworkProxy.data(for: request, session: session, delegate: redirectPolicy)
        guard let http = response as? HTTPURLResponse else { throw QuotaError.transport("non-http response") }
        guard (200..<300).contains(http.statusCode) else {
            // Server error bodies may echo credentials. Keep them out of errors and diagnostics.
            throw QuotaError.http(http.statusCode, "DeepSeek request failed")
        }
        guard data.count <= 65_536 else { throw QuotaError.decode("DeepSeek response too large") }
        return data
    }

    static func fetch(account: DeepSeekAccount, secret: String, metadata: ClientMetadata,
                      session: URLSession? = nil) async -> Result<DeepSeekBalance, QuotaError> {
        do {
            let balance: DeepSeekBalance
            switch account.kind {
            case .apiKey:
                var request = URLRequest(url: URL(string: "https://api.deepseek.com/user/balance")!,
                                         cachePolicy: .reloadIgnoringLocalCacheData)
                request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
                balance = try parseAPI(await send(request, session: session))
            case .account:
                balance = try parseAccount(await request(path: "/api/v0/users/get_user_summary", token: secret,
                                                         metadata: metadata, session: session))
            }
            return .success(balance)
        } catch let error as QuotaError { return .failure(error) }
        catch { return .failure(.from(transport: error)) }
    }

    static func decimal(_ string: String) throws -> Decimal {
        guard string.count <= 128,
              string.range(of: #"^-?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$"#,
                           options: .regularExpression) != nil,
              let value = Decimal(string: string, locale: Locale(identifier: "en_US_POSIX")), !value.isNaN else {
            throw QuotaError.decode("invalid DeepSeek amount")
        }
        return value
    }
    static func validateCurrency(_ currency: String) throws {
        guard ["CNY", "USD"].contains(currency) else { throw QuotaError.decode("invalid DeepSeek currency") }
    }
    static func parseAPI(_ data: Data, now: Date = Date()) throws -> DeepSeekBalance {
        struct Response: Decodable {
            struct Wallet: Decodable { var currency, total_balance, granted_balance, topped_up_balance: String }
            var is_available: Bool
            var balance_infos: [Wallet]
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data), !response.balance_infos.isEmpty else {
            throw QuotaError.decode("invalid DeepSeek balance")
        }
        var seen = Set<String>()
        let wallets = try response.balance_infos.map { wallet in
            try validateCurrency(wallet.currency)
            guard seen.insert(wallet.currency).inserted else { throw QuotaError.decode("duplicate DeepSeek currency") }
            return try DeepSeekWallet(currency: wallet.currency, total: decimal(wallet.total_balance),
                                      toppedUp: decimal(wallet.topped_up_balance), granted: decimal(wallet.granted_balance))
        }
        return DeepSeekBalance(wallets: wallets, isAvailable: response.is_available, fetchedAt: now)
    }
    static func parseAccount(_ data: Data, now: Date = Date()) throws -> DeepSeekBalance {
        struct Response: Decodable {
            struct Wallet: Decodable { var currency, balance: String }
            var normal_wallets, bonus_wallets: [Wallet]
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw QuotaError.decode("invalid DeepSeek wallets")
        }
        var cash: [String: Decimal] = [:], bonus: [String: Decimal] = [:]
        for wallet in response.normal_wallets {
            try validateCurrency(wallet.currency)
            cash[wallet.currency, default: 0] += try decimal(wallet.balance)
        }
        for wallet in response.bonus_wallets {
            try validateCurrency(wallet.currency)
            bonus[wallet.currency, default: 0] += try decimal(wallet.balance)
        }
        let wallets = Set(cash.keys).union(bonus.keys).sorted().map { currency in
            DeepSeekWallet(currency: currency, total: (cash[currency] ?? 0) + (bonus[currency] ?? 0),
                           toppedUp: cash[currency] ?? 0, granted: bonus[currency] ?? 0)
        }
        return DeepSeekBalance(wallets: wallets, isAvailable: nil, fetchedAt: now)
    }

    static func browserURL(_ string: String, path: String) throws -> URL {
        guard let url = URL(string: string), url.scheme == "https", url.host == "platform.deepseek.com",
              url.port == nil || url.port == 443, url.path == path,
              url.user == nil, url.password == nil, url.fragment == nil else {
            throw QuotaError.decode("invalid DeepSeek authorization destination")
        }
        return url
    }
}
