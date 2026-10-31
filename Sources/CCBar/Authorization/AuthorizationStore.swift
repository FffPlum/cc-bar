import Foundation
import Observation
import CCBarConfiguration

nonisolated struct SupplierAuthorization: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var supplier: ModelSupplier
    var name: String
    var endpoint: String
    var fingerprint: String
    var sourceApplications: Set<AgentApplication>
}

/// A single owner for API-key metadata and app profiles. Existing subscription stores remain
/// the credential owners for Codex, Kimi, Moonshot and DeepSeek; the center references them.
@Observable @MainActor
final class AuthorizationStore {
    private(set) var accounts: [SupplierAuthorization] = []
    private(set) var providers: [ApplicationProvider] = []
    private(set) var error: String?
    private var loaded = false
    private var loadFailed = false
    private var ignoredImports: Set<String> = []
    private let directory: URL
    private let credentials: APISecretFileStore

    init(directory: URL = ImportedCodexStore.fileURL().deletingLastPathComponent()) {
        self.directory = directory
        credentials = APISecretFileStore(directory: directory.appendingPathComponent("supplier_credentials"))
    }
    private struct Payload: Codable {
        var version = 1
        var accounts: [SupplierAuthorization]
        var providers: [ApplicationProvider]
        var ignoredImports: Set<String>
    }
    func load() {
        guard !loaded else { return }
        loaded = true
        let path = directory.appendingPathComponent("authorizations.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        do {
            let data = try JSONDecoder().decode(Payload.self, from: Data(contentsOf: path))
            guard data.version == 1 else { throw ConfigurationError.invalidFile }
            accounts = data.accounts; providers = data.providers; ignoredImports = data.ignoredImports
        } catch { loadFailed = true; self.error = tr("Authorization settings couldn't be loaded.", "授权设置未能读取，请检查本机文件。") }
    }
    @discardableResult func saveAccount(id: String? = nil, supplier: ModelSupplier, name: String,
                                        endpoint: String, key: String, source: AgentApplication? = nil) throws -> SupplierAuthorization {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = key.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try APIEndpoint(endpoint)
        guard !name.isEmpty, APISecret.isValid(secret) else {
            throw ConfigurationError.invalidProvider
        }
        let fingerprint = APISecret.fingerprint(secret)
        let duplicate = source == nil ? nil : accounts.first { $0.fingerprint == fingerprint && $0.endpoint == endpoint }
        let accountID = id ?? duplicate?.id ?? UUID().uuidString
        let existing = accounts.first { $0.id == accountID }
        var account = SupplierAuthorization(id: accountID, supplier: supplier, name: existing?.name ?? name,
                                             endpoint: endpoint, fingerprint: fingerprint,
                                             sourceApplications: existing?.sourceApplications ?? [])
        if source == nil { account.name = name }
        if let source { account.sourceApplications.insert(source) }
        if account == existing, credentials.load(id: accountID) == secret { return account }
        let previousSecret = credentials.load(id: accountID)
        let previousAccounts = accounts
        try credentials.save(secret, id: accountID)
        accounts.removeAll { $0.id == accountID }; accounts.append(account)
        do { try save() }
        catch {
            accounts = previousAccounts
            if let previousSecret { try? credentials.save(previousSecret, id: accountID) }
            else { _ = credentials.delete(id: accountID) }
            throw error
        }
        return account
    }
    func key(for id: String) -> String? {
        guard let account = accounts.first(where: { $0.id == id }), let key = credentials.load(id: id),
              APISecret.fingerprint(key) == account.fingerprint else { return nil }
        return key
    }
    func removeAccount(_ account: SupplierAuthorization) throws {
        guard !providers.contains(where: { $0.authorizationID == account.id && !$0.id.hasPrefix("native:") }) else {
            throw AuthorizationStoreError.inUse(tr("An application profile still uses this authorization. Remove the profile first.", "应用配置仍在使用此授权，请先移除对应供应商配置。"))
        }
        let previous = accounts; let previousIgnored = ignoredImports; let previousProviders = providers
        let key = credentials.load(id: account.id)
        guard credentials.delete(id: account.id) else { throw ConfigurationError.writeFailed }
        accounts.removeAll { $0.id == account.id }
        providers.removeAll { $0.authorizationID == account.id }
        ignoredImports.insert(account.fingerprint + account.endpoint)
        do { try save() }
        catch {
            accounts = previous; ignoredImports = previousIgnored; providers = previousProviders
            if let key { try? credentials.save(key, id: account.id) }
            throw error
        }
    }
    func importNative(_ native: NativeProvider) throws {
        guard !native.provider.isOfficial, let key = native.credential, APISecret.isValid(key),
              !key.hasPrefix("{env:"), !key.hasPrefix("${"),
              !ignoredImports.contains(APISecret.fingerprint(key) + native.provider.endpoint) else { return }
        let account = try saveAccount(supplier: native.provider.supplier, name: native.provider.name,
                                      endpoint: native.provider.endpoint, key: key, source: native.provider.application)
        var profile = native.provider
        profile.authorizationID = account.id
        // Native references follow key rotation. User-created profiles have separate IDs.
        guard providers.first(where: { $0.id == profile.id }) != profile else { return }
        try saveProvider(profile)
    }
    func saveProvider(_ provider: ApplicationProvider) throws {
        let previous = providers
        providers.removeAll { $0.id == provider.id }; providers.append(provider)
        do { try save() } catch { providers = previous; throw error }
    }
    func removeProvider(_ id: String) throws {
        let previous = providers
        providers.removeAll { $0.id == id }
        do { try save() } catch { providers = previous; throw error }
    }
    func isImportIgnored(_ fingerprint: String) -> Bool { ignoredImports.contains(fingerprint) }
    func ignoreImport(_ fingerprint: String) throws {
        let previous = ignoredImports
        ignoredImports.insert(fingerprint)
        do { try save() } catch { ignoredImports = previous; throw error }
    }
    private func save() throws {
        guard !loadFailed else { throw ConfigurationError.invalidFile }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let payload = Payload(accounts: accounts, providers: providers, ignoredImports: ignoredImports)
        try JSONEncoder().encode(payload).write(to: directory.appendingPathComponent("authorizations.json"), options: .atomic)
        error = nil
    }
}

private enum AuthorizationStoreError: LocalizedError {
    case inUse(String)
    var errorDescription: String? { switch self { case .inUse(let message): message } }
}
