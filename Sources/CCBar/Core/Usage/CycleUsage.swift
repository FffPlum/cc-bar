import Foundation
import Observation

nonisolated enum CycleUsageQuality: String, Sendable, Codable, Equatable {
    case exact
    case estimated
    case incomplete

    var rank: Int {
        switch self {
        case .exact: return 0
        case .estimated: return 1
        case .incomplete: return 2
        }
    }

    static func worst(_ lhs: Self, _ rhs: Self) -> Self {
        lhs.rank >= rhs.rank ? lhs : rhs
    }
}

nonisolated struct CycleUsageBucket: Sendable, Codable, Equatable {
    var cycleID: String
    var allowanceSegmentID: String?
    var app: UsageApp
    var model: String
    var speed: UsageSpeed
    var inputTokens: Int
    var outputTokens: Int
    var cacheReadTokens: Int
    var cacheCreationTokens: Int
    var costUSD: Decimal
    var requestCount: Int
    var hasUnpricedUsage: Bool
    var quality: CycleUsageQuality
    /// 来源对话；额度页按项目拆分周期进度时用。旧版本写入的桶没有该字段（nil），拆分时计入「其他」。
    /// 不参与 `UsageHistoryConsistency.cycleVector` 的键，安全重算的周期对账口径不变。
    var conversationKey: String?

    enum CodingKeys: String, CodingKey {
        case cycleID, allowanceSegmentID, app, model, speed
        case inputTokens, outputTokens, cacheReadTokens, cacheCreationTokens
        case costUSD, requestCount, hasUnpricedUsage, quality, conversationKey
    }

    init(
        cycleID: String,
        allowanceSegmentID: String?,
        app: UsageApp,
        model: String,
        speed: UsageSpeed,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheCreationTokens: Int,
        costUSD: Decimal,
        requestCount: Int,
        hasUnpricedUsage: Bool,
        quality: CycleUsageQuality,
        conversationKey: String? = nil
    ) {
        self.cycleID = cycleID
        self.allowanceSegmentID = allowanceSegmentID
        self.app = app
        self.model = model
        self.speed = speed
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.costUSD = costUSD
        self.requestCount = requestCount
        self.hasUnpricedUsage = hasUnpricedUsage
        self.quality = quality
        self.conversationKey = conversationKey
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cycleID = try c.decode(String.self, forKey: .cycleID)
        allowanceSegmentID = try c.decodeIfPresent(String.self, forKey: .allowanceSegmentID)
        app = try c.decode(UsageApp.self, forKey: .app)
        model = try c.decode(String.self, forKey: .model)
        speed = try c.decode(UsageSpeed.self, forKey: .speed)
        inputTokens = try c.decode(Int.self, forKey: .inputTokens)
        outputTokens = try c.decode(Int.self, forKey: .outputTokens)
        cacheReadTokens = try c.decode(Int.self, forKey: .cacheReadTokens)
        cacheCreationTokens = try c.decode(Int.self, forKey: .cacheCreationTokens)
        costUSD = Decimal(plainString: try c.decode(String.self, forKey: .costUSD)) ?? 0
        requestCount = try c.decode(Int.self, forKey: .requestCount)
        hasUnpricedUsage = try c.decode(Bool.self, forKey: .hasUnpricedUsage)
        quality = try c.decode(CycleUsageQuality.self, forKey: .quality)
        conversationKey = try c.decodeIfPresent(String.self, forKey: .conversationKey)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(cycleID, forKey: .cycleID)
        try c.encodeIfPresent(allowanceSegmentID, forKey: .allowanceSegmentID)
        try c.encode(app, forKey: .app)
        try c.encode(model, forKey: .model)
        try c.encode(speed, forKey: .speed)
        try c.encode(inputTokens, forKey: .inputTokens)
        try c.encode(outputTokens, forKey: .outputTokens)
        try c.encode(cacheReadTokens, forKey: .cacheReadTokens)
        try c.encode(cacheCreationTokens, forKey: .cacheCreationTokens)
        try c.encode(costUSD.asPlainString, forKey: .costUSD)
        try c.encode(requestCount, forKey: .requestCount)
        try c.encode(hasUnpricedUsage, forKey: .hasUnpricedUsage)
        try c.encode(quality, forKey: .quality)
        try c.encodeIfPresent(conversationKey, forKey: .conversationKey)
    }
}

