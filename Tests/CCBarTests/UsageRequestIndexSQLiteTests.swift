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
}
