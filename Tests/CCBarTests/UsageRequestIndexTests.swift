import XCTest
import Observation
@testable import CCBar

final class UsageRequestIndexTests: XCTestCase {
    func testIdenticalRequestsRemainDistinctAndIDsAreStable() {
        let entry = UsageEntry(app: .codex, conversationKey: "codex:test", model: "model", speed: .standard,
                               day: Date(timeIntervalSince1970: 0), timestamp: Date(timeIntervalSince1970: 3600),
                               inputTokens: 1, outputTokens: 2, cacheReadTokens: 0, cacheCreationTokens: 0,
                               costUSD: nil, costBreakdown: nil)
        var advisor = entry
        advisor.requestCount = 0
        var later = entry
        later.timestamp = Date(timeIntervalSince1970: 7200)
        let first = UsageRequestIndex.records(from: [entry, advisor, later, entry])
        let second = UsageRequestIndex.records(from: [later, entry, advisor, entry])
        XCTAssertEqual(first.count, 4)
        XCTAssertEqual(Set(first.map(\.id)).count, 4)
        XCTAssertEqual(first.map(\.id), second.map(\.id))
        XCTAssertEqual(first.reduce(0) { $0 + $1.entry.requestCount }, 3)
        XCTAssertEqual(first.filter { $0.entry.requestCount == 0 }.count, 1)
    }
    @MainActor
    func testReadOnlyIndexLoadsAndRefreshesFromIsolatedLogs() async throws {
        let env = try UsageTestEnvironment(name: "request-index")
        let firstLine = env.claudeLine(id: "first", session: "session", model: "model",
            timestamp: "2026-09-20T01:00:00Z", input: 100, output: 10)
        let file = try env.writeClaudeLog(session: "session", lines: [firstLine])
        let service = env.makeService()
        await env.bootstrap(service)
        await service.scanNow()
        let secondLine = env.claudeLine(id: "second", session: "session", model: "model",
            timestamp: "2026-09-20T02:00:00Z", input: 100, output: 10)
        try env.append(secondLine, to: file)
        let before = service.aggregator.snapshotLocal()
        let initial = await service.requestIndexSnapshot()
        XCTAssertEqual(initial.records.filter { $0.entry.app == .claude }.count, 1)
        XCTAssertEqual(service.aggregator.snapshotLocal(), before)
        let cached = await service.requestIndexSnapshot()
        XCTAssertEqual(cached.revision, initial.revision)
        await service.scanNow()
        let updated = await service.requestIndexSnapshot()
        XCTAssertEqual(updated.records.filter { $0.entry.app == .claude }.count, 2)
        XCTAssertNotEqual(updated.revision, initial.revision)
        let restarted = env.makeService()
        await env.bootstrap(restarted)
        let restored = await restarted.requestIndexSnapshot()
        XCTAssertEqual(restored.records.filter { $0.entry.app == .claude }.count, 1)
    }
    @MainActor
    func testUnchangedSourceReusesRecordsWhenAnotherSourceChanges() async throws {
        let env = try UsageTestEnvironment(name: "request-index-partitions")
        let line = env.claudeLine(id: "first", session: "session", model: "model",
            timestamp: "2026-09-20T01:00:00Z", input: 100, output: 10)
        let file = try env.writeClaudeLog(session: "session", lines: [line])
        let service = env.makeService()
        await env.bootstrap(service)
        await service.scanNow()
        let initial = await service.requestIndexSnapshot()
        XCTAssertEqual(initial.records.filter { $0.entry.app == .claude }.count, 1)
        // If Claude were rescanned here, its temporarily unavailable file would yield no record.
        try FileManager.default.removeItem(at: file)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        service.aggregator.ingestLocal([UsageEntry(app: .codex, conversationKey: "codex:test",
            model: "model", speed: .standard, day: date, timestamp: date, inputTokens: 1,
            outputTokens: 1, cacheReadTokens: 0, cacheCreationTokens: 0, costUSD: nil, costBreakdown: nil)])
        let updated = await service.requestIndexSnapshot()
        XCTAssertEqual(updated.records.filter { $0.entry.app == .claude }.map(\.id),
                       initial.records.filter { $0.entry.app == .claude }.map(\.id))
        XCTAssertNotEqual(updated.revision, initial.revision)
    }
    @MainActor
    func testCodexReplayStopsAtAcceptedOffset() async throws {
        let env = try UsageTestEnvironment(name: "request-index-codex-boundary")
        let initialLines = env.codexLines(id: "session", model: "gpt-5", timestampPrefix: "2026-09-20T01:00:00",
            input: 100, cachedInput: 10, output: 20)
        let file = try env.writeCodexLog(id: "session", lines: initialLines)
        let service = env.makeService()
        await env.bootstrap(service)
        await service.scanNow()
        let later = env.codexLines(id: "session", model: "gpt-5", timestampPrefix: "2026-09-20T02:00:00",
            input: 200, cachedInput: 20, output: 40)
        for line in later { try env.append(line, to: file) }
        let result = await service.requestIndexSnapshot()
        let records = result.records.filter { $0.entry.app == .codex }
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.entry.inputTokens, 90)
    }
    @MainActor
    func testTemporaryReadFailureRetainsRecordsAndRetriesWithoutRevisionChange() async throws {
        let env = try UsageTestEnvironment(name: "request-index-retry")
        let line = env.claudeLine(id: "first", session: "session", model: "model",
            timestamp: "2026-09-20T01:00:00Z", input: 100, output: 10)
        let file = try env.writeClaudeLog(session: "session", lines: [line])
        let service = env.makeService()
        await env.bootstrap(service)
        await service.scanNow()
        let initial = await service.requestIndexSnapshot()
        let oldRecords = initial.records.filter { $0.entry.app == .claude }
        XCTAssertEqual(oldRecords.count, 1)
        let data = try Data(contentsOf: file)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        service.aggregator.ingestLocal([UsageEntry(app: .claude, conversationKey: "claude:other",
            model: "model", speed: .standard, day: date, timestamp: date, inputTokens: 1,
            outputTokens: 1, cacheReadTokens: 0, cacheCreationTokens: 0, costUSD: nil, costBreakdown: nil)])
        let duringChange = service.requestIndexSnapshotForDisplay()
        XCTAssertEqual(duringChange.records.filter { $0.entry.app == .claude }.map(\.id), oldRecords.map(\.id))
        XCTAssertEqual(duringChange.revision, initial.revision)
        try Data().write(to: file)
        let failed = await service.requestIndexSnapshot()
        XCTAssertTrue(failed.retryableApps.contains(.claude))
        XCTAssertTrue(failed.incompleteApps.contains(.claude))
        XCTAssertEqual(failed.records.filter { $0.entry.app == .claude }.map(\.id), oldRecords.map(\.id))
        let displayFailed = service.requestIndexSnapshotForDisplay()
        XCTAssertEqual(displayFailed.records.filter { $0.entry.app == .claude }.map(\.id), oldRecords.map(\.id))
        XCTAssertTrue(displayFailed.incompleteApps.contains(.claude))
        try data.write(to: file)
        let recovered = await service.requestIndexSnapshot()
        XCTAssertFalse(recovered.retryableApps.contains(.claude))
        XCTAssertFalse(recovered.incompleteApps.contains(.claude))
        XCTAssertEqual(recovered.records.filter { $0.entry.app == .claude }.map(\.id), oldRecords.map(\.id))
    }
    @MainActor
    func testSidecarLoadsDuringPausedScanAndWarmCompletesAfterward() async throws {
        let env = try UsageTestEnvironment(name: "request-index-paused-scan")
        let line = env.claudeLine(id: "first", session: "session", model: "model", timestamp: "2026-09-20T01:00:00Z", input: 100, output: 10)
        _ = try env.writeClaudeLog(session: "session", lines: [line])
        let first = env.makeService()
        await env.bootstrap(first)
        await first.scanNow()
        _ = await first.requestIndexSnapshot()
        await first.waitForRequestIndexForTesting()
        let restarted = env.makeService()
        await env.bootstrap(restarted)
        let started = expectation(description: "scan paused")
        var resume: CheckedContinuation<Void, Never>?
        defer { resume?.resume() }
        restarted.scanStartedForIndexTesting = {
            started.fulfill()
            await withCheckedContinuation { resume = $0 }
        }
        let scan = Task { await restarted.scanNow() }
        await fulfillment(of: [started], timeout: 3)
        let loaded = expectation(description: "sidecar published during scan")
        if restarted.requestIndexSnapshotForDisplay().records.contains(where: { $0.entry.app == .claude }) {
            loaded.fulfill()
        } else {
            withObservationTracking {
                _ = restarted.requestIndexRevision
            } onChange: { loaded.fulfill() }
        }
        await fulfillment(of: [loaded], timeout: 3)
        let cached = restarted.requestIndexSnapshotForDisplay()
        XCTAssertEqual(cached.records.filter { $0.entry.app == .claude }.count, 1)
        XCTAssertTrue(cached.isRefreshing)
        let revision = restarted.requestIndexRevision
        for _ in 0..<20 { _ = restarted.requestIndexSnapshotForDisplay() }
        XCTAssertEqual(restarted.requestIndexRevision, revision)
        restarted.scanStartedForIndexTesting = nil
        resume?.resume()
        resume = nil
        await scan.value
        await restarted.waitForRequestIndexForTesting()
        XCTAssertFalse(restarted.requestIndexSnapshotForDisplay().isRefreshing)
        XCTAssertEqual(restarted.requestIndexSnapshotForDisplay().records.filter { $0.entry.app == .claude }.count, 1)
    }

    @MainActor
    func testKimiCommittedIndexSurvivesRestartWithoutRescan() async throws {
        let env = try UsageTestEnvironment(name: "request-index-kimi-restart")
        let share = env.root.appendingPathComponent("kimi-code")
        let wire = share.appendingPathComponent("sessions/work/session/agents/main/wire.jsonl")
        try env.append("{\"type\":\"usage.record\",\"agentId\":\"main\",\"model\":\"kimi-code/kimi-for-coding\",\"usage\":{\"inputOther\":100,\"output\":10,\"inputCacheRead\":20,\"inputCacheCreation\":5},\"usageScope\":\"turn\",\"time\":1792000000000}", to: wire)
        var roots = env.scanRoots
        roots.kimiRoots = [share]
        func makeService() -> UsageService {
            UsageService(historyStore: env.store, roots: roots, legacyLocations: env.legacyLocations,
                         backfillURL: env.backfillURL, cursorCacheDirectory: env.cursorCacheDirectory)
        }
        let first = makeService()
        await env.bootstrap(first)
        await first.scanNow()
        let original = await first.requestIndexSnapshot()
        XCTAssertEqual(original.records.filter { $0.entry.app == .kimi }.count, 1)
        await first.waitForRequestIndexForTesting()
        try FileManager.default.removeItem(at: share)
        let restarted = makeService()
        await env.bootstrap(restarted)
        await restarted.waitForRequestIndexForTesting()
        let restored = restarted.requestIndexSnapshotForDisplay()
        XCTAssertEqual(restored.records.filter { $0.entry.app == .kimi }.map(\.id), original.records.filter { $0.entry.app == .kimi }.map(\.id))
        XCTAssertFalse(restored.incompleteApps.contains(.kimi))
    }

    @MainActor
    func testSidecarRoundTripIsPrivateAndRejectsCorruption() throws {
        let env = try UsageTestEnvironment(name: "request-index-sidecar")
        let store = UsageRequestIndexStore(directory: env.historyDirectory)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let row = UsageRequestIndexStore.Row(id: "opaque-0", conversationHash: UsageRequestIndexStore.hash("private-session"),
            app: .claude, model: "model", speed: .standard, day: date, timestamp: date, input: 2, output: 1,
            cacheRead: 0, cacheCreation: 0, requests: 1, cost: nil, costInput: nil, costOutput: nil,
            costRead: nil, costCreation: nil, timing: nil)
        try store.save(.init(version: 1, sourceKeys: [.claude: String(repeating: "a", count: 64)],
            incompleteApps: [], rows: [row]))
        let url = env.historyDirectory.appendingPathComponent("request-index.sqlite3")
        let data = try Data(contentsOf: url)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private-session"))
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(store.load()?.rows.count, 1)
        try Data("bad".utf8).write(to: url)
        XCTAssertNil(store.load())
    }
    @MainActor
    func testRestartUsesPersistedIndexWithoutScanningUnchangedSource() async throws {
        let env = try UsageTestEnvironment(name: "request-index-persisted")
        let line = env.claudeLine(id: "first", session: "session", model: "model",
            timestamp: "2026-09-20T01:00:00Z", input: 100, output: 10)
        let file = try env.writeClaudeLog(session: "session", lines: [line])
        let service = env.makeService()
        let beforeBootstrap = service.requestIndexSnapshotForDisplay()
        XCTAssertTrue(beforeBootstrap.isRefreshing)
        XCTAssertTrue(beforeBootstrap.records.isEmpty)
        await env.bootstrap(service)
        await service.scanNow()
        _ = await service.requestIndexSnapshot()
        await service.waitForRequestIndexForTesting()
        let before = service.requestIndexSnapshotForDisplay()
        XCTAssertEqual(before.records.filter { $0.entry.app == .claude }.count, 1)
        try FileManager.default.removeItem(at: file)
        let restarted = env.makeService()
        await env.bootstrap(restarted)
        await restarted.waitForRequestIndexForTesting()
        let restored = restarted.requestIndexSnapshotForDisplay()
        // A rescan of the removed source could not produce this record.
        XCTAssertEqual(restored.records.filter { $0.entry.app == .claude }.count, 1)
        XCTAssertFalse(restored.isRefreshing)
        let calculations = restarted.requestIndexFingerprintCalculations
        for _ in 0..<50 { _ = restarted.requestIndexSnapshotForDisplay() }
        XCTAssertEqual(restarted.requestIndexFingerprintCalculations, calculations)
    }
}
