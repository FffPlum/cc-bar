import XCTest
@testable import CCBar

/// 新来源必须经过真实扫描、快照提交、重启和重算链路；不能只验证格式解析。
@MainActor
final class KimiUsageIntegrationTests: XCTestCase {
    func testScanRestartRebuildAndDeletedHistoryPreserveKimiUsage() async throws {
        let env = try UsageTestEnvironment(name: "kimi-integration")
        let share = env.root.appendingPathComponent("kimi-code", isDirectory: true)
        let session = share.appendingPathComponent("sessions/workspace/session_test", isDirectory: true)
        let wire = session.appendingPathComponent("agents/main/wire.jsonl")
        try FileManager.default.createDirectory(at: wire.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: [
            "id": "session_test", "version": 2, "cwd": env.root.path, "title": "Fixture",
        ]).write(to: session.appendingPathComponent("state.json"))
        try env.append(usage(time: 1_792_000_000_000, input: 100), to: wire)
        var roots = env.scanRoots
        roots.kimiRoots = [share]
        func service() -> UsageService {
            UsageService(historyStore: env.store, roots: roots, legacyLocations: env.legacyLocations,
                         backfillURL: env.backfillURL, cursorCacheDirectory: env.cursorCacheDirectory)
        }
        let first = service()
        await env.bootstrap(first)
        await first.scanNow()
        XCTAssertEqual(tokens(first), 135)
        XCTAssertEqual(first.aggregator.snapshotLocal().filter { $0.app == .kimi }.first?.requestCount, 1)
        XCTAssertTrue(first.aggregator.snapshotLocal().filter { $0.app == .kimi }.allSatisfy(\.hasUnpricedUsage))
        XCTAssertFalse(first.conversationAggregator.snapshot().infos.filter { $0.app == .kimi }.isEmpty)
        XCTAssertEqual(first.conversationAggregator.snapshot().infos.first { $0.app == .kimi }?.title, "Fixture")
        XCTAssertTrue(first.cycleAggregator.snapshot().isEmpty)
        let bucket = try XCTUnwrap(first.aggregator.snapshotLocal().first { $0.app == .kimi })
        var sample = DailySample(day: bucket.day)
        sample.add(bucket)
        XCTAssertEqual(sample.totals(for: .kimi).totalTokens, 135)
        XCTAssertEqual(sample.totalTokens, 135)

        // 新请求落盘后重启不应重复灌入旧请求。
        try env.append(usage(time: 1_792_000_001_000, input: 200), to: wire)
        await first.scanNow()
        XCTAssertEqual(tokens(first), 370)
        let restarted = service()
        await env.bootstrap(restarted)
        await restarted.scanNow()
        XCTAssertEqual(tokens(restarted), 370)
        await restarted.forceRescan()
        XCTAssertEqual(tokens(restarted), 370)

        try FileManager.default.removeItem(at: session)
        await restarted.forceRescan()
        XCTAssertEqual(tokens(restarted), 370, "重算保留源日志已删除的 Kimi 历史")
    }

