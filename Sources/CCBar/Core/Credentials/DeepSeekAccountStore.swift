import Foundation

nonisolated enum DeepSeekAuthKind: String, Codable, Sendable {
    case apiKey, account
}

nonisolated struct DeepSeekAccount: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var kind: DeepSeekAuthKind
    var credentialFingerprint: String
    var visibleInPopover = true
    var showInMenuBar = false
    var showInFloatingHUD = false
    var sourceApplication: String? = nil
    var sourceConfigurationID: String? = nil

    var showsInFloatingSurfaces: Bool { visibleInPopover || showInFloatingHUD }
    var isVisible: Bool { kind == .account && (showsInFloatingSurfaces || showInMenuBar) }

    static func fingerprint(_ secret: String, kind: DeepSeekAuthKind) -> String {
        APISecret.fingerprint(secret, namespace: kind.rawValue)
    }

    static func validSecret(_ value: String) -> Bool {
        APISecret.isValid(value)
    }
}

nonisolated protocol DeepSeekCredentialStore: Sendable {
    func load(id: String) -> String?
    func save(_ secret: String, id: String) throws
    func delete(id: String) -> Bool
}

nonisolated struct DeepSeekFileStore: DeepSeekCredentialStore {
    private let files: APISecretFileStore
    init(directory: URL = ImportedCodexStore.fileURL().deletingLastPathComponent()
        .appendingPathComponent("deepseek_credentials", isDirectory: true)) {
        files = APISecretFileStore(directory: directory)
    }
    func load(id: String) -> String? { files.load(id: id) }
    func save(_ secret: String, id: String) throws { try files.save(secret, id: id) }
    func delete(id: String) -> Bool { files.delete(id: id) }

}

nonisolated enum DeepSeekAccountStore {
    struct Payload: Codable {
        var version = 1
        var accounts: [DeepSeekAccount]
    }
    static func load(from url: URL) -> [DeepSeekAccount] {
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data), payload.version == 1 else { return [] }
        var seen = Set<String>()
        return payload.accounts.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
    }
    static func save(_ accounts: [DeepSeekAccount], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Payload(accounts: accounts)).write(to: url, options: .atomic)
    }
}
