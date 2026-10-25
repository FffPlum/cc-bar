import Foundation

/// Kimi Code 订阅额度：`GET {baseURL}/usages`，Bearer 为 CLI 的 OAuth access token
/// 或官方 API key。两种已知响应形态：
/// - 原始计量 `{usages:{limit_5h:{used_ratio,reset_time},limit_7d,limit_month_total,limit_month_code}}`，
///   `used_ratio` 是 0～1 的已用比例（0.2 = 已用 20%）；
/// - 官方规范化 `{kind:"ok",quota:{usages:{limit5h:{usedRatio,resetAt},limit7d,monthTotal,monthCode}}}`；
///   也兼容明确的 `code/data` 包装。`boosterWallet` 是余额不是百分比，不参与窗口解析。
nonisolated enum KimiQuotaClient {
    private static let timeout: TimeInterval = 10

    static func fetch(
        auth: KimiAuthSession,
        session: URLSession? = nil
    ) async -> Result<QuotaSnapshot, QuotaError> {
        guard [KimiCredentials.defaultBaseURL, KimiCredentials.globalBaseURL].contains(auth.baseURL) else {
            return .failure(.decode("unsupported Kimi endpoint"))
        }
        var request = URLRequest(url: auth.baseURL.appendingPathComponent("usages"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("cc-bar", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = timeout

        let data: Data
        do {
            let (body, response) = try await NetworkProxy.data(for: request, session: session)
            guard let http = response as? HTTPURLResponse else {
                return .failure(.transport("non-http response"))
            }
            guard (200...299).contains(http.statusCode) else {
                let msg = String(data: body, encoding: .utf8) ?? "status \(http.statusCode)"
                return .failure(.http(http.statusCode, msg))
            }
            data = body
        } catch {
            return .failure(.from(transport: error))
        }

        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .failure(.decode("response is not a JSON object"))
        }
        guard let snapshot = parse(root: root) else {
            return .failure(.decode("missing usage windows"))
        }
        return .success(snapshot)
    }

    /// 主条按 5h → weekly → monthlyTotal → monthlyCode 取第一个可靠窗口，
    /// 剩余窗口按同序填 secondary 与 auxiliary，不重复、不伪造 0%。
    /// 全部窗口都不可靠时返回 nil，由调用方保留旧快照。
    static func parse(root: [String: Any], fetchedAt: Date = Date()) -> QuotaSnapshot? {
        let usages = extractUsages(from: root)

        // 同一窗口接受 snake_case（原始计量）与 camelCase（规范化）两种键名。
        let fiveHour = parseWindow(
            usages?["limit_5h"] ?? usages?["limit5h"],
            id: "kimi-five-hour",
            displayName: "5HOUR",
            kind: .fiveHour,
            windowSeconds: 18_000
        )
        let weekly = parseWindow(
            usages?["limit_7d"] ?? usages?["limit7d"],
            id: "kimi-weekly",
            displayName: "WEEKLY",
            kind: .weekly,
            windowSeconds: 604_800
        )
        let monthlyTotal = parseWindow(
            usages?["limit_month_total"] ?? usages?["monthTotal"],
            id: "kimi-monthly-total",
            displayName: "MONTHLY",
            kind: .unknown,
            windowSeconds: nil
        )
        let monthlyCode = parseWindow(
            usages?["limit_month_code"] ?? usages?["monthCode"],
            id: "kimi-monthly-code",
            displayName: "CODE MONTHLY",
            kind: .unknown,
            windowSeconds: nil
        )

        let ordered = [fiveHour, weekly, monthlyTotal, monthlyCode]
        guard ordered.contains(where: { $0 != nil }) else { return nil }

        // 主条 = 第一个可靠窗口；其余按原序补齐，单个窗口不可靠不影响其他窗口。
        let parsed = ordered.compactMap { $0 }
        let primary = parsed.first
        var secondary: QuotaLimit?
        var auxiliary: [QuotaLimit] = []
        for limit in parsed.dropFirst() {
            if secondary == nil {
                secondary = limit
            } else {
                auxiliary.append(limit)
            }
        }

        return QuotaSnapshot(
            app: .kimi,
            primaryLimit: primary,
            secondaryLimit: secondary,
            auxiliaryLimits: auxiliary,
            modelLimits: [],
            planType: nil,
            fetchedAt: fetchedAt
        )
    }

    // MARK: - 响应形态

    /// 从三种形态里取 `usages` 字典：原始 `{usages:...}`、明确 `code/data` 包装、
    /// 规范化 `{kind:"ok",quota:{usages:...}}`。只认这几种，不泛猜其他字段。
    private static func extractUsages(from root: [String: Any]) -> [String: Any]? {
        if let kind = root["kind"] as? String, kind != "ok" { return nil }
        if let code = root["code"] as? NSNumber, code.intValue != 0 && code.intValue != 200 { return nil }
        if let quota = root["quota"] as? [String: Any],
           (root["kind"] as? String) == "ok" {
            return quota["usages"] as? [String: Any]
        }
        if let usages = root["usages"] as? [String: Any] {
            return usages
        }
        if let data = root["data"] as? [String: Any] {
            if let kind = data["kind"] as? String, kind != "ok" { return nil }
            if let quota = data["quota"] as? [String: Any],
               (data["kind"] as? String) == "ok" {
                return quota["usages"] as? [String: Any]
            }
            return data["usages"] as? [String: Any]
        }
        return nil
    }

    // MARK: - 窗口解析

    private static func parseWindow(
        _ value: Any?,
        id: String,
        displayName: String,
        kind: QuotaLimitKind,
        windowSeconds: Int?
    ) -> QuotaLimit? {
        guard let dict = value as? [String: Any] else { return nil }
        guard let ratio = parseRatio(dict["used_ratio"] ?? dict["usedRatio"]) else { return nil }
        return QuotaLimit(
            id: id,
            kind: kind,
            displayName: displayName,
            window: QuotaWindow(
                usedPercent: ratio * 100,
                resetsAt: parseDate(dict["reset_time"] ?? dict["resetAt"]),
                windowSeconds: windowSeconds
            )
        )
    }

    /// 已用比例：JSON number 或字符串；拒绝 bool、非有限值、负数和 >1 的比例。
    static func parseRatio(_ value: Any?) -> Double? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            let ratio = number.doubleValue
            guard ratio >= 0, ratio <= 1 else { return nil }
            return ratio
        }
        if let string = value as? String, let ratio = Double(string) {
            guard ratio.isFinite, ratio >= 0, ratio <= 1 else { return nil }
            return ratio
        }
        return nil
    }

    private static func parseDate(_ value: Any?) -> Date? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}

// MARK: - 用户信息

nonisolated struct KimiUserInfo: Sendable, Equatable {
    var userID: String?
    var email: String?
    var nickname: String?
    var userLevelName: String?
}

extension KimiQuotaClient {
    /// `GET {baseURL}/me`，取 user_id / email / nickname / user_level_name 做副标题。
    /// 失败只返回 nil，不阻止额度展示；不强制每次刷新都调用。
    static func fetchUserInfo(
        auth: KimiAuthSession,
        session: URLSession? = nil
    ) async -> KimiUserInfo? {
        guard [KimiCredentials.defaultBaseURL, KimiCredentials.globalBaseURL].contains(auth.baseURL) else { return nil }
        var request = URLRequest(url: auth.baseURL.appendingPathComponent("me"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("cc-bar", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = timeout

        do {
            let (body, response) = try await NetworkProxy.data(for: request, session: session)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            else { return nil }
            return KimiUserInfo(
                userID: stringField(root["user_id"]) ?? stringField(root["sub"]),
                email: root["email"] as? String,
                nickname: root["nickname"] as? String,
                userLevelName: root["user_level_name"] as? String
            )
        } catch {
            return nil
        }
    }

    private static func stringField(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return number.stringValue
        }
        return nil
    }
}