    func testKimiCycleOfficialAttributionRebuildRestartAndDeletedHistory() async throws {
        let env = try UsageTestEnvironment(name: "kimi-cycle-integration")
        let share = env.root.appendingPathComponent("kimi-code", isDirectory: true)
        let session = share.appendingPathComponent("sessions/workspace/session_cycle", isDirectory: true)
        let wire = session.appendingPathComponent("agents/main/wire.jsonl")
        let now = Date()
        let models = [
            ("kimi-code/k3", 100),
            ("kimi-code/kimi-for-coding", 200),
            ("deepseek/deepseek-v4-pro", 1_000),
            ("custom/kimi-code/k3", 2_000),
            ("unknown", 3_000),
        ]
        for (index, item) in models.enumerated() {
            let time = Int64(now.addingTimeInterval(TimeInterval(index - 60)).timeIntervalSince1970 * 1_000)
            try env.append(usage(time: time, input: item.1, model: item.0), to: wire)
        }

        let accountKey = "fixture-kimi-account"
        func cycle(kind: QuotaLimitKind, seconds: TimeInterval) -> QuotaCycleRecord {
            let start = now.addingTimeInterval(-120)
            let end = start.addingTimeInterval(seconds)
            let id = "kimi|\(kind.rawValue)"
            return QuotaCycleRecord(
                id: id,
                accountKey: accountKey,
                app: .kimi,
                limitID: kind.rawValue,
                limitKind: kind,
                startAt: start,
                endAt: end,
                scheduledEndAt: end,
                firstSampleAt: now,
                lastSampleAt: now,
                latestUsedPercent: 20,
                allowanceSegments: [QuotaCycleAllowanceSegment(
                    id: "\(id)|allowance",
                    startAt: start,
                    endAt: nil,
                    baselineUsedPercent: 0,
                    latestUsedPercent: 20,
                    maximumUsedPercent: 20,
                    firstSampleAt: now,
                    lastSampleAt: now,
                    startReason: .initial
                )],
                source: .api,
                boundaryQuality: .observed
            )
        }
        var quotaCycles = QuotaCyclePayload()
        quotaCycles.trackingStartedAt = now.addingTimeInterval(-8 * 86_400)
        quotaCycles.records = [cycle(kind: .fiveHour, seconds: 18_000), cycle(kind: .weekly, seconds: 604_800)]
        quotaCycles.accountSegments = [QuotaCycleAccountSegment(
            id: "kimi-account",
            accountKey: accountKey,
            app: .kimi,
            startAt: quotaCycles.trackingStartedAt,
            endAt: nil
        )]
        env.appState.quotaCycles = quotaCycles
        var roots = env.scanRoots
        roots.kimiRoots = [share]
        func service() -> UsageService {
            UsageService(historyStore: env.store, roots: roots, legacyLocations: env.legacyLocations,
                         backfillURL: env.backfillURL, cursorCacheDirectory: env.cursorCacheDirectory)
        }
        func assertCycle(_ service: UsageService, file: StaticString = #filePath, line: UInt = #line) {
            let buckets = service.cycleAggregator.snapshot()
            XCTAssertEqual(Set(buckets.map(\.cycleID)), Set(quotaCycles.records.map(\.id)), file: file, line: line)
            XCTAssertEqual(buckets.reduce(0) { $0 + $1.inputTokens }, 600, file: file, line: line)
            XCTAssertEqual(buckets.reduce(0) { $0 + $1.requestCount }, 4, file: file, line: line)
            XCTAssertTrue(buckets.allSatisfy { $0.app == .kimi && $0.model.hasPrefix("kimi-code/") }, file: file, line: line)
            XCTAssertEqual(Set(buckets.map(\.model)), ["kimi-code/k3", "kimi-code/kimi-for-coding"], file: file, line: line)
            XCTAssertTrue(buckets.filter { $0.model == "kimi-code/k3" }.allSatisfy {
                $0.costUSD == Decimal(string: "0.000471")! && !$0.hasUnpricedUsage
            }, file: file, line: line)
            XCTAssertTrue(buckets.filter { $0.model == "kimi-code/kimi-for-coding" }.allSatisfy(\.hasUnpricedUsage), file: file, line: line)
        }

        let first = service()
        await env.bootstrap(first)
        await first.scanNow()
        assertCycle(first)
        XCTAssertEqual(tokens(first), 6_475, "普通统计仍保留全部 Kimi 渠道")
        var expected = UsageHistoryConsistency.cycleVector(first.cycleAggregator.snapshot())

        await first.scanNow()
        XCTAssertEqual(UsageHistoryConsistency.cycleVector(first.cycleAggregator.snapshot()), expected)
        await first.rebuildCycleUsageForRecentChanges(reasons: ["fixture committed Kimi events"])
        XCTAssertEqual(UsageHistoryConsistency.cycleVector(first.cycleAggregator.snapshot()), expected,
                       "committedEvents 窗口补算不能漏记或重复")

        let appendedTime = Int64(now.addingTimeInterval(-20).timeIntervalSince1970 * 1_000)
        try env.append(usage(time: appendedTime, input: 50, model: "kimi-code/k3"), to: wire)
        await first.scanNow()
        XCTAssertEqual(first.cycleAggregator.snapshot().reduce(0) { $0 + $1.inputTokens }, 700)
        XCTAssertEqual(first.cycleAggregator.snapshot().reduce(0) { $0 + $1.requestCount }, 6)
        expected = UsageHistoryConsistency.cycleVector(first.cycleAggregator.snapshot())
        await first.rebuildCycleUsageForRecentChanges(reasons: ["fixture appended Kimi request"])
        XCTAssertEqual(UsageHistoryConsistency.cycleVector(first.cycleAggregator.snapshot()), expected,
                       "追加后的完整会话贡献必须替换，不能与旧贡献叠加")

        let restarted = service()
        await env.bootstrap(restarted)
        await restarted.scanNow()
        XCTAssertEqual(UsageHistoryConsistency.cycleVector(restarted.cycleAggregator.snapshot()), expected)
        try FileManager.default.removeItem(at: session)
        await restarted.rebuildCycleUsageForRecentChanges(reasons: ["fixture deleted Kimi source"])
        XCTAssertEqual(UsageHistoryConsistency.cycleVector(restarted.cycleAggregator.snapshot()), expected)
        await restarted.forceRescan()
        XCTAssertEqual(UsageHistoryConsistency.cycleVector(restarted.cycleAggregator.snapshot()), expected,
                       "删除日志后的 Kimi 周期历史必须保留")
        XCTAssertEqual(tokens(restarted), 6_560)
    }

