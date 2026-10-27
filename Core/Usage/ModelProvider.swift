import Foundation

/// 从已确认的渠道格式提取模型身份；无法解释的标识原样保留。
/// 原始标识用于存储和来源明细，解析结果供展示与查价共同使用。
nonisolated struct ModelIdentity: Sendable, Equatable {
    enum Channel: Sendable, Equatable { case cursor, codex, zenFree, unknown }
    enum Speed: String, Sendable { case fast, slow, unspecified }

    let raw: String
    let entry: String?
    let channel: Channel
    let model: String
    let context: String?
    let speed: Speed

    var cursorPricingKey: String? {
        guard channel == .cursor, speed != .unspecified else { return nil }
        return "cursor-sdk:\(model):\(context ?? "-"):\(speed.rawValue)"
    }

    static func parse(_ raw: String) -> ModelIdentity {
        let lower = raw.lowercased()
        func unresolved() -> ModelIdentity {
            ModelIdentity(raw: raw, entry: nil, channel: .unknown, model: raw, context: nil, speed: .unspecified)
        }
        let cursorPrefix: String?
        let entry: String?
        if lower.hasPrefix("magpie/cursor/") {
            cursorPrefix = "magpie/cursor/"
            entry = "magpie"
        } else if lower.hasPrefix("cursor/") {
            cursorPrefix = "cursor/"
            entry = nil
        } else {
            cursorPrefix = nil
            entry = nil
        }
        if let cursorPrefix {
            var name = String(lower.dropFirst(cursorPrefix.count))
            var speed: Speed = .unspecified
            if name.hasSuffix(":fast") {
                name.removeLast(":fast".count)
                speed = .fast
            } else if name.hasSuffix(":slow") {
                name.removeLast(":slow".count)
                speed = .slow
            }
            var context: String?
            if let at = name.firstIndex(of: "@") {
                let suffix = String(name[name.index(after: at)...])
                let digits = suffix.dropLast()
                guard let unit = suffix.last, unit == "k" || unit == "m",
                      !digits.isEmpty, digits.utf8.allSatisfy({ (48...57).contains($0) }),
                      digits.contains(where: { $0 != "0" }) else { return unresolved() }
                context = suffix
                name = String(name[..<at])
            }
            guard !name.isEmpty, name.utf8.allSatisfy({
                (48...57).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46 || $0 == 95
            }) else { return unresolved() }
            return ModelIdentity(raw: raw, entry: entry, channel: .cursor, model: name, context: context, speed: speed)
        }
        let codexRoutes: [(String, String?)] = [("openai-codex/", nil), ("magpie/codex/", "magpie")]
        for (prefix, entry) in codexRoutes where lower.hasPrefix(prefix) {
            let name = String(lower.dropFirst(prefix.count))
            if name.hasPrefix("gpt-"), !name.contains("/"), !name.contains("@"), !name.contains(":") {
                return ModelIdentity(raw: raw, entry: entry, channel: .codex, model: name, context: nil, speed: .unspecified)
            }
        }
        let zenRoutes: [(String, String?)] = [("opencode-zen-free/", nil), ("magpie/opencode-zen-free/", "magpie")]
        for (prefix, entry) in zenRoutes where lower.hasPrefix(prefix) {
            let name = String(lower.dropFirst(prefix.count))
            if ["deepseek-v4.1-flash-free", "mimo-v2.6-flash-free"].contains(name) {
                return ModelIdentity(raw: raw, entry: entry, channel: .zenFree, model: name, context: nil, speed: .unspecified)
            }
        }
        switch lower {
        case "composer-2.5", "composer-2.5-fast", "cursor-composer-2-5":
            return ModelIdentity(raw: raw, entry: nil, channel: .unknown, model: "composer-2.5", context: nil, speed: .unspecified)
        case "grok-4-7":
            return ModelIdentity(raw: raw, entry: nil, channel: .unknown, model: "grok-4.7", context: nil, speed: .unspecified)
        default: return unresolved()
        }
    }
}

/// 模型提供商（厂商归并 + opencode-go / command code 单列）分组键。
///
/// 从 `UsageBucket.model` 字符串推导：前缀优先（`openai/`、`openai-codex/`、
/// `anthropic/`、`deepseek/`、`opencode-go/`、`commandcode/`、`command-code/`），
/// 无前缀时按 app / 模型名关键词兜底。
/// 纯展示层用途，不参与定价与存储；价格仍由 `Pricing` 按模型名单独解析。
nonisolated enum ModelProvider: String, Sendable, CaseIterable {
    case openAI
    case anthropic
    case deepseek
    case opencodeGo
    case commandCode
    case other

    /// 推导提供商。
    ///
    /// 顺序：前缀匹配 → 模型名关键词匹配 → 按 app 兜底 → 其他。
    /// - 前缀（Pi / OpenCode 日志保留 `provider/model` 形态）
    /// - 关键词（裸模型，以及未能验证渠道的旧 Codex / Claude 历史）
    /// - app 兜底：codex → OpenAI、claude → Anthropic（两者日志模型几乎固定厂商）
    static func resolve(app: UsageApp, model: String) -> ModelProvider {
        let m = model.lowercased()

        let prefixes: [(String, ModelProvider)] = [
            ("openai-codex/", .openAI),
            ("openai/", .openAI),
            ("anthropic/", .anthropic),
            ("deepseek/", .deepseek),
            ("opencode-go/", .opencodeGo),
            ("commandcode/", .commandCode),
            ("command-code/", .commandCode)
        ]
        for (prefix, provider) in prefixes where m.hasPrefix(prefix) {
            return provider
        }

        if m.hasPrefix("claude-") { return .anthropic }
        if m.hasPrefix("gpt-") || m.hasPrefix("o1") || m.hasPrefix("o3")
            || m.hasPrefix("o4") || m.hasPrefix("chatgpt-") || m.hasPrefix("codex-") {
            return .openAI
        }
        if m.hasPrefix("deepseek-") { return .deepseek }

        switch app {
        case .codex: return .openAI
        case .claude: return .anthropic
        case .cursor: return .other
        case .pi, .opencode: return .other
        case .dsh, .antigravity: return .other
        }
    }

    /// 双语显示名。品牌名中英一致，「其他」单独翻译。
    @MainActor
    var displayName: String {
        switch self {
        case .openAI: return tr("OpenAI", "OpenAI")
        case .anthropic: return tr("Anthropic", "Anthropic")
        case .deepseek: return tr("DeepSeek", "DeepSeek")
        case .opencodeGo: return tr("OpenCode-Go", "OpenCode-Go")
        case .commandCode: return tr("Command Code", "Command Code")
        case .other: return tr("Other", "其他")
        }
    }
}
