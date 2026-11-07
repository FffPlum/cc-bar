import Foundation

/// Each adapter owns only native provider fields. Account tokens never cross API protocols.
enum NativeProviderAdapter {
    static func read(_ app: AgentApplication, files: [URL: Data], paths: [URL]) throws -> [NativeProvider] {
        guard let path = paths.first else { return [] }
        let root = try document(path, files: files).value
        switch app {
        case .codex: return codex(root)
        case .claude: return claude(root)
        case .kimi: return kimi(root)
        case .grok: return grok(root)
        case .gemini:
            let settings = try document(paths[1], files: files).value
            return gemini(root, settings: settings)
        case .dsh: return try dsh(paths: paths, files: files)
        case .opencode: return opencode(root)
        case .pi: return pi(root)
        default: return []
        }
    }
    static func update(_ profile: ApplicationProvider, credential: String?, snapshot: ConfigurationSnapshot) throws -> [URL: Data] {
        guard let path = snapshot.paths.first else { throw ConfigurationError.invalidProvider }
        var doc = try document(path, files: snapshot.files)
        let key = profile.nativeID ?? "ccbar-" + profile.id.lowercased()
        switch profile.application {
        case .codex: updateCodex(&doc.value, profile, key: key, credential: credential)
        case .claude: updateClaude(&doc.value, profile, credential: credential)
        case .kimi: updateKimi(&doc.value, profile, key: key, credential: credential)
        case .grok: updateGrok(&doc.value, profile, key: key, credential: credential)
        case .gemini: return try updateGemini(profile, credential: credential, snapshot: snapshot)
        case .dsh: return try updateDsh(profile, key: key, credential: credential, snapshot: snapshot)
        case .opencode: updateOpenCode(&doc.value, profile, key: key, credential: credential)
        case .pi: updatePi(&doc.value, profile, key: key, credential: credential)
        default: throw ConfigurationError.invalidProvider
        }
        return [path: try doc.encoded()]
    }
    static func select(_ provider: NativeProvider, snapshot: ConfigurationSnapshot) throws -> [URL: Data] {
        guard let path = snapshot.paths.first else { throw ConfigurationError.invalidProvider }
        if provider.provider.isOfficial, snapshot.application != .kimi {
            return try update(provider.provider, credential: nil, snapshot: snapshot)
        }
        var doc = try document(path, files: snapshot.files)
        switch snapshot.application {
        case .codex:
            guard !provider.provider.model.isEmpty else { throw ConfigurationError.invalidProvider }
            doc.value["model_provider"] = .string(provider.provider.nativeID ?? "openai")
            doc.value["model"] = .string(provider.modelKey)
        case .kimi: doc.value["default_model"] = .string(provider.modelKey)
        case .grok: doc.value["models"]["default"] = .string(provider.modelKey)
        case .claude, .gemini: return [:] // Already the live configuration.
        default: throw ConfigurationError.invalidProvider // Coexist apps choose their model natively.
        }
        return [path: try doc.encoded()]
    }
    static func document(_ path: URL, files: [URL: Data]) throws -> ConfigurationDocument {
        let format: ConfigurationDocument.Format = switch path.pathExtension {
        case "toml": .toml
        case "jsonc": .jsonc
        case "yaml", "yml": .yaml
        default: path.lastPathComponent == ".env" ? .environment : .json
        }
        return try ConfigurationDocument(data: files[path], format: format,
                                         emptyValue: path.lastPathComponent == "cordis.patch.yml" ? .array([]) : .object([:]))
    }
    private static func native(_ app: AgentApplication, key: String, name: String? = nil,
                               endpoint: String, model: String, modelKey: String? = nil,
                               api: ProviderAPI, credential: String? = nil,
                               active: Bool, official: Bool = false, context: Int = 128_000) -> NativeProvider {
        let supplier = official ? app.defaultSupplier : ModelSupplier.identify(endpoint: endpoint)
        let identity = app == .codex ? "native:\(app.rawValue):\(key)" : "native:\(app.rawValue):\(key):\(modelKey ?? model)"
        let profile = ApplicationProvider(id: identity, application: app,
                                           name: name ?? (official ? app.defaultSupplier.name : key), supplier: supplier,
                                           endpoint: endpoint, model: model, api: api, contextWindow: context,
                                           nativeID: key, isOfficial: official)
        let literal = credential.flatMap { value -> String? in
            guard !["{env:", "{file:", "$", "!"].contains(where: value.hasPrefix) else { return nil }
            // Pi resolves environment-variable names and shell expressions itself.
            if app == .pi, value.range(of: "^[A-Z_][A-Z0-9_]*$", options: .regularExpression) != nil { return nil }
            return value
        }
        return NativeProvider(provider: profile, isActive: active, credential: literal, modelKey: modelKey ?? model)
    }
    private static func codex(_ root: ConfigValue) -> [NativeProvider] {
        let active = root["model_provider"].string ?? "openai"
        let model = root["model"].string ?? ""
        var result = [native(.codex, key: "openai", endpoint: ModelSupplier.openai.defaultEndpoint,
                             model: active == "openai" ? model : "", api: .responses, active: active == "openai", official: true)]
        for (id, item) in root["model_providers"].object.sorted(by: { $0.key < $1.key }) {
            guard let endpoint = item["base_url"].string else { continue }
            result.append(native(.codex, key: id, name: item["name"].string, endpoint: endpoint, model: active == id ? model : "",
                                 api: .responses, credential: item["experimental_bearer_token"].string, active: active == id))
        }
        return result
    }
    private static func claude(_ root: ConfigValue) -> [NativeProvider] {
        let env = root["env"]
        let key = env["ANTHROPIC_API_KEY"].string ?? env["ANTHROPIC_AUTH_TOKEN"].string
        let endpoint = env["ANTHROPIC_BASE_URL"].string ?? ModelSupplier.anthropic.defaultEndpoint
        let custom = key != nil || env["ANTHROPIC_BASE_URL"].string != nil
        var result = [native(.claude, key: "official", endpoint: ModelSupplier.anthropic.defaultEndpoint,
                             model: "", api: .anthropic, active: !custom, official: true)]
        if custom {
            result.append(native(.claude, key: "current", name: ModelSupplier.identify(endpoint: endpoint).name,
                                 endpoint: endpoint, model: env["ANTHROPIC_MODEL"].string ?? root["model"].string ?? "",
                                 api: .anthropic, credential: key, active: true))
        }
        return result
    }
    private static func kimi(_ root: ConfigValue) -> [NativeProvider] {
        root["models"].object.sorted(by: { $0.key < $1.key }).compactMap { modelKey, model in
            guard let id = model["provider"].string else { return nil }
            let item = root["providers"][id]
            let type = item["type"].string ?? "kimi"
            let api: ProviderAPI = switch type {
            case "anthropic": .anthropic
            case "google-genai", "vertexai": .gemini
            case "openai_responses": .responses
            default: .chatCompletions
            }
            return native(.kimi, key: id, endpoint: item["base_url"].string ?? "",
                          model: model["model"].string ?? modelKey, modelKey: modelKey,
                          api: api, credential: item["api_key"].string,
                          active: root["default_model"].string == modelKey,
                          official: item["oauth"]["key"].string != nil,
                          context: model["max_context_size"].integer ?? 128_000)
        }
    }
    private static func grok(_ root: ConfigValue) -> [NativeProvider] {
        let selected = root["models"]["default"].string
        var result = [native(.grok, key: "official", endpoint: ModelSupplier.grok.defaultEndpoint,
                             model: "", api: .responses, active: selected == nil, official: true)]
        for (key, value) in root["model"].object.sorted(by: { $0.key < $1.key }) {
            result.append(native(.grok, key: key, name: value["name"].string, endpoint: value["base_url"].string ?? "",
                                 model: value["model"].string ?? key, modelKey: key,
                                 api: value["api_backend"].string == "responses" ? .responses : .chatCompletions,
                                 credential: value["api_key"].string, active: key == selected,
                                 context: value["context_window"].integer ?? 128_000))
        }
        return result
    }
    private static func gemini(_ env: ConfigValue, settings: ConfigValue) -> [NativeProvider] {
        let official = settings["security"]["auth"]["selectedType"].string != "gemini-api-key"
        var result = [native(.gemini, key: "official", endpoint: ModelSupplier.gemini.defaultEndpoint,
                             model: "", api: .gemini, active: official, official: true)]
        if let key = env["GEMINI_API_KEY"].string {
            result.append(native(.gemini, key: "current", endpoint: env["GOOGLE_GEMINI_BASE_URL"].string ?? ModelSupplier.gemini.defaultEndpoint,
                                 model: env["GEMINI_MODEL"].string ?? settings["model"]["name"].string ?? "",
                                 api: .gemini, credential: key, active: !official))
        }
        return result
    }
    private static func dsh(paths: [URL], files: [URL: Data]) throws -> [NativeProvider] {
        let credentials = try document(paths[5], files: files).value
        var result: [NativeProvider] = []
        for path in paths.prefix(5) where files[path] != nil {
            let root = try document(path, files: files).value
            for plugin in root.array where plugin["id"].string == "llm-pi-ai" {
                for (id, item) in plugin["config"]["providers"].object.sorted(by: { $0.key < $1.key }) {
                    for model in item["models"].array {
                        guard let modelID = model["id"].string else { continue }
                        let credential = item["apiKeyEnv"].string.flatMap { credentials["refs"][$0].string }
                        let row = native(.dsh, key: id, name: item["displayName"].string, endpoint: item["baseURL"].string ?? "",
                                         model: modelID, api: api(item["api"].string), credential: credential,
                                         active: true, context: model["contextWindow"].integer ?? 128_000)
                        if !result.contains(where: { $0.id == row.id }) { result.append(row) }
                    }
                }
            }
        }
        return result
    }
    private static func opencode(_ root: ConfigValue) -> [NativeProvider] {
        root["provider"].object.sorted(by: { $0.key < $1.key }).flatMap { id, item in
            item["models"].object.sorted(by: { $0.key < $1.key }).map { model, metadata in
                native(.opencode, key: id, name: item["name"].string, endpoint: item["options"]["baseURL"].string ?? "",
                       model: model, api: item["npm"].string == "@ai-sdk/anthropic" ? .anthropic : .chatCompletions,
                       credential: item["options"]["apiKey"].string, active: true, context: metadata["limit"]["context"].integer ?? 128_000)
            }
        }
    }
    private static func pi(_ root: ConfigValue) -> [NativeProvider] {
        root["providers"].object.sorted(by: { $0.key < $1.key }).flatMap { id, item in
            item["models"].array.compactMap { model in
                guard let name = model["id"].string else { return nil }
                return native(.pi, key: id, endpoint: item["baseUrl"].string ?? "", model: name,
                              api: api(item["api"].string), credential: item["apiKey"].string,
                              active: true, context: model["contextWindow"].integer ?? 128_000)
            }
        }
    }
    private static func api(_ value: String?) -> ProviderAPI {
        switch value {
        case "openai-responses": .responses
        case "anthropic-messages": .anthropic
        case "google-generative-ai": .gemini
        default: .chatCompletions
        }
    }
    private static func nativeAPI(_ api: ProviderAPI) -> String {
        switch api {
        case .responses: "openai-responses"
        case .chatCompletions: "openai-completions"
        case .anthropic: "anthropic-messages"
        case .gemini: "google-generative-ai"
        }
    }
    private static func updateCodex(_ root: inout ConfigValue, _ p: ApplicationProvider, key: String, credential: String?) {
        root["model_provider"] = .string(p.isOfficial ? "openai" : key)
        if !p.model.isEmpty { root["model"] = .string(p.model) }
        guard !p.isOfficial else {
            if p.model.isEmpty { root["model"] = .null }
            return
        }
        root["model_providers"][key]["name"] = .string(p.name)
        root["model_providers"][key]["base_url"] = .string(p.endpoint)
        root["model_providers"][key]["wire_api"] = .string("responses")
        root["model_providers"][key]["experimental_bearer_token"] = .string(credential ?? "")
        root["model_providers"][key]["requires_openai_auth"] = .bool(false)
        root["model_providers"][key]["env_key"] = .null
    }
    private static func updateClaude(_ root: inout ConfigValue, _ p: ApplicationProvider, credential: String?) {
        for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "ANTHROPIC_MODEL",
                    "ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL", "ANTHROPIC_DEFAULT_HAIKU_MODEL"] {
            root["env"][key] = .null
        }
        guard !p.isOfficial else { root["model"] = .null; return }
        root["env"]["ANTHROPIC_API_KEY"] = .string(credential ?? "")
        root["env"]["ANTHROPIC_BASE_URL"] = .string(p.endpoint)
        root["env"]["ANTHROPIC_MODEL"] = .string(p.model)
    }
    private static func updateKimi(_ root: inout ConfigValue, _ p: ApplicationProvider, key: String, credential: String?) {
        let modelKey = "ccbar-" + p.id.lowercased()
        let type: String = switch p.api {
        case .responses: "openai_responses"
        case .chatCompletions: "openai"
        case .anthropic: "anthropic"
        case .gemini: "google-genai"
        }
        root["providers"][key]["type"] = .string(type)
        root["providers"][key]["base_url"] = .string(p.endpoint)
        root["providers"][key]["api_key"] = .string(credential ?? "")
        root["providers"][key]["api_key_env"] = .null
        root["models"][modelKey]["provider"] = .string(key)
        root["models"][modelKey]["model"] = .string(p.model)
        root["models"][modelKey]["max_context_size"] = .integerNumber(Int64(p.contextWindow))
        root["default_model"] = .string(modelKey)
    }
    private static func updateGrok(_ root: inout ConfigValue, _ p: ApplicationProvider, key: String, credential: String?) {
        if p.isOfficial { root["models"] = .null; root["model"] = .null; return }
        root["models"]["default"] = .string(key)
        root["model"][key]["model"] = .string(p.model)
        root["model"][key]["name"] = .string(p.name)
        root["model"][key]["base_url"] = .string(p.endpoint)
        root["model"][key]["api_key"] = .string(credential ?? "")
        root["model"][key]["env_key"] = .null
        root["model"][key]["api_backend"] = .string(p.api == .responses ? "responses" : "chat_completions")
        root["model"][key]["context_window"] = .integerNumber(Int64(p.contextWindow))
    }
    private static func updateGemini(_ p: ApplicationProvider, credential: String?, snapshot: ConfigurationSnapshot) throws -> [URL: Data] {
        var env = try document(snapshot.paths[0], files: snapshot.files)
        var settings = try document(snapshot.paths[1], files: snapshot.files)
        settings.value["security"]["auth"]["selectedType"] = .string(p.isOfficial ? "oauth-personal" : "gemini-api-key")
        for key in ["GEMINI_API_KEY", "GOOGLE_GEMINI_BASE_URL", "GEMINI_MODEL"] { env.value[key] = .null }
        if !p.isOfficial {
            env.value["GEMINI_API_KEY"] = .string(credential ?? "")
            env.value["GOOGLE_GEMINI_BASE_URL"] = .string(p.endpoint)
            env.value["GEMINI_MODEL"] = .string(p.model)
            settings.value["model"]["name"] = .string(p.model)
        }
        return [snapshot.paths[0]: try env.encoded(), snapshot.paths[1]: try settings.encoded()]
    }
    private static func updateOpenCode(_ root: inout ConfigValue, _ p: ApplicationProvider, key: String, credential: String?) {
        let npm: String = switch p.api {
        case .anthropic: "@ai-sdk/anthropic"
        case .gemini: "@ai-sdk/google"
        case .responses: "@ai-sdk/openai"
        case .chatCompletions: "@ai-sdk/openai-compatible"
        }
        root["provider"][key]["name"] = .string(p.name)
        root["provider"][key]["npm"] = .string(npm)
        root["provider"][key]["options"]["baseURL"] = .string(p.endpoint)
        root["provider"][key]["options"]["apiKey"] = .string(credential ?? "")
        root["provider"][key]["models"][p.model]["name"] = .string(p.model)
        root["provider"][key]["models"][p.model]["limit"]["context"] = .integerNumber(Int64(p.contextWindow))
    }
    private static func updatePi(_ root: inout ConfigValue, _ p: ApplicationProvider, key: String, credential: String?) {
        root["providers"][key]["baseUrl"] = .string(p.endpoint)
        root["providers"][key]["apiKey"] = .string(credential ?? "")
        root["providers"][key]["api"] = .string(nativeAPI(p.api))
        var models = root["providers"][key]["models"].array.filter { $0["id"].string != p.model }
        models.append(.object(["id": .string(p.model), "name": .string(p.model), "contextWindow": .integerNumber(Int64(p.contextWindow)), "maxTokens": .integerNumber(8192)]))
        root["providers"][key]["models"] = .array(models)
    }
    private static func updateDsh(_ p: ApplicationProvider, key: String, credential: String?, snapshot: ConfigurationSnapshot) throws -> [URL: Data] {
        let home = try document(snapshot.paths[4], files: snapshot.files).value
        guard !home.array.contains(where: { $0["id"].string == "llm-pi-ai" && !$0["config"]["providers"].object.isEmpty }) else {
            throw ConfigurationError.changedOnDisk
        }
        var credentials = try document(snapshot.paths[5], files: snapshot.files)
        let reference = "CCBAR_" + p.id.replacingOccurrences(of: "-", with: "_").uppercased()
        credentials.value["version"] = .integerNumber(1)
        credentials.value["refs"][reference] = .string(credential ?? "")
        var updated = [snapshot.paths[5]: try credentials.encoded()]
        for (index, path) in snapshot.paths.prefix(4).enumerated() where index < 2 || snapshot.files[path] != nil {
            var doc = try document(path, files: snapshot.files)
            guard case .array(var plugins) = doc.value else { throw ConfigurationError.invalidFile }
            let matches = plugins.indices.filter { plugins[$0]["id"].string == "llm-pi-ai" }
            guard matches.count <= 1 else { throw ConfigurationError.invalidFile }
            let pluginIndex = matches.first ?? plugins.count
            if matches.isEmpty { plugins.append(.object(["id": .string("llm-pi-ai")])) }
            var node = plugins[pluginIndex]["config"]["providers"][key]
            node["displayName"] = .string(p.name)
            node["baseURL"] = .string(p.endpoint)
            node["api"] = .string(nativeAPI(p.api))
            node["apiKeyEnv"] = .string(reference)
            var models = node["models"].array.filter { $0["id"].string != p.model }
            models.append(.object(["id": .string(p.model), "name": .string(p.model), "contextWindow": .integerNumber(Int64(p.contextWindow)), "maxTokens": .integerNumber(8192)]))
            node["models"] = .array(models)
            plugins[pluginIndex]["config"]["providers"][key] = node
            doc.value = .array(plugins)
            updated[path] = try doc.encoded()
        }
        return updated
    }
}