    func testMoonshotCatalogExcludesSubscriptionZeroPricesAndRegionalConversion() throws {
        let fixture: [String: Any] = [
            "moonshotai": ["models": ["kimi-fixture": ["cost": ["input": 2, "output": 10, "cache_read": 0.2]]]],
            "moonshotai-cn": ["models": ["kimi-fixture": ["cost": ["input": 99, "output": 99]]]],
            "kimi-code-plan-global": ["models": ["kimi-for-coding": ["cost": ["input": 0, "output": 0]]]],
        ]
        let result = try ModelsDevPricingDecoder.decode(JSONSerialization.data(withJSONObject: fixture))
        XCTAssertEqual(result.standard["kimi-fixture"]?.input, 2)
        XCTAssertNil(result.standard["kimi-for-coding"])
        XCTAssertTrue(result.codexFast.isEmpty)
        XCTAssertTrue(result.claudeFast.isEmpty)
    }

    func testKimiRoutingKeepsUnverifiedAliasesUnpriced() {
        XCTAssertEqual(Pricing.pricingKey(model: "moonshotai/kimi-k3"), "kimi-k3")
        XCTAssertEqual(Pricing.pricingKey(model: "kimi-code/kimi-for-coding"), "kimi-for-coding")
        XCTAssertNil(Pricing.costBreakdown(app: .kimi, model: "kimi-code/kimi-for-coding", speed: .standard,
                                          input: 100, output: 20, cacheRead: 30, cacheCreation: 0, at: Date()))
        XCTAssertNil(CycleUsageAggregator.cycleApp(app: .kimi, model: "openai-codex/gpt-5"))
        XCTAssertEqual(CycleUsageAggregator.cycleApp(app: .kimi, model: "kimi-code/k3"), .kimi)
        XCTAssertNil(CycleUsageAggregator.cycleApp(app: .kimi, model: "deepseek/deepseek-v4-pro"))
        XCTAssertNil(CycleUsageAggregator.cycleApp(app: .kimi, model: "custom/kimi-code/k3"))
        XCTAssertNil(CycleUsageAggregator.cycleApp(app: .kimi, model: "kimi-code/deepseek-v4-pro"))
        XCTAssertNil(CycleUsageAggregator.cycleApp(app: .kimi, model: "kimi-code/custom-model"))
        XCTAssertFalse(CycleUsageAggregator.isSubscriptionUsage(app: .kimi, model: "kimi-code/deepseek-v4-pro"))
        XCTAssertNil(CycleUsageAggregator.cycleApp(app: .kimi, model: "unknown"))
        XCTAssertEqual(ModelProvider.resolve(app: .kimi, model: "kimi-code/k3"), .moonshot)
        XCTAssertEqual(ModelProvider.resolve(app: .kimi, model: "deepseek/deepseek-v4-pro"), .deepseek)
        XCTAssertTrue(KimiModelPresentation.isForCodingRoute(
            model: "kimi-code/kimi-for-coding", apps: [.kimi]
        ))
        XCTAssertTrue(KimiModelPresentation.isForCodingRoute(model: "kimi-for-coding", apps: [.kimi]))
        XCTAssertFalse(KimiModelPresentation.isForCodingRoute(model: "kimi-code/k3", apps: [.kimi]))
        XCTAssertFalse(KimiModelPresentation.isForCodingRoute(
            model: "kimi-code/kimi-for-coding", apps: [.codex]
        ), "当前 K2.8 Preview 只是 Kimi 滚动路由的展示说明，不扩大到其他服务")
    }

