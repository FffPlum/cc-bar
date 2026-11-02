import Foundation
import CryptoKit
import Darwin
import SQLite3

/// Rebuildable cache only. Never writes to the authoritative history store.
nonisolated struct UsageRequestIndexStore: Sendable {
    struct Row: Codable, Sendable {
        let id: String
        let conversationHash: String
        let app: UsageApp
        let model: String
        let speed: UsageSpeed
        let day: Date
        let timestamp: Date
        let input: Int
        let output: Int
        let cacheRead: Int
        let cacheCreation: Int
        let requests: Int
        let cost: Decimal?
        let costInput: Decimal?
        let costOutput: Decimal?
        let costRead: Decimal?
        let costCreation: Decimal?
        let timing: RequestTiming?
    }
    struct Payload: Codable, Sendable {
        let version: Int
        let sourceKeys: [UsageApp: String]
        let incompleteApps: Set<UsageApp>
        let rows: [Row]
    }
    let directory: URL
    private var url: URL { directory.appendingPathComponent("request-index.sqlite3") }
    private static let applicationID = 0x43434252
    private static let maximumRows = 1_000_000

    enum LoadResult: Sendable {
        case ready(Payload)
        case needsRebuild
        case unavailable
    }

    private enum StoreError: Error {
        case sqlite(Int32)
        case invalidData
        case unsupportedDatabase

        var isCorruption: Bool {
            switch self {
            case .sqlite(let code): return code & 0xff == SQLITE_CORRUPT || code & 0xff == SQLITE_NOTADB
            case .invalidData: return true
            case .unsupportedDatabase: return false
            }
        }
    }

    static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The former JSON detail cache is deliberately never read. A missing database is
    /// rebuilt by UsageService from accepted source state, without changing daily history.
    func load() -> Payload? {
        if case .ready(let payload) = loadResult() { return payload }
        return nil
    }

    func loadResult() -> LoadResult {
        guard FileManager.default.fileExists(atPath: url.path) else { return .needsRebuild }
        do {
            return try withLock {
                do {
                    return .ready(try readDatabase())
                } catch let error as StoreError where error.isCorruption {
                    try quarantine()
                    return .needsRebuild
                }
            }
        } catch {
            // Lock, permissions, future versions and I/O errors preserve the database.
            return .unavailable
        }
    }

    func save(_ payload: Payload) throws {
        try Self.validate(payload)
        try withLock {
            if FileManager.default.fileExists(atPath: url.path) {
                do {
                    try writeDatabase(payload, at: url, initialize: false)
                    return
                } catch let error as StoreError where error.isCorruption {
                    try quarantine()
                }
            }
            // Publish only a completely initialized database; interrupted first writes
            // cannot leave a schema-only file that looks like a successful empty cache.
            let temporary = directory.appendingPathComponent(".request-index-\(UUID().uuidString).sqlite3")
            defer {
                try? FileManager.default.removeItem(at: temporary)
                try? FileManager.default.removeItem(atPath: temporary.path + "-journal")
            }
            try writeDatabase(payload, at: temporary, initialize: true)
            guard rename(temporary.path, url.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    /// Serializes our short-lived connections, including first creation and quarantine.
    /// SQLite transactions still arbitrate with other SQLite clients; no global umask.
    private func withLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lockURL = directory.appendingPathComponent("request-index.lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard fchmod(descriptor, 0o600) == 0 else { throw POSIXError(.EACCES) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw StoreError.sqlite(SQLITE_BUSY) }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    private func quarantine() throws {
        // Never rename a database with a potentially active journal/WAL writer.
        guard ["-journal", "-wal", "-shm"].allSatisfy({ !FileManager.default.fileExists(atPath: url.path + $0) }) else {
            throw StoreError.sqlite(SQLITE_BUSY)
        }
        let destination = directory.appendingPathComponent("request-index-corrupt-\(UUID().uuidString).sqlite3")
        try FileManager.default.moveItem(at: url, to: destination)
    }

    private func readDatabase() throws -> Payload {
        let db = try Connection(url: url, create: false)
        try db.execute("BEGIN")
        defer { try? db.execute("ROLLBACK") }
        try validateSchema(db)
        guard try db.scalarText("PRAGMA quick_check(1)") == "ok" else { throw StoreError.invalidData }
        let sources = try readSources(db)
        let statement = try db.prepare("SELECT id, conversation_hash, app, model, speed, day, timestamp, input, output, cache_read, cache_creation, requests, cost, cost_input, cost_output, cost_read, cost_creation, timing FROM requests ORDER BY app,id LIMIT 1000001")
        defer { sqlite3_finalize(statement) }
        var rows: [Row] = []
        while try db.step(statement) {
            guard let app = UsageApp(rawValue: try text(statement, 2)),
                  let speed = UsageSpeed(rawValue: try text(statement, 4)) else { throw StoreError.invalidData }
            let timing: RequestTiming?
            if sqlite3_column_type(statement, 17) == SQLITE_NULL { timing = nil }
            else {
                let raw = try text(statement, 17)
                guard let decoded = try? JSONDecoder().decode(RequestTiming.self, from: Data(raw.utf8)) else { throw StoreError.invalidData }
                timing = decoded
            }
            rows.append(Row(id: try text(statement, 0), conversationHash: try text(statement, 1),
                app: app, model: try text(statement, 3), speed: speed,
                day: Date(timeIntervalSince1970: try real(statement, 5)),
                timestamp: Date(timeIntervalSince1970: try real(statement, 6)),
                input: try integer(statement, 7), output: try integer(statement, 8),
                cacheRead: try integer(statement, 9), cacheCreation: try integer(statement, 10),
                requests: try integer(statement, 11), cost: try decimal(statement, 12),
                costInput: try decimal(statement, 13), costOutput: try decimal(statement, 14),
                costRead: try decimal(statement, 15), costCreation: try decimal(statement, 16), timing: timing))
            guard rows.count <= Self.maximumRows else { throw StoreError.invalidData }
        }
        guard rows.allSatisfy({ sources[$0.app] != nil }) else { throw StoreError.invalidData }
        let payload = Payload(version: 1, sourceKeys: sources.compactMapValues(\.fingerprint),
            incompleteApps: Set(sources.filter { $0.value.incomplete }.keys), rows: rows)
        try Self.validate(payload)
        try db.execute("COMMIT")
        return payload
    }

    private func writeDatabase(_ payload: Payload, at path: URL, initialize: Bool) throws {
        let db = try Connection(url: path, create: initialize)
        // The cache has one serialized background writer and startup reads. Rollback
        // journaling keeps recovery/permissions simple without long-lived WAL sidecars.
        if initialize { try db.execute("PRAGMA journal_mode=DELETE") }
        try db.execute("PRAGMA synchronous=FULL")
        try db.execute("PRAGMA foreign_keys=ON")
        try db.execute("BEGIN IMMEDIATE")
        defer { try? db.execute("ROLLBACK") }
        if initialize {
            try db.execute("""
                CREATE TABLE sources(app TEXT PRIMARY KEY NOT NULL, fingerprint TEXT, incomplete INTEGER NOT NULL CHECK(incomplete IN (0,1)));
                CREATE TABLE requests(
                    app TEXT NOT NULL REFERENCES sources(app) ON DELETE CASCADE,
                    id TEXT NOT NULL, conversation_hash TEXT NOT NULL, model TEXT NOT NULL, speed TEXT NOT NULL,
                    day REAL NOT NULL, timestamp REAL NOT NULL,
                    input INTEGER NOT NULL, output INTEGER NOT NULL, cache_read INTEGER NOT NULL,
                    cache_creation INTEGER NOT NULL, requests INTEGER NOT NULL,
                    cost TEXT, cost_input TEXT, cost_output TEXT, cost_read TEXT, cost_creation TEXT, timing TEXT,
                    PRIMARY KEY(app,id));
                CREATE INDEX requests_app_time ON requests(app,timestamp);
                CREATE INDEX requests_app_model_time ON requests(app,model,timestamp);
                PRAGMA application_id=\(Self.applicationID);
                PRAGMA user_version=1;
                """)
        } else { try validateSchema(db) }
        let old = try readSources(db)
        let groups = Dictionary(grouping: payload.rows, by: \.app)
        let apps = Set(payload.sourceKeys.keys).union(payload.incompleteApps).union(groups.keys)
        for app in Set(old.keys).subtracting(apps) {
            try db.run("DELETE FROM sources WHERE app=?", [.text(app.rawValue)])
        }
        for app in apps.sorted(by: { $0.rawValue < $1.rawValue }) {
            let fingerprint = payload.sourceKeys[app]
            let changed = fingerprint == nil || old[app]?.fingerprint != fingerprint
            try db.run("INSERT INTO sources(app,fingerprint,incomplete) VALUES(?,?,?) ON CONFLICT(app) DO UPDATE SET fingerprint=excluded.fingerprint,incomplete=excluded.incomplete",
                [.text(app.rawValue), fingerprint.map(Value.text) ?? .null, .integer(payload.incompleteApps.contains(app) ? 1 : 0)])
            guard changed else { continue }
            try db.run("DELETE FROM requests WHERE app=?", [.text(app.rawValue)])
            let insert = try db.prepare("INSERT INTO requests(app,id,conversation_hash,model,speed,day,timestamp,input,output,cache_read,cache_creation,requests,cost,cost_input,cost_output,cost_read,cost_creation,timing) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)")
            defer { sqlite3_finalize(insert) }
            for row in groups[app] ?? [] {
                let costs = [row.cost, row.costInput, row.costOutput, row.costRead, row.costCreation].map { value in
                    value.map { Value.text(NSDecimalNumber(decimal: $0).stringValue) } ?? .null
                }
                let timing: Value = try row.timing.map { .text(String(decoding: try JSONEncoder().encode($0), as: UTF8.self)) } ?? .null
                let values: [Value] = [.text(app.rawValue), .text(row.id), .text(row.conversationHash), .text(row.model), .text(row.speed.rawValue),
                    .real(row.day.timeIntervalSince1970), .real(row.timestamp.timeIntervalSince1970),
                    .integer(Int64(row.input)), .integer(Int64(row.output)), .integer(Int64(row.cacheRead)),
                    .integer(Int64(row.cacheCreation)), .integer(Int64(row.requests))] + costs + [timing]
                try db.bind(values, to: insert)
                _ = try db.step(insert)
                try db.check(sqlite3_reset(insert))
                try db.check(sqlite3_clear_bindings(insert))
            }
        }
        try db.execute("COMMIT")
    }

    private func validateSchema(_ db: Connection) throws {
        guard try db.scalarInt("PRAGMA application_id") == Self.applicationID,
              try db.scalarInt("PRAGMA user_version") == 1 else { throw StoreError.unsupportedDatabase }
        guard try db.scalarInt("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN ('sources','requests')") == 2 else { throw StoreError.invalidData }
    }

    private struct Source {
        let fingerprint: String?
        let incomplete: Bool
    }

    private func readSources(_ db: Connection) throws -> [UsageApp: Source] {
        let statement = try db.prepare("SELECT app,fingerprint,incomplete FROM sources")
        defer { sqlite3_finalize(statement) }
        var result: [UsageApp: Source] = [:]
        while try db.step(statement) {
            guard let app = UsageApp(rawValue: try text(statement, 0)) else { throw StoreError.invalidData }
            let fingerprint = sqlite3_column_type(statement, 1) == SQLITE_NULL ? nil : try text(statement, 1)
            let incomplete = try integer(statement, 2)
            guard incomplete <= 1, fingerprint.map(Self.validHash) ?? true else { throw StoreError.invalidData }
            result[app] = Source(fingerprint: fingerprint, incomplete: incomplete == 1)
        }
        return result
    }

    private static func validHash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func validate(_ payload: Payload) throws {
        guard payload.version == 1, payload.rows.count <= maximumRows,
              payload.sourceKeys.values.allSatisfy(validHash) else { throw StoreError.invalidData }
        var identifiers = Set<String>()
        for row in payload.rows {
            let strings = [row.id, row.model]
            guard !row.id.isEmpty, row.id.utf8.count <= 100, row.model.utf8.count <= 1024,
                  strings.allSatisfy({ !$0.contains("\0") }), validHash(row.conversationHash),
                  row.day.timeIntervalSince1970.isFinite, row.timestamp.timeIntervalSince1970.isFinite,
                  [row.input, row.output, row.cacheRead, row.cacheCreation, row.requests].allSatisfy({ $0 >= 0 && $0 <= 1_000_000_000_000 }),
                  [row.cost, row.costInput, row.costOutput, row.costRead, row.costCreation].allSatisfy({ $0?.isNaN != true }),
                  identifiers.insert(row.app.rawValue + ":" + row.id).inserted else { throw StoreError.invalidData }
            if let timing = row.timing {
                guard timing.generationMs >= 0, Double(timing.generationMs) <= RequestTiming.maxGenerationMs,
                      timing.firstTokenMs.map({ $0 >= 0 && Double($0) <= RequestTiming.maxFirstTokenMs }) ?? true else { throw StoreError.invalidData }
            }
        }
    }

    private func text(_ statement: OpaquePointer, _ column: Int32) throws -> String {
        guard sqlite3_column_type(statement, column) == SQLITE_TEXT,
              sqlite3_column_bytes(statement, column) <= 4096,
              let pointer = sqlite3_column_text(statement, column) else { throw StoreError.invalidData }
        let bytes = UnsafeBufferPointer(start: pointer, count: Int(sqlite3_column_bytes(statement, column)))
        guard let string = String(bytes: bytes, encoding: .utf8), !string.contains("\0") else { throw StoreError.invalidData }
        return string
    }

    private func integer(_ statement: OpaquePointer, _ column: Int32) throws -> Int {
        guard sqlite3_column_type(statement, column) == SQLITE_INTEGER else { throw StoreError.invalidData }
        let value = sqlite3_column_int64(statement, column)
        guard value >= 0, value <= 1_000_000_000_000 else { throw StoreError.invalidData }
        return Int(value)
    }

    private func real(_ statement: OpaquePointer, _ column: Int32) throws -> Double {
        guard [SQLITE_FLOAT, SQLITE_INTEGER].contains(sqlite3_column_type(statement, column)) else { throw StoreError.invalidData }
        let value = sqlite3_column_double(statement, column)
        guard value.isFinite else { throw StoreError.invalidData }
        return value
    }

    private func decimal(_ statement: OpaquePointer, _ column: Int32) throws -> Decimal? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        let raw = try text(statement, column)
        guard raw.range(of: #"^-?[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil,
              let value = Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX")), !value.isNaN else { throw StoreError.invalidData }
        return value
    }

    private enum Value { case text(String), integer(Int64), real(Double), null }

    private final class Connection {
        private let handle: OpaquePointer
        init(url: URL, create: Bool) throws {
            if create {
                let fd = open(url.path, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                close(fd)
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { throw StoreError.unsupportedDatabase }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            var connection: OpaquePointer?
            let status = sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
            guard status == SQLITE_OK, let connection else {
                if let connection { sqlite3_close(connection) }
                throw StoreError.sqlite(status)
            }
            handle = connection
            sqlite3_busy_timeout(handle, 250)
        }
        deinit { sqlite3_close(handle) }
        func check(_ status: Int32) throws {
            guard status == SQLITE_OK else { throw StoreError.sqlite(status) }
        }
        func execute(_ sql: String) throws { try check(sqlite3_exec(handle, sql, nil, nil, nil)) }
        func prepare(_ sql: String) throws -> OpaquePointer {
            var statement: OpaquePointer?
            let status = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
            guard status == SQLITE_OK, let statement else {
                if let statement { sqlite3_finalize(statement) }
                throw StoreError.sqlite(status)
            }
            return statement
        }
        func step(_ statement: OpaquePointer) throws -> Bool {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: return true
            case SQLITE_DONE: return false
            case let status: throw StoreError.sqlite(status)
            }
        }
        func bind(_ values: [Value], to statement: OpaquePointer) throws {
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for (offset, value) in values.enumerated() {
                let index = Int32(offset + 1)
                let status: Int32
                switch value {
                case .text(let string): status = sqlite3_bind_text(statement, index, string, -1, transient)
                case .integer(let number): status = sqlite3_bind_int64(statement, index, number)
                case .real(let number): status = sqlite3_bind_double(statement, index, number)
                case .null: status = sqlite3_bind_null(statement, index)
                }
                try check(status)
            }
        }
        func run(_ sql: String, _ values: [Value]) throws {
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            try bind(values, to: statement)
            _ = try step(statement)
        }
        func scalarInt(_ sql: String) throws -> Int {
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            guard try step(statement), sqlite3_column_type(statement, 0) == SQLITE_INTEGER else { throw StoreError.invalidData }
            return Int(sqlite3_column_int64(statement, 0))
        }
        func scalarText(_ sql: String) throws -> String {
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            guard try step(statement), let text = sqlite3_column_text(statement, 0) else { throw StoreError.invalidData }
            return String(cString: text)
        }
    }
}
