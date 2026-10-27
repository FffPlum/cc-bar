import CryptoKit
import XCTest
@testable import CCBar

/// KimiSessionScanner 的 fixture 测试：全部写入临时注入的 share 根，不读用户真实日志。
/// 覆盖新版（JS，`agents/<agent>/wire.jsonl` 的 `usage.record`）与旧版（Python，
/// `wire.jsonl` 的 `StatusUpdate.token_usage`）两种格式、缓存口径、无 usage / 重复 /
/// 子代理 / fork 复制去重、签名未变不重读、半行不消费、截断替换、读取失败保留旧贡献，
/// 以及旧 State 缺字段兼容。费用只断言「未定价为 nil / 已定价非 nil」，不绑定具体价格。
final class KimiSessionScannerTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        PricingCatalogStore.shared.resetCatalogForTesting()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kimi-scan-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    // MARK: - 新版（~/.kimi-code）

    func testKimiCodeUsageRecordsAndMetadata() throws {
        let root = try makeRoot("kimi-code")
        let wire = try makeKimiCodeSession(root, id: "session_a", workspace: "wd_demo_a")
        try appendLines(wire, [
            #"{"type":"metadata","protocol_version":"2.0","created_at":1789430400000}"#,
            #"{"type":"profile.bind","agentId":"main","modelAlias":"kimi-code/kimi-for-coding","profileName":"default","time":1789430400001}"#,
            #"{"type":"llm.request","agentId":"main","kind":"loop","provider":"openai","model":"kimi-for-coding","modelAlias":"kimi-code/kimi-for-coding","turnStep":"0.1","time":1789430400100}"#,
            #"{"type":"usage.record","agentId":"main","model":"kimi-code/kimi-for-coding","usage":{"inputOther":5535,"output":533,"inputCacheRead":19712,"inputCacheCreation":0},"usageScope":"turn","time":1789430400200}"#,
            // 上下文占用不计：token_counting.measured 必须是独立的一行且被忽略。
            #"{"type":"token_counting.measured","agentId":"main","length":4,"tokens":25780,"time":1789430400201}"#,
            #"{"type":"llm.request","agentId":"main","kind":"loop","provider":"openai","model":"kimi-for-coding","modelAlias":"kimi-code/kimi-for-coding","turnStep":"0.2","time":1789430401000}"#,
            #"{"type":"usage.record","agentId":"main","model":"kimi-code/kimi-for-coding","usage":{"inputOther":100,"output":50,"inputCacheRead":500,"inputCacheCreation":20},"usageScope":"turn","time":1789430401100}"#,
        ])
        try writeStateJSON(
            directory: wire.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent(),
            fields: #""cwd":"/tmp/kimi-test-project","title":"修复登录页样式""#
        )

        let result = KimiSessionScanner.scan(previous: nil, roots: [root])
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.failedFileCount, 0)
        XCTAssertEqual(result.refreshedConversationIDs, ["session_a"])
        XCTAssertEqual(result.entries.count, 2)

        let first = try XCTUnwrap(result.entries.first { $0.inputTokens == 5535 })
        XCTAssertEqual(first.app, .kimi)
        XCTAssertEqual(first.conversationKey, "kimi:session_a")
        XCTAssertEqual(first.model, "kimi-code/kimi-for-coding")
        XCTAssertEqual(first.speed, .standard)
        XCTAssertEqual(first.inputTokens, 5535)   // inputOther 已排除缓存，原样入账
        XCTAssertEqual(first.outputTokens, 533)
        XCTAssertEqual(first.cacheReadTokens, 19712)
        XCTAssertEqual(first.cacheCreationTokens, 0)
        XCTAssertEqual(first.requestCount, 1)
        // kimi-for-coding 是订阅别名，未定价：token 照计，费用为 nil。
        XCTAssertNil(first.costUSD)
        XCTAssertNil(first.costBreakdown)

        let second = try XCTUnwrap(result.entries.first { $0.inputTokens == 100 })
        XCTAssertEqual(second.cacheReadTokens, 500)
        XCTAssertEqual(second.cacheCreationTokens, 20)

        let seed = try XCTUnwrap(result.conversationSeeds.first)
        XCTAssertEqual(seed.key, "kimi:session_a")
        XCTAssertEqual(seed.title, "修复登录页样式")
        XCTAssertTrue(seed.project.path.hasSuffix("kimi-test-project"))
        XCTAssertFalse(seed.includesSubtasks)
        XCTAssertTrue(seed.cacheCreationAvailable)
        XCTAssertNotNil(result.newState)
    }

    func testKimiCodePricedModelResolvesCost() throws {
        let root = try makeRoot("kimi-code")
        let wire = try makeKimiCodeSession(root, id: "session_priced", workspace: "wd_demo_b")
        try appendLines(wire, [
            #"{"type":"usage.record","agentId":"main","model":"deepseek/deepseek-v4-pro","usage":{"inputOther":1000,"output":500,"inputCacheRead":2000,"inputCacheCreation":0},"usageScope":"turn","time":1789430400000}"#,
        ])

        let result = KimiSessionScanner.scan(previous: nil, roots: [root])
        let entry = try XCTUnwrap(result.entries.first)
        XCTAssertEqual(entry.model, "deepseek/deepseek-v4-pro")
        // 该模型在现有本地价格表中有价：费用非 nil 且与 breakdown 一致。
        let cost = try XCTUnwrap(entry.costUSD)
        XCTAssertGreaterThan(cost, 0)
        XCTAssertEqual(entry.costBreakdown?.total, cost)
    }

    func testModelSwitchKeepsHistoricalNamesCostsAndCommittedEventsIndependent() throws {
        let root = try makeRoot("kimi-code")
        let wire = try makeKimiCodeSession(root, id: "session_model_switch", workspace: "wd_model_switch")
        try appendLines(wire, [
            #"{"type":"llm.request","model":"k3","modelAlias":"kimi-code/k3","time":1789430400000}"#,
            #"{"type":"usage.record","model":"kimi-code/k3","usage":{"inputOther":1000000,"output":1000000,"inputCacheRead":1000000,"inputCacheCreation":1000000},"time":1789430400100}"#,
            #"{"type":"llm.request","model":"k3.1-pro-highspeed","modelAlias":"kimi-code/k3.1-pro-highspeed","time":1789430401000}"#,
            #"{"type":"usage.record","model":"kimi-code/k3.1-pro-highspeed","usage":{"inputOther":1000000,"output":1000000,"inputCacheRead":1000000,"inputCacheCreation":1000000},"time":1789430401100}"#,
            #"{"type":"llm.request","model":"kimi-for-coding","modelAlias":"kimi-code/kimi-for-coding","time":1789430402000}"#,
            #"{"type":"usage.record","model":"kimi-code/kimi-for-coding","usage":{"inputOther":1000000,"output":1000000,"inputCacheRead":1000000,"inputCacheCreation":1000000},"time":1789430402100}"#,
        ])

        let result = KimiSessionScanner.scan(previous: nil, roots: [root])
        XCTAssertEqual(result.entries.count, 3)
        XCTAssertEqual(Set(result.entries.map(\.model)), [
            "kimi-code/k3", "kimi-code/k3.1-pro-highspeed", "kimi-code/kimi-for-coding",
        ])
        let k3 = try XCTUnwrap(result.entries.first { $0.model == "kimi-code/k3" })
        let highspeed = try XCTUnwrap(result.entries.first { $0.model == "kimi-code/k3.1-pro-highspeed" })
        let rolling = try XCTUnwrap(result.entries.first { $0.model == "kimi-code/kimi-for-coding" })
        XCTAssertEqual(k3.costUSD, Decimal(string: "21.3"))
        XCTAssertEqual(highspeed.costUSD, Decimal(string: "28.2"))
        XCTAssertNotEqual(k3.costUSD, highspeed.costUSD, "Highspeed 是独立费率，不能复用 K3 或 Fast")
        XCTAssertNil(rolling.costUSD, "滚动路由不按当前 K2.8 Preview 猜价")

        let state = try XCTUnwrap(result.newState)
        let committed = KimiSessionScanner.committedEntries(from: state)
        XCTAssertEqual(committed, result.entries)
        XCTAssertEqual(committed.map(\.timestamp), committed.map(\.timestamp).sorted())
        try FileManager.default.removeItem(at: root)
        XCTAssertEqual(KimiSessionScanner.committedEntries(from: state), committed,
                       "周期补算只读 committed state，源日志删除后贡献仍完整且顺序稳定")
    }

    func testKimiCodeSubagentFilesCountedOnce() throws {
        let root = try makeRoot("kimi-code")
        let sessionDir = try makeKimiCodeSessionDirectory(root, id: "session_sub", workspace: "wd_demo_c")
        let mainWire = sessionDir.appendingPathComponent("agents/main/wire.jsonl")
        try appendLines(mainWire, [
            #"{"type":"usage.record","agentId":"main","model":"kimi-code/k3","usage":{"inputOther":10,"output":5,"inputCacheRead":0,"inputCacheCreation":0},"usageScope":"turn","time":1789430400000}"#,
            // 父文件里的 subagent.completed 是子代理用量汇总，必须忽略（子代理自己有逐请求记录）。
            #"{"type":"subagent.completed","subagentId":"agent-0","usage":{"inputOther":7,"output":3,"inputCacheRead":70,"inputCacheCreation":0},"time":1789430400500}"#,
        ])
        let agentWire = sessionDir.appendingPathComponent("agents/agent-0/wire.jsonl")
        try appendLines(agentWire, [
            #"{"type":"usage.record","agentId":"agent-0","model":"kimi-code/k3","usage":{"inputOther":7,"output":3,"inputCacheRead":40,"inputCacheCreation":0},"usageScope":"turn","time":1789430400100}"#,
            #"{"type":"usage.record","agentId":"agent-0","model":"kimi-code/k3","usage":{"inputOther":8,"output":4,"inputCacheRead":30,"inputCacheCreation":0},"usageScope":"turn","time":1789430400200}"#,
        ])

        let result = KimiSessionScanner.scan(previous: nil, roots: [root])
        XCTAssertEqual(result.refreshedConversationIDs, ["session_sub"])
        // main 1 条 + 子代理 2 条；subagent.completed 不重复计入。
        XCTAssertEqual(result.entries.count, 3)
        XCTAssertEqual(
            result.entries.reduce(0) { $0 + $1.inputTokens }, 10 + 7 + 8
        )
        XCTAssertEqual(
            result.entries.reduce(0) { $0 + $1.cacheReadTokens }, 0 + 40 + 30
        )
        let seed = try XCTUnwrap(result.conversationSeeds.first)
        XCTAssertTrue(seed.includesSubtasks)
    }

    func testKimiCodeForkCopyDeduplicatedAcrossSessions() throws {
        let root = try makeRoot("kimi-code")
        let wireA = try makeKimiCodeSession(root, id: "session_fork_a", workspace: "wd_demo_d")
        let linesA = [
            #"{"type":"usage.record","agentId":"main","model":"kimi-code/k3","usage":{"inputOther":10,"output":5,"inputCacheRead":0,"inputCacheCreation":0},"usageScope":"turn","time":1789430400000}"#,
            #"{"type":"usage.record","agentId":"main","model":"kimi-code/k3","usage":{"inputOther":20,"output":6,"inputCacheRead":0,"inputCacheCreation":0},"usageScope":"turn","time":1789430400100}"#,
        ]
        try appendLines(wireA, linesA)

        // fork：复制源记录 + forked 标记 + 一条新请求。副本必须与源去重。
        let wireB = try makeKimiCodeSession(root, id: "session_fork_b", workspace: "wd_demo_d")
        try appendLines(wireB, linesA + [
            #"{"type":"forked","agentId":"main","time":1789430400200}"#,
            #"{"type":"usage.record","agentId":"main","model":"kimi-code/k3","usage":{"inputOther":30,"output":7,"inputCacheRead":0,"inputCacheCreation":0},"usageScope":"turn","time":1789430400300}"#,
        ])

        let result = KimiSessionScanner.scan(previous: nil, roots: [root])
        XCTAssertEqual(result.refreshedConversationIDs, ["session_fork_a", "session_fork_b"])
        let entriesA = result.entries.filter { $0.conversationKey == "kimi:session_fork_a" }
        let entriesB = result.entries.filter { $0.conversationKey == "kimi:session_fork_b" }
        XCTAssertEqual(entriesA.count, 2)
        XCTAssertEqual(entriesB.count, 1)
        XCTAssertEqual(entriesB.first?.inputTokens, 30)
        let committed = KimiSessionScanner.committedEntries(from: try XCTUnwrap(result.newState))
        XCTAssertEqual(committed.count, 3, "committed state 还原时同一签名仍只能归属一个会话")
        XCTAssertEqual(Set(committed.map(\.conversationKey)), ["kimi:session_fork_a", "kimi:session_fork_b"])
    }

    func testKimiCodeUnchangedSignatureSkipsReread() throws {
        let root = try makeRoot("kimi-code")
        let wire = try makeKimiCodeSession(root, id: "session_stable", workspace: "wd_demo_e")
        try appendLines(wire, [
            #"{"type":"usage.record","agentId":"main","model":"kimi-code/k3","usage":{"inputOther":10,"output":5,"inputCacheRead":0,"inputCacheCreation":0},"time":1789430400000}"#,
        ])

        let first = KimiSessionScanner.scan(previous: nil, roots: [root])
        XCTAssertEqual(first.entries.count, 1)
        let state = try XCTUnwrap(first.newState)

        let second = KimiSessionScanner.scan(previous: state, roots: [root])
        XCTAssertEqual(second.entries, [])
        XCTAssertEqual(second.refreshedConversationIDs, [])
        XCTAssertEqual(second.failedFileCount, 0)
        XCTAssertTrue(second.isComplete)
        XCTAssertEqual(second.newState, state)
    }

    func testKimiCodeAppendRefreshesFullContribution() throws {
        let root = try makeRoot("kimi-code")
        let wire = try makeKimiCodeSession(root, id: "session_append", workspace: "wd_demo_f")
        try appendLines(wire, [
            #"{"type":"usage.record","agentId":"main","model":"kimi-code/k3","usage":{"inputOther":10,"output":5,"inputCacheRead":0,"inputCacheCreation":0},"time":1789430400000}"#,
        ])
        let first = KimiSessionScanner.scan(previous: nil, roots: [root])
        let state = try XCTUnwrap(first.newState)

        // 同一文件内重复行（同签名）只计一次；新增行进入完整贡献，替换而非累加。
        try appendLines(wire, [
            #"{"type":"usage.record","agentId":"main","model":"kimi-code/k3","usage":{"inputOther":10,"output":5,"inputCacheRead":0,"inputCacheCreation":0},"time":1789430400000}"#,
            #"{"type":"usage.record","agentId":"main","model":"kimi-code/k3","usage":{"inputOther":40,"output":8,"inputCacheRead":0,"inputCacheCreation":0},"time":1789430401000}"#,
        ])
        let second = KimiSessionScanner.scan(previous: state, roots: [root])
        XCTAssertEqual(second.refreshedConversationIDs, ["session_append"])
        XCTAssertEqual(second.entries.count, 2)
        XCTAssertEqual(second.entries.reduce(0) { $0 + $1.inputTokens }, 10 + 40)
    }

    func testKimiCodeHalfLineNotConsumedUntilCompleted() throws {
        let root = try makeRoot("kimi-code")
        let wire = try makeKimiCodeSession(root, id: "session_half", workspace: "wd_demo_g")
        try appendLines(wire, [
            #"{"type":"usage.record","agentId":"main","model":"kimi-code/k3","usage":{"inputOther":10,"output":5,"inputCacheRead":0,"inputCacheCreation":0},"time":1789430400000}"#,
        ])
        let first = KimiSessionScanner.scan(previous: nil, roots: [root])

        // 末尾半行（无换行）：本轮只消费前面的完整行。
        try appendRaw(wire, #"{"type":"usage.record","agentId":"main","model":"kimi-code/k3","usage":{"inputOther":99"#)
        let second = KimiSessionScanner.scan(previous: first.newState, roots: [root])
        XCTAssertTrue(second.isComplete)
        XCTAssertEqual(second.entries.filter { $0.inputTokens == 99 }.count, 0)
        let afterHalf = try XCTUnwrap(second.newState)

        // 补完半行：签名变化后下一轮整条重读并计入。
        try appendRaw(wire, #","output":9,"inputCacheRead":0,"inputCacheCreation":0},"time":1789430401000}"# + "\n")
        let third = KimiSessionScanner.scan(previous: afterHalf, roots: [root])
        XCTAssertEqual(third.entries.count, 2)
        XCTAssertEqual(third.entries.reduce(0) { $0 + $1.inputTokens }, 10 + 99)
    }

    func testKimiCodeTruncatedFileReplacesContribution() throws {
        let root = try makeRoot("kimi-code")
        let wire = try makeKimiCodeSession(root, id: "session_trunc", workspace: "wd_demo_h")
        try appendLines(wire, [
            #"{"type":"usage.record","agentId":"main","model":"kimi-code/k3","usage":{"inputOther":10,"output":5,"inputCacheRead":0,"inputCacheCreation":0},"time":1789430400000}"#,
            #"{"type":"usage.record","agentId":"main","model":"kimi-code/k3","usage":{"inputOther":20,"output":6,"inputCacheRead":0,"inputCacheCreation":0},"time":1789430400100}"#,
        ])
        let first = KimiSessionScanner.scan(previous: nil, roots: [root])
        XCTAssertEqual(first.entries.count, 2)

        // 截断重写：只剩一条，整段替换后贡献不含被截掉的记录。
        try Data((#"{"type":"usage.record","agentId":"main","model":"kimi-code/k3","usage":{"inputOther":10,"output":5,"inputCacheRead":0,"inputCacheCreation":0},"time":1789430400000}"# + "\n").utf8)
            .write(to: wire)
        let second = KimiSessionScanner.scan(previous: first.newState, roots: [root])
        XCTAssertEqual(second.refreshedConversationIDs, ["session_trunc"])
        XCTAssertEqual(second.entries.count, 1)
        XCTAssertEqual(second.entries.first?.inputTokens, 10)
    }

    func testKimiCodeReadFailureKeepsOldContribution() throws {
        let root = try makeRoot("kimi-code")
        let wire = try makeKimiCodeSession(root, id: "session_fail", workspace: "wd_demo_i")
        try appendLines(wire, [
            #"{"type":"usage.record","agentId":"main","model":"kimi-code/k3","usage":{"inputOther":10,"output":5,"inputCacheRead":0,"inputCacheCreation":0},"time":1789430400000}"#,
        ])
        let first = KimiSessionScanner.scan(previous: nil, roots: [root])
        let state = try XCTUnwrap(first.newState)

        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: wire.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: wire.path) }

        let second = KimiSessionScanner.scan(previous: state, roots: [root])
        XCTAssertEqual(second.failedFileCount, 1)
        XCTAssertFalse(second.isComplete)
        XCTAssertEqual(second.entries, [])
        XCTAssertEqual(second.refreshedConversationIDs, [])
        // 不推进签名：旧贡献与旧去重记录原样保留。
        XCTAssertEqual(second.newState?.conversations["session_fail"], state.conversations["session_fail"])
        XCTAssertEqual(second.newState?.seenByConversation["session_fail"], state.seenByConversation["session_fail"])
    }

    func testKimiCodeDeletedSessionSignaturesStillSuppressForkCopies() throws {
        let root = try makeRoot("kimi-code")
        let wireA = try makeKimiCodeSession(root, id: "session_del_a", workspace: "wd_demo_j")
        let linesA = [
            #"{"type":"usage.record","agentId":"main","model":"kimi-code/k3","usage":{"inputOther":10,"output":5,"inputCacheRead":0,"inputCacheCreation":0},"time":1789430400000}"#,
        ]
        try appendLines(wireA, linesA)
        let first = KimiSessionScanner.scan(previous: nil, roots: [root])
        let state = try XCTUnwrap(first.newState)

        // 源会话删除、fork 副本出现：副本不能重复计费，源的历史贡献由调用方保留。
        try FileManager.default.removeItem(at: wireA.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent())
        let wireB = try makeKimiCodeSession(root, id: "session_del_b", workspace: "wd_demo_j")
        try appendLines(wireB, linesA + [
            #"{"type":"forked","agentId":"main","time":1789430400100}"#,
        ])

        let second = KimiSessionScanner.scan(previous: state, roots: [root])
        XCTAssertEqual(second.entries, [])
        XCTAssertEqual(second.refreshedConversationIDs, [])
        // 已删除会话的签名仍保留在 State 里。
        XCTAssertNotNil(second.newState?.conversations["session_del_a"])
    }

    func testKimiCodeZeroUsageRecordIgnored() throws {
        let root = try makeRoot("kimi-code")
        let wire = try makeKimiCodeSession(root, id: "session_zero", workspace: "wd_demo_k")
        try appendLines(wire, [
            // 失败请求落 emptyUsage（全 0），不计。
            #"{"type":"usage.record","agentId":"main","model":"kimi-code/k3","usage":{"inputOther":0,"output":0,"inputCacheRead":0,"inputCacheCreation":0},"time":1789430400000}"#,
        ])
        let result = KimiSessionScanner.scan(previous: nil, roots: [root])
        XCTAssertEqual(result.entries, [])
        XCTAssertEqual(result.refreshedConversationIDs, [])
    }

    // MARK: - 新版原生请求计时

    func testNativeStepTimingRoundTripsWithoutChangingUsage() throws {
        let root = try makeRoot("kimi-code")
        let wire = try makeKimiCodeSession(root, id: "session_timing", workspace: "wd_timing")
        try appendLines(wire, nativeStep(output: 120, firstTokenMs: 250, generationMs: 2_000))

        let result = KimiSessionScanner.scan(previous: nil, roots: [root])
        XCTAssertEqual(result.entries.count, 1)
        let entry = try XCTUnwrap(result.entries.first)
        XCTAssertEqual(entry.requestCount, 1)
        XCTAssertEqual(entry.inputTokens, 100)
        XCTAssertEqual(entry.outputTokens, 120)
        XCTAssertEqual(entry.cacheReadTokens, 20)
        XCTAssertEqual(entry.cacheCreationTokens, 5)
        XCTAssertEqual(entry.timing, RequestTiming(measuredFirstTokenMs: 250, generationMs: 2_000))
        XCTAssertEqual(entry.timing?.isEstimated, false)
        XCTAssertTrue(UsageApp.kimi.supportsGenerationTiming)
        XCTAssertTrue(UsageApp.kimi.supportsOutputSpeed)

        let aggregator = UsageAggregator()
        aggregator.ingestLocal(result.entries)
        let timing = try XCTUnwrap(aggregator.snapshotLocal().first?.timing)
        XCTAssertEqual(timing.averageFirstTokenSeconds, 0.25)
        XCTAssertEqual(timing.outputTokensPerSecond, 60)
        XCTAssertEqual(timing.estimatedGenerationMs, 0)

        let state = try XCTUnwrap(result.newState)
        XCTAssertEqual(state.version, 2)
        let restored = try JSONDecoder().decode(
            KimiSessionScanner.State.self, from: JSONEncoder().encode(state)
        )
        XCTAssertEqual(KimiSessionScanner.committedEntries(from: restored), result.entries)
        let unchanged = KimiSessionScanner.scan(previous: restored, roots: [root])
        XCTAssertTrue(unchanged.entries.isEmpty)
        XCTAssertEqual(unchanged.newState, restored)
    }

    func testSameTokensInDifferentStepsKeepTheirOwnTimingAndReplayDoesNotDuplicate() throws {
        let root = try makeRoot("kimi-code")
        let wire = try makeKimiCodeSession(root, id: "session_steps", workspace: "wd_steps")
        let first = nativeStep(step: 1, uuid: "step-one", time: 1_789_430_400_000,
                               firstTokenMs: 100, generationMs: 1_000)
        let second = nativeStep(step: 2, uuid: "step-two", time: 1_789_430_401_000,
                                firstTokenMs: 300, generationMs: 3_000)
        try appendLines(wire, first + second + [second[3]])

        let result = KimiSessionScanner.scan(previous: nil, roots: [root])
        XCTAssertEqual(result.entries.count, 2)
        XCTAssertEqual(result.entries.map(\.requestCount), [1, 1])
        XCTAssertEqual(result.entries[0].timing, RequestTiming(measuredFirstTokenMs: 100, generationMs: 1_000))
        XCTAssertEqual(result.entries[1].timing, RequestTiming(measuredFirstTokenMs: 300, generationMs: 3_000))
        XCTAssertEqual(KimiSessionScanner.committedEntries(from: try XCTUnwrap(result.newState)).count, 2)
    }

    func testRetryOtherKindMismatchAmbiguityAndInvalidTimingKeepUsageOnly() throws {
        let root = try makeRoot("kimi-code")
        let wire = try makeKimiCodeSession(root, id: "session_reject", workspace: "wd_reject")
        var lines: [String] = []
        let retry = nativeStep(step: 1, uuid: "retry", time: 1_789_430_400_000)
        lines += retry[0...1] + [retry[1]] + retry[2...3]
        lines += nativeStep(step: 2, uuid: "other-kind", time: 1_789_430_401_000, requestKind: "title")
        lines += nativeStep(step: 3, uuid: "mismatch", time: 1_789_430_402_000, endInput: 101)
        lines += nativeStep(step: 4, uuid: "invalid", time: 1_789_430_403_000, firstTokenMs: -1)
        lines += nativeStep(step: 5, uuid: "missing", time: 1_789_430_404_000, generationMs: nil)
        let ambiguous = nativeStep(step: 6, uuid: "ambiguous", time: 1_789_430_405_000)
        let secondUsage = ambiguous[2].replacingOccurrences(of: #""output":120"#, with: #""output":121"#)
        lines += ambiguous[0...2] + [secondUsage] + [ambiguous[3]]
        try appendLines(wire, lines)

        let result = KimiSessionScanner.scan(previous: nil, roots: [root])
        XCTAssertEqual(result.entries.count, 7)
        XCTAssertEqual(result.entries.reduce(0) { $0 + $1.requestCount }, 7)
        XCTAssertTrue(result.entries.allSatisfy { $0.timing == nil })
    }

    func testLenientUsageAccountingIsIndependentOfStrictTimingValidation() throws {
        let root = try makeRoot("kimi-code")
        let wire = try makeKimiCodeSession(root, id: "session_lenient_usage", workspace: "wd_lenient_usage")
        var missingInput = nativeStep(step: 1, uuid: "missing-input", time: 1_789_430_400_000,
                                      cacheRead: 0, cacheCreation: 0)
        missingInput[2] = missingInput[2].replacingOccurrences(of: #""inputOther":100,"#, with: "")
        var negativeCache = nativeStep(step: 2, uuid: "negative-cache", time: 1_789_430_401_000,
                                       cacheCreation: 0)
        negativeCache[2] = negativeCache[2].replacingOccurrences(
            of: #""inputCacheRead":20"#, with: #""inputCacheRead":-20"#
        )
        try appendLines(wire, missingInput + negativeCache)

        let result = KimiSessionScanner.scan(previous: nil, roots: [root])
        XCTAssertEqual(result.entries.count, 2)
        XCTAssertEqual(result.entries.map { $0.inputTokens + $0.outputTokens + $0.cacheReadTokens + $0.cacheCreationTokens }, [120, 220])
        XCTAssertEqual(result.entries.map(\.requestCount), [1, 1])
        XCTAssertTrue(result.entries.allSatisfy { $0.timing == nil })
    }

    func testMalformedNativeNumbersKeepUsageAndMissingEndCacheStaysCompatible() throws {
        let root = try makeRoot("kimi-code")
        let wire = try makeKimiCodeSession(root, id: "session_numbers", workspace: "wd_numbers")
        var lines: [String] = []

        var boolTiming = nativeStep(step: 1, uuid: "bool-timing", time: 1_789_430_400_000)
        boolTiming[3] = boolTiming[3].replacingOccurrences(
            of: #""llmFirstTokenLatencyMs":100"#, with: #""llmFirstTokenLatencyMs":true"#
        )
        lines += boolTiming

        var fractionalStep = nativeStep(step: 2, uuid: "fractional-step", time: 1_789_430_401_000)
        for index in [0, 3] {
            fractionalStep[index] = fractionalStep[index].replacingOccurrences(of: #""step":2"#, with: #""step":2.5"#)
        }
        lines += fractionalStep

        var boolToken = nativeStep(step: 3, uuid: "bool-token", time: 1_789_430_402_000, output: 0)
        boolToken[3] = boolToken[3].replacingOccurrences(of: #""output":0"#, with: #""output":false"#)
        lines += boolToken

        var fractionalToken = nativeStep(step: 4, uuid: "fractional-token", time: 1_789_430_403_000)
        fractionalToken[3] = fractionalToken[3].replacingOccurrences(of: #""output":120"#, with: #""output":120.5"#)
        lines += fractionalToken

        var negativeToken = nativeStep(step: 5, uuid: "negative-token", time: 1_789_430_404_000, output: 0)
        negativeToken[3] = negativeToken[3].replacingOccurrences(of: #""output":0"#, with: #""output":-1"#)
        lines += negativeToken

        var missingCache = nativeStep(step: 6, uuid: "missing-cache", time: 1_789_430_405_000,
                                      cacheRead: 0, cacheCreation: 0, generationMs: 6_000)
        missingCache[3] = missingCache[3]
            .replacingOccurrences(of: #","inputCacheRead":0"#, with: "")
            .replacingOccurrences(of: #","inputCacheCreation":0"#, with: "")
        lines += missingCache
        try appendLines(wire, lines)

        let result = KimiSessionScanner.scan(previous: nil, roots: [root])
        XCTAssertEqual(result.entries.count, 6)
        XCTAssertEqual(result.entries.compactMap(\.timing), [
            RequestTiming(measuredFirstTokenMs: 100, generationMs: 6_000),
        ])
    }

    func testNativeTimingIsIsolatedByFileAndAgent() throws {
        let root = try makeRoot("kimi-code")
        let directory = try makeKimiCodeSessionDirectory(root, id: "session_agents", workspace: "wd_agents")
        let main = directory.appendingPathComponent("agents/main/wire.jsonl")
        let child = directory.appendingPathComponent("agents/child/wire.jsonl")
        let valid = nativeStep(agent: "main", step: 1, uuid: "main-step", time: 1_789_430_400_000,
                               firstTokenMs: 100, generationMs: 1_000)
        var wrongAgentEnd = nativeStep(agent: "main", step: 2, uuid: "wrong-agent", time: 1_789_430_401_000)
        wrongAgentEnd[3] = wrongAgentEnd[3].replacingOccurrences(
                of: #""agentId":"main""#,
                with: #""agentId":"child""#
        )
        try appendLines(main, valid + wrongAgentEnd)
        try appendLines(child, nativeStep(agent: "child", step: 1, uuid: "child-step",
                                          time: 1_789_430_402_000, firstTokenMs: 300, generationMs: 3_000))

        let result = KimiSessionScanner.scan(previous: nil, roots: [root])
        XCTAssertEqual(result.entries.count, 3)
        let timed = result.entries.compactMap(\.timing)
        XCTAssertEqual(timed.count, 2)
        XCTAssertEqual(Set(timed.map(\.generationMs)), [1_000, 3_000])
    }

    func testInterleavedAgentsWithSameTurnStepKeepIndependentTiming() throws {
        let root = try makeRoot("kimi-code")
        let wire = try makeKimiCodeSession(root, id: "session_interleaved", workspace: "wd_interleaved")
        let main = nativeStep(agent: "main", step: 1, uuid: "main-step", time: 1_789_430_400_000,
                              firstTokenMs: 100, generationMs: 1_000)
        let child = nativeStep(agent: "child", step: 1, uuid: "child-step", time: 1_789_430_401_000,
                               output: 240, firstTokenMs: 300, generationMs: 3_000)
        try appendLines(wire, [
            main[0], child[0], main[1], child[1], main[2], child[2], child[3], main[3],
        ])

        let result = KimiSessionScanner.scan(previous: nil, roots: [root])
        XCTAssertEqual(result.entries.count, 2)
        XCTAssertEqual(result.entries.first { $0.outputTokens == 120 }?.timing,
                       RequestTiming(measuredFirstTokenMs: 100, generationMs: 1_000))
        XCTAssertEqual(result.entries.first { $0.outputTokens == 240 }?.timing,
                       RequestTiming(measuredFirstTokenMs: 300, generationMs: 3_000))
    }

    func testWrongAgentEndNeitherClaimsNorDiscardsPendingStep() throws {
        let root = try makeRoot("kimi-code")
        let wire = try makeKimiCodeSession(root, id: "session_wrong_agent", workspace: "wd_wrong_agent")
        let lines = nativeStep(step: 1, uuid: "shared-step", firstTokenMs: 200, generationMs: 2_000)
        let wrongAgentEnd = lines[3].replacingOccurrences(of: #""agentId":"main""#, with: #""agentId":"child""#)
        try appendLines(wire, Array(lines.prefix(3)) + [wrongAgentEnd])

        let first = KimiSessionScanner.scan(previous: nil, roots: [root])
        XCTAssertEqual(first.entries.count, 1)
        XCTAssertNil(first.entries.first?.timing)

        try appendLines(wire, [lines[3]])
        let second = KimiSessionScanner.scan(previous: first.newState, roots: [root])
        XCTAssertEqual(second.entries.count, 1)
        XCTAssertEqual(second.entries.first?.timing,
                       RequestTiming(measuredFirstTokenMs: 200, generationMs: 2_000))
    }

    func testStepEndWrittenLaterRefreshesContributionWithTiming() throws {
        let root = try makeRoot("kimi-code")
        let wire = try makeKimiCodeSession(root, id: "session_delayed", workspace: "wd_delayed")
        let lines = nativeStep(firstTokenMs: 200, generationMs: 2_000)
        try appendLines(wire, Array(lines.prefix(3)))
        let first = KimiSessionScanner.scan(previous: nil, roots: [root])
        XCTAssertEqual(first.entries.count, 1)
        XCTAssertNil(first.entries.first?.timing)

        try appendLines(wire, [lines[3]])
        let second = KimiSessionScanner.scan(previous: first.newState, roots: [root])
        XCTAssertEqual(second.refreshedConversationIDs, ["session_delayed"])
        XCTAssertEqual(second.entries.count, 1)
        XCTAssertEqual(second.entries.first?.timing, RequestTiming(measuredFirstTokenMs: 200, generationMs: 2_000))
    }

    func testStoredEventFromOldCacheDecodesWithoutTiming() throws {
        let root = try makeRoot("kimi-code")
        let wire = try makeKimiCodeSession(root, id: "session_old_event", workspace: "wd_old_event")
        try appendLines(wire, nativeStep())
        let state = try XCTUnwrap(KimiSessionScanner.scan(previous: nil, roots: [root]).newState)
        let event = try XCTUnwrap(state.fileEvents["session_old_event"]?.values.first?.first)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any]
        )
        object.removeValue(forKey: "timing")
        let decoded = try JSONDecoder().decode(
            KimiSessionScanner.StoredEvent.self, from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertNil(decoded.timing)
        XCTAssertEqual(decoded.signature, event.signature)
    }

    func testV1UpgradePreservesDeletedHistoryAndOwnershipButRereadsLiveFiles() throws {
        let root = try makeRoot("kimi-code")
        let deletedWire = try makeKimiCodeSession(root, id: "session_deleted", workspace: "wd_upgrade")
        let inherited = nativeStep(step: 1, uuid: "deleted-step", time: 1_789_430_400_000)
        try appendLines(deletedWire, inherited)

        let liveDirectory = try makeKimiCodeSessionDirectory(root, id: "session_live", workspace: "wd_upgrade")
        let liveMain = liveDirectory.appendingPathComponent("agents/main/wire.jsonl")
        let liveChild = liveDirectory.appendingPathComponent("agents/child/wire.jsonl")
        try appendLines(liveMain, nativeStep(agent: "main", step: 1, uuid: "live-main",
                                             time: 1_789_430_401_000, firstTokenMs: 200, generationMs: 2_000))
        try appendLines(liveChild, nativeStep(agent: "child", step: 1, uuid: "live-child",
                                              time: 1_789_430_402_000))
        var v1 = try XCTUnwrap(KimiSessionScanner.scan(previous: nil, roots: [root]).newState)
        v1.version = 1
        for conversation in Array(v1.fileEvents.keys) {
            for path in Array(v1.fileEvents[conversation]?.keys ?? [:].keys) {
                for index in (v1.fileEvents[conversation]?[path] ?? []).indices {
                    v1.fileEvents[conversation]?[path]?[index].timing = nil
                }
            }
        }
        try FileManager.default.removeItem(at: deletedWire.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent())
        try FileManager.default.removeItem(at: liveChild.deletingLastPathComponent())

        let fork = try makeKimiCodeSession(root, id: "session_fork", workspace: "wd_upgrade")
        try appendLines(fork, inherited + nativeStep(step: 2, uuid: "fork-new", time: 1_789_430_403_000,
                                                     firstTokenMs: 400, generationMs: 4_000))
        let upgraded = KimiSessionScanner.scan(previous: v1, roots: [root])
        XCTAssertTrue(upgraded.isComplete)
        XCTAssertEqual(upgraded.newState?.version, 2)
        XCTAssertEqual(upgraded.filesRead, 2, "现存 main 与 fork 即使签名未变也必须重读")
        XCTAssertEqual(upgraded.refreshedConversationIDs, ["session_fork", "session_live"])
        XCTAssertEqual(upgraded.entries.count, 3, "删除源的历史不在刷新结果中，fork 继承记录也不重计")
        XCTAssertNotNil(upgraded.entries.first {
            $0.conversationKey == "kimi:session_live"
                && $0.timestamp == Date(timeIntervalSince1970: 1_789_430_401)
        }?.timing)
        XCTAssertNotNil(upgraded.newState?.conversations["session_deleted"])
        XCTAssertNotNil(upgraded.newState?.seenByConversation["session_deleted"])
        XCTAssertTrue(upgraded.newState?.fileEvents["session_live"]?.keys.contains {
            $0.hasSuffix("/agents/child/wire.jsonl")
        } == true)

        let committed = KimiSessionScanner.committedEntries(from: try XCTUnwrap(upgraded.newState))
        XCTAssertEqual(committed.count, 4)
        XCTAssertEqual(committed.filter { $0.conversationKey == "kimi:session_deleted" }.count, 1)
        XCTAssertEqual(committed.filter { $0.conversationKey == "kimi:session_fork" }.count, 1)
        XCTAssertEqual(committed.filter { $0.conversationKey == "kimi:session_live" }.count, 2)
        XCTAssertNil(committed.first { $0.conversationKey == "kimi:session_deleted" }?.timing)
    }

    func testV1UpgradeReadFailureDoesNotAdvanceStateVersionOrSignature() throws {
        let root = try makeRoot("kimi-code")
        let wire = try makeKimiCodeSession(root, id: "session_upgrade_fail", workspace: "wd_upgrade_fail")
        try appendLines(wire, nativeStep())
        var v1 = try XCTUnwrap(KimiSessionScanner.scan(previous: nil, roots: [root]).newState)
        v1.version = 1
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: wire.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: wire.path) }

        let result = KimiSessionScanner.scan(previous: v1, roots: [root])
        XCTAssertFalse(result.isComplete)
        XCTAssertEqual(result.newState?.version, 1)
        XCTAssertEqual(result.newState?.conversations, v1.conversations)
        XCTAssertTrue(result.entries.isEmpty)
    }

    // MARK: - 旧版（~/.kimi）

    func testLegacyStatusUpdateCacheAccountingAndDedup() throws {
        let root = try makeRoot("kimi")
        let workPath = "/tmp/kimi-legacy-project"
        let hash = Insecure.MD5.hash(data: Data(workPath.utf8)).map { String(format: "%02x", $0) }.joined()
        let sessionDir = root
            .appendingPathComponent("sessions/\(hash)/22222222-3333-4444-5555-666666666666", isDirectory: true)
        let wire = sessionDir.appendingPathComponent("wire.jsonl")
        try appendLines(wire, [
            #"{"type":"metadata","protocol_version":"1.10"}"#,
            #"{"timestamp":1789430400.00064,"message":{"type":"TurnBegin","payload":{"user_input":"重构订单导出功能"}}}"#,
            #"{"timestamp":1789430401.0,"message":{"type":"StepBegin","payload":{"n":1}}}"#,
            // context_tokens 是上下文占用，与请求增量无关；message_id 用于去重。
            #"{"timestamp":1789430402.0,"message":{"type":"StatusUpdate","payload":{"context_usage":0.4,"context_tokens":12000,"max_context_tokens":262144,"token_usage":{"input_other":4748,"output":155,"input_cache_read":7424,"input_cache_creation":0},"message_id":"chatcmpl-AAAA","plan_mode":false}}}"#,
            // 子代理嵌套事件展开计入；其镜像文件（subagents/）不参与扫描，不会双计。
            #"{"timestamp":1789430403.0,"message":{"type":"SubagentEvent","payload":{"parent_tool_call_id":"tool_1","agent_id":"aa6cad42d","subagent_type":"coder","event":{"type":"StatusUpdate","payload":{"token_usage":{"input_other":1000,"output":200,"input_cache_read":3000,"input_cache_creation":10},"message_id":"chatcmpl-BBBB","context_tokens":9999}}}}}"#,
            // 同一 message_id 重复：只计一次。
            #"{"timestamp":1789430404.0,"message":{"type":"StatusUpdate","payload":{"token_usage":{"input_other":4748,"output":155,"input_cache_read":7424,"input_cache_creation":0},"message_id":"chatcmpl-AAAA"}}}"#,
            // 无 token_usage 的 StatusUpdate（上下文占用型）不计。
            #"{"timestamp":1789430405.0,"message":{"type":"StatusUpdate","payload":{"context_tokens":12172,"message_id":"chatcmpl-CCCC"}}}"#,
        ])
        try writeWorkDirs(root, paths: [workPath])

        let result = KimiSessionScanner.scan(previous: nil, roots: [root])
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.refreshedConversationIDs, ["22222222-3333-4444-5555-666666666666"])
        XCTAssertEqual(result.entries.count, 2)

        let main = try XCTUnwrap(result.entries.first { $0.inputTokens == 4748 })
        XCTAssertEqual(main.conversationKey, "kimi:22222222-3333-4444-5555-666666666666")
        // input_other 已排除缓存，不能再减：4748 原样入账。
        XCTAssertEqual(main.inputTokens, 4748)
        XCTAssertEqual(main.outputTokens, 155)
        XCTAssertEqual(main.cacheReadTokens, 7424)
        XCTAssertEqual(main.cacheCreationTokens, 0)
        // 旧版日志无法确认模型：token 照计，费用未定价。
        XCTAssertEqual(main.model, "unknown")
        XCTAssertNil(main.costUSD)

        let nested = try XCTUnwrap(result.entries.first { $0.inputTokens == 1000 })
        XCTAssertEqual(nested.cacheReadTokens, 3000)
        XCTAssertEqual(nested.cacheCreationTokens, 10)

        let seed = try XCTUnwrap(result.conversationSeeds.first)
        XCTAssertEqual(seed.title, "重构订单导出功能")
        XCTAssertTrue(seed.project.path.hasSuffix("kimi-legacy-project"))
        XCTAssertTrue(seed.includesSubtasks)
    }

    func testLegacyEmptyTokenUsageIgnored() throws {
        let root = try makeRoot("kimi")
        let sessionDir = root
            .appendingPathComponent("sessions/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/33333333-4444-5555-6666-777777777777", isDirectory: true)
        let wire = sessionDir.appendingPathComponent("wire.jsonl")
        try appendLines(wire, [
            #"{"timestamp":1789430400.0,"message":{"type":"StatusUpdate","payload":{"token_usage":{"input_other":0,"output":0,"input_cache_read":0,"input_cache_creation":0},"message_id":"chatcmpl-ZERO"}}}"#,
        ])
        let result = KimiSessionScanner.scan(previous: nil, roots: [root])
        XCTAssertEqual(result.entries, [])
        XCTAssertEqual(result.refreshedConversationIDs, [])
    }

    // MARK: - 多根与状态兼容

    func testBothRootsScannedInOnePass() throws {
        let codeRoot = try makeRoot("kimi-code")
        let wireNew = try makeKimiCodeSession(codeRoot, id: "session_multi_new", workspace: "wd_multi")
        try appendLines(wireNew, [
            #"{"type":"usage.record","agentId":"main","model":"kimi-code/k3","usage":{"inputOther":1,"output":1,"inputCacheRead":0,"inputCacheCreation":0},"time":1789430400000}"#,
        ])
        let legacyRoot = try makeRoot("kimi")
        let sessionDir = legacyRoot
            .appendingPathComponent("sessions/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/44444444-5555-6666-7777-888888888888", isDirectory: true)
        let wireLegacy = sessionDir.appendingPathComponent("wire.jsonl")
        try appendLines(wireLegacy, [
            #"{"timestamp":1789430400.0,"message":{"type":"StatusUpdate","payload":{"token_usage":{"input_other":2,"output":2,"input_cache_read":0,"input_cache_creation":0},"message_id":"chatcmpl-MULTI"}}}"#,
        ])

        let result = KimiSessionScanner.scan(previous: nil, roots: [codeRoot, legacyRoot])
        XCTAssertEqual(result.entries.count, 2)
        XCTAssertEqual(
            result.refreshedConversationIDs,
            ["44444444-5555-6666-7777-888888888888", "session_multi_new"]
        )
    }

    func testStateDecodeToleratesMissingFields() throws {
        // 旧快照缺少 version / seenByConversation：按空值解码，不抛错。
        let json = #"{"conversations":{}}"#.data(using: .utf8)!
        let state = try JSONDecoder().decode(KimiSessionScanner.State.self, from: json)
        XCTAssertEqual(state.version, 0)
        XCTAssertEqual(state.conversations, [:])
        XCTAssertEqual(state.seenByConversation, [:])

        // version 与当前不符时按无基线整段重扫。
        let root = try makeRoot("kimi-code")
        let wire = try makeKimiCodeSession(root, id: "session_compat", workspace: "wd_compat")
        try appendLines(wire, [
            #"{"type":"usage.record","agentId":"main","model":"kimi-code/k3","usage":{"inputOther":1,"output":1,"inputCacheRead":0,"inputCacheCreation":0},"time":1789430400000}"#,
        ])
        let result = KimiSessionScanner.scan(previous: state, roots: [root])
        XCTAssertEqual(result.entries.count, 1)
        XCTAssertEqual(result.refreshedConversationIDs, ["session_compat"])
    }

    // MARK: - fixture 工具

    private func makeRoot(_ name: String) throws -> URL {
        let root = tempDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @discardableResult
    private func makeKimiCodeSessionDirectory(_ root: URL, id: String, workspace: String) throws -> URL {
        let sessionDir = root.appendingPathComponent("sessions/\(workspace)/\(id)", isDirectory: true)
        let agentsMain = sessionDir.appendingPathComponent("agents/main", isDirectory: true)
        try FileManager.default.createDirectory(at: agentsMain, withIntermediateDirectories: true)
        return sessionDir
    }

    @discardableResult
    private func makeKimiCodeSession(_ root: URL, id: String, workspace: String) throws -> URL {
        let sessionDir = try makeKimiCodeSessionDirectory(root, id: id, workspace: workspace)
        return sessionDir.appendingPathComponent("agents/main/wire.jsonl")
    }

    private func appendLines(_ url: URL, _ lines: [String]) throws {
        let text = lines.joined(separator: "\n") + "\n"
        try appendRaw(url, text)
    }

    private func appendRaw(_ url: URL, _ raw: String) throws {
        let data = Data(raw.utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url)
        }
    }

    private func nativeStep(
        agent: String = "main",
        step: Int = 1,
        uuid: String = "native-step",
        time: Int64 = 1_789_430_400_000,
        endInput: Int = 100,
        output: Int = 120,
        cacheRead: Int = 20,
        cacheCreation: Int = 5,
        requestKind: String = "loop",
        firstTokenMs: Int = 100,
        generationMs: Int? = 2_000
    ) -> [String] {
        let generation = generationMs.map { "\"llmStreamDurationMs\":\($0)," } ?? ""
        return [
            #"{"type":"context.append_loop_event","agentId":"\#(agent)","event":{"type":"step.begin","uuid":"\#(uuid)","turnId":"0","step":\#(step),"time":\#(time)}}"#,
            #"{"type":"context.append_loop_event","agentId":"\#(agent)","event":{"type":"llm.request","kind":"\#(requestKind)","model":"kimi-code/k3","turnStep":"0.\#(step)","time":\#(time)}}"#,
            #"{"type":"context.append_loop_event","agentId":"\#(agent)","event":{"type":"usage.record","model":"kimi-code/k3","usage":{"inputOther":100,"output":\#(output),"inputCacheRead":\#(cacheRead),"inputCacheCreation":\#(cacheCreation)},"time":\#(time)}}"#,
            #"{"type":"context.append_loop_event","agentId":"\#(agent)","event":{"llmFirstTokenLatencyMs":\#(firstTokenMs),\#(generation)"type":"step.end","uuid":"\#(uuid)","turnId":"0","step":\#(step),"usage":{"inputOther":\#(endInput),"output":\#(output),"inputCacheRead":\#(cacheRead),"inputCacheCreation":\#(cacheCreation)},"time":\#(time)}}"#,
        ]
    }

    private func writeStateJSON(directory: URL, fields: String) throws {
        let json = "{\(fields)}"
        try Data(json.utf8).write(to: directory.appendingPathComponent("state.json"))
    }

    private func writeWorkDirs(_ root: URL, paths: [String]) throws {
        let entries = paths.map { "{\"path\":\"\($0)\"}" }.joined(separator: ",")
        try Data("{\"work_dirs\":[\(entries)]}".utf8)
            .write(to: root.appendingPathComponent("kimi.json"))
    }
}