nonisolated struct CycleUsageRollupPayload: Sendable, Codable {
    static let currentVersion = 4

    var version: Int = Self.currentVersion
    var generationID: String = ""
    var pricingFingerprint: String = ""
    var buckets: [CycleUsageBucket] = []
    var initialRebuildCompletedAt: Date?
    /// nil 表示旧 v4 payload；此时用 `initialRebuildCompletedAt` 兼容推导。
    var initialRebuildCompletedApps: Set<UsageApp>?
    var updatedAt: Date = Date()

    var effectiveInitialRebuildCompletedApps: Set<UsageApp> {
        if let initialRebuildCompletedApps { return initialRebuildCompletedApps }
        return initialRebuildCompletedAt == nil ? [] : [.codex, .claude]
    }
}

nonisolated enum CycleForecastConfidence: Sendable, Equatable {
    case early
    case rough
    case reference
    case reliable
}

nonisolated struct CycleUsageSummary: Sendable, Equatable, Identifiable {
    var cycle: QuotaCycleRecord
    var totals: UsageTotals
    var currentAllowanceTotals: UsageTotals
    var quality: CycleUsageQuality

    init(
        cycle: QuotaCycleRecord,
        totals: UsageTotals,
        currentAllowanceTotals: UsageTotals = .zero,
        quality: CycleUsageQuality
    ) {
        self.cycle = cycle
        self.totals = totals
        self.currentAllowanceTotals = currentAllowanceTotals
        self.quality = quality
    }

    var id: String { cycle.id }

    var hasLocalUsage: Bool {
        totals.requestCount > 0
            || totals.totalTokens > 0
            || totals.costUSD > 0
            || totals.hasUnpricedUsage
    }

    var forecastObservedPercent: Double {
        cycle.latestAllowanceSegment?.observedUsedPercent ?? 0
    }

    var forecastConfidence: CycleForecastConfidence? {
        guard forecastObservedPercent > 0,
              currentAllowanceTotals.totalTokens > 0 || currentAllowanceTotals.costUSD > 0
        else { return nil }
        switch forecastObservedPercent {
        case 80...: return .reliable
        case 30..<80: return .reference
        case 10..<30: return .rough
        default: return .early
        }
    }

    var estimatedFullAllowanceTokens: Int? {
        Self.estimatedFullAllowanceTokens(tokens: currentAllowanceTotals.totalTokens, observedPercent: forecastObservedPercent)
    }

    static func estimatedFullAllowanceTokens(tokens: Int, observedPercent: Double) -> Int? {
        guard observedPercent > 0, tokens > 0
        else { return nil }
        let estimate = Double(tokens) * 100 / observedPercent
        guard estimate.isFinite, estimate >= 1, estimate < Double(Int.max) else { return nil }
        return Int(estimate.rounded())
    }

    var estimatedFullAllowanceCostUSD: Decimal? {
        guard forecastObservedPercent > 0,
              currentAllowanceTotals.costUSD > 0
        else { return nil }
        return currentAllowanceTotals.costUSD * 100 / Decimal(forecastObservedPercent)
    }
}

enum CycleUsageRollupCache {
    nonisolated private static let fileName = "cycle-usage-rollup.json"
    nonisolated private static let bundleDirectory = "CCBar"

    nonisolated static func load(in directory: URL? = nil) -> CycleUsageRollupPayload {
        let url = fileURL(in: directory)
        guard let data = try? Data(contentsOf: url),
              let payload = decode(data)
        else {
            return CycleUsageRollupPayload()
        }
        return payload
    }

