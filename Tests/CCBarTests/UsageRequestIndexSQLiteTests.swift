import XCTest
import SQLite3
@testable import CCBar

/// Real SQLite checks in isolated directories; never opens production usage history.
final class UsageRequestIndexSQLiteTests: XCTestCase {
    private var directory: URL!
    private var databaseURL: URL { directory.appendingPathComponent("request-index.sqlite3") }
    private var legacyURL: URL { directory.appendingPathComponent("request-index-v1.json") }
    private var store: UsageRequestIndexStore { UsageRequestIndexStore(directory: directory) }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("request-index-sqlite-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func fingerprint(_ value: String) -> String { UsageRequestIndexStore.hash(value) }

    private func row(
        id: String = "row-a", app: UsageApp = .codex, tokens: Int = 12,
        cost: Decimal? = nil, timing: RequestTiming? = nil
    ) -> UsageRequestIndexStore.Row {
        UsageRequestIndexStore.Row(
            id: id, conversationHash: fingerprint("private-session-path"), app: app,
            model: "model'特殊", speed: .unknown,
            day: Date(timeIntervalSince1970: 1_800_000_000),
            timestamp: Date(timeIntervalSince1970: 1_800_000_123.125),
            input: tokens, output: 9, cacheRead: 3, cacheCreation: 2, requests: 1,
            cost: cost, costInput: cost, costOutput: cost == nil ? nil : 0,
            costRead: cost == nil ? nil : 0, costCreation: cost == nil ? nil : 0,
            timing: timing
        )
    }

    private func payload(
        _ rows: [UsageRequestIndexStore.Row],
        keys: [UsageApp: String]? = nil,
        incomplete: Set<UsageApp> = []
    ) -> UsageRequestIndexStore.Payload {
        let defaults = Dictionary(rows.map { ($0.app, fingerprint($0.app.rawValue)) },
            uniquingKeysWith: { first, _ in first })
        return .init(version: 1, sourceKeys: keys ?? defaults, incompleteApps: incomplete, rows: rows)
    }

    private func writeLegacy(_ value: UsageRequestIndexStore.Payload) throws {
        try JSONEncoder().encode(value).write(to: legacyURL)
    }

    private func withDatabase<T>(_ action: (OpaquePointer) throws -> T) throws -> T {
        var connection: OpaquePointer?
        let code = sqlite3_open_v2(databaseURL.path, &connection, SQLITE_OPEN_READWRITE, nil)
        guard code == SQLITE_OK, let connection else {
            if let connection { sqlite3_close(connection) }
            throw SQLiteFailure(code: code)
        }
        defer { sqlite3_close(connection) }
        return try action(connection)
    }

    private func execute(_ connection: OpaquePointer, _ sql: String) throws {
        let code = sqlite3_exec(connection, sql, nil, nil, nil)
        guard code == SQLITE_OK else { throw SQLiteFailure(code: code) }
    }

    private func scalar(_ connection: OpaquePointer, _ sql: String) throws -> String {
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(connection, sql, -1, &statement, nil)
        guard code == SQLITE_OK, let statement else { throw SQLiteFailure(code: code) }
        defer { sqlite3_finalize(statement) }
        let step = sqlite3_step(statement)
        guard step == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else {
            throw SQLiteFailure(code: step)
        }
        return String(cString: value)
    }

    private struct SQLiteFailure: Error { let code: Int32 }

    func testRoundTripPreservesDecimalNullTimingAndPrivatePermissions() throws {
        let precise = try XCTUnwrap(Decimal(string: "123456789.123456789123456789"))
        let timing = RequestTiming(firstTokenMs: nil, generationMs: 1234, isEstimated: true)
        let priced = row(tokens: 1_000_000_000_000, cost: precise, timing: timing)
        let unpriced = row(id: "row-b", app: .kimi)
        try store.save(payload([priced, unpriced], incomplete: [.cursor, .dsh]))

        let restored = try XCTUnwrap(store.load())
        let value = try XCTUnwrap(restored.rows.first { $0.id == priced.id })
        XCTAssertEqual(value.cost, precise)
        XCTAssertEqual(value.costInput, precise)
        XCTAssertEqual(value.costOutput, 0)
        XCTAssertEqual(value.timing, timing)
        XCTAssertEqual(value.input, 1_000_000_000_000)
        XCTAssertEqual(value.timestamp, priced.timestamp)
        XCTAssertEqual(value.day, priced.day)
        XCTAssertEqual(value.model, priced.model)
        XCTAssertEqual(value.speed, .unknown)
        XCTAssertNil(restored.rows.first { $0.id == unpriced.id }?.cost)
        XCTAssertNil(restored.rows.first { $0.id == unpriced.id }?.timing)
        XCTAssertEqual(restored.incompleteApps, [.cursor, .dsh])
        XCTAssertEqual(restored.sourceKeys, payload([priced, unpriced]).sourceKeys)

        let data = try Data(contentsOf: databaseURL)
        XCTAssertEqual(data.prefix(16), Data("SQLite format 3\0".utf8))
        XCTAssertNil(data.range(of: Data("private-session-path".utf8)))
        let attributes = try FileManager.default.attributesOfItem(atPath: databaseURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try withDatabase { connection in
            XCTAssertEqual(try scalar(connection, "PRAGMA user_version"), "1")
            XCTAssertEqual(try scalar(connection, "PRAGMA application_id"), String(0x43434252))
            XCTAssertEqual(try scalar(connection, "SELECT typeof(cost) FROM requests WHERE id='row-a'"), "text")
            XCTAssertEqual(try scalar(connection, "SELECT typeof(cost) FROM requests WHERE id='row-b'"), "null")
        }
    }

    func testExistingLegacyJSONIsIgnoredAndPreserved() throws {
        try writeLegacy(payload([row(id: "legacy")]))
        let before = try Data(contentsOf: legacyURL)
        XCTAssertNil(store.load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.path))
        XCTAssertEqual(try Data(contentsOf: legacyURL), before)
        try store.save(payload([row(id: "fresh-sqlite")]))
        XCTAssertEqual(store.load()?.rows.map(\.id), ["fresh-sqlite"])
        try writeLegacy(payload([row(id: "later-legacy")]))
        XCTAssertEqual(store.load()?.rows.map(\.id), ["fresh-sqlite"])
    }

    func testInvalidLegacyDoesNotChangeAuthoritativeHistory() throws {
        let current = directory.appendingPathComponent("current.json")
        let previous = directory.appendingPathComponent("previous.json")
        let sentinel = Data("authoritative-history-is-not-a-cache".utf8)
        try sentinel.write(to: current)
        try sentinel.write(to: previous)
        let invalid = Data("{not valid json".utf8)
        try invalid.write(to: legacyURL)
        XCTAssertNil(store.load())
        XCTAssertEqual(try Data(contentsOf: legacyURL), invalid)
        XCTAssertEqual(try Data(contentsOf: current), sentinel)
        XCTAssertEqual(try Data(contentsOf: previous), sentinel)
        XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.path))
    }

    func testFutureSchemaVersionIsPreservedRatherThanReset() throws {
        try store.save(payload([row()]))
        try withDatabase { try execute($0, "PRAGMA user_version=999") }
        let before = try Data(contentsOf: databaseURL)
        XCTAssertNil(store.load())
        XCTAssertThrowsError(try store.save(payload([row(id: "new")])))
        if case .unavailable = store.loadResult() {} else { XCTFail("A future schema must not request rebuilding") }
        XCTAssertEqual(try Data(contentsOf: databaseURL), before)
        try withDatabase { XCTAssertEqual(try scalar($0, "PRAGMA user_version"), "999") }
    }

    func testBusyDatabaseRemainsIntactAndWorksAfterLockIsReleased() throws {
        let initial = payload([row()])
        try store.save(initial)
        let before = try Data(contentsOf: databaseURL)
        try withDatabase { connection in
            try execute(connection, "BEGIN EXCLUSIVE")
            defer { try? execute(connection, "ROLLBACK") }
            XCTAssertNil(store.load())
            if case .unavailable = store.loadResult() {} else { XCTFail("A busy cache must be retried, not rebuilt") }
            XCTAssertThrowsError(try store.save(payload([row(id: "blocked")], keys: [.codex: fingerprint("new")])))
            XCTAssertEqual(try Data(contentsOf: databaseURL), before)
        }
        XCTAssertEqual(store.load()?.rows.map(\.id), ["row-a"])
        try store.save(payload([row(id: "after-lock")], keys: [.codex: fingerprint("new")]))
        XCTAssertEqual(store.load()?.rows.map(\.id), ["after-lock"])
    }

    func testCorruptionRebuildDoesNotResurrectLegacyOrTouchHistory() throws {
        try writeLegacy(payload([row(id: "old-json")]))
        try store.save(payload([row(id: "before-corruption")]))
        let current = directory.appendingPathComponent("current.json")
        let sentinel = Data("keep-authoritative-history".utf8)
        try sentinel.write(to: current)
        let oldJSON = try Data(contentsOf: legacyURL)
        try Data("not-a-sqlite-database".utf8).write(to: databaseURL)
        XCTAssertNil(store.load())
        XCTAssertNil(store.load(), "Established SQLite must not fall back to the stale JSON")
        try store.save(payload([row(id: "rebuilt")], keys: [.codex: fingerprint("rebuilt")]))
        XCTAssertEqual(store.load()?.rows.map(\.id), ["rebuilt"])
        XCTAssertEqual(try Data(contentsOf: legacyURL), oldJSON)
        XCTAssertEqual(try Data(contentsOf: current), sentinel)
    }

    func testUnchangedSourceRowsAreNotRewrittenWhileStatusAndOtherSourceAdvance() throws {
        let initial = payload([row(id: "codex-original"), row(id: "claude-old", app: .claude)])
        try store.save(initial)
        try withDatabase { connection in
            try execute(connection, """
                CREATE TRIGGER no_codex_delete BEFORE DELETE ON requests
                WHEN OLD.app='codex' BEGIN SELECT RAISE(ABORT, 'unchanged source deleted'); END;
                CREATE TRIGGER no_codex_insert BEFORE INSERT ON requests
                WHEN NEW.app='codex' BEGIN SELECT RAISE(ABORT, 'unchanged source inserted'); END;
                CREATE TRIGGER no_codex_update BEFORE UPDATE ON requests
                WHEN OLD.app='codex' BEGIN SELECT RAISE(ABORT, 'unchanged source updated'); END;
                """)
        }
        let next = payload([row(id: "codex-original"), row(id: "claude-new", app: .claude)],
            keys: [.codex: fingerprint("codex"), .claude: fingerprint("claude-next")], incomplete: [.codex, .cursor])
        try store.save(next)
        let restored = try XCTUnwrap(store.load())
        XCTAssertEqual(Set(restored.rows.map(\.id)), ["codex-original", "claude-new"])
        XCTAssertEqual(restored.incompleteApps, [.codex, .cursor])
        XCTAssertEqual(restored.sourceKeys, next.sourceKeys)
    }

    func testFailedUpdateRollsBackRowsAndSourceMetadataTogether() throws {
        let initial = payload([row(id: "codex-original"), row(id: "claude-original", app: .claude)])
        try store.save(initial)
        try withDatabase { connection in
            try execute(connection, """
                CREATE TRIGGER fail_claude_insert BEFORE INSERT ON requests
                WHEN NEW.app='claude' BEGIN SELECT RAISE(ABORT, 'simulated insert failure'); END;
                """)
        }
        let next = payload([row(id: "codex-new"), row(id: "claude-new", app: .claude)],
            keys: [.codex: fingerprint("codex-next"), .claude: fingerprint("claude-next")], incomplete: [.codex])
        XCTAssertThrowsError(try store.save(next))
        let restored = try XCTUnwrap(store.load())
        XCTAssertEqual(Set(restored.rows.map(\.id)), ["codex-original", "claude-original"])
        XCTAssertEqual(restored.sourceKeys, initial.sourceKeys)
        XCTAssertEqual(restored.incompleteApps, initial.incompleteApps)
    }

    func testUnknownFingerprintIsRewrittenAndRemovedSourcesAreDeleted() throws {
        try store.save(payload([row(id: "unknown"), row(id: "claude", app: .claude)],
            keys: [.claude: fingerprint("claude")], incomplete: [.codex]))
        try store.save(payload([row(id: "unknown-next")], keys: [:], incomplete: [.codex]))
        let restored = try XCTUnwrap(store.load())
        XCTAssertEqual(restored.rows.map(\.id), ["unknown-next"])
        XCTAssertTrue(restored.sourceKeys.isEmpty)
        XCTAssertEqual(restored.incompleteApps, [.codex])
    }

    private var utcCalendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(secondsFromGMT: 0)!
        return result
    }
    private var queryDay: Date { utcCalendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000)) }
    private func queryRow(_ id: String, app: UsageApp = .codex, model: String = "gpt-test", offset: TimeInterval = 100,
                          input: Int = 10, output: Int = 200, cost: Decimal? = 1,
                          timing: RequestTiming? = nil) -> UsageRequestIndexStore.Row {
        .init(id: id, conversationHash: fingerprint("conversation"), app: app, model: model, speed: .unknown,
            day: queryDay, timestamp: queryDay.addingTimeInterval(offset), input: input, output: output,
            cacheRead: 2, cacheCreation: 3, requests: 1, cost: cost,
            costInput: cost, costOutput: nil, costRead: nil, costCreation: nil, timing: timing)
    }
    private func canonical(_ rows: [UsageRequestIndexStore.Row]) -> [UsageBucket] {
        // Input can contain repeated partitions; the query must combine canonical buckets in SQL.
        rows.map { row in
            var timing = GenerationTiming.zero
            timing.add(row.timing, outputTokens: row.output)
            return UsageBucket(app: row.app, model: row.model, speed: row.speed, day: row.day,
                inputTokens: row.input, outputTokens: row.output, cacheReadTokens: row.cacheRead,
                cacheCreationTokens: row.cacheCreation, costUSD: row.cost ?? 0, requestCount: row.requests,
                hasUnpricedUsage: row.cost == nil, timing: timing)
        }
    }
    private func query(apps: Set<UsageApp> = [.codex, .claude], model: String? = nil,
                       from: TimeInterval = 0, to: TimeInterval = 86400,
                       hourly: Bool = false, page: UsageRequestIndexStore.Page? = nil) -> UsageRequestIndexStore.Query {
        .init(apps: apps, model: model, from: queryDay.addingTimeInterval(from), to: queryDay.addingTimeInterval(to),
            calendar: utcCalendar, hourly: hourly, page: page)
    }

    func testSQLFiltersPagesAndDecimalSortingAreExact() throws {
        let base = Decimal(string: "123456789.123456789123456789")!
        let rows = [queryRow("c", cost: base), queryRow("a", cost: base),
            queryRow("b", cost: base + Decimal(string: "0.000000000000000001")!),
            queryRow("other-app", app: .claude), queryRow("other-model", model: "other"),
            queryRow("at-exclusive-end", offset: 200)]
        try store.save(payload(rows))
        let q = query(apps: [.codex], model: "gpt-test", from: 100, to: 200,
            page: .init(offset: 0, limit: 2, sort: "cost", descending: true))
        let first = try store.query(q, canonical: canonical(rows))
        XCTAssertEqual(first.totalCount, 3)
        XCTAssertEqual(first.rows.map(\.id), ["b", "a"])
        XCTAssertEqual(first.buckets.count, 1)
        XCTAssertEqual(first.buckets[0].requestCount, 3)
        XCTAssertEqual(first.buckets[0].costUSD, base * 3 + Decimal(string: "0.000000000000000001")!)
        var next = q
        next.page?.offset = 2
        XCTAssertEqual(try store.query(next, canonical: canonical(rows)).rows.map(\.id), ["c"])
        next.page?.offset = 100
        XCTAssertTrue(try store.query(next, canonical: canonical(rows)).rows.isEmpty)
        next.model = "x' OR 1=1 --"
        XCTAssertEqual(try store.query(next, canonical: canonical(rows)).totalCount, 0)
    }

    func testSQLAggregatesTimingAndRetainsFullPartitionCoverageForPartialRange() throws {
        let rows = [queryRow("a", offset: 100, timing: RequestTiming(firstTokenMs: 50, generationMs: 1000)),
            queryRow("b", offset: 3700, cost: nil, timing: RequestTiming(firstTokenMs: nil, generationMs: 2000, isEstimated: true)),
            queryRow("c", offset: 7300, output: 5, timing: RequestTiming(firstTokenMs: 100, generationMs: 1))]
        try store.save(payload(rows))
        let results = try store.queryBatch([query(from: 0, to: 7200, hourly: true), query(from: 3600, to: 7200)], canonical: canonical(rows))
        XCTAssertEqual(results[0].metadata.revision, results[1].metadata.revision)
        XCTAssertEqual(results[0].buckets.map(\.day), [queryDay, queryDay.addingTimeInterval(3600)])
        XCTAssertEqual(results[0].buckets[0].timing.firstTokenMs, 50)
        XCTAssertEqual(results[0].buckets[0].timing.timedOutputTokens, 200)
        XCTAssertEqual(results[0].buckets[1].timing.estimatedGenerationMs, 2000)
        XCTAssertTrue(results[0].buckets[1].hasUnpricedUsage)
        XCTAssertEqual(results[1].buckets[0].requestCount, 1)
        XCTAssertEqual(results[1].partitions[0].requestCount, 3)
        XCTAssertEqual(results[1].partitions[0].timing.firstTokenMs, 150)
        XCTAssertTrue(results[1].rows.isEmpty, "Aggregate-only queries must never return request rows")
    }

    func testSQLRejectsUnacceptedPartitionAndMarksPricingMismatch() throws {
        let rows = [queryRow("a"), queryRow("b", app: .claude)]
        try store.save(payload(rows))
        var buckets = canonical(rows)
        buckets[0].inputTokens = 1
        buckets[1].costUSD = 2
        let result = try store.query(query(page: .init(offset: 0, limit: 20)), canonical: buckets)
        XCTAssertEqual(result.rows.map(\.id), ["b"])
        XCTAssertEqual(result.pendingPartitions.map(\.app), [.codex])
        XCTAssertEqual(result.pricingMismatches.map(\.app), [.claude])
        XCTAssertTrue(result.buckets[0].costIncomplete)
    }

    func testMetadataDoesNotDecodeDetailsAndMalformedAggregateIsNotSilentlyAccepted() throws {
        let rows = [queryRow("a")]
        try store.save(payload(rows))
        try withDatabase { try execute($0, "UPDATE requests SET cost='12junk'") }
        guard case .ready(let first) = store.loadMetadata() else { return XCTFail("Metadata must not load rows") }
        guard case .ready(let second) = store.loadMetadata() else { return XCTFail("Metadata must remain readable") }
        XCTAssertEqual(first.revision, second.revision)
        XCTAssertThrowsError(try store.query(query(), canonical: canonical(rows))) { error in
            XCTAssertTrue(UsageRequestIndexStore.queryFailureRequiresRebuild(error))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.path), "Confirmed damaged details are quarantined")
    }

    func testPartialWritesPreserveUntouchedRowsAndFailedSourceMetadata() throws {
        let first = [queryRow("codex"), queryRow("claude", app: .claude)]
        try store.save(payload(first))
        guard case .ready(let before) = store.loadMetadata() else { return XCTFail("Expected metadata") }
        try store.saveChanges(payload([queryRow("new-claude", app: .claude)],
            keys: [.codex: fingerprint("codex"), .claude: fingerprint("changed")], incomplete: [.codex]), replacingApps: [.claude])
        guard case .ready(let after) = store.loadMetadata() else { return XCTFail("Expected metadata") }
        XCTAssertNotEqual(before.revision, after.revision)
        XCTAssertEqual(after.incompleteApps, [.codex])
        XCTAssertEqual(Set(store.load()?.rows.map(\.id) ?? []), ["codex", "new-claude"])
    }

    func testConcurrentReadersUseIndependentSharedReadTransactions() async throws {
        let rows = (0..<200).map { queryRow(String($0), offset: Double($0)) }
        try store.save(payload(rows))
        let store = self.store
        let request = query(page: .init(offset: 50, limit: 10))
        let canonical = canonical(rows)
        let counts = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<8 {
                group.addTask { try store.query(request, canonical: canonical).rows.count }
            }
            var values: [Int] = []
            for try await count in group { values.append(count) }
            return values
        }
        XCTAssertEqual(counts, Array(repeating: 10, count: 8))
    }


    func testSQLHourlyBucketsPreserveBothOccurrencesOfDaylightSavingHour() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1)))
        let end = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: start))
        XCTAssertEqual(end.timeIntervalSince(start), 25 * 3600)
        let rows = [5400.0, 9000.0].enumerated().map { index, offset in
            UsageRequestIndexStore.Row(id: "dst-\(index)", conversationHash: fingerprint("dst"), app: .codex,
                model: "gpt-test", speed: .unknown, day: start, timestamp: start.addingTimeInterval(offset),
                input: 1, output: 2, cacheRead: 0, cacheCreation: 0, requests: 1,
                cost: 1, costInput: nil, costOutput: nil, costRead: nil, costCreation: nil, timing: nil)
        }
        try store.save(payload(rows))
        let result = try store.query(.init(apps: [.codex], from: start, to: end, calendar: calendar, hourly: true), canonical: canonical(rows))
        XCTAssertEqual(result.buckets.map { $0.day.timeIntervalSince(start) }, [3600, 7200])
        XCTAssertEqual(result.buckets.map(\.requestCount), [1, 1])
        XCTAssertEqual(result.partitions[0].requestCount, 2)
    }

    func testDecimalAggregateOverflowPreservesDatabase() throws {
        let rows = [queryRow("a", cost: NSDecimalNumber.maximum.decimalValue),
            queryRow("b", cost: NSDecimalNumber.maximum.decimalValue)]
        try store.save(payload(rows))
        XCTAssertThrowsError(try store.query(query(), canonical: canonical(rows))) { error in
            XCTAssertFalse(UsageRequestIndexStore.queryFailureRequiresRebuild(error))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: databaseURL.path))
        guard case .ready = store.loadMetadata() else { return XCTFail("Overflow must preserve readable metadata") }
    }


    func testSQLRejectsMalformedAndOutOfRangeStoredCounts() throws {
        let rows = [queryRow("a")]
        for invalid in ["'not-a-count'", "-1", "1000000000001"] {
            try store.save(payload(rows))
            try withDatabase { try execute($0, "UPDATE requests SET input=\(invalid)") }
            XCTAssertThrowsError(try store.query(query(), canonical: canonical(rows))) { error in
                XCTAssertTrue(UsageRequestIndexStore.queryFailureRequiresRebuild(error))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.path))
        }
    }

}
