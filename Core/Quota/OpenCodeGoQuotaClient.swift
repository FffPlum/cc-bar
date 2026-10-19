import Foundation

/// OpenCode Go 订阅额度：`GET https://opencode.ai/zen/go/v1/usage`，Bearer 为 OpenCode Go 的 API key。
/// 响应 `usage.{rolling,weekly,monthly}.{status, percent, resetsAt}`，`percent` 是 0～100 的已用比例。
/// 端点没有列入官方公开 API，字段按 OpenCode 服务端源码与 CodexBar、pi-model-selector 的实现交叉核对，解析保持容错。
nonisolated enum OpenCodeGoQuotaClient {
    private static let usageURL = URL(string: "https://opencode.ai/zen/go/v1/usage")!

    static func fetch(
        apiKey: String,
        session: URLSession = .shared
    ) async -> Result<QuotaSnapshot, QuotaError> {
        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("cc-bar", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        let data: Data
        do {
            let (body, response) = try await session.data(for: request)
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

    /// 三个窗口都无法解析时返回 nil；单个窗口缺失不影响其他窗口，也不伪造 0%。
    static func parse(root: [String: Any], fetchedAt: Date = Date()) -> QuotaSnapshot? {
        guard let usage = root["usage"] as? [String: Any] else { return nil }

        let rolling = parseWindow(
            usage["rolling"],
            id: "opencode-go-rolling",
            displayName: "5HOUR",
            kind: .fiveHour,
            windowSeconds: 18_000
        )
        let weekly = parseWindow(
            usage["weekly"],
            id: "opencode-go-weekly",
            displayName: "WEEKLY",
            kind: .weekly,
            windowSeconds: 604_800
        )
        let monthly = parseWindow(
            usage["monthly"],
            id: "opencode-go-monthly",
            displayName: "MONTHLY",
            kind: .unknown,
            windowSeconds: 30 * 86_400
        )
        guard rolling != nil || weekly != nil || monthly != nil else { return nil }

        return QuotaSnapshot(
            app: .opencodeGo,
            primaryLimit: rolling,
            secondaryLimit: weekly,
            auxiliaryLimits: monthly.map { [$0] } ?? [],
            modelLimits: [],
            planType: nil,
            fetchedAt: fetchedAt
        )
    }

    private static func parseWindow(
        _ value: Any?,
        id: String,
        displayName: String,
        kind: QuotaLimitKind,
        windowSeconds: Int
    ) -> QuotaLimit? {
        guard let dict = value as? [String: Any] else { return nil }
        let usedPercent: Double
        if (dict["status"] as? String)?.lowercased() == "rate-limited" {
            // 已用完的窗口照样展示为 0% 剩余，不当作接口不可用。
            usedPercent = 100
        } else {
            guard let percent = parseNumber(dict["percent"]), percent.isFinite else { return nil }
            usedPercent = min(100, max(0, percent))
        }
        return QuotaLimit(
            id: id,
            kind: kind,
            displayName: displayName,
            window: QuotaWindow(
                usedPercent: usedPercent,
                resetsAt: parseDate(dict["resetsAt"]),
                windowSeconds: windowSeconds
            )
        )
    }

    private static func parseNumber(_ value: Any?) -> Double? {
        // JSONSerialization 把 true / false 解成 NSNumber，不能当成 1 / 0。
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return number.doubleValue
        }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func parseDate(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}
