import Foundation
import SQLite3

nonisolated extension UsageRequestIndexStore {
    struct Metadata: Sendable {
        let sourceKeys: [UsageApp: String]
        let incompleteApps: Set<UsageApp>
        let revision: String
    }
    enum MetadataResult: Sendable {
        case ready(Metadata), needsRebuild, unavailable
    }
    struct Partition: Hashable, Sendable {
        let app: UsageApp
        let model: String
        let speed: UsageSpeed
        let day: Date
    }
    struct Page: Sendable {
        var offset: Int
        var limit: Int
        var sort: String = "time"
        var descending: Bool = true
    }
    struct Query: Sendable {
        var apps: Set<UsageApp>
        var model: String? = nil
        var from: Date
        var to: Date
        var calendar: Calendar = .current
        var hourly: Bool = false
        var page: Page? = nil
    }
    struct QueryResult: Sendable {
        let buckets: [UsageBucket]
        let partitions: [UsageBucket]
        let pendingPartitions: Set<Partition>
        let pricingMismatches: Set<Partition>
        let rows: [Row]
        let totalCount: Int
        let metadata: Metadata
    }

    /// Startup reads only source metadata. Request rows stay in SQLite.
    func loadMetadata() -> MetadataResult {
        guard FileManager.default.fileExists(atPath: url.path) else { return .needsRebuild }
        do {
            return try withLock {
                do {
                    let db = try Connection(url: url, create: false)
                    try db.execute("BEGIN")
                    defer { try? db.execute("ROLLBACK") }
                    try validateSchema(db)
                    try db.execute("CREATE INDEX IF NOT EXISTS requests_partition ON requests(app,model,speed,day)")
                    let value = try metadata(db)
                    try db.execute("COMMIT")
                    return .ready(value)
                } catch let error as StoreError where error.isCorruption {
                    try quarantine()
                    return .needsRebuild
                }
            }
        } catch { return .unavailable }
    }

    private func metadata(_ db: Connection) throws -> Metadata {
        let sources = try readSources(db)
        let revision: String
        if try db.scalarInt("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='cache_metadata'") > 0 {
            revision = try db.scalarText("SELECT value FROM cache_metadata WHERE key='revision'")
        } else {
            // v1 databases created before query-side reads acquire a transaction revision
            // on their next write. Their source metadata is stable in the meantime.
            revision = Self.hash(sources.sorted { $0.key.rawValue < $1.key.rawValue }.map {
                "\($0.key.rawValue):\($0.value.fingerprint ?? ""): \($0.value.incomplete)"
            }.joined(separator: "|"))
        }
        return Metadata(sourceKeys: sources.compactMapValues(\.fingerprint),
            incompleteApps: Set(sources.filter { $0.value.incomplete }.keys), revision: revision)
    }

    func query(_ query: Query, canonical: [UsageBucket]) throws -> QueryResult {
        try queryBatch([query], canonical: canonical)[0]
    }

    /// Related facets, coverage, chart buckets and a page share one database snapshot.
    /// All detail selection, sorting, counting and aggregation occur in SQLite.
    func queryBatch(_ queries: [Query], canonical: [UsageBucket]) throws -> [QueryResult] {
        do { return try withLock(shared: true) {
            let db = try Connection(url: url, create: false)
            try db.registerQueryFunctions()
            try db.execute("BEGIN")
            defer { try? db.execute("ROLLBACK") }
            try validateSchema(db)
            let metadata = try metadata(db)
            try installCanonical(canonical, db: db)
            var results: [QueryResult] = []
            for query in queries {
                try Task.checkCancellation()
                guard query.from < query.to, query.from.timeIntervalSince1970.isFinite,
                      query.to.timeIntervalSince1970.isFinite else { throw StoreError.invalidQuery }
                if let page = query.page {
                    guard page.offset >= 0, (1...500).contains(page.limit),
                          ["time", "cost", "tokens"].contains(page.sort) else { throw StoreError.invalidQuery }
                }
                results.append(try runQuery(query, metadata: metadata, db: db))
            }
            try db.execute("COMMIT")
            return results
        } } catch let error as StoreError where error.isCorruption {
            // Release the shared query lock before quarantining; never rename a live
            // connection's database or mistake a bad filter for damaged stored data.
            try? withLock { try quarantine() }
            throw error
        }
    }

    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if case .sqlite(let code) = error as? StoreError { return code & 0xff == SQLITE_INTERRUPT }
        return false
    }

    static func queryFailureRequiresRebuild(_ error: Error) -> Bool {
        (error as? StoreError)?.isCorruption ?? false
    }

    private func installCanonical(_ buckets: [UsageBucket], db: Connection) throws {
        try db.execute("CREATE TEMP TABLE canonical_input(app TEXT,model TEXT,speed TEXT,day REAL,input INTEGER,output INTEGER,cache_read INTEGER,cache_creation INTEGER,requests INTEGER,cost TEXT)")
        let insert = try db.prepare("INSERT INTO canonical_input VALUES(?,?,?,?,?,?,?,?,?,?)")
        defer { sqlite3_finalize(insert) }
        for b in buckets {
            try db.bind([.text(b.app.rawValue), .text(b.model), .text(b.speed.rawValue), .real(b.day.timeIntervalSince1970),
                .integer(Int64(b.inputTokens)), .integer(Int64(b.outputTokens)), .integer(Int64(b.cacheReadTokens)),
                .integer(Int64(b.cacheCreationTokens)), .integer(Int64(b.requestCount)), .text(NSDecimalNumber(decimal: b.costUSD).stringValue)], to: insert)
            _ = try db.step(insert)
            try db.check(sqlite3_reset(insert)); try db.check(sqlite3_clear_bindings(insert))
        }
        try db.execute("""
            CREATE TEMP TABLE canonical AS SELECT app,model,speed,day,SUM(input) input,SUM(output) output,
                SUM(cache_read) cache_read,SUM(cache_creation) cache_creation,SUM(requests) requests,
                decimal_sum(cost) cost FROM canonical_input GROUP BY app,model,speed,day;
            CREATE UNIQUE INDEX canonical_key ON canonical(app,model,speed,day);
            DROP TABLE canonical_input;
            """)
    }

    private static let aggregateColumns = """
        SUM(CASE WHEN typeof(r.input)='integer' AND r.input BETWEEN 0 AND 1000000000000 THEN r.input ELSE invalid_cache() END) input,SUM(CASE WHEN typeof(r.output)='integer' AND r.output BETWEEN 0 AND 1000000000000 THEN r.output ELSE invalid_cache() END) output,SUM(CASE WHEN typeof(r.cache_read)='integer' AND r.cache_read BETWEEN 0 AND 1000000000000 THEN r.cache_read ELSE invalid_cache() END) cache_read,SUM(CASE WHEN typeof(r.cache_creation)='integer' AND r.cache_creation BETWEEN 0 AND 1000000000000 THEN r.cache_creation ELSE invalid_cache() END) cache_creation,
        SUM(CASE WHEN typeof(r.requests)='integer' AND r.requests BETWEEN 0 AND 1000000000000 THEN r.requests ELSE invalid_cache() END) requests,decimal_sum(r.cost) cost,MAX(r.cost IS NULL) unpriced,
        SUM(json_extract(r.timing,'$.firstTokenMs') IS NOT NULL) first_count,
        SUM(COALESCE(json_extract(r.timing,'$.firstTokenMs'),0)) first_ms,
        SUM(CASE WHEN r.output>=100 AND json_extract(r.timing,'$.generationMs')>=500 AND COALESCE(json_extract(r.timing,'$.isEstimated'),0)=0 THEN r.output ELSE 0 END) timed_output,
        SUM(CASE WHEN r.output>=100 AND json_extract(r.timing,'$.generationMs')>=500 AND COALESCE(json_extract(r.timing,'$.isEstimated'),0)=0 THEN json_extract(r.timing,'$.generationMs') ELSE 0 END) generation_ms,
        SUM(CASE WHEN r.output>=100 AND json_extract(r.timing,'$.generationMs')>=500 AND json_extract(r.timing,'$.isEstimated')=1 THEN r.output ELSE 0 END) estimated_output,
        SUM(CASE WHEN r.output>=100 AND json_extract(r.timing,'$.generationMs')>=500 AND json_extract(r.timing,'$.isEstimated')=1 THEN json_extract(r.timing,'$.generationMs') ELSE 0 END) estimated_ms
        """
    private static let bucketColumns = "app,model,speed,day,input,output,cache_read,cache_creation,requests,cost,unpriced,first_count,first_ms,timed_output,generation_ms,estimated_output,estimated_ms"
    private static let partitionJoin = "r.app=v.app AND r.model=v.model AND r.speed=v.speed AND r.day=v.day"

    private func runQuery(_ q: Query, metadata: Metadata, db: Connection) throws -> QueryResult {
        let apps = q.apps.sorted { $0.rawValue < $1.rawValue }
        let marks = apps.map { _ in "?" }.joined(separator: ",")
        let fromDay = q.calendar.startOfDay(for: q.from).timeIntervalSince1970
        var values: [Value] = apps.map { .text($0.rawValue) } + [.real(fromDay), .real(q.to.timeIntervalSince1970)]
        let modelClause: String
        if let model = q.model { modelClause = " AND c.model=?"; values.append(.text(model)) }
        else { modelClause = "" }
        try db.execute("DROP TABLE IF EXISTS temp.verified; DROP TABLE IF EXISTS temp.partition_totals; DROP TABLE IF EXISTS temp.query_intervals")
        let sql = """
            CREATE TEMP TABLE partition_totals AS
            SELECT r.app,r.model,r.speed,r.day,\(Self.aggregateColumns)
            FROM canonical c JOIN requests r ON r.app=c.app AND r.model=c.model AND r.speed=c.speed AND r.day=c.day
            WHERE c.app IN (\(marks)) AND c.day>=? AND c.day<?\(modelClause)
            GROUP BY r.app,r.model,r.speed,r.day
            """
        try db.run(sql, values)
        try db.execute("""
            CREATE TEMP TABLE verified AS SELECT p.*,
                (p.input<=c.input AND p.output<=c.output AND p.cache_read<=c.cache_read AND p.cache_creation<=c.cache_creation AND p.requests<=c.requests) accepted,
                (p.cost COLLATE DECIMAL != c.cost COLLATE DECIMAL) mismatch
            FROM partition_totals p JOIN canonical c ON p.app=c.app AND p.model=c.model AND p.speed=c.speed AND p.day=c.day;
            CREATE UNIQUE INDEX verified_key ON verified(app,model,speed,day);
            """)
        var partitions: [UsageBucket] = []
        var pending: Set<Partition> = []
        var mismatches: Set<Partition> = []
        let verified = try db.prepare("SELECT \(Self.bucketColumns),accepted,mismatch FROM verified")
        defer { sqlite3_finalize(verified) }
        while try db.step(verified) {
            var bucket = try readBucket(verified)
            let key = Partition(app: bucket.app, model: bucket.model, speed: bucket.speed, day: bucket.day)
            if sqlite3_column_int(verified, 17) == 0 { pending.insert(key); continue }
            if sqlite3_column_int(verified, 18) != 0 { mismatches.insert(key); bucket.costIncomplete = true }
            partitions.append(bucket)
        }
        var intervalJoin = ""
        var dayExpression = "r.day"
        if q.hourly {
            try db.execute("CREATE TEMP TABLE query_intervals(start REAL PRIMARY KEY,end REAL)")
            var start = q.calendar.dateInterval(of: .hour, for: q.from)?.start ?? q.from
            var count = 0
            while start < q.to {
                guard count < 20_000, let end = q.calendar.date(byAdding: .hour, value: 1, to: start), end > start else { throw StoreError.invalidData }
                try db.run("INSERT INTO query_intervals VALUES(?,?)", [.real(start.timeIntervalSince1970), .real(end.timeIntervalSince1970)])
                start = end; count += 1
            }
            intervalJoin = " JOIN query_intervals i ON r.timestamp>=i.start AND r.timestamp<i.end"
            dayExpression = "i.start"
        }
        let rangeValues: [Value] = [.real(q.from.timeIntervalSince1970), .real(q.to.timeIntervalSince1970)]
        let selection = "FROM requests r JOIN verified v ON \(Self.partitionJoin)\(intervalJoin) WHERE v.accepted=1 AND r.timestamp>=? AND r.timestamp<?"
        let aggregate = try db.prepare("SELECT r.app,r.model,r.speed,\(dayExpression) day,\(Self.aggregateColumns),MAX(v.mismatch) \(selection) GROUP BY r.app,r.model,r.speed,\(dayExpression) ORDER BY day,r.app,r.model,r.speed")
        defer { sqlite3_finalize(aggregate) }
        try db.bind(rangeValues, to: aggregate)
        var buckets: [UsageBucket] = []
        while try db.step(aggregate) {
            var bucket = try readBucket(aggregate)
            bucket.costIncomplete = sqlite3_column_int(aggregate, 17) != 0
            buckets.append(bucket)
        }
        var rows: [Row] = []
        var total = 0
        if let page = q.page {
            let pageSelection = "FROM requests r JOIN verified v ON \(Self.partitionJoin) WHERE v.accepted=1 AND r.timestamp>=? AND r.timestamp<? AND r.requests>0"
            let count = try db.prepare("SELECT COUNT(*) \(pageSelection)")
            defer { sqlite3_finalize(count) }
            try db.bind(rangeValues, to: count)
            if try db.step(count) { total = Int(sqlite3_column_int64(count, 0)) }
            let order = switch page.sort {
            case "cost": "COALESCE(r.cost,'0') COLLATE DECIMAL"
            case "tokens": "(r.input+r.output+r.cache_read+r.cache_creation)"
            default: "r.timestamp"
            }
            let columns = "r.id,r.conversation_hash,r.app,r.model,r.speed,r.day,r.timestamp,r.input,r.output,r.cache_read,r.cache_creation,r.requests,r.cost,r.cost_input,r.cost_output,r.cost_read,r.cost_creation,r.timing"
            let statement = try db.prepare("SELECT \(columns) \(pageSelection) ORDER BY \(order) \(page.descending ? "DESC" : "ASC"),r.id ASC,r.app ASC LIMIT ? OFFSET ?")
            defer { sqlite3_finalize(statement) }
            try db.bind(rangeValues + [.integer(Int64(page.limit)), .integer(Int64(page.offset))], to: statement)
            while try db.step(statement) { rows.append(try readRow(statement)) }
        }
        return QueryResult(buckets: buckets, partitions: partitions, pendingPartitions: pending,
            pricingMismatches: mismatches, rows: rows, totalCount: total, metadata: metadata)
    }

    private func readBucket(_ statement: OpaquePointer) throws -> UsageBucket {
        guard let app = UsageApp(rawValue: try text(statement, 0)), let speed = UsageSpeed(rawValue: try text(statement, 2)) else { throw StoreError.invalidData }
        func count(_ column: Int32) throws -> Int {
            guard sqlite3_column_type(statement, column) == SQLITE_INTEGER, sqlite3_column_int64(statement, column) >= 0 else { throw StoreError.invalidData }
            return Int(sqlite3_column_int64(statement, column))
        }
        return try UsageBucket(app: app, model: text(statement, 1), speed: speed, day: Date(timeIntervalSince1970: real(statement, 3)),
            inputTokens: count(4), outputTokens: count(5), cacheReadTokens: count(6), cacheCreationTokens: count(7),
            costUSD: decimal(statement, 9) ?? 0, requestCount: count(8), hasUnpricedUsage: count(10) != 0,
            timing: GenerationTiming(firstTokenCount: count(11), firstTokenMs: count(12), timedOutputTokens: count(13),
                generationMs: count(14), estimatedOutputTokens: count(15), estimatedGenerationMs: count(16)))
    }

    private func readRow(_ s: OpaquePointer) throws -> Row {
        guard let app = UsageApp(rawValue: try text(s, 2)), let speed = UsageSpeed(rawValue: try text(s, 4)) else { throw StoreError.invalidData }
        let timing: RequestTiming? = try sqlite3_column_type(s, 17) == SQLITE_NULL ? nil : JSONDecoder().decode(RequestTiming.self, from: Data(text(s, 17).utf8))
        let row = try Row(id: text(s, 0), conversationHash: text(s, 1), app: app, model: text(s, 3), speed: speed,
            day: Date(timeIntervalSince1970: real(s, 5)), timestamp: Date(timeIntervalSince1970: real(s, 6)),
            input: integer(s, 7), output: integer(s, 8), cacheRead: integer(s, 9), cacheCreation: integer(s, 10), requests: integer(s, 11),
            cost: decimal(s, 12), costInput: decimal(s, 13), costOutput: decimal(s, 14), costRead: decimal(s, 15), costCreation: decimal(s, 16), timing: timing)
        try Self.validate(Payload(version: 1, sourceKeys: [:], incompleteApps: [], rows: [row]))
        return row
    }
}

