import Darwin
import Foundation
import os

/// 新 CLI 共用 oauth 目录的 mkdir 租约，旧 CLI 共用 credentials 目录的 flock。
/// 续期前后重读凭据，避免轮换 refresh token 时覆盖 CLI 刚写入的新登录。
nonisolated enum KimiTokenRefresher {
    enum Failure: Error, Sendable {
        case loginRequired
        case busy
        case storage
        case request(QuotaError)

        var quotaError: QuotaError? {
            if case .request(let error) = self { return error }
            return nil
        }

        @MainActor var userMessage: String {
            switch self {
            case .loginRequired:
                tr("Kimi Code sign-in expired. Sign in again in the CLI.", "Kimi Code 登录已失效，请在 CLI 中重新登录或检查 API Key")
            case .busy:
                tr("Kimi Code is updating its sign-in. Try again shortly.", "Kimi Code 正在更新登录状态，请稍后重试")
            case .storage:
                tr("Could not update Kimi Code sign-in. Check credential folder permissions.", "无法更新 Kimi Code 登录，请检查凭据目录权限")
            case .request(let error): error.userMessage
            }
        }
    }

    static func ensureFresh(
        auth: KimiAuthSession,
        force: Bool = false,
        session: URLSession? = nil,
        lockWait: TimeInterval = 8
    ) async -> Result<KimiAuthSession, Failure> {
        if auth.source == .apiKey { return force ? .failure(.loginRequired) : .success(auth) }
        guard let credentialURL = auth.credentialURL,
              let initial = read(auth: auth) else { return .failure(.loginRequired) }
        if initial.accessToken != auth.accessToken, usable(initial) { return .success(initial) }
        if !force, usable(initial) { return .success(initial) }
        guard initial.refreshToken != nil else { return .failure(.loginRequired) }
        let root = credentialURL.deletingLastPathComponent().deletingLastPathComponent()
        let target = root.appendingPathComponent("oauth")
            .appendingPathComponent(credentialURL.deletingPathExtension().lastPathComponent)
        let lease: (any RefreshLease)?
        if auth.source == .legacyCLI {
            lease = await acquireFileLock(url: credentialURL.deletingPathExtension().appendingPathExtension("lock"), wait: lockWait)
        } else {
            lease = await acquire(target: target, wait: lockWait)
        }
        guard let lease else { return .failure(.busy) }
        defer { lease.release() }
        guard let current = read(auth: auth) else { return .failure(.loginRequired) }
        if current.accessToken != initial.accessToken, usable(current) { return .success(current) }
        if !force, usable(current) { return .success(current) }
        guard let refreshToken = current.refreshToken,
              [KimiCredentials.defaultOAuthHost, KimiCredentials.globalOAuthHost].contains(current.oauthHost),
              [KimiCredentials.defaultBaseURL, KimiCredentials.globalBaseURL].contains(current.baseURL)
        else { return .failure(.loginRequired) }

        var request = URLRequest(url: current.oauthHost.appendingPathComponent("api/oauth/token"))
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let deviceID = try? String(contentsOf: root.appendingPathComponent("device_id"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !deviceID.isEmpty, deviceID.utf8.allSatisfy({ $0 >= 32 && $0 < 127 }) {
            request.setValue(deviceID, forHTTPHeaderField: "X-Msh-Device-Id")
        }
        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "client_id", value: "17e5f671-d194-4dfb-9706-5516cb48c098"),
                           URLQueryItem(name: "grant_type", value: "refresh_token"),
                           URLQueryItem(name: "refresh_token", value: refreshToken)]
        request.httpBody = form.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        do {
            let (data, response) = try await NetworkProxy.data(for: request, session: session)
            guard let http = response as? HTTPURLResponse else { return .failure(.request(.transport("non-http response"))) }
            guard (200...299).contains(http.statusCode) else {
                // 不写撤销 tombstone：CLI 可能已在另一个登录流程中换了身份。
                if let adopted = read(auth: auth), adopted.accessToken != current.accessToken, usable(adopted) {
                    return .success(adopted)
                }
                let body = String(data: data, encoding: .utf8) ?? ""
                let intercepted = QuotaError.http(http.statusCode, body).looksLikeInterceptedResponse
                let responseJSON = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                if !intercepted && (http.statusCode == 401 || http.statusCode == 403 ||
                    (http.statusCode == 400 && responseJSON?["error"] as? String == "invalid_grant")) {
                    return .failure(.loginRequired)
                }
                return .failure(.request(.http(http.statusCode, intercepted ? body : "Kimi OAuth refresh failed")))
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let access = KimiCredentials.sanitizeToken(json["access_token"] as? String),
                  let refresh = KimiCredentials.sanitizeToken(json["refresh_token"] as? String),
                  let expires = number(json["expires_in"]), expires > 0,
                  expires < 10 * 365 * 86_400 else { return .failure(.request(.decode("invalid OAuth response"))) }
            guard lease.isValid else { return .failure(.busy) }
            guard let latest = read(auth: auth), latest.accessToken == current.accessToken,
                  latest.refreshToken == current.refreshToken else {
                if let adopted = read(auth: auth), usable(adopted) { return .success(adopted) }
                return .failure(.busy)
            }
            guard let oldData = try? Data(contentsOf: credentialURL),
                  var stored = try? JSONSerialization.jsonObject(with: oldData) as? [String: Any]
            else { return .failure(.storage) }
            // 再检查将要替换的文档，防止交互登录（不使用刷新锁）恰在重读之间写入。
            guard stored["access_token"] as? String == current.accessToken,
                  stored["refresh_token"] as? String == current.refreshToken else { return .failure(.busy) }
            stored["access_token"] = access
            stored["refresh_token"] = refresh
            stored["expires_in"] = expires
            stored["expires_at"] = Date().timeIntervalSince1970 + expires
            stored["scope"] = json["scope"] ?? stored["scope"]
            stored["token_type"] = json["token_type"] ?? stored["token_type"] ?? "Bearer"
            let encoded = try JSONSerialization.data(withJSONObject: stored, options: [.sortedKeys])
            let temporary = credentialURL.deletingLastPathComponent().appendingPathComponent(".ccbar-kimi-\(UUID().uuidString).tmp")
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard FileManager.default.createFile(atPath: temporary.path, contents: encoded,
                                                attributes: [.posixPermissions: 0o600]) else { return .failure(.storage) }
            let handle = try FileHandle(forWritingTo: temporary)
            try handle.synchronize()
            try handle.close()
            guard lease.isValid else { return .failure(.busy) }
            guard rename(temporary.path, credentialURL.path) == 0 else { return .failure(.storage) }
            guard let updated = read(auth: auth) else { return .failure(.storage) }
            return .success(updated)
        } catch {
            if (error as NSError).domain == NSCocoaErrorDomain { return .failure(.storage) }
            return .failure(.request(.from(transport: error)))
        }
    }

    private static func usable(_ auth: KimiAuthSession) -> Bool {
        auth.expiresAt.map { $0.timeIntervalSinceNow > 30 } ?? true
    }

    private static func read(auth: KimiAuthSession) -> KimiAuthSession? {
        guard let url = auth.credentialURL, let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = KimiCredentials.sanitizeToken(json["access_token"] as? String) else { return nil }
        var next = auth
        next.accessToken = token
        next.refreshToken = KimiCredentials.sanitizeToken(json["refresh_token"] as? String)
        next.expiresAt = number(json["expires_at"]).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
        next.userID = KimiCredentials.jwtUserID(token)
            ?? next.refreshToken.flatMap(KimiCredentials.jwtUserID)
        return next
    }

    private static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite { return n.doubleValue }
        if let s = value as? String, let n = Double(s), n.isFinite { return n }
        return nil
    }

    /// 与 proper-lockfile 的 stale=5 秒约定相同；仅清理未更新的空锁目录。
    private static func acquire(target: URL, wait: TimeInterval) async -> Lease? {
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: target.path) {
                try Data().write(to: target, options: .withoutOverwriting)
            }
        } catch { return nil }
        let lock = URL(fileURLWithPath: target.path + ".lock", isDirectory: true)
        let deadline = Date().addingTimeInterval(max(0, wait))
        repeat {
            if mkdir(lock.path, 0o700) == 0 {
                if let identity = ScanFileIdentity.read(atPath: lock.path) {
                    return Lease(url: lock, identity: identity)
                }
                _ = rmdir(lock.path)
                return nil
            }
            if errno != EEXIST { return nil }
            if let attributes = try? FileManager.default.attributesOfItem(atPath: lock.path),
               let modified = attributes[.modificationDate] as? Date,
               Date().timeIntervalSince(modified) > 5,
               let identity = ScanFileIdentity.read(atPath: lock.path),
               let recheck = try? FileManager.default.attributesOfItem(atPath: lock.path),
               recheck[.modificationDate] as? Date == modified,
               ScanFileIdentity.read(atPath: lock.path) == identity {
                _ = rmdir(lock.path)
                continue
            }
            if Task.isCancelled { return nil }
            try? await Task.sleep(nanoseconds: 50_000_000)
        } while Date() < deadline
        return nil
    }

    private protocol RefreshLease: Sendable {
        var isValid: Bool { get }
        func release()
    }

    private static func acquireFileLock(url: URL, wait: TimeInterval) async -> FileLease? {
        let fd = open(url.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return nil }
        let deadline = Date().addingTimeInterval(max(0, wait))
        repeat {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                guard let identity = ScanFileIdentity.read(atPath: url.path) else { close(fd); return nil }
                return FileLease(fd: fd, url: url, identity: identity)
            }
            if errno != EWOULDBLOCK || Task.isCancelled { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        } while Date() < deadline
        close(fd)
        return nil
    }

    private final class FileLease: RefreshLease, @unchecked Sendable {
        let fd: Int32
        let url: URL
        let identity: ScanFileIdentity
        init(fd: Int32, url: URL, identity: ScanFileIdentity) {
            self.fd = fd; self.url = url; self.identity = identity
        }
        var isValid: Bool { ScanFileIdentity.read(atPath: url.path) == identity }
        func release() { _ = flock(fd, LOCK_UN); close(fd) }
    }

    private final class Lease: RefreshLease, @unchecked Sendable {
        let url: URL
        let identity: ScanFileIdentity
        private let active = OSAllocatedUnfairLock(initialState: true)
        private var heartbeat: Task<Void, Never>?

        init(url: URL, identity: ScanFileIdentity) {
            self.url = url
            self.identity = identity
            heartbeat = Task.detached { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    self?.active.withLock { running in
                        guard let self, running, ScanFileIdentity.read(atPath: self.url.path) == self.identity else { return }
                        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: self.url.path)
                    }
                }
            }
        }

        var isValid: Bool {
            active.withLock { $0 && ScanFileIdentity.read(atPath: url.path) == identity }
        }

        func release() {
            heartbeat?.cancel()
            active.withLock { running in
                guard running else { return }
                running = false
                if ScanFileIdentity.read(atPath: url.path) == identity { _ = rmdir(url.path) }
            }
        }
    }
}
