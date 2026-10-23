import XCTest
import SQLite3
@testable import CCBar

/// 旧文件迁移、快照恢复与受限恢复的端到端测试（执行计划 A01 / A02 / A04 / A05 / A06 /
/// A08 / A09 / A17 / A18 / A24）。
///
/// 每个用例都在临时目录里跑真实 `UsageService`，日志全部是脱敏合成 fixture。
@MainActor
final class UsageHistoryRecoveryTests: XCTestCase {
    private var environment: UsageTestEnvironment!

    override func setUpWithError() throws {
        environment = try UsageTestEnvironment(name: "usage-history-recovery")
    }

    override func tearDownWithError() throws {
        environment = nil
    }

    // MARK: - 共用辅助

    /// 写一条 Claude 日志 + 一条 DSH 会话日志，跑一轮真实扫描，返回完成的 service。
    @discardableResult
    private func seedAndScan(
        _ env: UsageTestEnvironment,
        claudeSession: String = "session-a",
        claudeModel: String = "ccbar-recovery-model",
        input: Int = 1_000,
        dshSession: String = "dsh-session-a",
        dshInput: Int = 500
    ) async throws -> UsageService {
        try env.writeClaudeLog(
            session: claudeSession,
            lines: [
                env.claudeLine(
                    id: "\(claudeSession)-msg-1",
                    session: claudeSession,
                    model: claudeModel,
                    timestamp: "2026-09-20T01:00:00Z",
                    input: input,
                    output: 10
                )
            ]
        )
        try env.writeDshLog(
            project: "project-a",
            session: dshSession,
            records: [
                DshTestFixtures.session(id: dshSession),
                DshTestFixtures.assistant(time: DshTestFixtures.baseTime + 1_000, input: dshInput, output: 20),
            ]
        )
        let service = env.makeService()
        await env.bootstrap(service)
        await service.scanNow()
        return service
    }

    private func snapshot(of service: UsageService) -> UsageServiceSnapshot {
        UsageServiceSnapshot(
            day: service.aggregator.snapshotLocal(),
            conversation: service.conversationAggregator.snapshot(),
            cycle: service.cycleAggregator.snapshot()
        )
    }

    private struct UsageServiceSnapshot {
        var day: [UsageBucket]
        var conversation: (infos: [ConversationInfo], buckets: [ConversationUsageBucket])
        var cycle: [CycleUsageBucket]
    }

    /// 把一份已提交快照写成旧格式文件（模拟升级前的磁盘状态）。
    private func writeLegacy(
        _ env: UsageTestEnvironment,
        from snapshot: UsageSnapshot,
        includeScanState: Bool = true,
        includeConversation: Bool = true,
        includeCycle: Bool = true,
        includeDsh: Bool = true
    ) throws {
        try UsageRollupCache.save(snapshot.usageRollup, in: env.supportDirectory)
        if includeConversation {
            try ConversationRollupCache.save(snapshot.conversationRollup, in: env.supportDirectory)
        }
        if includeCycle {
            try CycleUsageRollupCache.save(snapshot.cycleRollup, in: env.supportDirectory)
        }
        if includeDsh {
            try DshContributionCache.save(
                snapshot.dshContributions.contributions,
                generationID: snapshot.snapshotID,
                pricingFingerprint: snapshot.usageRollup.pricingFingerprint,
                requiresRebuild: snapshot.dshContributions.requiresRebuild ?? false,
                in: env.supportDirectory
            )
        }
        if includeScanState {
            try ScanCache.save(snapshot.scanState, in: env.cacheDirectory)
        }
    }

    private struct MissingSnapshot: Error {}

    private func committedSnapshot(_ env: UsageTestEnvironment) throws -> UsageSnapshot {
        switch env.store.loadCurrent() {
        case .valid(let snapshot):
            return snapshot
        case .missing:
            XCTFail("store has no current snapshot")
            throw MissingSnapshot()
        case .invalid(let reason):
            XCTFail("current snapshot invalid: \(reason)")
            throw MissingSnapshot()
        }
    }

    // MARK: - A01 当前版本旧文件同代导入

    func testLegacyImportReproducesEveryProjectionAndDoesNotRescan() async throws {
        let source = try UsageTestEnvironment(name: "usage-history-migration-source")
        let originalService = try await seedAndScan(source)
        let original = try committedSnapshot(source)
        XCTAssertFalse(original.usageRollup.buckets.isEmpty)
        XCTAssertFalse(original.dshContributions.contributions.isEmpty)

        let target = try UsageTestEnvironment(name: "usage-history-migration-target")
        try writeLegacy(target, from: original)

        let service = target.makeService()
        await target.bootstrap(service)

        // 不重扫：进度与汇总都来自旧文件，日用量向量必须逐键一致。
        XCTAssertEqual(service.historyRecoveryState, .complete)
        XCTAssertEqual(
            target.dayVector(service.aggregator.snapshotLocal()),
            target.dayVector(original.usageRollup.buckets),
            "日桶完整键集合与分项用量必须与旧数据一致"
        )
        XCTAssertEqual(
            target.dayCost(service.aggregator.snapshotLocal()),
            target.dayCost(original.usageRollup.buckets),
            "Decimal 费用必须逐分一致"
        )

        let conversation = service.conversationAggregator.snapshot()
        XCTAssertEqual(Set(conversation.infos.map(\.key)), Set(original.conversationRollup.infos.map(\.key)))
        XCTAssertEqual(
            target.conversationVector(conversation.buckets),
            target.conversationVector(original.conversationRollup.buckets)
        )

        XCTAssertEqual(Set(service.cycleAggregator.snapshot().map(\.cycleID)), Set(original.cycleRollup.buckets.map(\.cycleID)))
        XCTAssertEqual(service.dshTrackedSessionCount, original.dshContributions.contributions.count)

        let migrated = try committedSnapshot(target)
        XCTAssertEqual(migrated.scanState, original.scanState, "进度必须原样导入")
        XCTAssertEqual(migrated.snapshotID, original.snapshotID)

        // 同一批日志再扫一轮：进度未丢，不应该重复累计。
        await service.scanNow()
        XCTAssertEqual(
            target.dayVector(service.aggregator.snapshotLocal()),
            target.dayVector(original.usageRollup.buckets),
            "迁移后重复扫描不得重复累计"
        )
    }

