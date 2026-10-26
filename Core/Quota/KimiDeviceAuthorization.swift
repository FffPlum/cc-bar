import Foundation

nonisolated struct KimiDeviceAuthorization: Equatable, Sendable {
    var region: KimiRegion
    var userCode: String
    var deviceCode: String
    var verificationURL: URL
    var expiresAt: Date
    var interval: TimeInterval
}

nonisolated enum KimiDeviceAuthorizationError: Error, Equatable, Sendable {
    case invalidResponse
    case untrustedVerificationURL
    case rateLimited
    case http(Int)
    case network
    case denied
    case expired
    case cancelled
    case differentAccount

    @MainActor var userMessage: String {
        switch self {
        case .invalidResponse: tr("The official sign-in response was invalid. Try again.", "官方登录响应无效，请重试")
        case .untrustedVerificationURL: tr("The authorization page is not on the official Kimi host.", "授权页面不是 Kimi 官方地址")
        case .rateLimited: tr("Too many sign-in attempts. Try again later.", "登录请求过于频繁，请稍后再试")
        case .http(let code): tr("Official sign-in failed (HTTP \(code)).", "官方登录失败（HTTP \(code)）")
        case .network: tr("Couldn't connect to Kimi. Check your network or proxy.", "无法连接 Kimi，请检查网络或代理")
        case .denied: tr("Authorization was denied.", "授权已被拒绝")
        case .expired: tr("The verification code expired. Start sign-in again.", "验证码已过期，请重新登录")
        case .cancelled: tr("Sign-in cancelled.", "已取消登录")
        case .differentAccount: tr("Sign in with this account. Use Add account for a different identity.", "请登录此账号；添加其他身份请使用“添加账号”")
        }
    }
}

nonisolated enum KimiDeviceAuthorizationClient {
    static let clientID = "17e5f671-d194-4dfb-9706-5516cb48c098"
    static let deviceGrant = "urn:ietf:params:oauth:grant-type:device_code"

    static func request(
        region: KimiRegion,
        now: Date = Date(),
        session: URLSession? = nil
    ) async throws -> KimiDeviceAuthorization {
        let (data, response) = try await post(
            region.oauthHost.appendingPathComponent("api/oauth/device_authorization"),
            form: ["client_id": clientID],
            session: session
        )
        guard let http = response as? HTTPURLResponse else { throw KimiDeviceAuthorizationError.network }
        if http.statusCode == 429 { throw KimiDeviceAuthorizationError.rateLimited }
        guard http.statusCode == 200 else { throw KimiDeviceAuthorizationError.http(http.statusCode) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let userCode = nonempty(json["user_code"]),
              let deviceCode = nonempty(json["device_code"]),
              let complete = nonempty(json["verification_uri_complete"]),
              let verificationURL = URL(string: complete),
              isTrusted(verificationURL, region: region),
              let expiresIn = positiveNumber(json["expires_in"]),
              expiresIn <= 24 * 3600
        else { throw KimiDeviceAuthorizationError.invalidResponse }
        let interval = positiveNumber(json["interval"]) ?? 5
        guard interval <= 300 else { throw KimiDeviceAuthorizationError.invalidResponse }
        return KimiDeviceAuthorization(
            region: region,
            userCode: userCode,
            deviceCode: deviceCode,
            verificationURL: verificationURL,
            expiresAt: now.addingTimeInterval(expiresIn),
            interval: max(1, interval)
        )
    }

    enum PollResult: Equatable, Sendable {
        case success(KimiManagedTokens)
        case pending
        case slowDown
        case denied
        case expired
    }

    static func poll(
        _ authorization: KimiDeviceAuthorization,
        session: URLSession? = nil
    ) async throws -> PollResult {
        let (data, response) = try await post(
            authorization.region.oauthHost.appendingPathComponent("api/oauth/token"),
            form: ["client_id": clientID, "device_code": authorization.deviceCode, "grant_type": deviceGrant],
            session: session
        )
        guard let http = response as? HTTPURLResponse else { throw KimiDeviceAuthorizationError.network }
        if http.statusCode == 429 { throw KimiDeviceAuthorizationError.rateLimited }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if http.statusCode == 200, let json,
           let access = KimiCredentials.sanitizeToken(json["access_token"] as? String),
           let refresh = KimiCredentials.sanitizeToken(json["refresh_token"] as? String) {
            let expires = positiveNumber(json["expires_in"])
            return .success(KimiManagedTokens(
                accessToken: access,
                refreshToken: refresh,
                expiresAt: expires.map { Date().addingTimeInterval($0) }
            ))
        }
        if http.statusCode >= 500 { throw KimiDeviceAuthorizationError.http(http.statusCode) }
        switch json?["error"] as? String {
        case "authorization_pending": return .pending
        case "slow_down": return .slowDown
        case "access_denied": return .denied
        case "expired_token": return .expired
        default: throw KimiDeviceAuthorizationError.http(http.statusCode)
        }
    }

    static func isTrusted(_ url: URL, region: KimiRegion) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == region.oauthHost.host
            && (url.port == nil || url.port == 443) && url.user == nil && url.password == nil
    }

    private static func post(
        _ url: URL,
        form: [String: String],
        session: URLSession?
    ) async throws -> (Data, URLResponse) {
        var components = URLComponents()
        components.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        do {
            return try await NetworkProxy.data(for: request, session: session)
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                throw KimiDeviceAuthorizationError.cancelled
            }
            throw KimiDeviceAuthorizationError.network
        }
    }

    private static func nonempty(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }

    private static func positiveNumber(_ value: Any?) -> Double? {
        let number: Double?
        if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() {
            number = value.doubleValue
        } else if let value = value as? String {
            number = Double(value)
        } else {
            number = nil
        }
        guard let number, number.isFinite, number > 0 else { return nil }
        return number
    }
}

nonisolated enum KimiDeviceLoginRunner {
    static func run(
        authorization: KimiDeviceAuthorization,
        now: @Sendable () -> Date = Date.init,
        poll: @Sendable (KimiDeviceAuthorization) async throws -> KimiDeviceAuthorizationClient.PollResult = {
            try await KimiDeviceAuthorizationClient.poll($0)
        },
        sleep: @Sendable (TimeInterval) async throws -> Void = { seconds in
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    ) async throws -> KimiManagedTokens {
        guard authorization.interval.isFinite, authorization.interval > 0, authorization.interval <= 300 else {
            throw KimiDeviceAuthorizationError.invalidResponse
        }
        var interval = authorization.interval
        let deadline = min(authorization.expiresAt, now().addingTimeInterval(15 * 60))
        while true {
            if Task.isCancelled { throw KimiDeviceAuthorizationError.cancelled }
            if now() >= deadline { throw KimiDeviceAuthorizationError.expired }
            do { try await sleep(min(interval, max(0, deadline.timeIntervalSince(now())))) }
            catch {
                if Task.isCancelled { throw KimiDeviceAuthorizationError.cancelled }
                throw error
            }
            if Task.isCancelled { throw KimiDeviceAuthorizationError.cancelled }
            if now() >= deadline { throw KimiDeviceAuthorizationError.expired }
            let result = try await poll(authorization)
            if Task.isCancelled { throw KimiDeviceAuthorizationError.cancelled }
            switch result {
            case .success(let tokens): return tokens
            case .denied: throw KimiDeviceAuthorizationError.denied
            case .expired: throw KimiDeviceAuthorizationError.expired
            case .pending: break
            case .slowDown: interval = min(300, interval + 5)
            }
        }
    }
}
