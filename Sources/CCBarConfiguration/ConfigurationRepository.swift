import Foundation

public struct NativeProvider: Identifiable, Sendable {
    public let provider: ApplicationProvider
    public let isActive: Bool
    public let credential: String?
    public let modelKey: String
    public var id: String { provider.id }
}

public struct ConfigurationSnapshot: Sendable {
    public let application: AgentApplication
    public let providers: [NativeProvider]
    public let paths: [URL]
    let files: [URL: Data]
    public var hasConfiguration: Bool { !files.isEmpty }
}

public struct ConfigurationPlan: Sendable {
    public let application: AgentApplication
    public let changes: [FileChange]
    public struct FileChange: Sendable {
        public let url: URL
        let before: Data?
        let after: Data
    }
}

/// Reads and plans are side-effect free. Only apply writes, after checking every original file.
public struct ConfigurationRepository: Sendable {
    public let homeDirectory: URL
    let environment: [String: String]
    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.homeDirectory = homeDirectory; self.environment = environment
    }
    public func directory(for app: AgentApplication) -> URL {
        let setting: (String?, String) = switch app {
        case .codex: ("CODEX_HOME", ".codex")
        case .claude: ("CLAUDE_CONFIG_DIR", ".claude")
        case .kimi: ("KIMI_CODE_HOME", ".kimi-code")
        case .dsh: ("DSH_HOME", ".dsh")
        case .gemini: (nil, ".gemini")
        case .grok: (nil, ".grok")
        case .opencode: (nil, ".config/opencode")
        case .pi: ("PI_CODING_AGENT_DIR", ".pi/agent")
        case .cursor: (nil, "Library/Application Support/Cursor")
        case .antigravity: (nil, ".gemini/antigravity")
        case .commandCode: (nil, ".commandcode")
        }
        if let key = setting.0, let path = environment[key], path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        if app == .opencode, let path = environment["XDG_CONFIG_HOME"], path.hasPrefix("/") {
            return URL(fileURLWithPath: path).appendingPathComponent("opencode")
        }
        return homeDirectory.appendingPathComponent(setting.1)
    }
    func paths(for app: AgentApplication) throws -> [URL] {
        if app == .opencode {
            if let path = environment["OPENCODE_CONFIG"], path.hasPrefix("/") { return [URL(fileURLWithPath: path)] }
            let json = directory(for: app).appendingPathComponent("opencode.json")
            let jsonc = directory(for: app).appendingPathComponent("opencode.jsonc")
            let hasJSON = FileManager.default.fileExists(atPath: json.path)
            let hasJSONC = FileManager.default.fileExists(atPath: jsonc.path)
            guard !(hasJSON && hasJSONC) else { throw ConfigurationError.ambiguousConfiguration }
            return [hasJSONC ? jsonc : json]
        }
        let names: [String] = switch app {
        case .codex, .kimi, .grok: ["config.toml"]
        case .claude: ["settings.json"]
        case .gemini: [".env", "settings.json"]
        case .dsh: ["profiles/web/cordis.patch.yml", "profiles/desktop/cordis.patch.yml", "profiles/headless/cordis.patch.yml", "profiles/acp/cordis.patch.yml", "cordis.patch.yml", ".credentials.yaml"]
        case .opencode: ["opencode.json"]
        case .pi: ["models.json"]
        default: []
        }
        return names.map { directory(for: app).appendingPathComponent($0) }
    }
    public func read(_ app: AgentApplication) throws -> ConfigurationSnapshot {
        let paths = try paths(for: app)
        var files: [URL: Data] = [:]
        for path in paths { if let data = try ConfigurationFiles.read(path) { files[path] = data } }
        let providers = try NativeProviderAdapter.read(app, files: files, paths: paths)
        return ConfigurationSnapshot(application: app, providers: providers, paths: paths, files: files)
    }
    public func plan(provider: ApplicationProvider, credential: String?, snapshot: ConfigurationSnapshot) throws -> ConfigurationPlan {
        guard provider.application == snapshot.application else { throw ConfigurationError.invalidProvider }
        try Self.validate(provider, credential: credential)
        let updated = try NativeProviderAdapter.update(provider, credential: credential, snapshot: snapshot)
        return makePlan(snapshot: snapshot, updated: updated)
    }
    public func planSelecting(_ provider: NativeProvider, snapshot: ConfigurationSnapshot) throws -> ConfigurationPlan {
        guard snapshot.providers.contains(where: { $0.id == provider.id }) else { throw ConfigurationError.changedOnDisk }
        let updated = try NativeProviderAdapter.select(provider, snapshot: snapshot)
        return makePlan(snapshot: snapshot, updated: updated)
    }
    private func makePlan(snapshot: ConfigurationSnapshot, updated: [URL: Data]) -> ConfigurationPlan {
        ConfigurationPlan(application: snapshot.application, changes: updated.keys.sorted(by: { $0.path < $1.path }).compactMap { url in
            guard let after = updated[url], snapshot.files[url] != after else { return nil }
            return ConfigurationPlan.FileChange(url: url, before: snapshot.files[url], after: after)
        })
    }
    @discardableResult public func apply(_ plan: ConfigurationPlan) throws -> URL? {
        try ConfigurationFiles.apply(plan, backupRoot: homeDirectory.appendingPathComponent("Library/Application Support/CCBar/configuration-backups"))
    }
    public static func validate(_ provider: ApplicationProvider, credential: String?) throws {
        guard !provider.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              provider.contextWindow > 0, provider.contextWindow <= 10_000_000,
              !provider.model.contains(where: \.isNewline) else { throw ConfigurationError.invalidProvider }
        if provider.isOfficial { return }
        _ = try APIEndpoint(provider.endpoint)
        guard !provider.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ConfigurationError.invalidProvider }
        guard provider.application.supportedAPIs.contains(provider.api) else { throw ConfigurationError.unsupportedProtocol }
        guard let credential, !credential.isEmpty, credential.utf8.count <= 8192,
              credential.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 127 }) else { throw ConfigurationError.missingCredential }
    }
    public func deepSeekAccountGrant() throws -> String? {
        let path = directory(for: .dsh).appendingPathComponent(".credentials.yaml")
        guard let data = try ConfigurationFiles.read(path) else { return nil }
        let record = try ConfigurationDocument(data: data, format: .yaml).value["records"]["deepseek-account-platform/default"]
        guard record["kind"].string == "grant",
              record["payload"]["issuer"].string == "https://platform.deepseek.com" else { return nil }
        return record["payload"]["token"].string
    }
}