    // MARK: - A02 重复迁移幂等、旧文件字节不变

    func testSecondLaunchUsesMigratedSnapshotAndKeepsLegacyBytes() async throws {
        let source = try UsageTestEnvironment(name: "usage-history-idempotent-source")
        let originalService = try await seedAndScan(source)
        _ = originalService
        let original = try committedSnapshot(source)

        let target = try UsageTestEnvironment(name: "usage-history-idempotent-target")
        try writeLegacy(target, from: original)
        let legacyBytes = try XCTUnwrap(target.fileBytes(target.legacyPath("usage-rollup.json")))
        let cacheBytes = try XCTUnwrap(target.fileBytes(target.cachePath("scan-state.json")))

        let first = target.makeService()
        await target.bootstrap(first)
        let firstSnapshot = try committedSnapshot(target)
        XCTAssertEqual(firstSnapshot.snapshotID, original.snapshotID)
        XCTAssertEqual(
            target.dayVector(first.aggregator.snapshotLocal()),
            target.dayVector(original.usageRollup.buckets)
        )

        // 第二次启动：新快照生效，不再回读旧文件，也不重复累计。
        let second = target.makeService()
        await target.bootstrap(second)
        XCTAssertEqual(second.historyRecoveryState, .complete)
        XCTAssertEqual(
            target.dayVector(second.aggregator.snapshotLocal()),
            target.dayVector(original.usageRollup.buckets)
        )
        XCTAssertEqual(try target.fileBytes(target.legacyPath("usage-rollup.json")), legacyBytes)
        XCTAssertEqual(try target.fileBytes(target.cachePath("scan-state.json")), cacheBytes)
    }

    // MARK: - A04 迁移后清掉旧 Caches 目录仍有效

    func testMigratedSnapshotSurvivesLegacyCacheRemoval() async throws {
        let source = try UsageTestEnvironment(name: "usage-history-cache-removal-source")
        _ = try await seedAndScan(source)
        let original = try committedSnapshot(source)

        let target = try UsageTestEnvironment(name: "usage-history-cache-removal-target")
        try writeLegacy(target, from: original)
        let service = target.makeService()
        await target.bootstrap(service)

        // 旧 Caches 目录整棵删掉，再重启。
        try FileManager.default.removeItem(at: target.cacheDirectory)
        try FileManager.default.createDirectory(at: target.cacheDirectory, withIntermediateDirectories: true)

        let restarted = target.makeService()
        await target.bootstrap(restarted)
        await restarted.scanNow()
        XCTAssertEqual(
            target.dayVector(restarted.aggregator.snapshotLocal()),
            target.dayVector(original.usageRollup.buckets),
            "旧 Caches 清理不得让新快照失效或触发全量重建丢历史"
        )
        XCTAssertEqual(restarted.historyRecoveryState, .complete)
    }

    // MARK: - A03 迁移提交失败：旧文件不动、重试只提交一次