nonisolated extension UsageRequestIndexStore.Connection {
    /// Monetary values stay Decimal end-to-end instead of SQLite's binary floating SUM.
    fileprivate func registerQueryFunctions() throws {
        sqlite3_progress_handler(handle, 1000, { _ in Task.isCancelled ? 1 : 0 }, nil)
        try check(sqlite3_create_function_v2(handle, "invalid_cache", 0, SQLITE_UTF8, nil, { context, _, _ in
            sqlite3_result_error_code(context, SQLITE_CORRUPT)
        }, nil, nil, nil))
        try check(sqlite3_create_function_v2(handle, "decimal_sum", 1, SQLITE_UTF8, nil, nil, { context, _, values in
            guard let context, let storage = sqlite3_aggregate_context(context, Int32(MemoryLayout<UnsafeMutableRawPointer?>.size)) else { return }
            let slot = storage.assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
            let accumulator: UsageSQLDecimalAccumulator
            if let pointer = slot.pointee { accumulator = Unmanaged<UsageSQLDecimalAccumulator>.fromOpaque(pointer).takeUnretainedValue() }
            else {
                accumulator = UsageSQLDecimalAccumulator()
                slot.pointee = Unmanaged.passRetained(accumulator).toOpaque()
            }
            guard let value = values?.pointee, sqlite3_value_type(value) != SQLITE_NULL else { return }
            guard let raw = sqlite3_value_text(value), let decimal = UsageSQLDecimalAccumulator.parse(String(cString: raw)) else {
                accumulator.failureCode = SQLITE_CORRUPT
                sqlite3_result_error_code(context, SQLITE_CORRUPT); return
            }
            var current = accumulator.value, increment = decimal, sum = Decimal()
            guard NSDecimalAdd(&sum, &current, &increment, .plain) == .noError else { accumulator.failureCode = SQLITE_TOOBIG; sqlite3_result_error_code(context, SQLITE_TOOBIG); return }
            accumulator.value = sum
        }, { context in
            guard let context else { return }
            var value = Decimal.zero
            var failureCode: Int32 = SQLITE_OK
            if let storage = sqlite3_aggregate_context(context, 0) {
                let slot = storage.assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
                if let pointer = slot.pointee {
                    let accumulator = Unmanaged<UsageSQLDecimalAccumulator>.fromOpaque(pointer).takeRetainedValue()
                    value = accumulator.value
                    failureCode = accumulator.failureCode
                    slot.pointee = nil
                }
            }
            guard failureCode == SQLITE_OK else { sqlite3_result_error_code(context, failureCode); return }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_result_text(context, NSDecimalNumber(decimal: value).stringValue, -1, transient)
        }, nil))
        try check(sqlite3_create_collation_v2(handle, "DECIMAL", SQLITE_UTF8, nil, { _, aCount, a, bCount, b in
            guard let a, let b else { return 0 }
            let lhs = String(decoding: UnsafeRawBufferPointer(start: a, count: Int(aCount)), as: UTF8.self)
            let rhs = String(decoding: UnsafeRawBufferPointer(start: b, count: Int(bCount)), as: UTF8.self)
            guard let x = UsageSQLDecimalAccumulator.parse(lhs), let y = UsageSQLDecimalAccumulator.parse(rhs) else { return lhs == rhs ? 0 : (lhs < rhs ? -1 : 1) }
            return Int32(NSDecimalNumber(decimal: x).compare(NSDecimalNumber(decimal: y)).rawValue)
        }, nil))
    }
}

nonisolated private final class UsageSQLDecimalAccumulator {
    var value = Decimal.zero
    var failureCode: Int32 = SQLITE_OK
    static func parse(_ raw: String) -> Decimal? {
        guard raw.utf8.count <= 4096,
              raw.range(of: #"^-?[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil,
              let value = Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX")), !value.isNaN else { return nil }
        return value
    }
}
