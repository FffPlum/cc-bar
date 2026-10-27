import XCTest
@testable import CCBar

@MainActor
final class CodexModelIdentityMigrationTests: XCTestCase {
    private var env: UsageTestEnvironment!
    private let model = "commandcode/deepseek/deepseek-v4.1-flash"
    private let bare = "deepseek-v4.1-flash"
    private let firstID = "01a0e753-5fbd-70d3-b243-9bbd8e66dce6"
    private let secondID = "01a0e754-5fbd-70d3-b243-9bbd8e66dce6"
    private let thirdID = "01a0e755-5fbd-70d3-b243-9bbd8e66dce6"
    private let start = Date(timeIntervalSince1970: 1_790_587_400)

    override func setUpWithError() throws {
        env = try UsageTestEnvironment(name: "codex-model-identity")
    }

    override func tearDownWithError() throws { env = nil }

    private struct Call {
        var model: String
        var input: Int = 100
        var cached: Int = 20
        var output: Int = 10
        var write: Int = 0
    }

    private func lines(_ id: String, _ calls: [Call]) -> [String] {
        let formatter = ISO8601DateFormatter()
        var result = [#"{"type":"session_meta","payload":{"id":"\#(id)","cwd":"/tmp/ccbar-fixture","model_provider":"openai"}}"#]
        var input = 0, cached = 0, output = 0, write = 0
        for (index, call) in calls.enumerated() {
            input += call.input; cached += call.cached; output += call.output; write += call.write
            let timestamp = formatter.string(from: start.addingTimeInterval(Double(index * 30)))
            result += [
                #"{"type":"turn_context","payload":{"model":"\#(call.model)"}}"#,
                #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"cache_write_tokens":\#(write),"output_tokens":\#(output),"total_tokens":\#(input+output)},"last_token_usage":{"input_tokens":\#(call.input),"cached_input_tokens":\#(call.cached),"cache_write_tokens":\#(call.write),"output_tokens":\#(call.output)}}}}"#,
            ]
        }
        return result
    }

    @discardableResult
    private func write(_ id: String, _ calls: [Call]) throws -> URL {
        try env.writeCodexLog(id: id, lines: lines(id, calls))
    }

    private func scan(boundary: [String: ScanFileState]? = nil) async -> CodexJSONLScanner.Result {
        await CodexJSONLScanner.scan(previous: [:], roots: env.scanRoots.codexRoots,
                                     indexedTitles: [:], historicalBoundary: boundary)
    }

    private func installCycle() {
        let from = start.addingTimeInterval(-3_600), to = start.addingTimeInterval(3_600)
        env.appState.quotaCycles.accountSegments = [QuotaCycleAccountSegment(
            id: "account", accountKey: "account", app: .codex, startAt: from, endAt: nil)]
        env.appState.quotaCycles.records = [QuotaCycleRecord(
            id: "cycle", accountKey: "account", app: .codex, limitID: "five-hour", limitKind: .fiveHour,
            startAt: from, endAt: to, scheduledEndAt: to, firstSampleAt: from, lastSampleAt: from,
            latestUsedPercent: 10, allowanceSegments: [QuotaCycleAllowanceSegment(
                id: "segment", startAt: from, endAt: to, baselineUsedPercent: 0, latestUsedPercent: 10,
                maximumUsedPercent: 10, firstSampleAt: from, lastSampleAt: from, startReason: .initial)],
            source: .api, boundaryQuality: .observed)]
    }

    /// 生成真实旧格式：用原解析器的请求/进度，但存裸模型；费用使用固定历史价。
    private func baseline(legacyCycles: Bool = true) async -> UsageSnapshot {
        let result = await scan()
        let entries = result.entries.map { entry -> UsageEntry in
            var e = entry
            e.model = Pricing.normalize(model: e.model)
            let cost = CostBreakdown(input: Decimal(e.inputTokens) * Decimal(string: "0.30")! / 1_000_000,
                                     output: Decimal(e.outputTokens) * Decimal(string: "1.20")! / 1_000_000,
                                     cacheRead: Decimal(e.cacheReadTokens) * Decimal(string: "0.006")! / 1_000_000,
                                     cacheCreation: Decimal(e.cacheCreationTokens) / 1_000_000)
            e.costUSD = cost.total
            e.costBreakdown = cost
            return e
        }
        let daily = UsageAggregator(), conversations = ConversationAggregator(), cycles = CycleUsageAggregator()
        daily.ingestLocal(entries)
        conversations.ingest(entries: entries, seeds: result.conversationSeeds)
        cycles.ingest(entries: entries, cycles: env.appState.quotaCycles.records,
                      accountSegments: env.appState.quotaCycles.accountSegments)
        var cycleBuckets = cycles.snapshot()
        if legacyCycles {
            // 旧周期桶没有 conversationKey；先按旧完整键聚合，真实覆盖跨会话混合桶。
            var merged: [CycleVectorKey: CycleUsageBucket] = [:]
            for var b in cycleBuckets {
                b.conversationKey = nil
                let key = CycleVectorKey(cycleID: b.cycleID, allowanceSegmentID: b.allowanceSegmentID,
                                         app: b.app, model: b.model, speed: b.speed, quality: b.quality)
                if var old = merged[key] {
                    old.inputTokens += b.inputTokens; old.outputTokens += b.outputTokens
                    old.cacheReadTokens += b.cacheReadTokens; old.cacheCreationTokens += b.cacheCreationTokens
                    old.requestCount += b.requestCount; old.costUSD += b.costUSD
                    merged[key] = old
                } else { merged[key] = b }
            }
            cycleBuckets = Array(merged.values)
        }
        var snapshot = UsageSnapshot()
        snapshot.snapshotID = "legacy"
        snapshot.createdAt = start
        snapshot.committedAt = start
        snapshot.scanState = ScanState(generationID: "legacy", codex: result.newState, codexSeenTokenIds: result.newSeenIds)
        snapshot.usageRollup = UsageRollupPayload(generationID: "legacy", buckets: daily.snapshotLocal())
        let conversation = conversations.snapshot()
        snapshot.conversationRollup = ConversationRollupPayload(generationID: "legacy", infos: conversation.infos, buckets: conversation.buckets)
        snapshot.cycleRollup = CycleUsageRollupPayload(generationID: "legacy", buckets: cycleBuckets,
                                                      initialRebuildCompletedAt: start, initialRebuildCompletedApps: [.codex, .claude])
        snapshot.dshContributions.generationID = "legacy"
        return snapshot
    }

    private func migrate(_ old: UsageSnapshot) async throws -> CodexModelIdentityMigration.Candidate {
        let evidence = await scan(boundary: old.scanState.codex)
        XCTAssertEqual(evidence.failedFileCount, 0)
        return try CodexModelIdentityMigration.makeCandidate(
            baseline: old, evidence: evidence, cycles: env.appState.quotaCycles.records,
            accountSegments: env.appState.quotaCycles.accountSegments)
    }

    func testStorageIdentityKeepsChannelAndLegacyDateRules() {
        XCTAssertEqual(CodexJSONLScanner.storageModel(model), model)
        XCTAssertEqual(CodexJSONLScanner.storageModel("gpt-5-2026-09-28"), "gpt-5")
        XCTAssertEqual(CodexJSONLScanner.storageModel("GPT-5-20260928"), "gpt-5")
        XCTAssertEqual(CodexJSONLScanner.storageModel("commandcode/openai/gpt-5-20260928"), "commandcode/openai/gpt-5")
        XCTAssertEqual(CodexJSONLScanner.storageModel("command-code/anthropic/claude-sonnet-4@20260928"), "command-code/anthropic/claude-sonnet-4")
        XCTAssertEqual(CodexJSONLScanner.storageModel("magpie/cursor/grok-4.7@256k:fast"),
                       "magpie/cursor/grok-4.7@256k:fast")
        XCTAssertEqual(Pricing.normalize(model: "magpie/cursor/grok-4.7@256k:fast"),
                       "magpie/cursor/grok-4.7")
        XCTAssertEqual(Pricing.normalize(model: model), bare)
        XCTAssertEqual(ModelProvider.resolve(app: .codex, model: model), .commandCode)
        XCTAssertEqual(Pricing.cost(app: .codex, model: model, speed: .standard, input: 100, output: 10,
                                   cacheRead: 20, cacheCreation: 0, at: start),
                       Pricing.cost(app: .codex, model: bare, speed: .standard, input: 100, output: 10,
                                    cacheRead: 20, cacheCreation: 0, at: start))
    }

    func testCursorIdentityRebuildRequiresMatchingHistoryAndCycleAttribution() async throws {
        let fullModel = "magpie/cursor/grok-4.7@256k:fast"
        try write(firstID, [Call(model: fullModel)])
        var old = await baseline()
        let pricedOld = old
        for index in old.usageRollup.buckets.indices {
            old.usageRollup.buckets[index].costUSD = 0
            old.usageRollup.buckets[index].hasUnpricedUsage = true
        }
        for index in old.conversationRollup.buckets.indices {
            old.conversationRollup.buckets[index].costUSD = 0
            old.conversationRollup.buckets[index].hasUnpricedUsage = true
            old.conversationRollup.buckets[index].inputCostUSD = 0
            old.conversationRollup.buckets[index].outputCostUSD = 0
            old.conversationRollup.buckets[index].cacheReadCostUSD = 0
            old.conversationRollup.buckets[index].cacheCreationCostUSD = 0
        }
        let scanResult = await scan()
        let daily = UsageAggregator(), conversations = ConversationAggregator()
        daily.ingestLocal(scanResult.entries)
        conversations.ingest(entries: scanResult.entries, seeds: scanResult.conversationSeeds)
        let candidateDay = daily.snapshotLocal()
        let candidateConversations = conversations.snapshot().buckets
        func safe(_ days: [UsageBucket], _ conversation: [ConversationUsageBucket],
                  oldCycles: [CycleUsageBucket] = [], newCycles: [CycleUsageBucket] = []) -> Bool {
            UsageHistoryConsistency.cursorIdentityRebuildIsSafe(
                baselineDay: old.usageRollup.buckets, candidateDay: days,
                baselineConversation: old.conversationRollup.buckets, candidateConversation: conversation,
                baselineCycle: oldCycles, candidateCycle: newCycles
            )
        }
        XCTAssertTrue(safe(candidateDay, candidateConversations))
        var changed = candidateConversations
        changed[0].inputTokens += 1
        XCTAssertFalse(safe(candidateDay, changed))
        XCTAssertFalse(safe(candidateDay, []))
        XCTAssertFalse(safe([], []), "旧标识的源日志全部缺失时不能跳过对账")
        XCTAssertFalse(UsageHistoryConsistency.cursorIdentityRebuildIsSafe(
            baselineDay: pricedOld.usageRollup.buckets, candidateDay: candidateDay,
            baselineConversation: pricedOld.conversationRollup.buckets, candidateConversation: candidateConversations,
            baselineCycle: [], candidateCycle: []
        ), "已有金额改变时不能把普通重算当作可信身份迁移")
        var sameIdentityDay = candidateDay
        var sameIdentityConversations = candidateConversations
        for index in sameIdentityDay.indices { sameIdentityDay[index].model = "magpie/cursor/grok-4.7" }
        for index in sameIdentityConversations.indices { sameIdentityConversations[index].model = "magpie/cursor/grok-4.7" }
        XCTAssertTrue(UsageHistoryConsistency.cursorIdentityRebuildIsSafe(
            baselineDay: pricedOld.usageRollup.buckets, candidateDay: sameIdentityDay,
            baselineConversation: pricedOld.conversationRollup.buckets, candidateConversation: sameIdentityConversations,
            baselineCycle: [], candidateCycle: []
        ), "身份未拆分时允许正常更新价格")
        var knownZero = old
        for index in knownZero.usageRollup.buckets.indices { knownZero.usageRollup.buckets[index].hasUnpricedUsage = false }
        for index in knownZero.conversationRollup.buckets.indices { knownZero.conversationRollup.buckets[index].hasUnpricedUsage = false }
        XCTAssertFalse(UsageHistoryConsistency.cursorIdentityRebuildIsSafe(
            baselineDay: knownZero.usageRollup.buckets, candidateDay: candidateDay,
            baselineConversation: knownZero.conversationRollup.buckets, candidateConversation: candidateConversations,
            baselineCycle: [], candidateCycle: []
        ), "已知零价不能当成缺价补算")

        let oldCycle = CycleUsageBucket(cycleID: "cycle", allowanceSegmentID: nil, app: .codex,
            model: "magpie/cursor/grok-4.7", speed: .standard, inputTokens: 80, outputTokens: 10,
            cacheReadTokens: 20, cacheCreationTokens: 0, costUSD: 0, requestCount: 1,
            hasUnpricedUsage: true, quality: .exact, conversationKey: nil)
        var newCycle = oldCycle
        newCycle.model = fullModel
        newCycle.conversationKey = "codex:fixture"
        XCTAssertFalse(safe(candidateDay, candidateConversations, oldCycles: [oldCycle], newCycles: [newCycle]))
        newCycle.conversationKey = nil
        XCTAssertTrue(safe(candidateDay, candidateConversations, oldCycles: [oldCycle], newCycles: [newCycle]))
    }

    func testFourRequestsPreserveHistoricalMoneyInAllProjections() async throws {
        installCycle()
        try write(firstID, [Call(model: model, input: 55_970, cached: 2_048, output: 1_083),
                            Call(model: model, input: 57_201, cached: 55_936, output: 987),
                            Call(model: model, input: 57_816, cached: 57_088, output: 94),
                            Call(model: model, input: 57_933, cached: 57_728, output: 2_350)])
        let old = await baseline()
        // 无论当前价格怎样变化，标识迁移完全使用旧金额。
        env.installPricing(model: bare, input: 999, output: 999, cacheRead: 999)
        let new = try await migrate(old).snapshot
        let b = try XCTUnwrap(new.conversationRollup.buckets.first)
        XCTAssertEqual(b.model, model)
        XCTAssertEqual(b.app, .codex)
        XCTAssertEqual(b.requestCount, 4)
        XCTAssertEqual(b.inputTokens, 56_120)
        XCTAssertEqual(b.cacheReadTokens, 172_800)
        XCTAssertEqual(b.outputTokens, 4_514)
        XCTAssertEqual(b.cacheCreationTokens, 0)
        XCTAssertEqual(b.costUSD, Decimal(string: "0.0232896"))
        XCTAssertEqual(new.usageRollup.buckets.first?.costUSD, b.costUSD)
        XCTAssertEqual(new.cycleRollup.buckets.first?.costUSD, b.costUSD)
        XCTAssertEqual(new.cycleRollup.buckets.first?.model, model)
        XCTAssertNil(new.cycleRollup.buckets.first?.conversationKey)
        XCTAssertEqual(new.scanState.codex, old.scanState.codex)
        XCTAssertEqual(new.scanState.codexSeenTokenIds, old.scanState.codexSeenTokenIds)
    }

    func testMixedDailyAndLegacyCycleBucketsSplitUsingConversationAmounts() async throws {
        installCycle()
        try write(firstID, [Call(model: model, input: 120)])
        try write(secondID, [Call(model: "deepseek/" + bare, input: 320)])
        let old = await baseline()
        XCTAssertEqual(old.usageRollup.buckets.count, 1)
        XCTAssertEqual(old.cycleRollup.buckets.count, 1)
        let new = try await migrate(old).snapshot
        XCTAssertEqual(Set(new.usageRollup.buckets.map(\.model)), [model, "deepseek/" + bare])
        XCTAssertEqual(new.cycleRollup.buckets.count, 2)
        for b in new.conversationRollup.buckets {
            XCTAssertEqual(new.usageRollup.buckets.first { $0.model == b.model }?.costUSD, b.costUSD)
            XCTAssertEqual(new.cycleRollup.buckets.first { $0.model == b.model }?.costUSD, b.costUSD)
        }
    }

    func testAmbiguousPaidConversationPreservesEntireOldModelGroup() async throws {
        try write(firstID, [Call(model: model), Call(model: "deepseek/" + bare)])
        let old = await baseline()
        let new = try await migrate(old).snapshot
        XCTAssertEqual(new.usageRollup.buckets, old.usageRollup.buckets)
        XCTAssertEqual(new.conversationRollup.buckets, old.conversationRollup.buckets)
        XCTAssertEqual(new.codexModelIdentityMigration?.retainedModels[bare], "mixed_conversation_cost_unverifiable")
    }

    func testRejectedCandidateFallbackRetainsAllModelsWithoutChangingHistoryOrProgress() async throws {
        try write(firstID, [Call(model: model)])
        let old = await baseline()
        let new = try CodexModelIdentityMigration.makeRetainingCandidate(baseline: old).snapshot
        XCTAssertEqual(new.usageRollup.buckets, old.usageRollup.buckets)
        XCTAssertEqual(new.conversationRollup.buckets, old.conversationRollup.buckets)
        XCTAssertEqual(new.cycleRollup.buckets, old.cycleRollup.buckets)
        XCTAssertEqual(new.scanState.codex, old.scanState.codex)
        XCTAssertEqual(new.scanState.codexSeenTokenIds, old.scanState.codexSeenTokenIds)
        XCTAssertEqual(new.codexModelIdentityMigration?.retainedModels[bare], "candidate_rejected")
        XCTAssertEqual(new.codexModelIdentityMigration?.migratedModels, [])
        XCTAssertNotEqual(new.snapshotID, old.snapshotID)
    }

    func testMissingLogRetainsMixedGroupWithoutGuessingAndOtherModelStillMigrates() async throws {
        try write(firstID, [Call(model: model)])
        let removed = try write(secondID, [Call(model: "deepseek/" + bare)])
        try write(thirdID, [Call(model: "commandcode/openai/gpt-5")])
        let old = await baseline()
        try FileManager.default.removeItem(at: removed) // 仅测试临时 fixture。
        let new = try await migrate(old).snapshot
        XCTAssertEqual(new.conversationRollup.buckets.filter { $0.model == bare }, old.conversationRollup.buckets.filter { $0.model == bare })
        XCTAssertTrue(new.usageRollup.buckets.contains { $0.model == "commandcode/openai/gpt-5" })
        XCTAssertNotNil(new.codexModelIdentityMigration?.retainedModels[bare])
    }

    func testAppendedRequestRemainsBeyondMigrationWatermarkAndCountsOnceAfterRestart() async throws {
        let calls = [Call(model: model), Call(model: model, input: 200)]
        let url = try write(firstID, Array(calls.prefix(1)))
        let old = await baseline()
        try env.store.commit(old)
        for line in lines(firstID, calls).suffix(2) { try env.append(line, to: url) }
        let evidence = await scan(boundary: old.scanState.codex)
        XCTAssertEqual(evidence.entries.count, 1)
        XCTAssertEqual(evidence.newState[firstID]?.offset, old.scanState.codex[firstID]?.offset)
        let service = env.makeService()
        await env.bootstrap(service)
        await service.scanNow()
        await service.flushPendingRollupChangesForTesting()
        XCTAssertEqual(service.aggregator.snapshotLocal().reduce(0) { $0 + $1.requestCount }, 2)
        XCTAssertTrue(service.aggregator.snapshotLocal().allSatisfy { $0.model == model })
        let restart = env.makeService()
        await env.bootstrap(restart)
        await restart.scanNow()
        XCTAssertEqual(restart.aggregator.snapshotLocal().reduce(0) { $0 + $1.requestCount }, 2)
        XCTAssertNotNil(env.store.loadCurrent().snapshot?.codexModelIdentityMigration)
    }

    func testCommitFailureRetainsOldHistoryAndRetryDoesNotDuplicate() async throws {
        try write(firstID, [Call(model: model)])
        let old = await baseline()
        try env.store.commit(old)
        let bytes = try Data(contentsOf: env.store.currentFileURL)
        let service = env.makeService()
        await env.bootstrap(service)
        env.faults.fail(at: .beforeCurrentReplace)
        await service.scanNow()
        XCTAssertEqual(try Data(contentsOf: env.store.currentFileURL), bytes)
        XCTAssertEqual(service.aggregator.snapshotLocal(), old.usageRollup.buckets)
        env.faults.clear()
        await service.scanNow()
        let once = try XCTUnwrap(env.store.loadCurrent().snapshot)
        await service.scanNow()
        XCTAssertEqual(env.store.loadCurrent().snapshot?.snapshotID, once.snapshotID)
        XCTAssertEqual(service.aggregator.snapshotLocal().first?.requestCount, 1)
        XCTAssertEqual(service.aggregator.snapshotLocal().first?.model, model)
    }

    func testAllCommitFaultsRecoverOneCompleteGeneration() async throws {
        try write(firstID, [Call(model: model)])
        let old = await baseline()
        let candidate = try await migrate(old).snapshot
        for point: UsageSnapshotStore.FaultPoint in [.beforeEncode, .afterEncode, .beforePreviousRotation,
                                                      .afterPreviousRotation, .beforeCurrentReplace, .afterCurrentReplace] {
            env.faults.clear()
            try env.store.commit(old)
            env.faults.fail(at: point)
            XCTAssertThrowsError(try env.store.commit(candidate))
            let durable = try XCTUnwrap(env.store.loadCurrent().snapshot)
            XCTAssertTrue(durable.snapshotID == old.snapshotID || durable.snapshotID == candidate.snapshotID)
            XCTAssertEqual(durable.usageRollup.buckets.first?.requestCount, 1)
            env.faults.clear()
            let retry = try await migrate(durable).snapshot
            try env.store.commit(retry)
            XCTAssertEqual(retry.usageRollup.buckets.first?.model, model)
            XCTAssertEqual(retry.usageRollup.buckets.first?.requestCount, 1)
        }
    }

    func testMigrationValidatorRejectsTokensMoneySpeedAndCycleAttributionChanges() async throws {
        installCycle()
        try write(firstID, [Call(model: model, write: 5)])
        let old = await baseline(legacyCycles: false)
        let candidate = try await migrate(old)
        var new = candidate.snapshot
        new.scanState.generationID = old.scanState.generationID
        func valid(_ value: UsageSnapshot) -> Bool {
            UsageHistoryConsistency.validateCodexIdentityMigration(baseline: old, candidate: value, origins: candidate.origins)
        }
        XCTAssertTrue(valid(new))
        var changed = new
        changed.usageRollup.buckets[0].cacheCreationTokens += 1
        XCTAssertFalse(valid(changed))
        changed = new
        changed.conversationRollup.buckets[0].inputCostUSD += 1
        XCTAssertFalse(valid(changed))
        changed = new
        changed.usageRollup.buckets[0].speed = .fast
        XCTAssertFalse(valid(changed))
        changed = new
        changed.cycleRollup.buckets[0].conversationKey = "codex:wrong"
        XCTAssertFalse(valid(changed))
        changed = new
        changed.scanState.codex[firstID]?.offset += 1
        XCTAssertFalse(valid(changed))
        let mismatch = UsageHistoryConsistency.compareUsage(
            baseline: old.usageRollup.buckets, candidateDay: new.usageRollup.buckets,
            baselineConversation: old.conversationRollup.buckets, candidateConversation: new.conversationRollup.buckets,
            baselineInfos: old.conversationRollup.infos, candidateInfos: new.conversationRollup.infos)
        XCTAssertTrue(mismatch.hasUsageDifference, "普通重算不能被迁移校验放宽")
    }

    func testTruncatedOrMalformedHistoricalSourceCannotProduceEvidence() async throws {
        let url = try write(firstID, [Call(model: model)])
        let old = await baseline()
        try Data("bad\n".utf8).write(to: url)
        let evidence = await scan(boundary: old.scanState.codex)
        XCTAssertGreaterThan(evidence.failedFileCount, 0)
        XCTAssertEqual(evidence.historicalTransientFailureCount, 0, "截断是确定结果，不能按可重试失败推迟")
        XCTAssertTrue(evidence.entries.isEmpty)
    }

    func testTransientReadFailureDefersMigrationAndKeepsLegacyIdentityUntilRetry() async throws {
        let calls = [Call(model: model), Call(model: model, input: 200)]
        let firstURL = try write(firstID, Array(calls.prefix(1)))
        let locked = try write(secondID, [Call(model: model)])
        let old = await baseline()
        try env.store.commit(old)
        // 仅测试临时 fixture：去掉读权限模拟一次可重试的读取失败。
        let fm = FileManager.default
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }
        let evidence = await scan(boundary: old.scanState.codex)
        XCTAssertGreaterThan(evidence.historicalTransientFailureCount, 0)

        for line in lines(firstID, calls).suffix(2) { try env.append(line, to: firstURL) }

        let service = env.makeService()
        await env.bootstrap(service)
        await service.scanNow()
        await service.flushPendingRollupChangesForTesting()
        let deferred = try XCTUnwrap(env.store.loadCurrent().snapshot)
        XCTAssertNil(deferred.codexModelIdentityMigration, "可重试失败不能提交迁移结果")
        XCTAssertTrue(deferred.usageRollup.buckets.allSatisfy { $0.model == bare }, "迁移提交前新调用沿用旧身份")
        XCTAssertEqual(deferred.usageRollup.buckets.reduce(0) { $0 + $1.requestCount }, 3)

        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path)
        let restart = env.makeService()
        await env.bootstrap(restart)
        await restart.scanNow()
        let migrated = try XCTUnwrap(env.store.loadCurrent().snapshot)
        XCTAssertEqual(migrated.codexModelIdentityMigration?.migratedModels, [bare])
        XCTAssertTrue(restart.aggregator.snapshotLocal().allSatisfy { $0.model == model })
        XCTAssertEqual(restart.aggregator.snapshotLocal().reduce(0) { $0 + $1.requestCount }, 3)
    }

    func testPartOfPaidConversationCannotBeUsedToSplitCycleMoney() async throws {
        installCycle()
        env.appState.quotaCycles.records[0].startAt = start.addingTimeInterval(15)
        env.appState.quotaCycles.records[0].allowanceSegments[0].startAt = start.addingTimeInterval(15)
        try write(firstID, [Call(model: model), Call(model: model)])
        try write(secondID, [Call(model: "deepseek/" + bare), Call(model: "deepseek/" + bare)])
        let old = await baseline()
        let new = try await migrate(old).snapshot
        XCTAssertEqual(new.cycleRollup.buckets, old.cycleRollup.buckets)
        XCTAssertEqual(new.conversationRollup.buckets, old.conversationRollup.buckets)
        XCTAssertEqual(new.codexModelIdentityMigration?.retainedModels[bare], "mixed_cycle_cost_unverifiable")
    }

    func testForkReplayDoesNotReassignParentUsage() async throws {
        try write(firstID, [Call(model: model)])
        let fork = [#"{"type":"session_meta","payload":{"id":"\#(secondID)"}}"#]
            + lines(firstID, [Call(model: model)])
        try env.writeCodexLog(id: secondID, lines: fork)
        let old = await baseline()
        let new = try await migrate(old).snapshot
        XCTAssertEqual(new.conversationRollup.buckets.count, 1)
        XCTAssertEqual(new.conversationRollup.buckets.first?.conversationKey, "codex:" + firstID)
        XCTAssertEqual(new.conversationRollup.buckets.first?.requestCount, 1)
        XCTAssertEqual(new.conversationRollup.buckets.first?.model, model)
    }

    func testNewCodexKeepsChannelWhileClaudeAndBareModelsKeepExistingBehavior() async throws {
        try write(firstID, [Call(model: model)])
        try write(secondID, [Call(model: "gpt-5-20260928")])
        try env.writeClaudeLog(session: "claude", lines: [env.claudeLine(
            id: "claude", session: "claude", model: "anthropic/claude-sonnet-4-20250514",
            timestamp: "2026-09-28T09:23:30Z", input: 100, output: 10, speed: "standard")])
        let service = env.makeService()
        await env.bootstrap(service)
        await service.scanNow()
        let buckets = service.aggregator.snapshotLocal()
        XCTAssertTrue(buckets.contains { $0.app == .codex && $0.model == model && $0.requestCount == 1 })
        XCTAssertTrue(buckets.contains { $0.app == .codex && $0.model == "gpt-5" })
        XCTAssertTrue(buckets.contains { $0.app == .claude && $0.model == "claude-sonnet-4" })
        XCTAssertNotNil(env.store.loadCurrent().snapshot?.codexModelIdentityMigration)
    }

    func testOldSnapshotWithoutMigrationFieldStillDecodesAndFutureVersionIsRejected() async throws {
        try write(firstID, [Call(model: model)])
        let old = await baseline()
        let bytes = try JSONEncoder().encode(old)
        XCTAssertNil(UsageSnapshotStore.decode(bytes).snapshot?.codexModelIdentityMigration)
        XCTAssertNotNil(UsageSnapshotStore.decode(bytes).snapshot)
        var future = old
        future.codexModelIdentityMigration = CodexModelIdentityMigrationState(version: 999)
        XCTAssertNil(UsageSnapshotStore.decode(try JSONEncoder().encode(future)).snapshot)
    }
}