    /// 版本不匹配时拒绝恢复派生 rollup，让启动流程按现有机制自动完整重建。
    nonisolated static func decode(_ data: Data) -> CycleUsageRollupPayload? {
        guard let payload = try? JSONDecoder().decode(CycleUsageRollupPayload.self, from: data),
              payload.version == CycleUsageRollupPayload.currentVersion
        else { return nil }
        return payload
    }

    nonisolated static func save(_ payload: CycleUsageRollupPayload, in directory: URL? = nil) throws {
        let url = fileURL(in: directory)
        let fileDirectory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: fileDirectory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(payload)
        try data.write(to: url, options: [.atomic])
    }

    nonisolated static func fileURL(in directory: URL? = nil) -> URL {
        if let directory {
            return directory.appendingPathComponent(fileName, isDirectory: false)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support
            .appendingPathComponent(bundleDirectory, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }
}

@MainActor
@Observable
final class CycleUsageAggregator {
    private struct BucketKey: Hashable {
        var cycleID: String
        var allowanceSegmentID: String?
        var app: UsageApp
        var model: String
        var speed: UsageSpeed
        var quality: CycleUsageQuality
        var conversationKey: String?
    }

    private var buckets: [BucketKey: CycleUsageBucket] = [:]

    /// 可归入 Codex 周期的其他 Agent。桶的 `app` 记来源 Agent，展示层按设置决定是否计入。
    nonisolated static let otherAgentSourceApps: Set<UsageApp> = [.pi, .opencode, .dsh]

    /// 请求归属的额度周期服务；nil 表示不进入周期统计。
    /// Pi / DSH 只认订阅渠道 `openai-codex/`（Pi 的 `openai/` 是 API Key）；OpenCode 的订阅和 API Key
    /// 都记作 `openai/`，日志无法区分，一律视为订阅。
    nonisolated static func cycleApp(for entry: UsageEntry) -> UsageApp? {
        cycleApp(app: entry.app, model: entry.model)
    }

    /// 同 `cycleApp(for:)`，供只有 (app, model) 的日桶复用（弹出面板的订阅花费）。
    nonisolated static func cycleApp(app: UsageApp, model: String) -> UsageApp? {
        switch app {
        case .codex, .claude:
            return app
        case .pi, .dsh:
            return model.lowercased().hasPrefix("openai-codex/") ? .codex : nil
        case .opencode:
            return model.lowercased().hasPrefix("openai/") ? .codex : nil
        case .kimi:
            return isKimiSubscriptionModel(model) ? .kimi : nil
        case .cursor, .antigravity:
            return nil
        }
    }

    /// Codex / Claude 自己日志里的请求是否计入订阅消耗，按模型名近似判断。
    /// Claude 只认 `claude-*`；Codex 只认 OpenAI 自家模型（可带 `openai/`、`openai-codex/` 前缀），
    /// 其他渠道前缀（如 `commandcode/...`）和其他厂商模型不算。第三方渠道转发的同名模型、
    /// API Key 调用在日志里分不出来，仍算订阅。Kimi 只认官方 `kimi-code/` 渠道的已知订阅型号；
    /// 其他 Agent 的归属由 `cycleApp` 决定，这里一律放行。
    /// 只在展示层使用：周期桶与日桶仍保存全部用量，规则调整无需重建。
    nonisolated static func isSubscriptionUsage(app: UsageApp, model: String) -> Bool {
        let name = model.lowercased()
        switch app {
        case .claude:
            return name.hasPrefix("claude-")
        case .codex:
            let bare = ["openai-codex/", "openai/"]
                .first { name.hasPrefix($0) }
                .map { String(name.dropFirst($0.count)) } ?? name
            guard !bare.contains("/") else { return false }
            return ["gpt-", "codex-", "chatgpt-", "o1", "o3", "o4"].contains { bare.hasPrefix($0) }
        case .kimi:
            return isKimiSubscriptionModel(model)
        case .pi, .opencode, .dsh, .cursor, .antigravity:
            return true
        }
    }

    private nonisolated static func isKimiSubscriptionModel(_ model: String) -> Bool {
        let name = model.lowercased()
        guard name.hasPrefix("kimi-code/") else { return false }
        let route = String(name.dropFirst("kimi-code/".count))
        return ["k3", "k3-256k", "k3.1-pro", "k3.1-pro-highspeed",
                "kimi-for-coding", "kimi-for-coding-highspeed"].contains(route)
    }

    func load(from snapshot: [CycleUsageBucket]) {
        buckets.removeAll(keepingCapacity: true)
        for bucket in snapshot {
            buckets[key(for: bucket)] = bucket
        }
    }

    func snapshot() -> [CycleUsageBucket] {
        Array(buckets.values)
    }

    @discardableResult
    func ingest(
        entries: [UsageEntry],
        cycles: [QuotaCycleRecord],
        accountSegments: [QuotaCycleAccountSegment],
        quality: CycleUsageQuality = .exact
    ) -> Bool {
        var changed = false
        for entry in entries {
            guard let cycleApp = Self.cycleApp(for: entry),
                  let accountKey = Self.accountKey(
                      for: entry.timestamp,
                      app: cycleApp,
                      segments: accountSegments
                  ) else { continue }
            for kind in [QuotaLimitKind.weekly, .fiveHour] {
                guard let cycle = Self.bestCycle(
                    for: entry.timestamp,
                    app: cycleApp,
                    accountKey: accountKey,
                    kind: kind,
                    cycles: cycles
                ) else { continue }
                let allowanceSegmentID = Self.bestAllowanceSegment(for: entry.timestamp, cycle: cycle)?.id
                add(
                    cycleID: cycle.id,
                    allowanceSegmentID: allowanceSegmentID,
                    app: entry.app,
                    model: entry.model,
                    speed: entry.speed,
                    inputTokens: entry.inputTokens,
                    outputTokens: entry.outputTokens,
                    cacheReadTokens: entry.cacheReadTokens,
                    cacheCreationTokens: entry.cacheCreationTokens,
                    costUSD: entry.costUSD ?? 0,
                    requestCount: entry.requestCount,
                    hasUnpricedUsage: entry.costUSD == nil,
                    quality: quality,
                    conversationKey: entry.conversationKey
                )
                changed = true
            }
        }
        return changed
    }

    func rebuild(
        exactEntries: [UsageEntry],
        cycles: [QuotaCycleRecord],
        accountSegments: [QuotaCycleAccountSegment]
    ) {
        buckets.removeAll(keepingCapacity: true)
        _ = ingest(entries: exactEntries, cycles: cycles, accountSegments: accountSegments)
    }

    /// 受限重建：只重算 `affectedCycleIDs` 内的桶，其余历史桶原样保留。
    /// 用于周期窗口滚动后的增量修正——窗口外的历史归属早已固化，不需要重扫，
    /// 只需把受影响周期内已聚合的数据清掉，用最近窗口扫描出的 entries 重新灌入。
    /// 注意：`exactEntries` 只应包含能归属到受影响周期的条目（调用方按时间范围过滤扫描）。
    /// - Parameter sourceApps: 非 nil 时只清除并重灌这些来源 Agent 的桶；本轮没有重扫的来源原样保留。
    func rebuildRange(
        exactEntries: [UsageEntry],
        cycles: [QuotaCycleRecord],
        accountSegments: [QuotaCycleAccountSegment],
        affectedCycleIDs: Set<String>,
        sourceApps: Set<UsageApp>? = nil
    ) {
        guard !affectedCycleIDs.isEmpty else { return }
        buckets = buckets.filter {
            !affectedCycleIDs.contains($0.value.cycleID)
                || !(sourceApps?.contains($0.value.app) ?? true)
        }
        let affectedCycles = cycles.filter { affectedCycleIDs.contains($0.id) }
        _ = ingest(
            entries: sourceApps.map { apps in exactEntries.filter { apps.contains($0.app) } } ?? exactEntries,
            cycles: affectedCycles,
            accountSegments: accountSegments
        )
    }

    /// 按会话整体替换某个来源的周期桶（OpenCode 每轮给出刷新会话的完整用量，不能累加；
    /// DSH 换 generation、文件被替换或截断时同理）。
    @discardableResult
    func replaceConversations(
        app: UsageApp,
        conversationKeys: Set<String>,
        entries: [UsageEntry],
        cycles: [QuotaCycleRecord],
        accountSegments: [QuotaCycleAccountSegment]
    ) -> Bool {
        guard !conversationKeys.isEmpty else { return false }
        let before = buckets
        buckets = buckets.filter {
            $0.value.app != app || !conversationKeys.contains($0.value.conversationKey ?? "")
        }
        _ = ingest(
            entries: entries.filter { $0.app == app && conversationKeys.contains($0.conversationKey) },
            cycles: cycles,
            accountSegments: accountSegments
        )
        return buckets != before
    }

    /// 只计订阅消耗：Codex / Claude 自己日志里非订阅模型的桶不计入（见 `isSubscriptionUsage`）。
    /// - Parameter includeOtherAgents: false 时只计周期服务自己的日志（如 Codex 周期只算 Codex 自己的日志）。
    func summaries(
        cycles: [QuotaCycleRecord],
        kind: QuotaLimitKind,
        app: UsageApp?,
        includeOtherAgents: Bool = false,
        now: Date = Date()
    ) -> [CycleUsageSummary] {
        let grouped = Dictionary(grouping: buckets.values, by: \.cycleID)
        return cycles
            .filter { $0.limitKind == kind }
            .filter { app == nil || $0.app == app }
            .map { cycle in
                var totals = UsageTotals.zero
                var currentAllowanceTotals = UsageTotals.zero
                var quality: CycleUsageQuality = cycle.boundaryQuality == .observed ? .exact : .estimated
                for bucket in grouped[cycle.id] ?? []
                    where (includeOtherAgents || bucket.app == cycle.app)
                        && Self.isSubscriptionUsage(app: bucket.app, model: bucket.model) {
                    totals.add(bucket.usageTotals)
                    if bucket.allowanceSegmentID == cycle.latestAllowanceSegment?.id {
                        currentAllowanceTotals.add(bucket.usageTotals)
                    }
                    quality = .worst(quality, bucket.quality)
                }
                if cycle.extraResetCount > 0 {
                    quality = .worst(quality, .estimated)
                }
                if cycle.boundaryQuality == .observed,
                   let firstSampleAt = cycle.firstSampleAt,
                   firstSampleAt.timeIntervalSince(cycle.startAt) > 10 * 60 {
                    quality = .incomplete
                }
                if cycle.isComplete(at: now),
                   let lastSampleAt = cycle.lastSampleAt,
                   cycle.endAt.timeIntervalSince(lastSampleAt) > 10 * 60 {
                    quality = .incomplete
                }
                return CycleUsageSummary(
                    cycle: cycle,
                    totals: totals,
                    currentAllowanceTotals: currentAllowanceTotals,
                    quality: quality
                )
            }
            .sorted { $0.cycle.endAt > $1.cycle.endAt }
    }

    nonisolated static func bestAllowanceSegment(
        for date: Date,
        cycle: QuotaCycleRecord
    ) -> QuotaCycleAllowanceSegment? {
        cycle.allowanceSegments
            .filter { $0.contains(date) }
            .max { $0.startAt < $1.startAt }
    }

    nonisolated static func bestCycle(
        for date: Date,
        app: UsageApp,
        accountKey: String,
        kind: QuotaLimitKind,
        cycles: [QuotaCycleRecord]
    ) -> QuotaCycleRecord? {
        cycles
            .filter {
                $0.app == app
                    && $0.accountKey == accountKey
                    && $0.limitKind == kind
                    && $0.contains(date)
            }
            .sorted {
                if $0.boundaryQuality == $1.boundaryQuality { return $0.startAt > $1.startAt }
                return $0.boundaryQuality == .observed
            }
            .first
    }

    nonisolated static func accountKey(
        for date: Date,
        app: UsageApp,
        segments: [QuotaCycleAccountSegment]
    ) -> String? {
        segments
            .filter { $0.app == app && $0.contains(date) }
            .max { $0.startAt < $1.startAt }?
            .accountKey
    }

    private func add(
        cycleID: String,
        allowanceSegmentID: String?,
        app: UsageApp,
        model: String,
        speed: UsageSpeed,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheCreationTokens: Int,
        costUSD: Decimal,
        requestCount: Int,
        hasUnpricedUsage: Bool,
        quality: CycleUsageQuality,
        conversationKey: String?
    ) {
        let key = BucketKey(
            cycleID: cycleID,
            allowanceSegmentID: allowanceSegmentID,
            app: app,
            model: model,
            speed: speed,
            quality: quality,
            conversationKey: conversationKey
        )
        if var bucket = buckets[key] {
            bucket.inputTokens += inputTokens
            bucket.outputTokens += outputTokens
            bucket.cacheReadTokens += cacheReadTokens
            bucket.cacheCreationTokens += cacheCreationTokens
            bucket.costUSD += costUSD
            bucket.requestCount += requestCount
            bucket.hasUnpricedUsage = bucket.hasUnpricedUsage || hasUnpricedUsage
            buckets[key] = bucket
        } else {
            buckets[key] = CycleUsageBucket(
                cycleID: cycleID,
                allowanceSegmentID: allowanceSegmentID,
                app: app,
                model: model,
                speed: speed,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cacheReadTokens: cacheReadTokens,
                cacheCreationTokens: cacheCreationTokens,
                costUSD: costUSD,
                requestCount: requestCount,
                hasUnpricedUsage: hasUnpricedUsage,
                quality: quality,
                conversationKey: conversationKey
            )
        }
    }

    private func key(for bucket: CycleUsageBucket) -> BucketKey {
        BucketKey(
            cycleID: bucket.cycleID,
            allowanceSegmentID: bucket.allowanceSegmentID,
            app: bucket.app,
            model: bucket.model,
            speed: bucket.speed,
            quality: bucket.quality,
            conversationKey: bucket.conversationKey
        )
    }

    /// 某个周期内按来源对话汇总的用量；key 为 nil 的一项是旧版本写入、没有对话信息的桶。
    func usageByConversation(cycleID: String) -> [String?: UsageTotals] {
        var result: [String?: UsageTotals] = [:]
        for bucket in buckets.values where bucket.cycleID == cycleID {
            result[bucket.conversationKey, default: .zero].add(bucket.usageTotals)
        }
        return result
    }
}

private extension CycleUsageBucket {
    nonisolated var usageTotals: UsageTotals {
        UsageTotals(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheCreationTokens: cacheCreationTokens,
            costUSD: costUSD,
            requestCount: requestCount,
            hasUnpricedUsage: hasUnpricedUsage
        )
    }
}

/// A daily estimate from indexed local requests. This is not the provider's daily
/// bill or an official quota percentage; account/cycle gaps remain unknown.
nonisolated struct CycleDailyUsage: Sendable {
    enum State: String, Sendable { case ready, loading, unavailable }
    struct Point: Sendable {
        let day: Date
        let tokens: Int?
        let estimatedUsedPercent: Double?
        let partial: Bool
    }
    var state: State
    var points: [Point]

    struct Slice: Sendable {
        let from: Date
        let to: Date
        let accountKnown: Bool
        let selectedAccount: Bool
        let fullTokens: Int?
        let partialBasis: Bool
    }
    struct Plan: Sendable {
        let app: UsageApp
        let apps: Set<UsageApp>
        let days: [Date]
        let slices: [Slice]
        let calendar: Calendar
        let now: Date

        var queries: [UsageRequestIndexStore.Query] {
            slices.map { .init(apps: apps, from: $0.from, to: $0.to, calendar: calendar) }
        }
        func empty(_ state: State) -> CycleDailyUsage {
            CycleDailyUsage(state: state, points: days.map {
                Point(day: $0, tokens: nil, estimatedUsedPercent: nil, partial: true)
            })
        }
        func includes(_ bucket: UsageBucket) -> Bool {
            apps.contains(bucket.app)
                && CycleUsageAggregator.cycleApp(app: bucket.app, model: bucket.model) == app
                && CycleUsageAggregator.isSubscriptionUsage(app: bucket.app, model: bucket.model)
        }
    }

    static func plan(app: UsageApp, accountKey: String, payload: QuotaCyclePayload,
                     buckets: [CycleUsageBucket], includeOtherAgents: Bool,
                     now: Date, calendar: Calendar = .current) -> Plan {
        let today = calendar.startOfDay(for: now)
        let days = (-13...0).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
        let from = days.first ?? today
        let apps: Set<UsageApp> = app == .codex && includeOtherAgents
            ? CycleUsageAggregator.otherAgentSourceApps.union([app]) : [app]
        let cycles = payload.records.filter {
            $0.app == app && $0.limitKind == .weekly && $0.endAt > from && $0.startAt < now
        }
        let accountSegments = payload.accountSegments.filter {
            $0.app == app && ($0.endAt ?? .distantFuture) > from && $0.startAt < now
        }
        let grouped = Dictionary(grouping: buckets.filter {
            apps.contains($0.app) && CycleUsageAggregator.isSubscriptionUsage(app: $0.app, model: $0.model)
        }, by: \.cycleID)
        var boundaries: Set<Date> = [from, now]
        for segment in accountSegments {
            boundaries.insert(max(from, segment.startAt))
            boundaries.insert(min(now, segment.endAt ?? now))
        }
        for cycle in cycles {
            boundaries.insert(max(from, cycle.startAt))
            boundaries.insert(min(now, cycle.endAt))
            for segment in cycle.allowanceSegments {
                if segment.startAt > from && segment.startAt < now { boundaries.insert(segment.startAt) }
                if let end = segment.endAt, end > from && end < now { boundaries.insert(end) }
            }
        }
        let sorted = boundaries.sorted()
        let slices = zip(sorted, sorted.dropFirst()).map { start, end -> Slice in
            let owner = CycleUsageAggregator.accountKey(for: start, app: app, segments: accountSegments)
            let cycle = owner.flatMap {
                CycleUsageAggregator.bestCycle(for: start, app: app, accountKey: $0, kind: .weekly, cycles: cycles)
            }
            let allowance = cycle.flatMap { CycleUsageAggregator.bestAllowanceSegment(for: start, cycle: $0) }
            var totals = UsageTotals.zero
            var partialBasis = false
            if let cycle, let allowance {
                for bucket in grouped[cycle.id] ?? [] where bucket.allowanceSegmentID == allowance.id {
                    totals.add(bucket.usageTotals)
                    partialBasis = partialBasis || bucket.quality == .incomplete
                }
                partialBasis = partialBasis
                    || allowance.firstSampleAt.timeIntervalSince(allowance.startAt) > 600
                    || (min(cycle.endAt, allowance.endAt ?? cycle.endAt) <= now
                        && min(cycle.endAt, allowance.endAt ?? cycle.endAt).timeIntervalSince(allowance.lastSampleAt) > 600)
            }
            let full = allowance.flatMap {
                CycleUsageSummary.estimatedFullAllowanceTokens(tokens: totals.totalTokens, observedPercent: $0.observedUsedPercent)
            }
            return Slice(from: start, to: end, accountKnown: owner != nil,
                         selectedAccount: owner == accountKey, fullTokens: full, partialBasis: partialBasis)
        }
        return Plan(app: app, apps: apps, days: days, slices: slices, calendar: calendar, now: now)
    }

    static func resolve(_ plan: Plan, results: [UsageRequestIndexStore.QueryResult],
                        canonical: [UsageBucket], status: UsageRequestIndexStatus) -> CycleDailyUsage {
        guard results.count == plan.slices.count else { return plan.empty(.loading) }
        typealias Partition = UsageRequestIndexStore.Partition
        func partition(_ bucket: UsageBucket) -> Partition {
            Partition(app: bucket.app, model: bucket.model, speed: bucket.speed, day: bucket.day)
        }
        // Each SQL result's partitions describe full days, even when its exact query
        // interval starts at a mid-day account switch. Deduplicate, never add them.
        var verified: [Partition: UsageBucket] = [:]
        var pending: Set<Partition> = []
        var incompleteApps = status.incompleteApps
        for result in results {
            for bucket in result.partitions { verified[partition(bucket)] = bucket }
            pending.formUnion(result.pendingPartitions)
            incompleteApps.formUnion(result.metadata.incompleteApps)
        }
        var dailyCanonical: [Partition: UsageTotals] = [:]
        for bucket in canonical where plan.includes(bucket) && plan.days.contains(bucket.day) {
            dailyCanonical[partition(bucket), default: .zero].add(bucket)
        }
        var incompleteDays: Set<Date> = []
        for (key, expected) in dailyCanonical {
            // DSH has no request-index implementation. Its nonzero authoritative
            // daily buckets identify the dates we cannot safely attribute.
            if key.app == .dsh && expected.totalTokens == 0 && expected.requestCount == 0 { continue }
            var actual = UsageTotals.zero
            if let bucket = verified[key] { actual.add(bucket) }
            if incompleteApps.contains(key.app) || pending.contains(key)
                || actual.inputTokens != expected.inputTokens || actual.outputTokens != expected.outputTokens
                || actual.cacheReadTokens != expected.cacheReadTokens || actual.cacheCreationTokens != expected.cacheCreationTokens
                || actual.requestCount != expected.requestCount {
                incompleteDays.insert(key.day)
            }
        }
        // Supported sources still loading cannot confirm an otherwise empty day.
        // DSH's structural lack of detail is handled per day above, not as a
        // permanent failure of every Codex day when other agents are included.
        let unavailableIndexedApps = incompleteApps.intersection(plan.apps).subtracting([.dsh])
        if !unavailableIndexedApps.isEmpty { incompleteDays.formUnion(plan.days) }

        let points = plan.days.map { day -> Point in
            let end = min(plan.calendar.date(byAdding: .day, value: 1, to: day) ?? plan.now, plan.now)
            var tokens = 0
            var percent = 0.0
            var selected = false
            var unknown = incompleteDays.contains(day)
            var missingBasis = false
            var partialBasis = false
            for (index, slice) in plan.slices.enumerated() where slice.from < end && slice.to > day {
                if !slice.accountKnown { unknown = true }
                guard slice.selectedAccount else { continue }
                selected = true
                partialBasis = partialBasis || slice.partialBasis
                var totals = UsageTotals.zero
                for bucket in results[index].buckets where bucket.day == day && plan.includes(bucket) { totals.add(bucket) }
                tokens += totals.totalTokens
                if let full = slice.fullTokens {
                    percent += Double(totals.totalTokens) / Double(full) * 100
                } else {
                    missingBasis = true
                }
            }
            let knownTokens = selected && !unknown ? tokens : nil
            let knownPercent = knownTokens != nil && !missingBasis && percent.isFinite ? percent : nil
            return Point(day: day, tokens: knownTokens, estimatedUsedPercent: knownPercent,
                         partial: unknown || !selected || missingBasis || partialBasis)
        }
        return CycleDailyUsage(state: .ready, points: points)
    }
}
