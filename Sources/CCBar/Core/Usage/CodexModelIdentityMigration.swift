import Foundation

/// 标识迁移的结果与历史同代持久化。nil 表示旧快照，不能靠提高 payload 版本丢弃历史。
nonisolated struct CodexModelIdentityMigrationState: Sendable, Codable, Equatable {
    static let currentVersion = 1
    var version = Self.currentVersion
    var migratedModels: [String] = []
    var retainedModels: [String: String] = [:]
}

/// 只改 Codex 标识，不取价格、不重新累计历史。一个旧模型横跨的三种投影作为一个事务单元：
/// 任一投影缺少证据或金额不能可靠拆分，就保留该模型的全部旧桶，其他模型仍可迁移。
@MainActor
enum CodexModelIdentityMigration {
    struct Candidate {
        var snapshot: UsageSnapshot
        var origins: [String: String]
    }

    private struct Piece {
        var bucket: ConversationUsageBucket
        var cycles: [CycleUsageBucket]
    }

    private enum Refusal: String, Error {
        case sourceCoverage = "source_coverage_unverified"
        case conversationMismatch = "conversation_vector_mismatch"
        case ambiguousConversationCost = "mixed_conversation_cost_unverifiable"
        case dayMismatch = "day_vector_or_cost_mismatch"
        case cycleMismatch = "cycle_vector_or_attribution_mismatch"
        case ambiguousCycleCost = "mixed_cycle_cost_unverifiable"
        case identityCollision = "identity_collision"
        case candidateRejected = "candidate_rejected"
    }

    static func makeCandidate(
        baseline: UsageSnapshot,
        evidence: CodexJSONLScanner.Result,
        cycles: [QuotaCycleRecord],
        accountSegments: [QuotaCycleAccountSegment]
    ) throws -> Candidate {
        guard baseline.codexModelIdentityMigration == nil else {
            return Candidate(snapshot: baseline, origins: [:])
        }
        var candidate = baseline
        var state = CodexModelIdentityMigrationState()
        var origins: [String: String] = [:]
        let models = Set(baseline.usageRollup.buckets.filter { $0.app == .codex }.map(\.model))
            .union(baseline.conversationRollup.buckets.filter { $0.app == .codex }.map(\.model))
            .union(baseline.cycleRollup.buckets.filter { $0.app == .codex }.map(\.model))
        let byLegacyModel = Dictionary(grouping: evidence.entries) { Pricing.normalize(model: $0.model) }
        for model in models.sorted() {
            let entries = byLegacyModel[model] ?? []
            let oldConversations = baseline.conversationRollup.buckets.filter { $0.app == .codex && $0.model == model }
            guard entries.contains(where: { $0.model != model }) else {
                // 没有前缀证据，绝不从模型名猜渠道。仅记覆盖缺口，不生成重命名。
                if !oldConversations.isEmpty,
                   conversationCounts(entries, legacy: true) != UsageHistoryConsistency.conversationVector(oldConversations) {
                    state.retainedModels[model] = Refusal.sourceCoverage.rawValue
                }
                continue
            }
            do {
                // 坏文件不会产出证据；每个旧模型仍须逐会话对账，不能用 fork 的副本顶替。
                let pieces = try conversationPieces(oldConversations, entries: entries,
                                                    cycles: cycles, accountSegments: accountSegments)
                let newConversations = pieces.map(\.bucket)
                let oldDays = baseline.usageRollup.buckets.filter { $0.app == .codex && $0.model == model }
                let newDays = try dayBuckets(oldDays, pieces: pieces)
                let oldCycles = baseline.cycleRollup.buckets.filter { $0.app == .codex && $0.model == model }
                let newCycles = try cycleBuckets(oldCycles, pieces: pieces)
                let destinations = Set(newConversations.map(\.model)).subtracting([model])
                // 首次迁移前已存在目标桶时，拒绝隐式覆盖或合并两套身份。
                guard destinations.isDisjoint(with: models) else { throw Refusal.identityCollision }
                for destination in destinations { origins[destination] = model }
                candidate.usageRollup.buckets.removeAll { $0.app == .codex && $0.model == model }
                candidate.usageRollup.buckets += newDays
                candidate.conversationRollup.buckets.removeAll { $0.app == .codex && $0.model == model }
                candidate.conversationRollup.buckets += newConversations
                candidate.cycleRollup.buckets.removeAll { $0.app == .codex && $0.model == model }
                candidate.cycleRollup.buckets += newCycles
                state.migratedModels.append(model)
            } catch let reason as Refusal {
                state.retainedModels[model] = reason.rawValue
            }
        }
        candidate.codexModelIdentityMigration = state
        // 先按原代次验证；提交只更换代次，不推进任何 watermark 或 seen 集。
        guard UsageHistoryConsistency.validateCodexIdentityMigration(
            baseline: baseline, candidate: candidate, origins: origins
        ) else { throw Refusal.conversationMismatch }
        try stamp(&candidate)
        return Candidate(snapshot: candidate, origins: origins)
    }