    func testMigrationCommitFaultKeepsLegacyFilesAndRetriesCleanly() async throws {
        let source = try UsageTestEnvironment(name: "usage-history-migration-fault-source")
        _ = try await seedAndScan(source)
        let original = try committedSnapshot(source)

        let target = try UsageTestEnvironment(name: "usage-history-migration-fault-target")
        try writeLegacy(target, from: original)
        let legacyBytes = try XCTUnwrap(target.fileBytes(target.legacyPath("usage-rollup.json")))
        let scanStateBytes = try XCTUnwrap(target.fileBytes(target.cachePath("scan-state.json")))

        target.faults.fail(at: .beforeEncode)
        let first = target.makeService()
        await target.bootstrap(first)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: target.store.currentFileURL.path),
            "提交失败不得留下半成品快照"
        )
        XCTAssertEqual(try target.fileBytes(target.legacyPath("usage-rollup.json")), legacyBytes)
        XCTAssertEqual(try target.fileBytes(target.cachePath("scan-state.json")), scanStateBytes)

        // 同进程下一轮必须重试迁移保存，不能等 15 分钟或等用量变化。
        XCTAssertNotNil(first.lastError)
        target.faults.clear()
        await first.scanNow()
        XCTAssertEqual(target.stats.commitCount, 1)
        XCTAssertEqual(target.dayVector(first.aggregator.snapshotLocal()), target.dayVector(original.usageRollup.buckets))
        // 重启后使用成功提交，不重复迁移。
        let second = target.makeService()
        await target.bootstrap(second)
        XCTAssertEqual(target.stats.commitCount, 1, "迁移重试只能提交一次")
        XCTAssertEqual(
            target.dayVector(second.aggregator.snapshotLocal()),
            target.dayVector(original.usageRollup.buckets)
        )
        XCTAssertEqual(try target.fileBytes(target.legacyPath("usage-rollup.json")), legacyBytes, "旧文件始终只读")

        // 第三次启动走新快照，不再回读旧文件。
        let third = target.makeService()
        await target.bootstrap(third)
        XCTAssertEqual(target.stats.commitCount, 1)
        XCTAssertEqual(
            target.dayVector(third.aggregator.snapshotLocal()),
            target.dayVector(original.usageRollup.buckets)
        )
    }

    // MARK: - A05 回退上一份后继续增量只计一次

    func testCorruptCurrentFallsBackToPreviousThenCountsNewEntriesOnce() async throws {
        let env = environment!
        let service = try await seedAndScan(env)
        let first = try committedSnapshot(env)

        // 第二批数据形成新的 current，并使第一份成为 previous。
        try env.writeClaudeLog(
            session: "session-b",
            lines: [
                env.claudeLine(
                    id: "session-b-msg-1",
                    session: "session-b",
                    model: "ccbar-recovery-model",
                    timestamp: "2026-09-20T02:00:00Z",
                    input: 2_000,
                    output: 20
                )
            ]
        )
        await service.scanNow()
        // 常规扫描按 15 分钟节流只更新内存；显式 flush 等价于节流窗口到期后的那次落盘。
        await service.flushPendingRollupChangesForTesting()
        let second = try committedSnapshot(env)
        XCTAssertNotEqual(first.snapshotID, second.snapshotID)

        // current 截断，模拟写盘中断；重启必须整份回退到 previous。
        let currentData = try XCTUnwrap(env.fileBytes(env.store.currentFileURL))
        try currentData.prefix(currentData.count / 3).write(to: env.store.currentFileURL)

        let restarted = env.makeService()
        await env.bootstrap(restarted)
        XCTAssertEqual(restarted.historyRecoveryState, .complete)
        XCTAssertEqual(
            env.dayVector(restarted.aggregator.snapshotLocal()),
            env.dayVector(first.usageRollup.buckets),
            "回退后只能看到上一份完整提交，不能混合两代"
        )
        // 回退必须能被展示层识别，并带上「只能保证到这个时点」的边界。
        guard case .previous(_, let committedAt) = restarted.historyLoadSource else {
            return XCTFail("回退后必须记录来源与恢复时点")
        }
        XCTAssertEqual(committedAt, first.committedAt)
        let notice = try XCTUnwrap(restarted.historyRecoveryNotice)
        XCTAssertEqual(notice.restoredFromPreviousAt, first.committedAt)
        XCTAssertFalse(notice.isReadOnly)

        // 回退后新增一条：只增加一次，正常刷新继续可用。
        try env.append(
            env.claudeLine(
                id: "session-a-msg-2",
                session: "session-a",
                model: "ccbar-recovery-model",
                timestamp: "2026-09-20T03:00:00Z",
                input: 100,
                output: 1
            ) + "\n",
            to: env.claudeRoot.appendingPathComponent("fixture-project/session-a.jsonl")
        )
        await restarted.scanNow()
        // 回退把 session-b 一并退回未落盘状态：它必须被重新扫到且只算一次，
        // 而不是「旧总量 + 新一轮全量」地叠加。
        let baseline = env.totals(first.usageRollup.buckets, app: .claude)
        let after = env.totals(restarted.aggregator.snapshotLocal(), app: .claude)
        XCTAssertEqual(after.inputTokens, baseline.inputTokens + 2_000 + 100)
        XCTAssertEqual(after.requestCount, baseline.requestCount + 2)

        // 再扫一轮没有新日志：不再增加。
        await restarted.scanNow()
        let stable = env.totals(restarted.aggregator.snapshotLocal(), app: .claude)
        XCTAssertEqual(stable.inputTokens, after.inputTokens)
        XCTAssertEqual(stable.requestCount, after.requestCount)
    }

    // MARK: - A06 两份都坏 / 版本不支持

    func testBothSnapshotsCorruptKeepsEvidenceAndReportsAccurately() async throws {
        let env = environment!
        let service = try await seedAndScan(env)
        _ = service
        try FileManager.default.createDirectory(at: env.historyDirectory, withIntermediateDirectories: true)
        let corruptCurrent = Data("corrupt-current".utf8)
        let corruptPrevious = Data("corrupt-previous".utf8)
        try corruptCurrent.write(to: env.store.currentFileURL)
        try corruptPrevious.write(to: env.store.previousFileURL)

        let restarted = env.makeService()
        await env.bootstrap(restarted)
        await restarted.scanNow()

        XCTAssertEqual(try env.fileBytes(env.store.currentFileURL), corruptCurrent)
        XCTAssertEqual(try env.fileBytes(env.store.previousFileURL), corruptPrevious)
        XCTAssertEqual(restarted.historyRecoveryState, .unavailable)
        XCTAssertTrue(restarted.historyRecoveryNotice?.isUnavailable == true)
        XCTAssertTrue(restarted.historyRecoveryNotice?.isReadOnly == true)
        XCTAssertNotNil(restarted.lastError)
        XCTAssertTrue(restarted.aggregator.snapshotLocal().isEmpty)
        await restarted.forceRescan()
        await restarted.rebuildCycleUsageIfNeeded()
        XCTAssertEqual(try env.fileBytes(env.store.currentFileURL), corruptCurrent)
        XCTAssertEqual(try env.fileBytes(env.store.previousFileURL), corruptPrevious)
    }

    func testEstablishedHistoryNeverReimportsStaleLegacyAfterSnapshotLoss() async throws {
        let env = environment!
        _ = try await seedAndScan(env)
        let original = try committedSnapshot(env)
        try writeLegacy(env, from: original)
        let legacy = try XCTUnwrap(env.fileBytes(env.legacyPath("usage-rollup.json")))
        // 新快照损坏时即使有可解析的旧缓存，也必须停止，不能重新迁移。
        try Data("broken".utf8).write(to: env.store.currentFileURL)
        let broken = env.makeService()
        await env.bootstrap(broken)
        XCTAssertEqual(broken.historyRecoveryState, .unavailable)
        XCTAssertTrue(broken.aggregator.snapshotLocal().isEmpty)
        // 两份快照都删除后，独立标记仍阻止退回旧格式。
        try FileManager.default.removeItem(at: env.store.currentFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: env.store.establishedFileURL.path))
        let missing = env.makeService()
        await env.bootstrap(missing)
        await missing.scanNow()
        await missing.forceRescan()
        XCTAssertEqual(missing.historyRecoveryState, .unavailable)
        XCTAssertTrue(missing.aggregator.snapshotLocal().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.store.currentFileURL.path))
        XCTAssertEqual(env.fileBytes(env.legacyPath("usage-rollup.json")), legacy)
    }

    func testUnsupportedInnerVersionsPreserveBothSnapshotsAndNeverMigrate() async throws {
        let source = environment!
        _ = try await seedAndScan(source)
        let original = try committedSnapshot(source)
        for field in ["scanState", "usageRollup", "conversationRollup", "cycleRollup", "dshContributions"] {
            let target = try UsageTestEnvironment(name: "unsupported-inner")
            try writeLegacy(target, from: original)
            try FileManager.default.createDirectory(at: target.historyDirectory, withIntermediateDirectories: true)
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
            // 故意省略其他字段：版本探测必须先于完整解码。
            json[field] = ["version": 999]
            let data = try JSONSerialization.data(withJSONObject: json)
            try data.write(to: target.store.currentFileURL)
            try data.write(to: target.store.previousFileURL)
            let service = target.makeService()
            await target.bootstrap(service)
            await service.scanNow()
            await service.forceRescan()
            XCTAssertTrue(service.historyRecoveryNotice?.isReadOnly == true, field)
            XCTAssertTrue(service.aggregator.snapshotLocal().isEmpty, field)
            XCTAssertEqual(target.fileBytes(target.store.currentFileURL), data)
            XCTAssertEqual(target.fileBytes(target.store.previousFileURL), data)
        }
    }

    func testUnsupportedCurrentDisplaysPreviousReadOnlyWithRecoveryTime() async throws {
        let env = environment!
        _ = try await seedAndScan(env)
        let previous = try committedSnapshot(env)
        let previousBytes = try XCTUnwrap(env.fileBytes(env.store.currentFileURL))
        try previousBytes.write(to: env.store.previousFileURL)
        let future = Data("{\"version\":999}".utf8)
        try future.write(to: env.store.currentFileURL)
        let service = env.makeService()
        await env.bootstrap(service)
        await service.scanNow()
        await service.forceRescan()
        XCTAssertEqual(service.historyRecoveryNotice?.restoredFromPreviousAt, previous.committedAt)
        XCTAssertTrue(service.historyRecoveryNotice?.isReadOnly == true)
        XCTAssertEqual(env.dayVector(service.aggregator.snapshotLocal()), env.dayVector(previous.usageRollup.buckets))
        XCTAssertEqual(env.fileBytes(env.store.currentFileURL), future)
        XCTAssertEqual(env.fileBytes(env.store.previousFileURL), previousBytes)
    }

    func testUnusableLegacyIsNotFirstInstall() async throws {
        let env = environment!
        let bytes = Data("{\"version\":999}".utf8)
        try bytes.write(to: env.legacyPath("usage-rollup.json"))
        let service = env.makeService()
        await env.bootstrap(service)
        await service.scanNow()
        XCTAssertEqual(service.historyRecoveryState, .unavailable)
        XCTAssertNotNil(service.lastError)
        XCTAssertEqual(env.fileBytes(env.legacyPath("usage-rollup.json")), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.store.currentFileURL.path))
    }

    /// 升级前的版本遇到旧版本、损坏或缺失的主日缓存会丢弃并全量重扫；迁移沿用该行为，不能停止采集。
    func testStaleLegacyDayRollupFallsBackToFullRescan() async throws {
        let source = environment!
        _ = try await seedAndScan(source)
        let original = try committedSnapshot(source)
        for mode in ["oldVersion", "corrupt", "missing"] {
            let target = try UsageTestEnvironment(name: "stale-legacy-\(mode)")
            try target.copySources(from: source)
            try writeLegacy(target, from: original)
            let url = target.legacyPath("usage-rollup.json")
            switch mode {
            case "oldVersion":
                var stale = original.usageRollup
                stale.version = UsageRollupPayload.currentVersion - 1
                try UsageRollupCache.save(stale, in: target.supportDirectory)
            case "corrupt":
                try Data("broken".utf8).write(to: url)
            default:
                try FileManager.default.removeItem(at: url)
            }
            let legacyBytes = target.fileBytes(url)
            let scanStateBytes = target.fileBytes(target.cachePath("scan-state.json"))

            let service = target.makeService()
            await target.bootstrap(service)
            await service.scanNow()
            XCTAssertEqual(service.historyRecoveryState, .complete, mode)
            XCTAssertNil(service.historyRecoveryNotice, mode)
            XCTAssertNil(service.lastError, mode)
            XCTAssertEqual(target.dayVector(service.aggregator.snapshotLocal()), target.dayVector(original.usageRollup.buckets), mode)
            XCTAssertTrue(FileManager.default.fileExists(atPath: target.store.currentFileURL.path), mode)
            XCTAssertEqual(target.fileBytes(url), legacyBytes, mode)
            XCTAssertEqual(target.fileBytes(target.cachePath("scan-state.json")), scanStateBytes, mode)

            // 重启读新快照，不再回读旧文件，也不重复累计。
            let restarted = target.makeService()
            await target.bootstrap(restarted)
            await restarted.scanNow()
            XCTAssertEqual(restarted.historyRecoveryState, .complete, mode)
            XCTAssertEqual(target.dayVector(restarted.aggregator.snapshotLocal()), target.dayVector(original.usageRollup.buckets), mode)
        }
    }

    func testInvalidConversationMigrationPausesUntilVerifiedAndSurvivesRestart() async throws {
        let source = environment!
        _ = try await seedAndScan(source)
        let original = try committedSnapshot(source)
        for mode in ["missing", "corrupt", "generation"] {
            let target = try UsageTestEnvironment(name: "conversation-\(mode)")
            try target.copySources(from: source)
            try writeLegacy(target, from: original, includeConversation: false)
            let url = target.legacyPath("conversation-rollup.json")
            if mode == "corrupt" { try Data("broken".utf8).write(to: url) }
            if mode == "generation" {
                var conversation = original.conversationRollup
                conversation.generationID = "other"
                try ConversationRollupCache.save(conversation, in: target.supportDirectory)
            }
            let oldBytes = target.fileBytes(url)
            let service = target.makeService()
            await target.bootstrap(service)
            XCTAssertEqual(service.historyRecoveryState, .pendingVerification, mode)
            XCTAssertFalse(try committedSnapshot(target).hasScanProgress)
            XCTAssertTrue(try committedSnapshot(target).scanState.generationID.isEmpty)
            let restarted = target.makeService()
            await target.bootstrap(restarted)
            XCTAssertEqual(restarted.historyRecoveryState, .pendingVerification, mode)
            XCTAssertFalse(restarted.historyDegradeReasons.isEmpty)
            await restarted.scanNow()
            XCTAssertEqual(restarted.historyRecoveryState, .complete, restarted.lastRebuildDiagnostic ?? mode)
            XCTAssertEqual(target.dayVector(restarted.aggregator.snapshotLocal()), target.dayVector(original.usageRollup.buckets))
            XCTAssertEqual(target.conversationVector(restarted.conversationAggregator.snapshot().buckets), target.conversationVector(original.conversationRollup.buckets))
            XCTAssertEqual(target.fileBytes(url), oldBytes)
            await restarted.scanNow()
            XCTAssertEqual(target.conversationVector(restarted.conversationAggregator.snapshot().buckets), target.conversationVector(original.conversationRollup.buckets))
        }
    }

    func testUnsupportedCurrentRunsReadOnlyWithoutOverwriting() async throws {
        let env = environment!
        try FileManager.default.createDirectory(at: env.historyDirectory, withIntermediateDirectories: true)
        let future = Data(#"{"version":999,"snapshotID":"future","usageRollup":{"version":999}}"#.utf8)
        try future.write(to: env.store.currentFileURL)

        let service = env.makeService()
        await env.bootstrap(service)
        XCTAssertEqual(service.lastRebuildOutcome, nil)
        XCTAssertNotNil(service.lastError)
        let notice = try XCTUnwrap(service.historyRecoveryNotice)
        XCTAssertTrue(notice.isReadOnly, "只读模式必须能被展示层识别")
        XCTAssertFalse(notice.canRetryVerification, "只读时重算无法写入，不能提示用户去重算")
        try env.writeClaudeLog(
            session: "session-a",
            lines: [
                env.claudeLine(
                    id: "msg-1",
                    session: "session-a",
                    model: "ccbar-recovery-model",
                    timestamp: "2026-09-20T01:00:00Z",
                    input: 1_000,
                    output: 10
                )
            ]
        )
        await service.scanNow()
        XCTAssertEqual(try env.fileBytes(env.store.currentFileURL), future, "只读模式不得覆盖更新版本的文件")
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.store.previousFileURL.path))
    }

    // MARK: - A08 源日志删除后普通增量仍保留历史

    func testIncrementalKeepsHistoryForDeletedClaudeDshAndOpencodeSources() async throws {
        let env = environment!
        let db = try env.openOpencodeDatabase()
        env.insertOpencodeSession(db, id: "oc-1", title: "opencode-one")
        env.insertOpencodeMessage(
            db,
            id: "oc-1-msg",
            sessionID: "oc-1",
            timeCreated: 1_786_075_934_005,
            data: env.opencodeAssistantData(input: 400, output: 40, cost: 0.5)
        )
        sqlite3_close(db)

        try env.writeClaudeLog(
            session: "claude-keep",
            lines: [env.claudeLine(id: "keep-1", session: "claude-keep", model: "ccbar-recovery-model", timestamp: "2026-09-20T01:00:00Z", input: 1_000, output: 10)]
        )
        let deletedClaude = try env.writeClaudeLog(
            session: "claude-deleted",
            lines: [env.claudeLine(id: "deleted-1", session: "claude-deleted", model: "ccbar-recovery-model", timestamp: "2026-09-20T01:05:00Z", input: 4_000, output: 40)]
        )
        let deletedDsh = try env.writeDshLog(
            project: "project-a",
            session: "dsh-deleted",
            records: [
                DshTestFixtures.session(id: "dsh-deleted"),
                DshTestFixtures.assistant(time: DshTestFixtures.baseTime + 1_000, input: 900, output: 20),
            ]
        )

        let service = env.makeService()
        await env.bootstrap(service)
        await service.scanNow()
        let before = env.totals(service.aggregator.snapshotLocal())

        // 删除日志文件（模拟日志清理 / 会话被删），再追加一条新记录。
        try FileManager.default.removeItem(at: deletedClaude)
        try FileManager.default.removeItem(at: deletedDsh)
        try env.append(
            env.claudeLine(id: "keep-2", session: "claude-keep", model: "ccbar-recovery-model", timestamp: "2026-09-20T02:00:00Z", input: 100, output: 1) + "\n",
            to: env.claudeRoot.appendingPathComponent("fixture-project/claude-keep.jsonl")
        )

        await service.scanNow()
        let after = env.totals(service.aggregator.snapshotLocal())
        XCTAssertEqual(after.inputTokens, before.inputTokens + 100, "删除日志不得倒扣历史；新增只加一次")
        XCTAssertEqual(after.requestCount, before.requestCount + 1)

        // 重启后再扫一轮，历史与新增都保持不变，也不重复。
        let restarted = env.makeService()
        await env.bootstrap(restarted)
        await restarted.scanNow()
        XCTAssertEqual(env.totals(restarted.aggregator.snapshotLocal()).inputTokens, after.inputTokens)
        XCTAssertEqual(env.totals(restarted.aggregator.snapshotLocal()).requestCount, after.requestCount)
        XCTAssertEqual(
            env.dayVector(restarted.aggregator.snapshotLocal()),
            env.dayVector(service.aggregator.snapshotLocal())
        )
    }

    // MARK: - A09 主历史存在但扫描状态缺失

    func testHistoryWithoutScanStateEntersRestrictedRecoveryAndVerifiesOnce() async throws {
        let source = try UsageTestEnvironment(name: "usage-history-restricted-source")
        _ = try await seedAndScan(source)
        let original = try committedSnapshot(source)

        let target = try UsageTestEnvironment(name: "usage-history-restricted-target")
        try target.copySources(from: source)
        try writeLegacy(target, from: original, includeScanState: false)

        let service = target.makeService()
        await target.bootstrap(service)
        XCTAssertEqual(service.historyRecoveryState, .pendingVerification)
        XCTAssertEqual(service.historyRecoveryNotice?.isRestricted, true)
        XCTAssertEqual(
            target.dayVector(service.aggregator.snapshotLocal()),
            target.dayVector(original.usageRollup.buckets),
            "缺少进度时历史仍必须完整展示"
        )

        // 日志未变：一次核对后采纳进度，历史不增不减。
        await service.scanNow()
        XCTAssertEqual(
            service.lastRebuildOutcome,
            .recoveredFromRestrictedHistory,
            "诊断：\(service.lastRebuildDiagnostic ?? "nil")"
        )
        XCTAssertEqual(service.historyRecoveryState, .complete)
        XCTAssertEqual(
            target.dayVector(service.aggregator.snapshotLocal()),
            target.dayVector(original.usageRollup.buckets)
        )

        let adopted = try committedSnapshot(target)
        XCTAssertTrue(adopted.hasScanProgress)
        await service.scanNow()
        XCTAssertEqual(
            target.dayVector(service.aggregator.snapshotLocal()),
            target.dayVector(original.usageRollup.buckets)
        )
    }

    func testRestrictedRecoveryRejectsWhenLogsChangedAndStopsRescanning() async throws {
        let source = try UsageTestEnvironment(name: "usage-history-restricted-reject-source")
        _ = try await seedAndScan(source)
        let original = try committedSnapshot(source)

        let target = try UsageTestEnvironment(name: "usage-history-restricted-reject-target")
        try target.copySources(from: source)
        try writeLegacy(target, from: original, includeScanState: false)
        // 日志在进度丢失之后又发生了变化：无法证明全量结果与旧历史同一，必须拒绝。
        try target.writeClaudeLog(
            session: "session-a",
            lines: [
                target.claudeLine(id: "session-a-msg-1", session: "session-a", model: "ccbar-recovery-model", timestamp: "2026-09-20T01:00:00Z", input: 1_000, output: 10),
                target.claudeLine(id: "session-a-msg-2", session: "session-a", model: "ccbar-recovery-model", timestamp: "2026-09-20T01:10:00Z", input: 777, output: 7),
            ]
        )

        let service = target.makeService()
        await target.bootstrap(service)
        await service.scanNow()
        XCTAssertEqual(service.historyRecoveryState, .verificationRejected)
        XCTAssertEqual(service.lastRebuildOutcome, .restrictedRecoveryRejected)
        let notice = try XCTUnwrap(service.historyRecoveryNotice)
        XCTAssertTrue(notice.isRestricted)
        XCTAssertFalse(notice.isReadOnly)
        XCTAssertTrue(notice.canRetryVerification, "受限但可写时只允许重试核对，不承诺恢复")
        XCTAssertTrue(notice.verificationRejected)
        XCTAssertNil(notice.restoredFromPreviousAt)
        await service.forceRescan()
        XCTAssertEqual(service.lastRebuildOutcome, .restrictedRecoveryRejected)
        XCTAssertEqual(service.historyRecoveryState, .verificationRejected)
        XCTAssertEqual(
            target.dayVector(service.aggregator.snapshotLocal()),
            target.dayVector(original.usageRollup.buckets),
            "拒绝后必须保留原历史"
        )

        // 不再每轮重新发起昂贵全量扫描。
        let encodesAfterVerification = target.stats.encodeCount
        await service.scanNow()
        await service.scanNow()
        XCTAssertEqual(target.stats.encodeCount, encodesAfterVerification)
        XCTAssertEqual(
            target.dayVector(service.aggregator.snapshotLocal()),
            target.dayVector(original.usageRollup.buckets)
        )
    }

    func testRestrictedRecoveryRetriesAfterTransientCommitFailure() async throws {
        let source = environment!
        _ = try await seedAndScan(source)
        let original = try committedSnapshot(source)
        let target = try UsageTestEnvironment(name: "restricted-retry")
        try target.copySources(from: source)
        try writeLegacy(target, from: original, includeScanState: false)
        let service = target.makeService()
        await target.bootstrap(service)
        target.faults.fail(at: .beforeEncode)
        await service.scanNow()
        XCTAssertEqual(service.historyRecoveryState, .verificationRejected)
        XCTAssertNotNil(service.lastRebuildDiagnostic)
        XCTAssertFalse(try committedSnapshot(target).hasScanProgress)
        await service.forceRescan()
        XCTAssertEqual(service.historyRecoveryState, .complete)
        XCTAssertTrue(try committedSnapshot(target).hasScanProgress)
        XCTAssertEqual(target.dayVector(original.usageRollup.buckets), target.dayVector(service.aggregator.snapshotLocal()))
        let restarted = target.makeService()
        await target.bootstrap(restarted)
        await restarted.scanNow()
        XCTAssertEqual(target.dayVector(original.usageRollup.buckets), target.dayVector(restarted.aggregator.snapshotLocal()))
    }

    // MARK: - A17 DSH v1 待复核 / 已删除会话 / 代次变化

    func testDshV1MigrationKeepsDeletedSessionAndDoesNotDoubleCount() async throws {
        let source = try UsageTestEnvironment(name: "usage-history-dsh-source")
        try source.writeDshLog(
            project: "project-a",
            session: "dsh-live",
            records: [
                DshTestFixtures.session(id: "dsh-live"),
                DshTestFixtures.assistant(time: DshTestFixtures.baseTime + 1_000, input: 500, output: 50),
            ]
        )
        try source.writeDshLog(
            project: "project-a",
            session: "dsh-deleted",
            records: [
                DshTestFixtures.session(id: "dsh-deleted"),
                DshTestFixtures.assistant(time: DshTestFixtures.baseTime + 2_000, input: 1_500, output: 150),
            ]
        )
        let originalService = source.makeService()
        await source.bootstrap(originalService)
        await originalService.scanNow()
        let original = try committedSnapshot(source)
        XCTAssertEqual(original.dshContributions.contributions.count, 2)
        XCTAssertGreaterThan(
            source.totals(original.usageRollup.buckets, app: .dsh).inputTokens,
            0,
            "基线必须真的含有 DSH 历史"
        )

        // 升级前的磁盘状态：删掉一个会话文件，DSH 缓存写成 v1，且没有新快照。
        try FileManager.default.removeItem(
            at: source.dshRoot.appendingPathComponent("project-a/dsh-deleted/session.jsonl")
        )
        let target = try UsageTestEnvironment(name: "usage-history-dsh-v1-target")
        try target.copySources(from: source)
        var legacyV1 = original.dshContributions
        legacyV1.version = 1
        try target.writeLegacyDshV1(legacyV1, usageRollup: original.usageRollup, scanState: original.scanState)

        let service = target.makeService()
        await target.bootstrap(service)
        XCTAssertFalse(service.isDshHistoryFrozen, "v1 可迁移，不允许冻结 DSH 分区")
        let dshBefore = target.totals(service.aggregator.snapshotLocal(), app: .dsh)
        XCTAssertEqual(
            dshBefore.inputTokens,
            source.totals(original.usageRollup.buckets, app: .dsh).inputTokens,
            "v1 迁移后 DSH 历史必须原样保留"
        )
        XCTAssertEqual(
            service.dshUnverifiedSessionIDsForTesting(),
            ["dsh-live", "dsh-deleted"],
            "v1 贡献必须整体标记待复核"
        )

        // 下一轮从零重扫现存会话：已删除会话的贡献保留、不翻倍；现存会话复核后清标记。
        await service.scanNow()
        XCTAssertEqual(
            target.totals(service.aggregator.snapshotLocal(), app: .dsh).inputTokens,
            dshBefore.inputTokens,
            "同一会话的完整重扫只能替换贡献，不能追加"
        )
        XCTAssertEqual(
            target.totals(service.aggregator.snapshotLocal(), app: .dsh).requestCount,
            dshBefore.requestCount
        )
        XCTAssertEqual(service.dshUnverifiedSessionIDsForTesting(), ["dsh-deleted"], "已删除会话无法复核，标记保留")
        XCTAssertNotNil(service.lastError)
    }

    // MARK: - A18 OpenCode 会话更新 / 删除 / 库不可读

    func testOpencodeReplacementPreservesDeletedSessionsAndErrorsDoNotClearHistory() async throws {
        let env = environment!
        let db = try env.openOpencodeDatabase()
        env.insertOpencodeSession(db, id: "oc-1", title: "one")
        env.insertOpencodeMessage(
            db,
            id: "oc-1-msg",
            sessionID: "oc-1",
            timeCreated: 1_786_075_934_005,
            data: env.opencodeAssistantData(input: 1_000, output: 100, cost: 0.25)
        )
        env.insertOpencodeSession(db, id: "oc-2", title: "two")
        env.insertOpencodeMessage(
            db,
            id: "oc-2-msg",
            sessionID: "oc-2",
            timeCreated: 1_786_075_934_006,
            data: env.opencodeAssistantData(input: 2_000, output: 200, cost: 0.5)
        )
        sqlite3_close(db)

        let service = env.makeService()
        await env.bootstrap(service)
        await service.scanNow()
        let before = env.totals(service.aggregator.snapshotLocal(), app: .opencode)
        XCTAssertEqual(before.inputTokens, 3_000)

        // 更新 oc-1 的完整贡献（替换而非相加），删除 oc-2。
        let update = try env.openOpencodeDatabase()
        env.opencodeExec(update, "DELETE FROM message WHERE id = ?", ["oc-1-msg"])
        env.insertOpencodeMessage(
            update,
            id: "oc-1-msg",
            sessionID: "oc-1",
            timeCreated: 1_786_075_934_005,
            timeUpdated: 1_786_075_999_005,
            data: env.opencodeAssistantData(input: 1_200, output: 120, cost: 0.3)
        )
        env.opencodeExec(update, "DELETE FROM message WHERE id = ?", ["oc-2-msg"])
        env.opencodeExec(update, "DELETE FROM session WHERE id = ?", ["oc-2"])
        sqlite3_close(update)

        await service.scanNow()
        let after = env.totals(service.aggregator.snapshotLocal(), app: .opencode)
        XCTAssertEqual(after.inputTokens, 1_200 + 2_000, "更新按会话整体替换，删除会话保留历史，不追加")
        XCTAssertEqual(after.requestCount, before.requestCount)

        // 库暂时不可读：保留已有数据，只报告错误。
        let replaceable = try env.openOpencodeDatabase()
        sqlite3_close(replaceable)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: env.opencodeDatabaseURL.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: env.opencodeDatabaseURL.path)
        }
        await service.scanNow()
        XCTAssertEqual(
            env.totals(service.aggregator.snapshotLocal(), app: .opencode).inputTokens,
            after.inputTokens,
            "读取失败不得清零已有 OpenCode 历史"
        )
        XCTAssertNotNil(service.lastError)
    }

    // MARK: - A24 Cursor 远端桶与账号隔离不受本地重算 / 恢复影响

    func testCursorRemotePartitionSurvivesLocalRebuildAndRestore() async throws {
        let env = environment!
        let service = try await seedAndScan(env)
        let day = UsageDay.startOfDay(for: Date(timeIntervalSince1970: 1_780_000_000))
        service.activateCursorRemoteUsage(accountID: "cursor-account")
        await service.storeCursorRemoteUsageForTesting(
            buckets: [
                UsageBucket(
                    app: .cursor,
                    model: "cursor-auto",
                    speed: .standard,
                    day: day,
                    inputTokens: 5_000,
                    outputTokens: 500,
                    cacheReadTokens: 0,
                    cacheCreationTokens: 0,
                    costUSD: 1.25,
                    requestCount: 5,
                    hasUnpricedUsage: false
                )
            ],
            dayRange: day..<day.addingTimeInterval(86_400),
            accountID: "cursor-account"
        )
        XCTAssertEqual(env.totals(service.aggregator.snapshot(), app: .cursor).inputTokens, 5_000)
        XCTAssertTrue(service.isCursorRemoteUsageCovered(day..<day.addingTimeInterval(3_600)))

        await service.forceRescan()
        XCTAssertEqual(
            service.lastRebuildOutcome,
            .replaced(cycleVerified: true),
            "诊断：\(service.lastRebuildDiagnostic ?? "nil")"
        )
        XCTAssertEqual(
            env.totals(service.aggregator.snapshot(), app: .cursor).inputTokens,
            5_000,
            "本地重算不得清空 Cursor 远端桶"
        )
        XCTAssertTrue(service.isCursorRemoteUsageCovered(day..<day.addingTimeInterval(3_600)))

        // 本地快照损坏后整体恢复，同样不影响远端分区与账号绑定。
        let currentData = try XCTUnwrap(env.fileBytes(env.store.currentFileURL))
        try currentData.prefix(10).write(to: env.store.currentFileURL)
        let restarted = env.makeService()
        await env.bootstrap(restarted)
        restarted.activateCursorRemoteUsage(accountID: "cursor-account")
        XCTAssertEqual(
            env.totals(restarted.aggregator.snapshot(), app: .cursor).inputTokens,
            5_000,
            "本地快照恢复不得丢失独立的 Cursor 远端缓存"
        )
        // 账号切换只隔离远端分区，不动本地历史。
        restarted.activateCursorRemoteUsage(accountID: "other-account")
        XCTAssertEqual(env.totals(restarted.aggregator.snapshot(), app: .cursor).inputTokens, 0)
        XCTAssertEqual(
            env.totals(restarted.aggregator.snapshotLocal()).inputTokens,
            env.totals(service.aggregator.snapshotLocal()).inputTokens
        )
    }
}

/// 测试宿主隔离自检：宿主 App 也是 CCBar.app，如果判定失效，它会启动真实采集
/// 并写入用户真实历史。这条断言是「测试不碰真实数据」的前置条件。
final class AppRuntimeIsolationTests: XCTestCase {
    func testTestProcessIsRecognizedAsUnitTestHost() {
        XCTAssertTrue(
            AppRuntime.isRunningUnitTests,
            "测试进程必须被识别为测试宿主；否则 CCBarApp 的 .task 会启动真实采集"
        )
    }
}

// MARK: - 测试辅助

private extension UsageTestEnvironment {
    /// 把 DSH 贡献写成 v1 格式，同时写入配套的日 / 对话 / 进度文件。
    func writeLegacyDshV1(
        _ payload: DshContributionPayload,
        usageRollup: UsageRollupPayload,
        scanState: ScanState
    ) throws {
        var v1 = payload
        v1.version = 1
        let encoder = JSONEncoder()
        try encoder.encode(v1).write(to: supportDirectory.appendingPathComponent("dsh-contributions.json"))
        try UsageRollupCache.save(usageRollup, in: supportDirectory)
        try ScanCache.save(scanState, in: cacheDirectory)
    }
}