    func testFullyUnpricedKimiModelUsesDashAndExplanationOnlyForKimiRows() {
        var totals = UsageTotals.zero
        totals.inputTokens = 100
        totals.hasUnpricedUsage = true
        XCTAssertEqual(KimiModelPresentation.cost(totals, apps: [.kimi], enabled: true), "—")
        let help = KimiModelPresentation.missingPriceHelp(totals, apps: [.kimi], enabled: true)
        XCTAssertTrue(help.contains("public reference price") || help.contains("公开参考价格"))
        XCTAssertEqual(KimiModelPresentation.cost(totals, apps: [.kimi], enabled: false), "$0.00")
        XCTAssertEqual(KimiModelPresentation.cost(totals, apps: [.codex], enabled: true), "$0.00")
        XCTAssertEqual(KimiModelPresentation.cost(totals, apps: [.kimi, .codex], enabled: true), "$0.00")
        XCTAssertEqual(KimiModelPresentation.missingPriceHelp(totals, apps: [.codex], enabled: true), "")
        totals.costUSD = Decimal(string: "1.25")!
        XCTAssertEqual(KimiModelPresentation.cost(totals, apps: [.kimi], enabled: true), "$1.25",
                       "只有完全无已知金额的 Kimi 模型行使用缺价占位")
    }

    func testOldScanStateAndInjectedRootsStayCompatible() throws {
        let data = try JSONEncoder().encode(ScanState())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "kimi")
        let restored = try JSONDecoder().decode(ScanState.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(restored.kimi)
        let env = try UsageTestEnvironment(name: "kimi-default-roots")
        XCTAssertTrue(env.scanRoots.kimiRoots.isEmpty)
        XCTAssertTrue(UsageApp.localApps.contains(.kimi))
        XCTAssertFalse(ServiceOrderItem.usageOnlyApps.contains(.kimi))
        XCTAssertEqual(ServiceOrderItem(rawValue: "kimi"), .quota(.kimi))
        XCTAssertEqual(StatsServiceFilter.kimi.usageApp, .kimi)
    }

    func testWatcherIncludesKimiLogsAndLegacyProjectMetadata() throws {
        let env = try UsageTestEnvironment(name: "kimi-watcher")
        let share = env.root.appendingPathComponent("kimi", isDirectory: true)
        var roots = env.scanRoots
        roots.kimiRoots = [share]
        let matcher = UsageLogPathMatcher.standard(roots: roots)
        XCTAssertTrue(matcher.matches(share.appendingPathComponent("sessions/work/session/agents/main/wire.jsonl").path))
        XCTAssertTrue(matcher.matches(share.appendingPathComponent("kimi.json").path))
        XCTAssertFalse(matcher.matches(share.appendingPathComponent("credentials/token.json").path))
        XCTAssertFalse(matcher.matches(share.appendingPathComponent("logs/kimi.log").path))
    }

    func testRebuildRetainsDeletedSourceOwnershipWhenForkReplaysItsUsage() async throws {
        let env = try UsageTestEnvironment(name: "kimi-fork-rebuild")
        let share = env.root.appendingPathComponent("kimi-code")
        let source = share.appendingPathComponent("sessions/work/session_a")
        let firstWire = source.appendingPathComponent("agents/main/wire.jsonl")
        let inherited = usage(time: 1_792_000_000_000, input: 100)
        try env.append(inherited, to: firstWire)
        var roots = env.scanRoots
        roots.kimiRoots = [share]
        let service = UsageService(historyStore: env.store, roots: roots, legacyLocations: env.legacyLocations,
                                   backfillURL: env.backfillURL, cursorCacheDirectory: env.cursorCacheDirectory)
        await env.bootstrap(service)
        await service.scanNow()
        XCTAssertEqual(tokens(service), 135)

        let fork = share.appendingPathComponent("sessions/work/session_b/agents/main/wire.jsonl")
        try env.append(inherited, to: fork)
        try env.append(usage(time: 1_792_000_001_000, input: 200), to: fork)
        try FileManager.default.removeItem(at: source)
        await service.forceRescan()
        XCTAssertEqual(tokens(service), 370, "保留的原会话和 fork 重放不能同时计入同一请求")
        await service.forceRescan()
        XCTAssertEqual(tokens(service), 370)
    }

