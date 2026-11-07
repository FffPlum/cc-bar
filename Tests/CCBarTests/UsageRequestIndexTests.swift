import XCTest
import Observation
@testable import CCBar

final class UsageRequestIndexTests: XCTestCase {
    /// Test fixtures contain only a few rows. Exercise the production bounded SQL
    /// query rather than restoring a full index even in lifecycle assertions.
    @MainActor
    private func page(_ service: UsageService, app: UsageApp) throws -> [UsageRequestIndexStore.Row] {
        let result = try service.requestIndexStore.query(
            .init(apps: [app], from: .distantPast, to: .distantFuture,
                  page: .init(offset: 0, limit: 10)),
            canonical: service.aggregator.snapshotLocal())
        XCTAssertLessThanOrEqual(result.totalCount, 10, "Fixture must fit a bounded test page")
        XCTAssertEqual(result.rows.count, result.totalCount)
        return result.rows
    }

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

    func testRequestIDsPreserveCanonicalFormat() throws {
        let entry = UsageEntry(app: .codex, conversationKey: "codex:test", model: "model", speed: .standard,
                               day: Date(timeIntervalSince1970: 0), timestamp: Date(timeIntervalSince1970: 3600),
                               inputTokens: 1, outputTokens: 2, cacheReadTokens: 0, cacheCreationTokens: 0,
                               costUSD: nil, costBreakdown: nil)
        let cost = try XCTUnwrap(Decimal(string: "12.3400", locale: Locale(identifier: "en_US_POSIX")))
        let timed = UsageEntry(app: .claude, conversationKey: "会话:一", model: "provider/模型:fast", speed: .fast,
                               day: Date(timeIntervalSince1970: 0), timestamp: Date(timeIntervalSince1970: 1_800_000_000.25),
                               inputTokens: 1200, outputTokens: 34, cacheReadTokens: 560, cacheCreationTokens: 78,
                               requestCount: 0, costUSD: cost, costBreakdown: nil,
                               timing: RequestTiming(firstTokenMs: 42, generationMs: 345))
        var estimated = timed
        estimated.timing = RequestTiming(firstTokenMs: nil, generationMs: 345, isEstimated: true)
        var sameIDFields = entry
        sameIDFields.day = Date(timeIntervalSince1970: 86400)
        var excluded = entry
        excluded.requestCount = -1

        let records = UsageRequestIndex.records(from: [timed, sameIDFields, excluded, estimated, entry])
        // Pin persisted IDs, including UTF-8 byte lengths, optional fields and duplicate ordinals.
        XCTAssertEqual(records.map(\.id), [
            "1acb3441e7eaac9327d01692b40b38e7b13095c31a167c7c61e90bb51174fda1-0",
            "1acb3441e7eaac9327d01692b40b38e7b13095c31a167c7c61e90bb51174fda1-1",
            "4fd9d45dedd07175cbd3f361c3d2393008015322aa02811c35510059dbb19b33-0",
            "67b8d2f70c6b4934692a9cdf23a6dcfbea562cf41d613756d75d08fb0a121919-0",
        ])
        XCTAssertEqual(records.filter { $0.entry.requestCount == 0 }.count, 2)
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
        await service.synchronizeRequestIndexForTesting()
        let initial = service.requestIndexStatusForDisplay()
        let initialRows = try page(service, app: .claude)
        XCTAssertEqual(initialRows.count, 1)
        XCTAssertEqual(service.aggregator.snapshotLocal(), before)
        await service.synchronizeRequestIndexForTesting()
        let cached = service.requestIndexStatusForDisplay()
        XCTAssertEqual(cached.revision, initial.revision)
        await service.scanNow()
        await service.synchronizeRequestIndexForTesting()
        let updated = service.requestIndexStatusForDisplay()
        let updatedRows = try page(service, app: .claude)
        XCTAssertEqual(updatedRows.count, 2)
        XCTAssertNotEqual(updated.revision, initial.revision)
        let restarted = env.makeService()
        await env.bootstrap(restarted)
        await restarted.synchronizeRequestIndexForTesting()
        XCTAssertEqual(try page(restarted, app: .claude).count, 1)
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
        await service.synchronizeRequestIndexForTesting()
        let initial = service.requestIndexStatusForDisplay()
        let initialRows = try page(service, app: .claude)
        XCTAssertEqual(initialRows.count, 1)
        // If Claude were rescanned here, its temporarily unavailable file would yield no record.
        try FileManager.default.removeItem(at: file)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        service.aggregator.ingestLocal([UsageEntry(app: .codex, conversationKey: "codex:test",
            model: "model", speed: .standard, day: date, timestamp: date, inputTokens: 1,
            outputTokens: 1, cacheReadTokens: 0, cacheCreationTokens: 0, costUSD: nil, costBreakdown: nil)])
        await service.synchronizeRequestIndexForTesting()
        let updated = service.requestIndexStatusForDisplay()
        let updatedRows = try page(service, app: .claude)
        XCTAssertEqual(updatedRows.map(\.id),
                       initialRows.map(\.id))
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
        await service.synchronizeRequestIndexForTesting()
        let records = try page(service, app: .codex)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.input, 90)
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
        await service.synchronizeRequestIndexForTesting()
        let initial = service.requestIndexStatusForDisplay()
        let initialRows = try page(service, app: .claude)
        let oldRecords = initialRows
        XCTAssertEqual(oldRecords.count, 1)
        let data = try Data(contentsOf: file)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        service.aggregator.ingestLocal([UsageEntry(app: .claude, conversationKey: "claude:other",
            model: "model", speed: .standard, day: date, timestamp: date, inputTokens: 1,
            outputTokens: 1, cacheReadTokens: 0, cacheCreationTokens: 0, costUSD: nil, costBreakdown: nil)])
        let duringChange = service.requestIndexStatusForDisplay()
        XCTAssertEqual(try page(service, app: .claude).map(\.id), oldRecords.map(\.id))
        XCTAssertEqual(duringChange.revision, initial.revision)
        try Data().write(to: file)
        await service.synchronizeRequestIndexForTesting()
        let failed = service.requestIndexStatusForDisplay()
        XCTAssertTrue(failed.retryableApps.contains(.claude))
        XCTAssertTrue(failed.incompleteApps.contains(.claude))
        XCTAssertEqual(try page(service, app: .claude).map(\.id), oldRecords.map(\.id))
        let displayFailed = service.requestIndexStatusForDisplay()
        XCTAssertTrue(displayFailed.isReady)
        XCTAssertTrue(displayFailed.incompleteApps.contains(.claude))
        try data.write(to: file)
        await service.synchronizeRequestIndexForTesting()
        let recovered = service.requestIndexStatusForDisplay()
        XCTAssertFalse(recovered.retryableApps.contains(.claude))
        XCTAssertFalse(recovered.incompleteApps.contains(.claude))
        XCTAssertEqual(try page(service, app: .claude).map(\.id), oldRecords.map(\.id))
    }
    @MainActor
    func testSidecarLoadsDuringPausedScanAndWarmCompletesAfterward() async throws {
        let env = try UsageTestEnvironment(name: "request-index-paused-scan")
        let line = env.claudeLine(id: "first", session: "session", model: "model", timestamp: "2026-09-20T01:00:00Z", input: 100, output: 10)
        _ = try env.writeClaudeLog(session: "session", lines: [line])
        let first = env.makeService()
        await env.bootstrap(first)
        await first.scanNow()
        await first.synchronizeRequestIndexForTesting()
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
        if restarted.requestIndexStatusForDisplay().isReady {
            loaded.fulfill()
        } else {
            withObservationTracking {
                _ = restarted.requestIndexRevision
            } onChange: { loaded.fulfill() }
        }
        await fulfillment(of: [loaded], timeout: 3)
        let cached = restarted.requestIndexStatusForDisplay()
        XCTAssertTrue(cached.isReady)
        XCTAssertEqual(try page(restarted, app: .claude).count, 1)
        XCTAssertTrue(cached.isRefreshing)
        let revision = restarted.requestIndexRevision
        for _ in 0..<20 { _ = restarted.requestIndexStatusForDisplay() }
        XCTAssertEqual(restarted.requestIndexRevision, revision)
        restarted.scanStartedForIndexTesting = nil
        resume?.resume()
        resume = nil
        await scan.value
        await restarted.waitForRequestIndexForTesting()
        XCTAssertFalse(restarted.requestIndexStatusForDisplay().isRefreshing)
        XCTAssertEqual(try page(restarted, app: .claude).count, 1)
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
        await first.synchronizeRequestIndexForTesting()
        let original = try page(first, app: .kimi)
        XCTAssertEqual(original.count, 1)
        await first.waitForRequestIndexForTesting()
        try FileManager.default.removeItem(at: share)
        let restarted = makeService()
        await env.bootstrap(restarted)
        await restarted.waitForRequestIndexForTesting()
        let restored = restarted.requestIndexStatusForDisplay()
        XCTAssertEqual(try page(restarted, app: .kimi).map(\.id), original.map(\.id))
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
        guard case .ready(let metadata) = store.loadMetadata() else {
            return XCTFail("Expected SQLite source metadata")
        }
        XCTAssertEqual(metadata.sourceKeys[.claude], String(repeating: "a", count: 64))
        let query = UsageRequestIndexStore.Query(apps: [.claude], from: .distantPast, to: .distantFuture,
                                                page: .init(offset: 0, limit: 1))
        let canonical = [UsageBucket(app: .claude, model: "model", speed: .standard, day: date,
            inputTokens: 2, outputTokens: 1, cacheReadTokens: 0, cacheCreationTokens: 0,
            costUSD: 0, requestCount: 1, hasUnpricedUsage: true)]
        XCTAssertEqual(try store.query(query, canonical: canonical).rows.count, 1)
        try Data("bad".utf8).write(to: url)
        // Query failure is not a successful empty page; startup can quarantine and rebuild it.
        XCTAssertThrowsError(try store.query(query, canonical: canonical))
        guard case .needsRebuild = store.loadMetadata() else {
            return XCTFail("Confirmed corruption should rebuild the derived index")
        }
    }
    @MainActor
    func testRestartUsesPersistedIndexWithoutScanningUnchangedSource() async throws {
        let env = try UsageTestEnvironment(name: "request-index-persisted")
        let line = env.claudeLine(id: "first", session: "session", model: "model",
            timestamp: "2026-09-20T01:00:00Z", input: 100, output: 10)
        let file = try env.writeClaudeLog(session: "session", lines: [line])
        let service = env.makeService()
        let beforeBootstrap = service.requestIndexStatusForDisplay()
        XCTAssertTrue(beforeBootstrap.isRefreshing)
        XCTAssertFalse(beforeBootstrap.isReady)
        XCTAssertFalse(Mirror(reflecting: beforeBootstrap).children.contains { ["records", "rows"].contains($0.label ?? "") })
        await env.bootstrap(service)
        await service.scanNow()
        await service.synchronizeRequestIndexForTesting()
        await service.waitForRequestIndexForTesting()
        let before = service.requestIndexStatusForDisplay()
        XCTAssertTrue(before.isReady)
        XCTAssertEqual(try page(service, app: .claude).count, 1)
        try FileManager.default.removeItem(at: file)
        let restarted = env.makeService()
        await env.bootstrap(restarted)
        await restarted.waitForRequestIndexForTesting()
        let restored = restarted.requestIndexStatusForDisplay()
        // A rescan of the removed source could not produce this record.
        XCTAssertEqual(try page(restarted, app: .claude).count, 1)
        XCTAssertFalse(restored.isRefreshing)
        let calculations = restarted.requestIndexFingerprintCalculations
        for _ in 0..<50 { _ = restarted.requestIndexStatusForDisplay() }
        XCTAssertEqual(restarted.requestIndexFingerprintCalculations, calculations)
    }
}
