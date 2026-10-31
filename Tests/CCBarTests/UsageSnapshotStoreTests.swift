import XCTest
@testable import CCBar

/// `UsageSnapshotStore` 的提交协议与恢复选择顺序（对应执行计划 A03 / A05 / A06 / A07）。
///
/// 全部在临时目录里跑：不读也不写用户真实的 `~/Library/Application Support/CCBar`。
final class UsageSnapshotStoreTests: XCTestCase {
    private var tempDir: URL!
    private var historyDirectory: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-snapshot-store-\(UUID().uuidString)", isDirectory: true)
        historyDirectory = tempDir.appendingPathComponent("usage-history", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    // MARK: - fixture

    private func makeSnapshot(
        snapshotID: String,
        tokens: Int = 10,
        model: String = "ccbar-test-model",
        hasProgress: Bool = true,
        integrity: UsageSnapshotIntegrity = .complete
    ) -> UsageSnapshot {
        var snapshot = UsageSnapshot()
        snapshot.snapshotID = snapshotID
        snapshot.createdAt = Date()
        snapshot.committedAt = Date()
        snapshot.integrity = integrity
        snapshot.hasScanProgress = hasProgress
        let day = UsageDay.startOfDay(for: Date(timeIntervalSince1970: 1_780_000_000))
        snapshot.usageRollup = UsageRollupPayload(
            generationID: snapshotID,
            pricingFingerprint: "fp-\(snapshotID)",
            buckets: [
                UsageBucket(
                    app: .claude,
                    model: model,
                    speed: .standard,
                    day: day,
                    inputTokens: tokens,
                    outputTokens: 0,
                    cacheReadTokens: 0,
                    cacheCreationTokens: 0,
                    costUSD: 1,
                    requestCount: 1,
                    hasUnpricedUsage: false
                )
            ],
            updatedAt: Date()
        )
        snapshot.conversationRollup = ConversationRollupPayload(
            generationID: snapshotID,
            pricingFingerprint: "fp-\(snapshotID)",
            infos: [],
            buckets: [],
            updatedAt: Date()
        )
        snapshot.cycleRollup = CycleUsageRollupPayload(
            generationID: snapshotID,
            pricingFingerprint: "fp-\(snapshotID)",
            buckets: [],
            updatedAt: Date()
        )
        snapshot.dshContributions = DshContributionPayload(
            generationID: snapshotID,
            pricingFingerprint: "fp-\(snapshotID)",
            contributions: [:],
            requiresRebuild: false,
            updatedAt: Date()
        )
        if hasProgress {
            snapshot.scanState = ScanState(generationID: snapshotID)
        } else {
            snapshot.scanState = ScanState()
        }
        return snapshot
    }

    private func makeStore() -> UsageSnapshotStore {
        UsageSnapshotStore(directory: historyDirectory)
    }

    private func tokenCount(_ result: UsageSnapshotLoadResult) -> Int? {
        result.snapshot?.usageRollup.buckets.reduce(0) { $0 + $1.inputTokens }
    }

    // MARK: - A03 提交故障：旧文件不动、重试只提交一次

    func testCommitRotatesValidCurrentToPreviousWithOriginalBytes() throws {
        let store = makeStore()
        let first = makeSnapshot(snapshotID: "gen-1", tokens: 11)
        try store.commit(first)
        let firstBytes = try XCTUnwrap(try? Data(contentsOf: store.currentFileURL))

        let second = makeSnapshot(snapshotID: "gen-2", tokens: 22)
        try store.commit(second)

        XCTAssertEqual(try Data(contentsOf: store.previousFileURL), firstBytes, "previous 必须是上一份 current 的原始字节")
        XCTAssertEqual(tokenCount(store.loadCurrent()), 22)
        XCTAssertEqual(tokenCount(store.loadPrevious()), 11)
    }

    func testEncodeFaultLeavesExistingSnapshotUntouchedAndRetryCommitsOnce() throws {
        let store = makeStore()
        try store.commit(makeSnapshot(snapshotID: "gen-1", tokens: 11))
        let before = try Data(contentsOf: store.currentFileURL)

        store.faults.fail(at: .beforeEncode)
        XCTAssertThrowsError(try store.commit(makeSnapshot(snapshotID: "gen-2", tokens: 22)))
        XCTAssertEqual(try Data(contentsOf: store.currentFileURL), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.previousFileURL.path))

        // 故障注入只命中一次：重试成功后 current 换成新提交，previous 是旧的。
        try store.commit(makeSnapshot(snapshotID: "gen-2", tokens: 22))
        XCTAssertEqual(tokenCount(store.loadCurrent()), 22)
        XCTAssertEqual(tokenCount(store.loadPrevious()), 11)
        XCTAssertEqual(store.stats.commitCount, 2)
    }