    func testLegacyIndependentSubagentAndMirroredEventAreCountedOnce() throws {
        let env = try UsageTestEnvironment(name: "kimi-legacy-agent")
        let share = env.root.appendingPathComponent("kimi")
        let session = share.appendingPathComponent("sessions/hash/session_a")
        let main = session.appendingPathComponent("wire.jsonl")
        let nested = #"{"timestamp":1792000001,"message":{"type":"SubagentEvent","payload":{"agent_id":"child","event":{"type":"StatusUpdate","payload":{"message_id":"child-result","token_usage":{"input_other":200,"output":10}}}}}}"#
        let child = #"{"timestamp":1792000000,"message":{"type":"StatusUpdate","payload":{"message_id":"child-result","token_usage":{"input_other":200,"output":10}}}}"#
        try env.append(nested, to: main)
        try env.append(child, to: session.appendingPathComponent("subagents/child/wire.jsonl"))
        let result = KimiSessionScanner.scan(previous: nil, roots: [share])
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.entries.count, 1)
        XCTAssertEqual(result.entries.first?.inputTokens, 200)
        XCTAssertTrue(result.conversationSeeds.first?.includesSubtasks == true)

        // 后台代理没有镜像时，独立文件仍是来源。
        try Data("{\"type\":\"metadata\"}\n".utf8).write(to: main)
        let independent = KimiSessionScanner.scan(previous: result.newState, roots: [share])
        XCTAssertEqual(independent.entries.count, 1)
        XCTAssertEqual(independent.entries.first?.inputTokens, 200)
    }

    func testEmptyReplacementAndCorruptCompleteLineDoNotSilentlyKeepOrEraseUsage() throws {
        let env = try UsageTestEnvironment(name: "kimi-empty-replacement")
        let share = env.root.appendingPathComponent("kimi-code")
        let wire = share.appendingPathComponent("sessions/work/session_a/agents/main/wire.jsonl")
        try env.append(usage(time: 1_792_000_000_000, input: 100), to: wire)
        let baseline = KimiSessionScanner.scan(previous: nil, roots: [share])
        try Data("broken-json\n".utf8).write(to: wire)
        let corrupt = KimiSessionScanner.scan(previous: baseline.newState, roots: [share])
        XCTAssertFalse(corrupt.isComplete)
        XCTAssertTrue(corrupt.refreshedConversationIDs.isEmpty)
        XCTAssertEqual(corrupt.newState, baseline.newState)
        try Data().write(to: wire)
        let empty = KimiSessionScanner.scan(previous: baseline.newState, roots: [share])
        XCTAssertTrue(empty.isComplete)
        XCTAssertTrue(empty.entries.isEmpty)
        XCTAssertEqual(empty.refreshedConversationIDs, ["session_a"])
    }

    func testHistoricalRequestModelResolvesCustomAlias() throws {
        let env = try UsageTestEnvironment(name: "kimi-custom-model")
        let share = env.root.appendingPathComponent("kimi-code")
        let wire = share.appendingPathComponent("sessions/work/session_a/agents/main/wire.jsonl")
        try env.append(#"{"type":"llm.request","model":"deepseek-v4-pro","modelAlias":"custom/my-model","time":1792000000000}"#, to: wire)
        try env.append(#"{"type":"usage.record","model":"custom/my-model","usage":{"inputOther":100,"output":10},"time":1792000001000}"#, to: wire)
        let result = KimiSessionScanner.scan(previous: nil, roots: [share])
        XCTAssertEqual(result.entries.first?.model, "deepseek-v4-pro")
        XCTAssertNotNil(result.entries.first?.costUSD)
    }

    func testFirstScanAssignsInheritedUsageToOriginalBeforeLexicallyEarlierFork() throws {
        let env = try UsageTestEnvironment(name: "kimi-first-fork")
        let share = env.root.appendingPathComponent("kimi-code")
        for (id, createdAt) in [("session_z_original", 1_000), ("session_a_fork", 2_000)] {
            let directory = share.appendingPathComponent("sessions/work/\(id)")
            try env.append(usage(time: 1_792_000_000_000, input: 100),
                           to: directory.appendingPathComponent("agents/main/wire.jsonl"))
            try JSONSerialization.data(withJSONObject: ["createdAt": createdAt])
                .write(to: directory.appendingPathComponent("state.json"))
        }
        let result = KimiSessionScanner.scan(previous: nil, roots: [share])
        XCTAssertEqual(result.entries.count, 1)
        XCTAssertEqual(result.entries.first?.conversationKey, "kimi:session_z_original")
    }

    func testDeletedSubagentContributionSurvivesMainAppendRestartAndRebuild() throws {
        let env = try UsageTestEnvironment(name: "kimi-deleted-child")
        let share = env.root.appendingPathComponent("kimi-code")
        let session = share.appendingPathComponent("sessions/work/session_a")
        let main = session.appendingPathComponent("agents/main/wire.jsonl")
        let child = session.appendingPathComponent("agents/child/wire.jsonl")
        try env.append(usage(time: 1_792_000_000_000, input: 100), to: main)
        try env.append(usage(time: 1_792_000_001_000, input: 200), to: child)
        let first = KimiSessionScanner.scan(previous: nil, roots: [share])
        XCTAssertEqual(first.entries.count, 2)
        try FileManager.default.removeItem(at: child.deletingLastPathComponent())
        let unchanged = KimiSessionScanner.scan(previous: first.newState, roots: [share])
        XCTAssertTrue(unchanged.entries.isEmpty)
        try env.append(usage(time: 1_792_000_002_000, input: 300), to: main)
        let appended = KimiSessionScanner.scan(previous: unchanged.newState, roots: [share])
        XCTAssertEqual(appended.entries.count, 3)
        XCTAssertEqual(appended.entries.reduce(0) { $0 + $1.inputTokens }, 600)
        XCTAssertTrue(appended.conversationSeeds.first?.includesSubtasks == true)
        let encoded = try JSONEncoder().encode(XCTUnwrap(appended.newState))
        let restarted = try JSONDecoder().decode(KimiSessionScanner.State.self, from: encoded)
        let rebuilt = KimiSessionScanner.scan(previous: restarted, roots: [share], force: true)
        XCTAssertEqual(rebuilt.entries.count, 3)
        XCTAssertEqual(rebuilt.entries.reduce(0) { $0 + $1.inputTokens }, 600)
    }

    func testMetadataOnlyChangesRefreshConversationTitle() throws {
        let env = try UsageTestEnvironment(name: "kimi-title-update")
        let share = env.root.appendingPathComponent("kimi-code")
        let session = share.appendingPathComponent("sessions/work/session_a")
        try env.append(usage(time: 1_792_000_000_000, input: 100),
                       to: session.appendingPathComponent("agents/main/wire.jsonl"))
        let metadata = session.appendingPathComponent("state.json")
        try JSONSerialization.data(withJSONObject: ["title": "Before"]).write(to: metadata)
        let first = KimiSessionScanner.scan(previous: nil, roots: [share])
        XCTAssertEqual(first.conversationSeeds.first?.title, "Before")
        try JSONSerialization.data(withJSONObject: ["title": "After renaming"]).write(to: metadata)
        let renamed = KimiSessionScanner.scan(previous: first.newState, roots: [share])
        XCTAssertEqual(renamed.conversationSeeds.first?.title, "After renaming")
        XCTAssertEqual(renamed.entries.count, 1)
    }

    private func tokens(_ service: UsageService) -> Int {
        service.aggregator.snapshotLocal().filter { $0.app == .kimi }.reduce(0) { $0 + $1.inputTokens + $1.outputTokens + $1.cacheReadTokens + $1.cacheCreationTokens }
    }

    private func usage(time: Int64, input: Int, model: String = "kimi-code/kimi-for-coding") -> String {
        "{\"type\":\"usage.record\",\"agentId\":\"main\",\"model\":\"\(model)\",\"usage\":{\"inputOther\":\(input),\"output\":10,\"inputCacheRead\":20,\"inputCacheCreation\":5},\"usageScope\":\"turn\",\"time\":\(time)}"
    }
}
