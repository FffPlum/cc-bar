import Foundation

/// 旧缓存文件（本计划基线的分散格式）的读取结论。
///
/// 必须把「文件不存在」「版本不受支持」「文件损坏」分开：迁移时按各自规则处理，
/// 不能一律当成空数据。主日缓存的处理见 `LegacyUsageHistoryOutcome`。
nonisolated enum LegacyUsageHistoryFileProbe<Value: Sendable>: Sendable {
    case missing
    case valid(Value)
    case unsupportedVersion(Int)
    case corrupt
}

/// 旧文件位置。nil 表示走生产路径；测试注入临时目录。
nonisolated struct LegacyUsageHistoryLocations: Sendable {
    /// `Application Support/CCBar`（日 / 对话 / 周期 / DSH）。
    var supportDirectory: URL?
    /// `Caches/CCBar`（scan-state）。
    var cacheDirectory: URL?

    static let production = LegacyUsageHistoryLocations(supportDirectory: nil, cacheDirectory: nil)

    var usageRollupURL: URL { UsageRollupCache.cacheFileURL(in: supportDirectory) }
    var conversationRollupURL: URL { ConversationRollupCache.cacheFileURL(in: supportDirectory) }
    var cycleRollupURL: URL { CycleUsageRollupCache.fileURL(in: supportDirectory) }
    var dshContributionsURL: URL { DshContributionCache.cacheFileURL(in: supportDirectory) }
    var scanStateURL: URL { ScanCache.cacheFileURL(in: cacheDirectory) }
}

/// 只读 version 字段，用来区分「版本不受支持」与「文件损坏」。
private nonisolated struct LegacyVersionProbe: Decodable {
    let version: Int
}

nonisolated enum LegacyUsageHistoryReader {
    nonisolated static func read<Value: Decodable & Sendable>(
        _ type: Value.Type,
        url: URL,
        currentVersion: Int
    ) -> LegacyUsageHistoryFileProbe<Value> {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url) else { return .corrupt }
        guard let probe = try? JSONDecoder().decode(LegacyVersionProbe.self, from: data) else {
            return .corrupt
        }
        guard probe.version == currentVersion else {
            return .unsupportedVersion(probe.version)
        }
        guard let value = try? JSONDecoder().decode(Value.self, from: data) else {
            return .corrupt
        }
        return .valid(value)
    }

    /// DSH 贡献缓存兼容 v1 与 v2；v1 的贡献按现有语义全部标记为待复核。
    nonisolated static func readDshContributions(
        url: URL
    ) -> LegacyUsageHistoryFileProbe<DshContributionPayload> {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url) else { return .corrupt }
        guard let probe = try? JSONDecoder().decode(LegacyVersionProbe.self, from: data) else {
            return .corrupt
        }
        guard probe.version == 1 || probe.version == DshContributionPayload.currentVersion else {
            return .unsupportedVersion(probe.version)
        }
        guard let payload = try? JSONDecoder().decode(DshContributionPayload.self, from: data) else {
            return .corrupt
        }
        guard payload.version == 1 else { return .valid(payload) }
        var migrated = payload
        for (id, var contribution) in migrated.contributions {
            contribution.needsVerification = true
            migrated.contributions[id] = contribution
        }
        migrated.version = DshContributionPayload.currentVersion
        // v1 的旧口径无法逐会话复核：沿用升级前的 `.pending` 语义，下一轮从零重扫 DSH，
        // 现存日志完整扫描后替换对应会话，已删除会话保留贡献并继续带待复核标记。
        migrated.requiresRebuild = true
        return .valid(migrated)
    }

    /// 某个旧文件是否存在（不需要能解码）。
    nonisolated static func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}

/// 旧文件 → 单份快照的迁移结论。
nonisolated enum LegacyUsageHistoryOutcome: Sendable {
    /// 真正的首次安装：没有任何旧历史。按现有来源规则首次采集。
    case firstInstall
    /// 导入成功。可能带受限标记（历史可用但进度 / 周期 / DSH 之一不可信）。
    case imported(UsageSnapshot)
    /// 主日缓存是低于当前的旧版本、已损坏、为空或缺失（只剩其他旧文件）。升级前的版本遇到
    /// 这些情况同样丢弃缓存、从本机日志全量重扫，这里沿用该行为：按首装采集，原文件保持不动。
    case discarded(detail: String)
    /// 主日缓存版本高于当前版本，无法解释。原文件保持不动。
    case unusable(reason: UsageSnapshotDegradeReason, detail: String)

    var snapshot: UsageSnapshot? {
        if case .imported(let snapshot) = self { return snapshot }
        return nil
    }
}

