import Foundation

/// A supplier is an authorization issuer, independent of the application using it.
public enum ModelSupplier: String, Codable, CaseIterable, Sendable, Identifiable {
    case openai, anthropic, kimi, deepseek, grok, gemini, custom
    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .openai: "OpenAI"
        case .anthropic: "Anthropic"
        case .kimi: "Kimi / Moonshot"
        case .deepseek: "DeepSeek"
        case .grok: "Grok"
        case .gemini: "Gemini"
        case .custom: "Custom"
        }
    }
    public var website: String {
        switch self {
        case .openai: "https://platform.openai.com/api-keys"
        case .anthropic: "https://console.anthropic.com/settings/keys"
        case .kimi: "https://platform.moonshot.cn/console/api-keys"
        case .deepseek: "https://platform.deepseek.com/api_keys"
        case .grok: "https://console.x.ai"
        case .gemini: "https://aistudio.google.com/apikey"
        case .custom: ""
        }
    }
    public var defaultEndpoint: String {
        switch self {
        case .openai: "https://api.openai.com/v1"
        case .anthropic: "https://api.anthropic.com"
        case .kimi: "https://api.moonshot.cn/v1"
        case .deepseek: "https://api.deepseek.com"
        case .grok: "https://api.x.ai/v1"
        case .gemini: "https://generativelanguage.googleapis.com"
        case .custom: ""
        }
    }
    public static func identify(endpoint: String) -> Self {
        guard let host = URL(string: endpoint)?.host?.lowercased() else { return .custom }
        switch host {
        case "api.openai.com", "chatgpt.com": return .openai
        case "api.anthropic.com": return .anthropic
        case "api.moonshot.cn", "api.moonshot.ai", "api.kimi.com", "api.kimi.ai": return .kimi
        case "api.deepseek.com": return .deepseek
        case "api.x.ai": return .grok
        case "generativelanguage.googleapis.com": return .gemini
        default: return .custom
        }
    }
}

public enum AgentApplication: String, CaseIterable, Codable, Sendable, Identifiable {
    case codex, claude, kimi, dsh, gemini, grok, opencode, pi, cursor, antigravity, commandCode
    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude Code"
        case .kimi: "Kimi Code"
        case .dsh: "DeepSeek Harness"
        case .gemini: "Gemini CLI"
        case .grok: "Grok Build"
        case .opencode: "OpenCode"
        case .pi: "Pi"
        case .cursor: "Cursor"
        case .antigravity: "Antigravity"
        case .commandCode: "Command Code"
        }
    }
    public var supportsProviderConfiguration: Bool {
        ![.cursor, .antigravity, .commandCode].contains(self)
    }
    public var coexistingProviders: Bool { [.dsh, .opencode, .pi].contains(self) }
    public var supportedAPIs: [ProviderAPI] {
        switch self {
        case .codex, .grok: [.responses]
        case .claude: [.anthropic]
        case .gemini: [.gemini]
        default: ProviderAPI.allCases
        }
    }
    public var defaultSupplier: ModelSupplier {
        switch self {
        case .codex: .openai
        case .claude: .anthropic
        case .kimi: .kimi
        case .dsh: .deepseek
        case .gemini, .antigravity: .gemini
        case .grok: .grok
        default: .custom
        }
    }
}

/// A credential may move between paths on its issuer's origin, never to another host.
public struct APIEndpoint: Equatable, Sendable {
    public let value: String
    private let scheme: String
    private let host: String
    private let port: Int
    public init(_ value: String) throws {
        guard let url = URLComponents(string: value), let host = url.host?.lowercased(), !host.isEmpty,
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw ConfigurationError.invalidProvider
        }
        self.value = value; self.scheme = scheme; self.host = host
        self.port = url.port ?? (scheme == "https" ? 443 : 80)
        guard (1...65535).contains(port) else { throw ConfigurationError.invalidProvider }
    }
    public func acceptsCredential(issuedFor issuer: APIEndpoint) -> Bool {
        scheme == issuer.scheme && host == issuer.host && port == issuer.port
    }
}

public enum ProviderAPI: String, CaseIterable, Codable, Sendable {
    case responses, chatCompletions, anthropic, gemini
    public var title: String {
        switch self {
        case .responses: "OpenAI Responses"
        case .chatCompletions: "OpenAI Chat Completions"
        case .anthropic: "Anthropic Messages"
        case .gemini: "Gemini"
        }
    }
}

/// Persisted profile contains a credential reference, never a credential value.
public struct ApplicationProvider: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var application: AgentApplication
    public var name: String
    public var supplier: ModelSupplier
    public var endpoint: String
    public var model: String
    public var api: ProviderAPI
    public var authorizationID: String?
    public var contextWindow: Int
    public var nativeID: String?
    public var isOfficial: Bool
    public init(id: String = UUID().uuidString, application: AgentApplication, name: String,
                supplier: ModelSupplier, endpoint: String, model: String, api: ProviderAPI,
                authorizationID: String? = nil, contextWindow: Int = 128_000,
                nativeID: String? = nil, isOfficial: Bool = false) {
        self.id = id; self.application = application; self.name = name; self.supplier = supplier
        self.endpoint = endpoint; self.model = model; self.api = api
        self.authorizationID = authorizationID; self.contextWindow = contextWindow
        self.nativeID = nativeID; self.isOfficial = isOfficial
    }
}

public enum ConfigurationError: Error, LocalizedError, Equatable {
    case invalidFile, invalidProvider, unsupportedProtocol, changedOnDisk, unsafePath, missingCredential, writeFailed, ambiguousConfiguration
    public var errorDescription: String? {
        switch self {
        case .invalidFile: "配置格式无法识别，请检查应用原有配置。"
        case .invalidProvider: "请填写有效的名称、地址、模型和上下文长度。"
        case .unsupportedProtocol: "此应用不能直接使用所选 API 协议。"
        case .changedOnDisk: "配置已被其他程序修改，请重新读取后再操作。"
        case .unsafePath: "配置路径不是当前用户拥有的普通文件，未写入。"
        case .missingCredential: "API Key 不可用，请在添加供应商中重新配置。"
        case .writeFailed: "配置保存失败；请检查备份和文件权限。"
        case .ambiguousConfiguration: "发现多个配置文件，请先在应用中确认当前使用的文件。"
        }
    }
}