    func testPreviousRotationFaultAbortsCommitWithoutChangingCurrent() throws {
        let store = makeStore()
        try store.commit(makeSnapshot(snapshotID: "gen-1", tokens: 11))
        let currentBefore = try Data(contentsOf: store.currentFileURL)

        store.faults.fail(at: .beforePreviousRotation)
        XCTAssertThrowsError(try store.commit(makeSnapshot(snapshotID: "gen-2", tokens: 22)))
        XCTAssertEqual(try Data(contentsOf: store.currentFileURL), currentBefore)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.previousFileURL.path))

        store.faults.fail(at: .afterPreviousRotation)
        XCTAssertThrowsError(try store.commit(makeSnapshot(snapshotID: "gen-2", tokens: 22)))
        XCTAssertEqual(try Data(contentsOf: store.currentFileURL), currentBefore)
        XCTAssertEqual(tokenCount(store.loadPrevious()), 11)
    }

    func testCurrentReplaceFaultKeepsPreviousAndOriginalCurrent() throws {
        let store = makeStore()
        try store.commit(makeSnapshot(snapshotID: "gen-1", tokens: 11))
        let currentBefore = try Data(contentsOf: store.currentFileURL)

        store.faults.fail(at: .beforeCurrentReplace)
        XCTAssertThrowsError(try store.commit(makeSnapshot(snapshotID: "gen-2", tokens: 22)))
        store.faults.fail(at: .afterCurrentReplace)
        XCTAssertThrowsError(try store.commit(makeSnapshot(snapshotID: "gen-2", tokens: 22)))

        // current 已换成新提交（切换点上进程退出），previous 仍是旧的完整提交。
        XCTAssertEqual(tokenCount(store.loadCurrent()), 22)
        XCTAssertEqual(tokenCount(store.loadPrevious()), 11)
        XCTAssertNotEqual(try Data(contentsOf: store.currentFileURL), currentBefore)
    }

    // MARK: - A05 / A06 加载与恢复

    func testTruncatedCurrentFallsBackToPreviousWholesale() throws {
        let store = makeStore()
        try store.commit(makeSnapshot(snapshotID: "gen-1", tokens: 11, model: "ccbar-model-a"))
        try store.commit(makeSnapshot(snapshotID: "gen-2", tokens: 22, model: "ccbar-model-b"))

        let data = try Data(contentsOf: store.currentFileURL)
        try data.prefix(data.count / 2).write(to: store.currentFileURL)

        guard case .invalid = store.loadCurrent() else {
            return XCTFail("截断的 current 必须判为无效")
        }
        let previous = store.loadPrevious()
        guard case .valid(let snapshot) = previous else {
            return XCTFail("previous 应当是完整提交")
        }
        // 整体恢复：只出现 previous 那一代，不混合两代数据。
        XCTAssertEqual(snapshot.snapshotID, "gen-1")
        XCTAssertEqual(snapshot.usageRollup.buckets.count, 1)
        XCTAssertEqual(snapshot.usageRollup.buckets.first?.model, "ccbar-model-a")
    }

    func testUnsupportedVersionIsReportedAndNeverOverwritten() throws {
        let store = makeStore()
        try FileManager.default.createDirectory(at: historyDirectory, withIntermediateDirectories: true)
        // 伪造一份「更新版本」写下的 current。
        let future = #"{"version":999,"snapshotID":"future"}"#
        try Data(future.utf8).write(to: store.currentFileURL)
        let before = try Data(contentsOf: store.currentFileURL)

        guard case .invalid(.unsupportedVersion(let version)) = store.loadCurrent() else {
            return XCTFail("未来版本的 current 必须报 unsupportedVersion")
        }
        XCTAssertEqual(version, 999)
        XCTAssertThrowsError(try store.commit(makeSnapshot(snapshotID: "gen-1"))) { error in
            XCTAssertTrue(
                String(describing: error).contains("not committable"),
                "未隔离的不受支持 current 不允许被轮转/覆盖：\(error)"
            )
        }
        XCTAssertEqual(try Data(contentsOf: store.currentFileURL), before)
    }

    func testCorruptCurrentIsQuarantinedWithoutLosingEvidence() throws {
        let store = makeStore()
        try FileManager.default.createDirectory(at: historyDirectory, withIntermediateDirectories: true)
        let garbage = Data("not json at all".utf8)
        try garbage.write(to: store.currentFileURL)

        guard case .invalid = store.loadCurrent() else {
            return XCTFail("损坏的 current 必须判为无效")
        }
        let quarantined = try XCTUnwrap(store.quarantineCurrent())
        XCTAssertEqual(try Data(contentsOf: quarantined), garbage, "隔离文件必须保留原始字节")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.currentFileURL.path))
        guard case .missing = store.loadCurrent() else {
            return XCTFail("隔离后 current 应为缺失")
        }
    }

    func testBothSnapshotsCorruptReportsInvalidAndKeepsFiles() throws {
        let store = makeStore()
        try FileManager.default.createDirectory(at: historyDirectory, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: store.currentFileURL)
        try Data("[]".utf8).write(to: store.previousFileURL)

        guard case .invalid = store.loadCurrent() else { return XCTFail("current 应为 invalid") }
        guard case .invalid = store.loadPrevious() else { return XCTFail("previous 应为 invalid") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.currentFileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.previousFileURL.path))
    }

    // MARK: - 结构校验

    func testGenerationMismatchIsRejected() throws {
        var snapshot = makeSnapshot(snapshotID: "gen-1")
        snapshot.conversationRollup.generationID = "gen-other"
        XCTAssertThrowsError(try makeStore().commit(snapshot))
    }

    func testMissingProgressMustNotCarryScanState() {
        var snapshot = makeSnapshot(snapshotID: "gen-1", hasProgress: false, integrity: .historyWithoutProgress)
        snapshot.usageRollup.generationID = "gen-1"
        snapshot.scanState = ScanState(generationID: "gen-1")
        XCTAssertThrowsError(try makeStore().commit(snapshot)) { error in
            XCTAssertTrue(String(describing: error).contains("progress"), "\(error)")
        }
    }

    func testFrozenDshPartitionMustNotCarryContributions() {
        var snapshot = makeSnapshot(snapshotID: "gen-1")
        snapshot.dshHistoryFrozen = true
        XCTAssertThrowsError(try makeStore().commit(snapshot))
    }

    // MARK: - A07 每个阶段注入异常后重启只能看到完整提交

    func testRestartAfterAnySingleStageFaultYieldsCompleteOldOrNewSnapshot() throws {
        for point in UsageSnapshotStore.FaultPoint.allCases {
            let directory = tempDir.appendingPathComponent("fault-\(point.rawValue)", isDirectory: true)
            let store = UsageSnapshotStore(directory: directory)
            try store.commit(makeSnapshot(snapshotID: "gen-old", tokens: 11, model: "ccbar-model-old"))

            store.faults.fail(at: point)
            _ = try? store.commit(makeSnapshot(snapshotID: "gen-new", tokens: 22, model: "ccbar-model-new"))

            // 新实例（等价重启）：只能读到完整旧提交或完整新提交。
            let restarted = UsageSnapshotStore(directory: directory)
            let candidates = [restarted.loadCurrent().snapshot, restarted.loadPrevious().snapshot]
                .compactMap { $0 }
            XCTAssertFalse(candidates.isEmpty, "\(point.rawValue) 之后至少应有一份完整提交")
            for snapshot in candidates {
                XCTAssertEqual(snapshot.usageRollup.buckets.count, 1, "\(point.rawValue) 不允许混代")
                let model = snapshot.usageRollup.buckets[0].model
                XCTAssertTrue(
                    model == "ccbar-model-old" || model == "ccbar-model-new",
                    "\(point.rawValue) 出现了无法解释的混代数据：\(model)"
                )
                XCTAssertEqual(snapshot.usageRollup.generationID, snapshot.snapshotID)
                XCTAssertEqual(snapshot.conversationRollup.generationID, snapshot.snapshotID)
            }
        }
    }
}
