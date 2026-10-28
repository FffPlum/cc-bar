import Foundation

/// The commit after the network request runs on MainActor, together with account
/// removal and re-login. An old refresh cannot recreate or overwrite credentials.
@MainActor
enum KimiManagedTokenRefresher {
    static func ensureFresh(
        account: KimiManagedAccount,
        force: Bool = false,
        tokenStore: any KimiTokenStore = KimiFileTokenStore(),
        session: URLSession? = nil,
        now: Date = Date(),
        isCurrent: @MainActor () -> Bool = { true }
    ) async -> Result<KimiManagedTokens, QuotaError> {
        guard isCurrent(), let initial = tokenStore.load(accountID: account.id) else {
            return .failure(.missingToken)
        }
        if !force, initial.expiresAt.map({ $0.timeIntervalSince(now) > 30 }) ?? true {
            return .success(initial)
        }
        let lease: KimiRefreshLease?
        do { lease = try await tokenStore.acquireRefreshLease(accountID: account.id) }
        catch { return .failure(.from(transport: error)) }
        defer { withExtendedLifetime(lease) {} }
        guard isCurrent(), !Task.isCancelled, let current = tokenStore.load(accountID: account.id) else {
            return .failure(.missingToken)
        }
        // Another CCBar process may have rotated the token while we waited.
        if current != initial { return .success(current) }
        var request = URLRequest(url: account.region.oauthHost.appendingPathComponent("api/oauth/token"))
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "client_id", value: KimiDeviceAuthorizationClient.clientID),
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: initial.refreshToken),
        ]
        request.httpBody = form.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        do {
            let (data, response) = try await NetworkProxy.data(for: request, session: session)
            guard isCurrent(), !Task.isCancelled, let latest = tokenStore.load(accountID: account.id) else {
                return .failure(.missingToken)
            }
            if latest != initial { return .success(latest) }
            guard let http = response as? HTTPURLResponse else { return .failure(.transport("non-http response")) }
            guard (200..<300).contains(http.statusCode) else {
                return .failure(.http(http.statusCode, "Kimi OAuth refresh failed"))
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let access = KimiCredentials.sanitizeToken(json["access_token"] as? String),
                  let refresh = KimiCredentials.sanitizeToken(json["refresh_token"] as? String) else {
                return .failure(.decode("invalid OAuth response"))
            }
            var expiresAt: Date?
            if let raw = json["expires_in"] {
                guard let seconds = raw as? NSNumber, CFGetTypeID(seconds) != CFBooleanGetTypeID(),
                      seconds.doubleValue.isFinite, seconds.doubleValue > 0,
                      seconds.doubleValue <= 366 * 86400 else {
                    return .failure(.decode("invalid OAuth expiry"))
                }
                expiresAt = Date().addingTimeInterval(seconds.doubleValue)
            }
            let renewed = KimiManagedTokens(accessToken: access, refreshToken: refresh, expiresAt: expiresAt)
            try tokenStore.save(renewed, accountID: account.id)
            return .success(renewed)
        } catch {
            return .failure(.from(transport: error))
        }
    }
}
