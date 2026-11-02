import Foundation
import CryptoKit
import Darwin

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
    private var url: URL { directory.appendingPathComponent("request-index-v1.json") }
    static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func load() -> Payload? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber, size.int64Value <= 200_000_000,
              let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.version == 1, payload.rows.count <= 1_000_000,
              payload.sourceKeys.values.allSatisfy({ $0.count == 64 }),
              payload.rows.allSatisfy({ row in
                  row.id.count <= 100 && row.conversationHash.count == 64 && row.model.utf8.count <= 1024 &&
                  row.day.timeIntervalSince1970.isFinite && row.timestamp.timeIntervalSince1970.isFinite &&
                  [row.input, row.output, row.cacheRead, row.cacheCreation, row.requests].allSatisfy { $0 >= 0 && $0 <= 1_000_000_000_000 }
              }) else { return nil }
        return payload
    }
    func save(_ payload: Payload) throws {
        let data = try JSONEncoder().encode(payload)
        guard data.count <= 200_000_000 else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temp = directory.appendingPathComponent(".request-index-\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temp.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? FileManager.default.removeItem(at: temp) }
        let handle = try FileHandle(forWritingTo: temp)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        guard rename(temp.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
