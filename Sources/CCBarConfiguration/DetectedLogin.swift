import Foundation

/// Only display metadata leaves the native login reader. Tokens stay in their owning app.
public struct DetectedLogin: Identifiable, Equatable, Sendable {
    public let application: AgentApplication
    public let accountName: String?
    public let needsRefresh: Bool
    public var id: String { application.rawValue }
}

extension ConfigurationRepository {
    public func detectedLogin(for app: AgentApplication, now: Date = Date()) throws -> DetectedLogin? {
        switch app {
        case .gemini:
            let file = directory(for: app).appendingPathComponent("google_accounts.json")
            guard let data = try ConfigurationFiles.read(file),
                  let account = try ConfigurationDocument(data: data, format: .json).value["active"].string,
                  !account.isEmpty else { return nil }
            return DetectedLogin(application: app, accountName: account, needsRefresh: false)
        case .grok:
            let file = directory(for: app).appendingPathComponent("auth.json")
            guard let data = try ConfigurationFiles.read(file) else { return nil }
            let root = try ConfigurationDocument(data: data, format: .json).value.object
            let scopes = root.keys.filter { $0.hasPrefix("https://auth.x.ai::") }.sorted()
                + ["https://accounts.x.ai/sign-in"]
            guard let entry = scopes.compactMap({ root[$0] }).first(where: { !($0["key"].string ?? "").isEmpty }) else { return nil }
            let expiry = entry["expires_at"].string.flatMap { ISO8601DateFormatter().date(from: $0) }
            return DetectedLogin(application: app, accountName: nil, needsRefresh: expiry.map { $0 <= now } ?? false)
        default: return nil
        }
    }
}
