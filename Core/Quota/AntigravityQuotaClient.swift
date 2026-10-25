import Foundation
import Darwin

/// Antigravity 额度客户端：优先读取 agy 的结构化额度，Cloud Mode 作为兜底。
///
/// 直连 `https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist`，
/// 使用 `AntigravityCredentials` 读取的 `access_token` 作为 `Bearer`。
/// 解析 5小时（`primaryLimit`）与周（`secondaryLimit`）窗口，以及
/// Gemini 5小时（`geminiWindow`）/ 周（`geminiWeekly`）细粒度。
/// 富化链路：`loadCodeAssist`（tier / plan）→ `retrieveUserQuotaSummary`
/// （权威分组：Gemini / Claude+GPT 各含 5h + weekly，实测免费版即有）→
/// `fetchAvailableModels`（Gemini 轮换）→ `retrieveUserQuota`（按模型分桶，仅 5h）。
/// 见 `docs/草案-Antigravity支持-设计方案.md` §2。
nonisolated enum AntigravityQuotaClient {
    static let endpoint = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!
    static let dailyEndpoint = URL(string: "https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!

    /// 取数结果，附带账号订阅层级。
    struct Fetched: Sendable {
        var snapshot: QuotaSnapshot
        var account: AntigravityAccount
    }

    enum CLIResult: Sendable {
        case success(QuotaSnapshot)
        case failure(QuotaError)
        /// agy 的登录已失效，需要用户自己在终端运行 agy 重新登录。此时没有调用 agy。
        case signedOut
    }

    /// nil 表示没装 agy 或代理没法交给它，按没有 CLI 处理。
    static func fetchCLIQuota(sessionKey: String) async -> CLIResult? {
        await CLIQuery.shared.fetch(sessionKey: sessionKey)
    }

    /// CLI 不携带套餐和可核实身份；仅在需要时用有效令牌补充套餐，不混入云端额度。
    static func fetchPlan(accessToken: String) async -> Result<String?, QuotaError> {
        var request = URLRequest(url: dailyEndpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("antigravity/1.0 darwin/arm64 google-api-nodejs-client/10.3.0", forHTTPHeaderField: "User-Agent")
        request.setValue("gl-node/20.0.0", forHTTPHeaderField: "X-Goog-Api-Client")
        request.httpBody = Data("{}".utf8)
        request.timeoutInterval = 15
        do {
            let (data, response) = try await NetworkProxy.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failure(.transport("non-http")) }
            guard (200..<300).contains(http.statusCode) else {
                return .failure(.http(http.statusCode, "Antigravity plan lookup failed"))
            }
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failure(.decode("Antigravity plan response is not a JSON object"))
            }
            return .success(parse(root: root).snapshot.planType)
        } catch {
            return .failure(.from(transport: error))
        }
    }

    /// agy 1.4.0 的 /quota：command.data.groups，字段使用 snake_case。
    static func parseCLI(root: [String: Any], fetchedAt: Date = Date()) -> QuotaSnapshot? {
        guard root["status"] as? String == "SUCCESS",
              let command = root["command"] as? [String: Any],
              ["usage", "quota"].contains(command["name"] as? String ?? ""),
              let data = command["data"] as? [String: Any],
              let groups = data["groups"] as? [[String: Any]]
        else { return nil }
        let normalized = groups.map { group -> [String: Any] in
            let buckets = (group["buckets"] as? [[String: Any]] ?? []).map { bucket -> [String: Any] in
                var result = bucket
                result["bucketId"] = bucket["id"]
                result["displayName"] = bucket["name"]
                result["remainingFraction"] = bucket["remaining_fraction"]
                result["resetTime"] = bucket["reset_time"]
                return result
            }
            return ["displayName": group["name"] as? String ?? "", "buckets": buckets]
        }
        let snapshot = parse(root: ["groups": normalized], fetchedAt: fetchedAt).snapshot
        return snapshot.allLimits.isEmpty ? nil : snapshot
    }

    nonisolated static func fetch(accessToken: String) async -> Result<Fetched, QuotaError> {
        let token = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return .failure(.missingToken) }

        // 官方 Antigravity 2.12.0 使用 daily 域；主域可能返回另一套基础额度池，
        // 即使请求成功也会造成套餐、用量与重置时间错配，因此仅作为回退。
        let endpoints = [dailyEndpoint, endpoint]
        var lastError: QuotaError?
        for url in endpoints {
            let result = await fetch(from: url, accessToken: token)
            switch result {
            case .success:
                return result
            case .failure(let err):
                // 认证失败或限流直接返回，不以另一域名绕过。
                if err.isAuthFailure || err.isRateLimited { return .failure(err) }
                lastError = err
                continue
            }
        }
        return .failure(lastError ?? .transport("no endpoint"))
    }

    private static func fetch(from url: URL, accessToken: String) async -> Result<Fetched, QuotaError> {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("antigravity/1.0 darwin/arm64 google-api-nodejs-client/10.3.0", forHTTPHeaderField: "User-Agent")
        req.setValue("gl-node/20.0.0", forHTTPHeaderField: "X-Goog-Api-Client")
        req.timeoutInterval = 30
        // daily 域保持与官方客户端一致的空 body；旧主域回退保留既有 project 上下文。
        let payload: [String: Any] = url == dailyEndpoint ? [:] : [
            "cloudaicompanionProject": "aicode-consumers",
            "metadata": ["ideName": "antigravity"],
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await NetworkProxy.data(for: req)
        } catch {
            return .failure(.from(transport: error))
        }
        guard let http = resp as? HTTPURLResponse else {
            return .failure(.transport("non-http"))
        }
        guard (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            return .failure(.http(http.statusCode, msg.isEmpty ? "antigravity loadCodeAssist failed" : msg))
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.decode("not json object"))
        }
        var fetched = parse(root: root)
        let fetchedAt = Date()
        // 二阶段富化（首选）：retrieveUserQuotaSummary 返回按组（Gemini / Claude+GPT）
        // 区分的 5h + weekly 窗口，与官方 UI 一致，是信息最全的真实数据源。
        // （实测免费版账号即有 4 桶：gemini-weekly/5h + 3p-weekly/5h。）
        if let enriched = await tryFetchUserQuotaSummary(baseURL: url, accessToken: accessToken, fetchedAt: fetchedAt) {
            fetched = merge(base: fetched, enrichment: enriched)
        }
        // 若已拿到完整权威分组配额（Gemini 主条 + Claude 组），无需发起后续三四阶段兜底请求，
        // 避免多余网络 RTT 并降低 Google 429 风险。
        let hasCompleteGroupedQuota = fetched.snapshot.primaryLimit != nil && !fetched.snapshot.auxiliaryLimits.isEmpty
        if !hasCompleteGroupedQuota {
            // 三阶段富化：loadCodeAssist 未返回额度时（如 daily 域回退），fetchAvailableModels
            // 提供 Gemini 轮换窗口；g1 账号缺少该接口时此步为空，不视为失败。
            if let enriched = await tryEnrichWithAvailableModels(baseURL: url, accessToken: accessToken, fetchedAt: fetchedAt) {
                fetched = merge(base: fetched, enrichment: enriched)
            }
            // 四阶段富化（兜底）：retrieveUserQuota 按模型分桶的剩余额度（仅 5h 语义），
            // 在 summary 不可用时仍可给出第三方/Gemini 的 5h 窗口。
            if let enriched = await tryFetchUserQuota(baseURL: url, accessToken: accessToken, fetchedAt: fetchedAt) {
                fetched = merge(base: fetched, enrichment: enriched)
            }
        }
        return .success(fetched)
    }

    /// 尝试用同一 host 的 `fetchAvailableModels` 补齐窗口；403/401 等视为无权，不算失败。
    private static func tryEnrichWithAvailableModels(baseURL: URL, accessToken: String, fetchedAt: Date) async -> Fetched? {
        let baseStr = baseURL.absoluteString
        // 将 v1internal:loadCodeAssist 替换为 v1internal:fetchAvailableModels
        let modelsStr = baseStr.replacingOccurrences(of: "loadCodeAssist", with: "fetchAvailableModels")
        guard let modelsURL = URL(string: modelsStr) else { return nil }
        var req = URLRequest(url: modelsURL)
        req.httpMethod = "POST"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("antigravity/1.0 darwin/arm64 google-api-nodejs-client/10.3.0", forHTTPHeaderField: "User-Agent")
        req.setValue("gl-node/20.0.0", forHTTPHeaderField: "X-Goog-Api-Client")
        req.timeoutInterval = 15
        // fetchAvailableModels 不接受 cloudaicompanionProject 字段（实测 400），保持空 body
        req.httpBody = try? JSONSerialization.data(withJSONObject: [String: Any]())
        guard let (data, resp) = try? await NetworkProxy.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return parse(root: root, fetchedAt: fetchedAt)
    }

    /// 用同一 host 的 `retrieveUserQuotaSummary` 补齐按组区分的权威额度。
    /// 返回 `groups[]`：`{ displayName, buckets: [{ bucketId, window, remainingFraction, resetTime }] }`。
    /// bucketId 语义：`gemini-weekly` / `gemini-5h`（Gemini Models 组）、
    /// `3p-weekly` / `3p-5h`（Claude and GPT models 组）。
    private static func tryFetchUserQuotaSummary(baseURL: URL, accessToken: String, fetchedAt: Date) async -> Fetched? {
        let baseStr = baseURL.absoluteString
        // 将 v1internal:loadCodeAssist 替换为 v1internal:retrieveUserQuotaSummary
        let summaryStr = baseStr.replacingOccurrences(of: "loadCodeAssist", with: "retrieveUserQuotaSummary")
        guard summaryStr != baseStr, let summaryURL = URL(string: summaryStr) else { return nil }
        var req = URLRequest(url: summaryURL)
        req.httpMethod = "POST"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("antigravity/1.0 darwin/arm64 google-api-nodejs-client/10.3.0", forHTTPHeaderField: "User-Agent")
        req.setValue("gl-node/20.0.0", forHTTPHeaderField: "X-Goog-Api-Client")
        req.timeoutInterval = 15
        // retrieveUserQuotaSummary 不接受 cloudaicompanionProject 等字段，保持空 body
        req.httpBody = try? JSONSerialization.data(withJSONObject: [String: Any]())
        guard let (data, resp) = try? await NetworkProxy.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return parse(root: root, fetchedAt: fetchedAt)
    }

    /// 用同一 host 的 `retrieveUserQuota` 补齐按模型分桶的真实额度。
    /// `buckets[]`：`{ modelId, remainingFraction, resetTime?, tokenType? }`。
    /// 与 `fetchAvailableModels` 不同，该端点区分第三方（Claude/GPT）5h 窗口与 Gemini 轮换窗口。
    private static func tryFetchUserQuota(baseURL: URL, accessToken: String, fetchedAt: Date) async -> Fetched? {
        let baseStr = baseURL.absoluteString
        // 将 v1internal:loadCodeAssist 替换为 v1internal:retrieveUserQuota
        let quotaStr = baseStr.replacingOccurrences(of: "loadCodeAssist", with: "retrieveUserQuota")
        guard quotaStr != baseStr, let quotaURL = URL(string: quotaStr) else { return nil }
        var req = URLRequest(url: quotaURL)
        req.httpMethod = "POST"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("antigravity/1.0 darwin/arm64 google-api-nodejs-client/10.3.0", forHTTPHeaderField: "User-Agent")
        req.setValue("gl-node/20.0.0", forHTTPHeaderField: "X-Goog-Api-Client")
        req.timeoutInterval = 15
        // retrieveUserQuota 不接受 cloudaicompanionProject 等字段，保持空 body
        req.httpBody = try? JSONSerialization.data(withJSONObject: [String: Any]())
        guard let (data, resp) = try? await NetworkProxy.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return parse(root: root, fetchedAt: fetchedAt)
    }

    // MARK: - Merge

    /// 富化合并：base 有值则保留，缺失用富化补齐。
    /// 注意：`retrieveUserQuotaSummary` 是权威分组源，当它解析出真实窗口时，
    /// 富化（fetchAvailableModels / retrieveUserQuota 等 per-model 兜底）不得覆盖。
    /// 普通富化只补缺失；含 Argon 的完整分组按整组采用，保留独立额度及展示顺序。
    static func merge(base: Fetched, enrichment: Fetched) -> Fetched {
        if enrichment.snapshot.primaryLimit?.id == "gemini-argon-wtu-weekly" {
            var snapshot = enrichment.snapshot
            snapshot.planType = base.snapshot.planType ?? snapshot.planType
            var account = base.account
            account.planType = account.planType ?? enrichment.account.planType
            return Fetched(snapshot: snapshot, account: account)
        }
        var snap = base.snapshot
        // 仅当 base 无窗口时，用富化结果补齐
        if snap.primaryLimit == nil { snap.primaryLimit = enrichment.snapshot.primaryLimit }
        if snap.secondaryLimit == nil { snap.secondaryLimit = enrichment.snapshot.secondaryLimit }
        if snap.geminiWindow == nil { snap.geminiWindow = enrichment.snapshot.geminiWindow }
        if snap.geminiWeekly == nil { snap.geminiWeekly = enrichment.snapshot.geminiWeekly }
        // 富化补齐了 weekly 且 base 已有 5h 主条 → 挂成 secondary；
        // 富化只有 weekly（无 5h）而 base 完全无窗口 → weekly 升为主条。
        if snap.secondaryLimit == nil, enrichment.snapshot.weeklyLimit != nil {
            if snap.primaryLimit?.kind == .fiveHour {
                snap.secondaryLimit = enrichment.snapshot.weeklyLimit
            } else if snap.primaryLimit == nil {
                snap.primaryLimit = enrichment.snapshot.weeklyLimit
            }
        }
        // 富化主窗口未命中（如合并顺序问题）时，若 primary 仍缺，用富化的补。
        if snap.primaryLimit == nil, enrichment.snapshot.primaryLimit != nil {
            snap.primaryLimit = enrichment.snapshot.primaryLimit
            if snap.secondaryLimit == nil {
                snap.secondaryLimit = enrichment.snapshot.secondaryLimit
            }
        }
        // auxiliaryLimits 同样缺失补齐：base 为空时采用富化（如 Claude 5H / Claude WK）。
        if snap.auxiliaryLimits.isEmpty {
            snap.auxiliaryLimits = enrichment.snapshot.auxiliaryLimits
        }
        // planType 保留 base，缺失时用富化的
        if snap.planType == nil { snap.planType = enrichment.snapshot.planType }
        var account = base.account
        if account.planType == nil { account.planType = enrichment.account.planType }
        return Fetched(snapshot: snap, account: account)
    }

    // MARK: - Parse

    nonisolated static func parse(root: [String: Any], fetchedAt: Date = Date()) -> Fetched {
        // 1. 尝试新版 loadCodeAssist 的 tier 结构
        // 典型字段：currentTier, paidTier, allowedTiers, project
        // 若包含显式额度 buckets（如 retrieveUserQuota / fetchAvailableModels 的 fallback），则走 buckets
        var fiveHour: QuotaWindow?   // 非分组源（fetchAvailableModels / retrieveUserQuota 兜底）的 5h
        var weekly: QuotaWindow?     // 非分组源兜底的 weekly
        var geminiWindow: QuotaWindow?
        var geminiWeekly: QuotaWindow?
        var argonWeekly: QuotaWindow?
        var claude5h: QuotaWindow?   // 仅 retrieveUserQuotaSummary 分组源（3p-5h）
        var claudeWeekly: QuotaWindow? // 仅 retrieveUserQuotaSummary 分组源（3p-weekly）
        var planType: String?
        var hasGroupedData = false   // 是否拿到 retrieveUserQuotaSummary 的分组数据

        // Google AI 订阅身份在 paidTier；Pro 账号仍可能同时返回 currentTier=free-tier，
        // 后者是基础 Code Assist 层级，不能覆盖付费订阅。展示优先用官方套餐名。
        if let paid = root["paidTier"] as? [String: Any],
           let paidPlan = paidTierPlanName(paid)
        {
            planType = paidPlan
        } else if let cur = root["currentTier"] as? [String: Any], let id = cur["id"] as? String {
            planType = tierPlanName(id)
        } else if let cur = root["currentTier"] as? String {
            planType = tierPlanName(cur)
        } else if let allowed = root["allowedTiers"] as? [[String: Any]], let first = allowed.first, let id = first["id"] as? String {
            planType = tierPlanName(id)
        } else if let tier = root["tier"] as? [String: Any], let id = tier["id"] as? String {
            planType = tierPlanName(id)
        }

        // 2. 若 root 顶层包含 "groups"（retrieveUserQuotaSummary 的权威结构，
        // 也是旧版语言服务器 RetrieveUserQuotaSummary 的兼容来源）
        if let groups = root["groups"] as? [[String: Any]] {
            let parsed = parseGroups(groups, fetchedAt: fetchedAt)
            // 分组源语义明确：5h/weekly = Claude/GPT 组，gemini* = Gemini 组。
            // 独立存一份用于“拿到分组数据”判定与组装映射。
            claude5h = parsed.fiveHour
            claudeWeekly = parsed.weekly
            geminiWindow = parsed.geminiWindow ?? geminiWindow
            geminiWeekly = parsed.geminiWeekly ?? geminiWeekly
            argonWeekly = parsed.argonWeekly
            hasGroupedData = parsed.fiveHour != nil || parsed.weekly != nil
                || parsed.geminiWindow != nil || parsed.geminiWeekly != nil || argonWeekly != nil
            if planType == nil { planType = parsed.planType }
        }

        // 3. 若包含 "quota" / "buckets" / "models"
        // 常见于 fetchAvailableModels / retrieveUserQuota
        if let quota = root["quota"] as? [String: Any] {
            let parsed = parseQuotaDict(quota, fetchedAt: fetchedAt)
            fiveHour = fiveHour ?? parsed.fiveHour
            weekly = weekly ?? parsed.weekly
            geminiWindow = geminiWindow ?? parsed.geminiWindow
            geminiWeekly = geminiWeekly ?? parsed.geminiWeekly
        }
        if let buckets = root["buckets"] as? [[String: Any]] {
            let parsed = parseBuckets(buckets, fetchedAt: fetchedAt)
            // 与顶层 quotaInfo 反序不同：buckets 是 retrieveUserQuota 的主数据，信息最全，
            // 新解析值非 nil 时覆盖旧值，保证富化第三段能真实覆盖早期宽松窗口；
            // buckets 缺某个窗口（nil）时保留 quotaInfo 解析出的旧值。
            fiveHour = parsed.fiveHour ?? fiveHour
            weekly = parsed.weekly ?? weekly
            geminiWindow = parsed.geminiWindow ?? geminiWindow
            geminiWeekly = parsed.geminiWeekly ?? geminiWeekly
        }
        // 3b. 仅当 buckets 缺席时，才用 models 解析（buckets 优先级更高且语义更准）
        if root["buckets"] == nil, let models = root["models"] as? [[String: Any]] {
            let parsed = parseModels(models, fetchedAt: fetchedAt)
            if fiveHour == nil { fiveHour = parsed.fiveHour }
            if weekly == nil { weekly = parsed.weekly }
            if geminiWindow == nil { geminiWindow = parsed.geminiWindow }
            if geminiWeekly == nil { geminiWeekly = parsed.geminiWeekly }
        }
        // fetchAvailableModels 的 models 实际是 dict：{ "model-id": { ..., "quotaInfo": { remainingFraction, resetTime } } }
        if let modelsDict = root["models"] as? [String: Any] {
            let parsed = parseModelsDict(modelsDict, fetchedAt: fetchedAt)
            if fiveHour == nil { fiveHour = parsed.fiveHour }
            if weekly == nil { weekly = parsed.weekly }
            if geminiWindow == nil { geminiWindow = parsed.geminiWindow }
            if geminiWeekly == nil { geminiWeekly = parsed.geminiWeekly }
        }
        // 4. fetchAvailableModels 的 "availableModels"
        if let available = root["availableModels"] as? [[String: Any]] {
            let parsed = parseModels(available, fetchedAt: fetchedAt)
            if fiveHour == nil { fiveHour = parsed.fiveHour }
            if weekly == nil { weekly = parsed.weekly }
            if geminiWindow == nil { geminiWindow = parsed.geminiWindow }
            if geminiWeekly == nil { geminiWeekly = parsed.geminiWeekly }
        }
        // 5. 若仍无窗，尝试从 currentTier 的 quotaInfo（保留只在此分支填，避免覆盖前序结果）
        if fiveHour == nil, weekly == nil, geminiWindow == nil, geminiWeekly == nil, claude5h == nil, claudeWeekly == nil {
            if let info = root["quotaInfo"] as? [String: Any] {
                let parsed = parseQuotaDict(info, fetchedAt: fetchedAt)
                fiveHour = fiveHour ?? parsed.fiveHour
                weekly = weekly ?? parsed.weekly
                geminiWindow = geminiWindow ?? parsed.geminiWindow
                geminiWeekly = geminiWeekly ?? parsed.geminiWeekly
            }
        }

        // 组装 QuotaSnapshot：
        // 分组源固定顺序：Argon 周（存在时）→ Gemini 5h / weekly → Claude 5h / weekly。
        // 前两条分别落 primary / secondary，其余进入 auxiliary；不把 Argon 合入普通 Gemini 周额度。
        // - 无分组源时退化为旧行为：优先 5h 主条，weekly 作副条。
        // 分组源数据优先：即便兜底（buckets/models）也填了 5h，也不覆盖分组语义。
        let primaryLimit: QuotaLimit?
        let secondaryLimit: QuotaLimit?
        let auxiliaryLimits: [QuotaLimit]
        if hasGroupedData {
            var limits: [QuotaLimit] = []
            if let argonWeekly {
                limits.append(QuotaLimit(id: "gemini-argon-wtu-weekly", kind: .modelWeekly, displayName: "Gemini 4 Argon", window: argonWeekly, isActive: nil))
            }
            if let geminiWindow {
                limits.append(QuotaLimit(id: "gemini-5h", kind: .fiveHour, displayName: "Gemini 5H", window: geminiWindow, isActive: nil))
            }
            if let geminiWeekly {
                limits.append(QuotaLimit(id: "gemini-weekly", kind: .weekly, displayName: "Gemini WK", window: geminiWeekly, isActive: nil))
            }
            if let claude5h { limits.append(QuotaLimit(id: "claude-5h", kind: .fiveHour, displayName: "Claude 5H", window: claude5h, isActive: nil)) }
            if let claudeWeekly { limits.append(QuotaLimit(id: "claude-weekly", kind: .weekly, displayName: "Claude WK", window: claudeWeekly, isActive: nil)) }
            // 没有 Gemini / Argon 时保留原来的第三方辅助行语义，供旧云端兜底继续补主条。
            if argonWeekly == nil, geminiWindow == nil, geminiWeekly == nil {
                primaryLimit = nil
                secondaryLimit = nil
                auxiliaryLimits = limits
            } else {
                primaryLimit = limits.first
                secondaryLimit = limits.dropFirst().first
                auxiliaryLimits = Array(limits.dropFirst(2))
            }
        } else {
            let primaryWindow = fiveHour ?? weekly
            let secondaryWindow = fiveHour != nil ? weekly : nil
            primaryLimit = primaryWindow.map { QuotaLimit.standard(kind: QuotaSnapshot.kind(for: $0, fallback: .fiveHour), window: $0) }
            secondaryLimit = secondaryWindow.map { QuotaLimit.standard(kind: QuotaSnapshot.kind(for: $0, fallback: .weekly), window: $0) }
            auxiliaryLimits = []
        }

        let snapshot = QuotaSnapshot(
            app: .antigravity,
            primaryLimit: primaryLimit,
            secondaryLimit: secondaryLimit,
            auxiliaryLimits: auxiliaryLimits,
            // 分组源已把 Gemini 窗口映射进 primary/secondary/aux，细行字段留空；
            // 非分组 fallback（buckets/models 兜底）仍保留 geminiWindow/geminiWeekly 供 GM/GW 细行展示。
            geminiWindow: hasGroupedData ? nil : geminiWindow,
            geminiWeekly: hasGroupedData ? nil : geminiWeekly,
            planType: planType,
            fetchedAt: fetchedAt
        )
        let account = AntigravityAccount(email: nil, planType: planType, source: .jetski)
        return Fetched(snapshot: snapshot, account: account)
    }

    /// 用 `access_token` 调 Google UserInfo 端点解析当前登录账号邮箱。
    /// 返回 nil 仅表示拿不到（不视为失败，邮箱不是额度链路的必需项）。
    nonisolated static func fetchAccountEmail(accessToken: String) async -> String? {
        let token = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return nil }
        var req = URLRequest(url: URL(string: "https://www.googleapis.com/oauth2/v3/userinfo")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("gl-node/20.0.0", forHTTPHeaderField: "X-Goog-Api-Client")
        req.timeoutInterval = 15
        guard let (data, resp) = try? await NetworkProxy.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let email = root["email"] as? String
        return email?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? email : nil
    }

    // MARK: - Groups parser（retrieveUserQuotaSummary 权威分组；兼容旧版 language_server Summary）

    private struct GroupParsed {
        var fiveHour: QuotaWindow?
        var weekly: QuotaWindow?
        var geminiWindow: QuotaWindow?
        var geminiWeekly: QuotaWindow?
        var argonWeekly: QuotaWindow?
        var planType: String?
    }

    /// 解析 `retrieveUserQuotaSummary` 的 `groups[]`（也兼容旧版本地 Summary 结构）：
    /// 每组含 `buckets[]`，真实响应（免费版实测）：
    /// - Gemini Models：`gemini-weekly` / `gemini-5h`
    /// - Claude and GPT models：`3p-weekly` / `3p-5h`
    /// bucketId 前缀（`gemini-*` / `3p-*`）与 `window` 字段（weekly / 5h）最准确，
    /// 组 displayName 与桶内文案仅作兼容兜底；不再按名称把整组硬编码到某个窗口。
    private static func parseGroups(_ groups: [[String: Any]], fetchedAt: Date) -> GroupParsed {
        var result = GroupParsed()
        for group in groups {
            guard let groupBuckets = group["buckets"] as? [[String: Any]] else { continue }
            let groupName = ((group["displayName"] as? String) ?? "").lowercased()
            for bucket in groupBuckets {
                guard bucket["disabled"] as? Bool != true,
                      let remaining = remainingFraction(in: bucket), remaining.isFinite,
                      (0...1).contains(remaining) else { continue }
                let id = (bucket["bucketId"] as? String ?? "").lowercased()
                let name = (bucket["displayName"] as? String ?? "").lowercased()
                let windowTag = (bucket["window"] as? String ?? "").lowercased()
                let reset = resetDate(value: bucket["resetTime"])

                if id == "gemini-argon-wtu-weekly" {
                    adoptMin(&result.argonWeekly, remaining: remaining, reset: reset, windowSeconds: 7 * 24 * 3600)
                    continue
                }

                // 归属判定：显式 gemini-/3p- 前缀优先；其次组 displayName；
                // 旧结构缺前缀时按默认第三方（Claude/GPT）处理，Gemini 由组名命中。
                let isGemini: Bool
                if id.hasPrefix("gemini") {
                    isGemini = true
                } else if id.hasPrefix("3p") || id.hasPrefix("third") || id.hasPrefix("claude") || id.hasPrefix("gpt") {
                    isGemini = false
                } else {
                    isGemini = groupName.contains("gemini")
                }
                let isWeekly = id.contains("week") || windowTag.contains("week") || name.contains("week")
                if isGemini {
                    if isWeekly {
                        adoptMin(&result.geminiWeekly, remaining: remaining, reset: reset, windowSeconds: 7 * 24 * 3600)
                    } else {
                        adoptMin(&result.geminiWindow, remaining: remaining, reset: reset, windowSeconds: 5 * 3600)
                    }
                } else if isWeekly {
                    adoptMin(&result.weekly, remaining: remaining, reset: reset, windowSeconds: 7 * 24 * 3600)
                } else {
                    adoptMin(&result.fiveHour, remaining: remaining, reset: reset, windowSeconds: 5 * 3600)
                }
            }
        }
        return result
    }

    /// 模型桶语义化归类（区分第三方与 Gemini 不同额度组）。
    private static func bucketFamily(_ bucket: [String: Any]) -> Family {
        let model = (bucket["modelId"] as? String ?? bucket["model"] as? String ?? "").lowercased()
        let bucketID = (bucket["bucketId"] as? String ?? "").lowercased()
        if model.contains("gemini") || model.contains("tab_") || model.contains("chat_") {
            return bucketID.contains("week") || bucketID.contains("weekly") ? .geminiWeekly : .geminiWindow
        }
        if bucketID.contains("week") || bucketID.contains("weekly") { return .weekly }
        if model.contains("claude") || model.contains("gpt") || model.contains("opus") || model.contains("sonnet") { return .thirdPartyWindow }
        // 内部补齐 / 完整标记类：无真实用量窗口
        return .internalPlaceholder
    }

    private enum Family {
        case weekly
        case geminiWeekly
        case geminiWindow
        case thirdPartyWindow
        case internalPlaceholder
    }

    private static func parseBuckets(_ buckets: [[String: Any]], fetchedAt: Date) -> GroupParsed {
        var result = GroupParsed()
        for bucket in buckets {
            guard let remaining = remainingFraction(in: bucket) else { continue }
            let family = bucketFamily(bucket)
            guard family != .internalPlaceholder else { continue }
            let reset = resetDate(value: bucket["resetTime"] ?? bucket["reset_time"])
            // remaining=1 且无 reset 的未消耗桶（如新账号从未用过的模型）不是真实额度窗口，
            // 不能合成未来重置时间后当成 0% 窗口展示，直接跳过。
            if remaining >= 1.0, reset == nil { continue }
            // 语义：第三方模型一律视为 5h 轮换（实测），Gemini 轮换同理；
            // 周额度（bucketId=weekly）无标准时长信息，windowSeconds 显式给 7 天，
            // 使 kind(for:fallback:) 能正确判定 .weekly。
            switch family {
            case .weekly:
                adoptMin(&result.weekly, remaining: remaining, reset: reset, windowSeconds: 7 * 24 * 3600)
            case .geminiWeekly:
                adoptMin(&result.geminiWeekly, remaining: remaining, reset: reset, windowSeconds: 7 * 24 * 3600)
            case .geminiWindow:
                adoptMin(&result.geminiWindow, remaining: remaining, reset: reset, windowSeconds: 5 * 3600)
            case .thirdPartyWindow:
                adoptMin(&result.fiveHour, remaining: remaining, reset: reset, windowSeconds: 5 * 3600)
            case .internalPlaceholder:
                continue
            }
        }
        return result
    }

    private static func adoptMin(_ slot: inout QuotaWindow?, remaining: Double, reset: Date?, windowSeconds: Int?) {
        guard let existing = slot else {
            slot = QuotaWindow(usedPercent: max(0, min(100, 100 - remaining * 100)), resetsAt: reset, windowSeconds: windowSeconds)
            return
        }
        // 保留最紧张窗口（remaining 最小）；并列时优先带重置时间的
        if remaining < existing.remainingPercent / 100 {
            slot = QuotaWindow(usedPercent: max(0, min(100, 100 - remaining * 100)), resetsAt: reset, windowSeconds: windowSeconds)
        } else if remaining == existing.remainingPercent / 100, existing.resetsAt == nil, reset != nil {
            slot = QuotaWindow(usedPercent: max(0, min(100, 100 - remaining * 100)), resetsAt: reset, windowSeconds: windowSeconds)
        }
    }

    private static func parseModels(_ models: [[String: Any]], fetchedAt: Date) -> GroupParsed {
        var result = GroupParsed()
        for m in models {
            guard let remaining = m["remainingFraction"] as? Double ?? (m["remaining_fraction"] as? Double) else { continue }
            let modelId = (m["modelId"] as? String ?? m["name"] as? String ?? "").lowercased()
            let reset = resetDate(value: m["resetTime"] ?? m["reset_time"])
            let isWeekly = modelId.contains("week")
            let windowSecs: Int = isWeekly ? 7 * 24 * 3600 : 5 * 3600
            let window = QuotaWindow(usedPercent: max(0, min(100, 100 - remaining * 100)), resetsAt: reset, windowSeconds: windowSecs)
            if modelId.contains("gemini") {
                // 启发式：第一个 gemini 当作 5h，第二个当 weekly
                if result.geminiWindow == nil { result.geminiWindow = window } else { result.geminiWeekly = window }
            } else {
                if result.fiveHour == nil { result.fiveHour = window } else { result.weekly = window }
            }
        }
        return result
    }

    /// fetchAvailableModels 的 models 是 dict：{ "model-id": { ..., "quotaInfo": { remainingFraction, resetTime } } }
    /// quotaInfo 无窗口类型标记，按 resetTime 距当前时间推断：
    ///   ~0.6h（<2h）→ Gemini 5h 轮换窗口；~5h（≥2h）→ Claude/GPT 5h 轮换窗口。
    /// 注意：该接口的 resetTime 不是自然周窗口，周额度不在本接口（由 loadCodeAssist 或旧 groups 提供）。
    private static func parseModelsDict(_ models: [String: Any], fetchedAt: Date) -> GroupParsed {
        var result = GroupParsed()
        // Gemini 模型组 5h 轮换窗口：取剩余比例最小（最紧张）的一个作为主额度
        // 与 GM 细行的共同来源；其余同组模型不再重复填充。
        var gemini5h: QuotaWindow?
        var gemini5hRemaining = Double.greatestFiniteMagnitude
        for (key, value) in models {
            guard let entry = value as? [String: Any] else { continue }
            let info = entry["quotaInfo"] as? [String: Any] ?? entry
            guard let remaining = remainingFraction(in: info) else { continue }
            let modelId = key.lowercased()
            let reset = resetDate(value: info["resetTime"] ?? info["reset_time"])
            let usedPercent = max(0, min(100, 100 - remaining * 100))
            let window = QuotaWindow(usedPercent: usedPercent, resetsAt: reset, windowSeconds: nil)
            let isGemini = modelId.contains("gemini") || modelId.contains("tab_") || modelId.contains("chat_")
            // 距当前 2h 内重置 → 5h 轮换窗口；其余（如 5h 整点/缺失）不算
            let isFiveHour = reset.map { fetchedAt.timeIntervalSince($0) > -2 * 3600 } ?? false
            if isGemini {
                if isFiveHour, remaining < gemini5hRemaining {
                    gemini5hRemaining = remaining
                    gemini5h = window
                }
            } else {
                if isFiveHour { result.fiveHour = window }
            }
        }
        // Gemini 组主条 5h 与 GM 细行共用最紧张窗口；fiveHour 与 geminiWindow 都填，
        // 保证 popover 主条（primaryLimit）与 GM 细行都有数可渲染。
        if let gemini5h {
            result.fiveHour = gemini5h
            result.geminiWindow = gemini5h
        }
        return result
    }

    private static func parseQuotaDict(_ dict: [String: Any], fetchedAt: Date) -> GroupParsed {
        var result = GroupParsed()
        for (k, v) in dict {
            guard let bucket = v as? [String: Any], let remaining = remainingFraction(in: bucket) else { continue }
            let key = k.lowercased()
            let reset = resetDate(value: bucket["resetTime"] ?? bucket["reset_time"])
            let isWeekly = key.contains("week")
            let windowSecs: Int = isWeekly ? 7 * 24 * 3600 : 5 * 3600
            let window = QuotaWindow(usedPercent: max(0, min(100, 100 - remaining * 100)), resetsAt: reset, windowSeconds: windowSecs)
            if key.contains("gemini") {
                if key.contains("week") { result.geminiWeekly = window } else { result.geminiWindow = window }
            } else {
                if key.contains("week") { result.weekly = window } else { result.fiveHour = window }
            }
        }
        return result
    }

    // MARK: - Helpers

    private static func remainingFraction(in bucket: [String: Any]) -> Double? {
        if let v = bucket["remainingFraction"] as? Double { return v }
        if let v = bucket["remaining_fraction"] as? Double { return v }
        if let v = bucket["remaining"] as? Double { return v > 1 ? v / 100 : v }
        if let v = bucket["remainingPercent"] as? Double { return 1 - v / 100 }
        if let s = bucket["remainingFraction"] as? String, let d = Double(s) { return d }
        if let n = bucket["remainingFraction"] as? NSNumber { return n.doubleValue }
        // remainingAmount / limit 推算
        if let used = bucket["usedPercent"] as? Double { return 1 - used / 100 }
        return nil
    }

    /// 免费层 id 为 `free-tier`，官方名是「Antigravity Starter Quota」（paidTier）或「Antigravity」
    /// （currentTier），都看不出是免费层，统一显示 Free；其他层级保持原值。
    private static func tierPlanName(_ id: String) -> String {
        id == "free-tier" ? "Free" : id
    }

    private static func paidTierPlanName(_ tier: [String: Any]) -> String? {
        if let id = nonEmpty(tier["id"] as? String), id == "free-tier" { return tierPlanName(id) }
        return nonEmpty(tier["name"] as? String) ?? nonEmpty(tier["id"] as? String)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func resetDate(value: Any?) -> Date? {
        if let s = value as? String {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = iso.date(from: s) {
                guard d.timeIntervalSince1970 > 0 else { return nil }
                return d
            }
            iso.formatOptions = [.withInternetDateTime]
            if let d = iso.date(from: s) {
                guard d.timeIntervalSince1970 > 0 else { return nil }
                return d
            }
            if let n = Double(s) {
                guard n > 0 else { return nil }
                return Date(timeIntervalSince1970: n > 1e12 ? n / 1000 : n)
            }
        }
        if let n = value as? Double {
            guard n > 0 else { return nil }
            return Date(timeIntervalSince1970: n > 1e12 ? n / 1000 : n)
        }
        if let n = value as? Int {
            guard n > 0 else { return nil }
            return Date(timeIntervalSince1970: Double(n) > 1e12 ? Double(n) / 1000 : Double(n))
        }
        return nil
    }

    // MARK: - Official CLI

    private actor CLIQuery {
        static let shared = CLIQuery()
        private var failedSession: String?
        private var failedAt: Date?

        private var lastError: QuotaError = .transport("Antigravity CLI quota unavailable")

        private static let signedOutDefaultsKey = "antigravityCLISignedOutTokenSignatureV1"
        /// 确认 agy 登录失效时其凭据（文件或钥匙串）的签名。凭据变了（用户重新登录过）才再调用 agy；持久化，重启后不再试。
        private var signedOutSignature = UserDefaults.standard.string(forKey: CLIQuery.signedOutDefaultsKey)
        private var secretCache: (key: String, secrets: [String: String])?

        func fetch(sessionKey: String) async -> CLIResult? {
            if failedSession == sessionKey, let failedAt, Date().timeIntervalSince(failedAt) < 10 * 60 {
                return .failure(lastError)
            }
            guard let executable = AntigravityQuotaClient.cliExecutable() else { return nil }
            // 代理没法交给 agy 时按没装 CLI 处理，改走云端接口（走 cc-bar 的代理），不让 agy 绕开代理直连。
            guard let environment = NetworkProxy.subprocessEnvironment(base: ProcessInfo.processInfo.environment) else {
                return nil
            }
            // agy 续期失败会自己打开浏览器登录页，所以登录失效时不调用它，只提示用户去终端重新登录。
            let token: AntigravityCredentials.CLIToken
            switch await Self.loadCLIToken() {
            case .found(let found):
                token = found
            case .missing:
                return .signedOut
            case .unreadable(let error):
                recordFailure(error, sessionKey: sessionKey, detail: "keychain read failed")
                return .failure(error)
            }
            if token.signature == signedOutSignature { return .signedOut }
            let tokenWasValid = token.isValid
            if !tokenWasValid {
                let secrets = await clientSecrets(for: executable)
                switch await AntigravityCredentials.probeCLISignIn(token: token, secrets: secrets) {
                case .valid:
                    break
                case .signedOut:
                    markSignedOut(token.signature)
                    return .signedOut
                case .unknown(let error):
                    recordFailure(error, sessionKey: sessionKey, detail: "sign-in probe failed")
                    return .failure(error)
                }
            }
            let run = await Task.detached(priority: .utility) {
                AntigravityQuotaClient.runCLI(executable: executable, environment: environment)
            }.value
            let result = AntigravityQuotaClient.evaluateCLIRun(run)
            switch result {
            case .failure(let error):
                // 续期判断为可用，agy 却没能续期（凭据仍过期）：同样按登录失效处理，不再调用它。
                if !tokenWasValid, case .found(let current) = await Self.loadCLIToken(), !current.isValid {
                    markSignedOut(current.signature)
                    return .signedOut
                }
                recordFailure(error, sessionKey: sessionKey, detail: AntigravityQuotaClient.describe(run))
                return .failure(error)
            case .success(let snapshot):
                failedSession = nil
                failedAt = nil
                return .success(snapshot)
            }
        }

        private func recordFailure(_ error: QuotaError, sessionKey: String, detail: String? = nil) {
            failedSession = sessionKey
            failedAt = Date()
            lastError = error
            var message = "antigravity CLI fetch failed: \(Redact.message(error.description))"
            if let detail, !detail.isEmpty { message += " (\(detail))" }
            AppLog.warn(.quota, message)
        }

        private func markSignedOut(_ signature: String) {
            signedOutSignature = signature
            UserDefaults.standard.set(signature, forKey: Self.signedOutDefaultsKey)
            AppLog.info(.credentials, "antigravity CLI signed out; agy skipped until its token changes")
        }

        /// 读钥匙串要起 `security` 子进程，万一弹授权框还要等用户选择，不占用 actor。
        private static func loadCLIToken() async -> AntigravityCredentials.CLITokenLoad {
            await Task.detached(priority: .utility) { AntigravityCredentials.loadCLIToken() }.value
        }

        /// agy 二进制近 200 MB，按路径、修改时间和大小缓存提取结果。
        private func clientSecrets(for executable: URL) async -> [String: String] {
            let binary = executable.resolvingSymlinksInPath()
            let attrs = try? FileManager.default.attributesOfItem(atPath: binary.path)
            let modified = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            let key = "\(binary.path)|\(modified)|\(size)"
            if let secretCache, secretCache.key == key { return secretCache.secrets }
            let secrets = await Task.detached(priority: .utility) {
                AntigravityCredentials.clientSecrets(inBinary: binary)
            }.value
            secretCache = (key, secrets)
            return secrets
        }
    }

    private static func cliExecutable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let directories = path.split(separator: ":").map(String.init) + [
            home.appendingPathComponent(".local/bin").path,
            "/opt/homebrew/bin", "/usr/local/bin",
            home.appendingPathComponent(".gemini/bin").path,
        ]
        return directories.lazy.filter { $0.hasPrefix("/") }.map {
            URL(fileURLWithPath: $0).appendingPathComponent("agy")
        }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// 一次 agy 调用的进程结果。超时或非 0 退出时也带回已读到的 stdout：
    /// 只要 JSON 完整，额度数据仍然可用，不因进程没及时退出而丢弃。
    struct CLIRun: Sendable {
        /// nil 表示进程没启动，或 stdout 读不出来（超过 1 MiB / 读取失败）。
        var data: Data?
        /// nil 表示没能确认进程已经退出。
        var exitStatus: Int32?
        var timedOut: Bool
        /// 读取线程是否在超时内排空；false 时 `data` 可能不完整。
        var drained: Bool
    }

    /// 按 stdout 判定成败，不要求进程正常退出：agy 可能已经输出完整 JSON，
    /// 却因为收尾、争锁迟迟不退。JSON 不完整时解析不出来，不会把半截数据当成功。
    static func evaluateCLIRun(_ run: CLIRun) -> Result<QuotaSnapshot, QuotaError> {
        guard let data = run.data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .failure(.transport("Antigravity CLI quota unavailable")) }
        if root["status"] as? String != "SUCCESS" {
            let message = (root["response"] as? String ?? "").lowercased()
            if ["429", "rate limit", "rate_limit", "resource_exhausted"].contains(where: message.contains) {
                return .failure(.http(429, "Antigravity CLI quota is rate limited"))
            }
        }
        guard let snapshot = parseCLI(root: root) else {
            return .failure(.decode("Antigravity CLI quota unavailable"))
        }
        return .success(snapshot)
    }

    /// 失败日志用：只描述进程层面发生了什么，不打印 stdout（可能含账号相关内容）。
    private static func describe(_ run: CLIRun) -> String {
        guard let exitStatus = run.exitStatus else { return "did not start or exit" }
        var parts = ["exit \(exitStatus)"]
        if run.timedOut { parts.append("timed out") }
        if !run.drained { parts.append("stdout not drained") }
        if run.data == nil { parts.append("no readable stdout") }
        return parts.joined(separator: ", ")
    }

    /// 持续排空 stdout，避免管道写满；超时后终止进程，但保留已经读到的输出。
    private static func runCLI(executable: URL, environment: [String: String]) -> CLIRun {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-p", "/quota", "--output-format", "json", "--log-file", "/dev/null"]
        var environment = environment
        environment["AGY_CLI_DISABLE_AUTO_UPDATE"] = "true"
        for key in ["GEMINI_API_KEY", "GOOGLE_API_KEY", "ANTHROPIC_API_KEY", "OPENAI_API_KEY"] {
            environment.removeValue(forKey: key)
        }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        let completed = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completed.signal() }
        do {
            try process.run()
        } catch {
            return CLIRun(data: nil, exitStatus: nil, timedOut: false, drained: false)
        }
        output.fileHandleForWriting.closeFile()
        let buffer = CLIOutput()
        let reader = DispatchGroup()
        reader.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { reader.leave() }
            do {
                while let chunk = try output.fileHandleForReading.read(upToCount: 8192), !chunk.isEmpty {
                    if !buffer.append(chunk) {
                        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                        break
                    }
                }
            } catch {
                buffer.invalidate()
            }
        }
        let timedOut = completed.wait(timeout: .now() + 30) == .timedOut
        if timedOut {
            process.terminate()
            if completed.wait(timeout: .now() + 0.5) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = completed.wait(timeout: .now() + 1)
            }
        }
        let drained = reader.wait(timeout: .now() + 1) == .success
        output.fileHandleForReading.closeFile()
        let exitStatus: Int32? = process.isRunning ? nil : process.terminationStatus
        return CLIRun(data: buffer.result(), exitStatus: exitStatus, timedOut: timedOut, drained: drained)
    }

    nonisolated private final class CLIOutput: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var valid = true

        func append(_ chunk: Data) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard valid, data.count + chunk.count <= 1024 * 1024 else {
                valid = false
                return false
            }
            data.append(chunk)
            return true
        }

        func invalidate() {
            lock.lock()
            defer { lock.unlock() }
            valid = false
        }

        func result() -> Data? {
            lock.lock()
            defer { lock.unlock() }
            return valid ? data : nil
        }
    }
}