    /// `makeCandidate` 被整体拒绝（对账不符、结构不合法）时的确定性兜底：不改任何桶，
    /// 把全部 Codex 旧模型记为保留并落盘，避免同一个失败在每次扫描重复出现、阻塞增量采集。
    static func makeRetainingCandidate(baseline: UsageSnapshot) throws -> Candidate {
        var candidate = baseline
        var state = CodexModelIdentityMigrationState()
        let models = Set(baseline.usageRollup.buckets.filter { $0.app == .codex }.map(\.model))
            .union(baseline.conversationRollup.buckets.filter { $0.app == .codex }.map(\.model))
            .union(baseline.cycleRollup.buckets.filter { $0.app == .codex }.map(\.model))
        for model in models { state.retainedModels[model] = Refusal.candidateRejected.rawValue }
        candidate.codexModelIdentityMigration = state
        try stamp(&candidate)
        return Candidate(snapshot: candidate, origins: [:])
    }

    /// 迁移只更换代次，不推进任何 watermark 或 seen 集。
    private static func stamp(_ candidate: inout UsageSnapshot) throws {
        let id = UUID().uuidString
        candidate.snapshotID = id
        candidate.committedAt = Date()
        candidate.scanState.generationID = id
        candidate.usageRollup.generationID = id
        candidate.conversationRollup.generationID = id
        if !candidate.cycleRollup.generationID.isEmpty { candidate.cycleRollup.generationID = id }
        if !candidate.dshContributions.generationID.isEmpty { candidate.dshContributions.generationID = id }
        try candidate.validateStructure()
    }

    private static func conversationKey(_ entry: UsageEntry, legacy: Bool) -> ConversationVectorKey {
        ConversationVectorKey(conversationKey: entry.conversationKey, day: entry.day,
                              model: legacy ? Pricing.normalize(model: entry.model) : entry.model,
                              speed: entry.speed)
    }

    private static func conversationCounts(_ entries: [UsageEntry], legacy: Bool) -> [ConversationVectorKey: UsageVectorCounts] {
        var result: [ConversationVectorKey: UsageVectorCounts] = [:]
        for entry in entries {
            let key = conversationKey(entry, legacy: legacy)
            var count = result[key] ?? .zero
            count.inputTokens += entry.inputTokens
            count.outputTokens += entry.outputTokens
            count.cacheReadTokens += entry.cacheReadTokens
            count.cacheCreationTokens += entry.cacheCreationTokens
            count.requestCount += entry.requestCount
            result[key] = count
        }
        return result
    }

    private static func conversationPieces(
        _ old: [ConversationUsageBucket], entries: [UsageEntry],
        cycles: [QuotaCycleRecord], accountSegments: [QuotaCycleAccountSegment]
    ) throws -> [Piece] {
        let vector = UsageHistoryConsistency.conversationVector(old)
        guard !old.isEmpty, vector.count == old.count,
              vector == conversationCounts(entries, legacy: true) else { throw Refusal.conversationMismatch }
        let byKey = Dictionary(grouping: entries) { conversationKey($0, legacy: true) }
        var pieces: [Piece] = []
        for bucket in old {
            let key = ConversationVectorKey(conversationKey: bucket.conversationKey, day: bucket.day,
                                             model: bucket.model, speed: bucket.speed)
            guard let calls = byKey[key], calls.map(\.timestamp).min() == bucket.firstAt,
                  calls.map(\.timestamp).max() == bucket.lastAt else { throw Refusal.conversationMismatch }
            let byModel = Dictionary(grouping: calls, by: \.model)
            let hasCost = bucket.costUSD != 0 || bucket.inputCostUSD != 0 || bucket.outputCostUSD != 0
                || bucket.cacheReadCostUSD != 0 || bucket.cacheCreationCostUSD != 0
            guard byModel.count == 1 || !hasCost else { throw Refusal.ambiguousConversationCost }
            for model in byModel.keys.sorted() {
                let part = byModel[model]!
                let counts = conversationCounts(part, legacy: false).values.first!
                var updated = bucket
                updated.model = model
                updated.inputTokens = counts.inputTokens
                updated.outputTokens = counts.outputTokens
                updated.cacheReadTokens = counts.cacheReadTokens
                updated.cacheCreationTokens = counts.cacheCreationTokens
                updated.requestCount = counts.requestCount
                updated.firstAt = part.map(\.timestamp).min()!
                updated.lastAt = part.map(\.timestamp).max()!
                let projection = CycleUsageAggregator()
                projection.ingest(entries: part, cycles: cycles, accountSegments: accountSegments)
                pieces.append(Piece(bucket: updated, cycles: projection.snapshot()))
            }
        }
        return pieces
    }