/// 把旧版本分散缓存合成一份完整提交。不删除、不覆盖任何旧文件。
nonisolated enum LegacyUsageHistoryImport {
    nonisolated static func makeSnapshot(
        locations: LegacyUsageHistoryLocations,
        createdAt: Date = Date()
    ) -> LegacyUsageHistoryOutcome {
        let dayProbe = LegacyUsageHistoryReader.read(
            UsageRollupPayload.self,
            url: locations.usageRollupURL,
            currentVersion: UsageRollupPayload.currentVersion
        )
        let conversationProbe = LegacyUsageHistoryReader.read(
            ConversationRollupPayload.self,
            url: locations.conversationRollupURL,
            currentVersion: ConversationRollupPayload.currentVersion
        )
        let cycleProbe = LegacyUsageHistoryReader.read(
            CycleUsageRollupPayload.self,
            url: locations.cycleRollupURL,
            currentVersion: CycleUsageRollupPayload.currentVersion
        )
        let scanProbe = LegacyUsageHistoryReader.read(
            ScanState.self,
            url: locations.scanStateURL,
            currentVersion: ScanState.currentVersion
        )
        let dshProbe = LegacyUsageHistoryReader.readDshContributions(url: locations.dshContributionsURL)

        let anythingExists = LegacyUsageHistoryReader.fileExists(at: locations.usageRollupURL)
            || LegacyUsageHistoryReader.fileExists(at: locations.conversationRollupURL)
            || LegacyUsageHistoryReader.fileExists(at: locations.cycleRollupURL)
            || LegacyUsageHistoryReader.fileExists(at: locations.scanStateURL)
            || LegacyUsageHistoryReader.fileExists(at: locations.dshContributionsURL)
        guard anythingExists else { return .firstInstall }

        let day: UsageRollupPayload?
        switch dayProbe {
        case .valid(let payload) where !payload.generationID.isEmpty:
            day = payload
        case .valid:
            // 空 generation 的 payload 等价于「没有这份历史」，不是可导入数据。
            day = nil
        case .unsupportedVersion(let version) where version < UsageRollupPayload.currentVersion:
            return .discarded(detail: "usage-rollup version \(version)")
        case .unsupportedVersion(let version):
            return .unusable(reason: .legacyDayUnsupportedVersion, detail: "usage-rollup version \(version)")
        case .corrupt:
            return .discarded(detail: "usage-rollup unreadable")
        case .missing:
            day = nil
        }

        guard let day else {
            // 主日历史不可用：不能凭周期或 DSH 拼一份「完整历史」出来，只能全量重扫。
            if LegacyUsageHistoryReader.fileExists(at: locations.usageRollupURL) {
                return .discarded(detail: "usage-rollup empty")
            }
            return .discarded(detail: "usage-rollup missing")
        }

        var reasons: [UsageSnapshotDegradeReason] = []
        var snapshot = UsageSnapshot()
        snapshot.snapshotID = day.generationID
        snapshot.createdAt = createdAt
        snapshot.committedAt = createdAt
        snapshot.usageRollup = day
        // 对话分区即使被丢弃也属于本次提交：空分区 + 同代，并在 degradeReasons 里说明原因。
        snapshot.conversationRollup.generationID = day.generationID

        // 对话历史：只有与主日同代才可能作为同一份历史。
        switch conversationProbe {
        case .valid(let payload) where payload.generationID == day.generationID:
            snapshot.conversationRollup = payload
        case .valid:
            reasons.append(.conversationGenerationMismatch)
        case .unsupportedVersion:
            reasons.append(.legacyConversationUnsupportedVersion)
        case .corrupt:
            reasons.append(.legacyConversationUnusable)
        case .missing:
            reasons.append(.legacyConversationUnusable)
        }

        // 扫描进度：与主日同代才可续扫。
        switch scanProbe {
        case .valid(let state) where state.generationID == day.generationID:
            snapshot.scanState = state
            snapshot.hasScanProgress = true
        case .valid:
            reasons.append(.scanStateGenerationMismatch)
            snapshot.hasScanProgress = false
        case .unsupportedVersion:
            reasons.append(.scanStateInvalid)
            snapshot.hasScanProgress = false
        case .corrupt:
            reasons.append(.scanStateInvalid)
            snapshot.hasScanProgress = false
        case .missing:
            reasons.append(.scanStateMissing)
            snapshot.hasScanProgress = false
        }

        // 日与对话不同代时不能使用日进度跳过尚未恢复的对话历史。
        if reasons.contains(where: {
            $0 == .conversationGenerationMismatch || $0 == .legacyConversationUnsupportedVersion
                || $0 == .legacyConversationUnusable
        }) {
            snapshot.hasScanProgress = false
        }
        if !snapshot.hasScanProgress { snapshot.scanState = ScanState() }

        // 周期：独立派生投影，错代时丢弃并由现有规则重建，不能连带清空主历史。
        switch cycleProbe {
        case .valid(let payload) where payload.generationID == day.generationID:
            snapshot.cycleRollup = payload
        case .valid:
            reasons.append(.cycleGenerationMismatch)
        case .unsupportedVersion:
            reasons.append(.cycleUnsupportedVersion)
        case .corrupt, .missing:
            // 文件不存在不是降级；损坏才记录。
            if case .corrupt = cycleProbe { reasons.append(.legacyCycleUnusable) }
        }

        // DSH：主历史含 DSH 分区时，贡献不可用就必须冻结该分区，不能归并空贡献。
        let historyHasDsh = day.buckets.contains { $0.app == .dsh }
            || snapshot.conversationRollup.buckets.contains { $0.app == .dsh }
        switch dshProbe {
        case .valid(let payload) where payload.generationID == day.generationID:
            snapshot.dshContributions = payload
        case .valid:
            if historyHasDsh {
                snapshot.dshHistoryFrozen = true
                reasons.append(.dshGenerationMismatch)
            }
        case .unsupportedVersion:
            if historyHasDsh {
                snapshot.dshHistoryFrozen = true
            }
            reasons.append(.dshUnsupportedVersion)
        case .corrupt:
            if historyHasDsh {
                snapshot.dshHistoryFrozen = true
            }
            reasons.append(.dshUnavailable)
        case .missing:
            if historyHasDsh {
                snapshot.dshHistoryFrozen = true
                reasons.append(.dshUnavailable)
            }
        }

        if snapshot.hasScanProgress {
            snapshot.integrity = .complete
        } else {
            snapshot.integrity = .historyWithoutProgress
        }
        snapshot.degradeReasons = Array(Set(reasons)).sorted { $0.rawValue < $1.rawValue }
        return .imported(snapshot)
    }
}
