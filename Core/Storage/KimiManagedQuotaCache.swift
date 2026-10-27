import Foundation

nonisolated enum KimiManagedQuotaCache {
    private struct Payload: Codable {
        var version = 1
        var records: [String: QuotaCacheRecord]
    }

    static func load(from url: URL = fileURL()) -> [String: QuotaCacheRecord] {
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.version == 1
        else { return [:] }
        return payload.records
    }

    static func save(_ records: [String: QuotaCacheRecord], to url: URL = fileURL()) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Payload(records: records)).write(to: url, options: .atomic)
    }

    static func fileURL() -> URL {
        ImportedCodexStore.fileURL().deletingLastPathComponent().appendingPathComponent("kimi_subscription_quota_cache.json")
    }
}