    private static func dayBuckets(_ old: [UsageBucket], pieces: [Piece]) throws -> [UsageBucket] {
        let projection = UsageAggregator()
        // 用旧对话的真实汇总金额生成日桶，完全不查询 Pricing。
        projection.ingestLocal(pieces.map { piece in
            let b = piece.bucket
            return UsageEntry(app: .codex, conversationKey: b.conversationKey, model: b.model,
                              speed: b.speed, day: b.day, timestamp: b.firstAt, inputTokens: b.inputTokens,
                              outputTokens: b.outputTokens, cacheReadTokens: b.cacheReadTokens,
                              cacheCreationTokens: b.cacheCreationTokens, requestCount: b.requestCount,
                              costUSD: b.costUSD, costBreakdown: nil)
        })
        var result = projection.snapshotLocal()
        for index in result.indices {
            let b = result[index]
            result[index].hasUnpricedUsage = pieces.contains {
                $0.bucket.day == b.day && $0.bucket.speed == b.speed && $0.bucket.model == b.model && $0.bucket.hasUnpricedUsage
            }
            result[index].costIncomplete = old.contains { $0.day == b.day && $0.speed == b.speed && $0.costIncomplete }
        }
        let collapsed = result.map { bucket -> UsageBucket in
            var b = bucket; b.model = Pricing.normalize(model: b.model); return b
        }
        guard UsageHistoryConsistency.dayVector(old) == UsageHistoryConsistency.dayVector(collapsed),
              UsageHistoryConsistency.migrationDayBalances(old) == UsageHistoryConsistency.migrationDayBalances(collapsed)
        else { throw Refusal.dayMismatch }
        return result
    }

    private static func matches(_ candidate: CycleUsageBucket, _ old: CycleUsageBucket) -> Bool {
        candidate.cycleID == old.cycleID && candidate.allowanceSegmentID == old.allowanceSegmentID
            && candidate.app == old.app && candidate.speed == old.speed && candidate.quality == old.quality
            && (old.conversationKey == nil || candidate.conversationKey == old.conversationKey)
    }

    private static func cycleBuckets(_ old: [CycleUsageBucket], pieces: [Piece]) throws -> [CycleUsageBucket] {
        let replay = pieces.flatMap(\.cycles)
        // 每条证据必须恰好归入一个旧键；不混合 nil 会话桶与有会话归属的桶。
        guard replay.allSatisfy({ part in old.filter { matches(part, $0) }.count == 1 })
        else { throw Refusal.cycleMismatch }
        var result: [CycleUsageBucket] = []
        for bucket in old {
            let parts = replay.filter { matches($0, bucket) }
            var remapped = parts.map { part -> CycleUsageBucket in
                var b = part; b.model = bucket.model; b.conversationKey = bucket.conversationKey; return b
            }
            guard UsageHistoryConsistency.cycleVector([bucket]) == UsageHistoryConsistency.cycleVector(remapped)
            else { throw Refusal.cycleMismatch }
            let byModel = Dictionary(grouping: parts, by: \.model)
            var costs: [String: Decimal] = [:]
            if byModel.count == 1, let model = byModel.keys.first {
                costs[model] = bucket.costUSD
            } else {
                // 只有整个对话日桶落入该周期/额度段，才能使用它的历史金额；局部切片不按比例猜价。
                for piece in pieces {
                    let slices = piece.cycles.filter { matches($0, bucket) }
                    guard !slices.isEmpty else { continue }
                    let b = piece.bucket
                    let count = slices.reduce(0) { $0 + $1.requestCount }
                    guard count == b.requestCount || b.costUSD == 0 else { throw Refusal.ambiguousCycleCost }
                    costs[b.model, default: 0] += b.costUSD
                }
                guard costs.values.reduce(Decimal(0), +) == bucket.costUSD else { throw Refusal.ambiguousCycleCost }
            }
            for model in byModel.keys.sorted() {
                remapped = byModel[model]!
                var b = bucket
                b.model = model
                b.inputTokens = remapped.reduce(0) { $0 + $1.inputTokens }
                b.outputTokens = remapped.reduce(0) { $0 + $1.outputTokens }
                b.cacheReadTokens = remapped.reduce(0) { $0 + $1.cacheReadTokens }
                b.cacheCreationTokens = remapped.reduce(0) { $0 + $1.cacheCreationTokens }
                b.requestCount = remapped.reduce(0) { $0 + $1.requestCount }
                b.costUSD = costs[model] ?? 0
                result.append(b)
            }
        }
        return result
    }
}
