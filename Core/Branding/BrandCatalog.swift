import Foundation

/// 品牌目录：额度服务与只有用量的服务共用的品牌身份。
/// `rawValue` 与 logo / favicon 资源名一致，`commandCode` 除外（资源名是 `commandcode`）。
nonisolated enum ServiceBrand: String, CaseIterable, Codable, Hashable, Sendable {
    case codex
    case claude
    case antigravity
    case cursor
    case commandCode
    case opencode
    case kimi
    case pi
    case dsh

    /// logo / favicon 资源名。Command Code 的额度 rawValue 是 `commandCode`，
    /// 但资源文件名为 `commandcode`。
    var logoName: String {
        self == .commandCode ? "commandcode" : rawValue
    }

    /// 浅色外观下的默认品牌色（`#RRGGBB`）。
    var defaultLightHex: String {
        switch self {
        case .codex: "#000000"
        case .claude: "#D97757"
        case .antigravity: "#2F88F8"
        case .cursor: "#14120B"
        case .commandCode: "#000000"
        case .opencode: "#080808"
        case .kimi: "#1783FF"
        case .pi: "#4D9ABF"
        case .dsh: "#4D6BFE"
        }
    }

    /// 深色外观下的默认品牌色（`#RRGGBB`）。
    var defaultDarkHex: String {
        switch self {
        case .codex: "#FFFFFF"
        case .claude: "#D97757"
        case .antigravity: "#2F88F8"
        case .cursor: "#F7F7F4"
        case .commandCode: "#FFFFFF"
        case .opencode: "#F7F7F7"
        case .kimi: "#1783FF"
        case .pi: "#4D9ABF"
        case .dsh: "#4D6BFE"
        }
    }

    /// favicon 是否铺满整块 tile；false 时放在白底 tile 中央留白。
    var faviconFillsTile: Bool {
        switch self {
        case .codex, .cursor, .commandCode, .opencode, .kimi, .pi: true
        case .claude, .antigravity, .dsh: false
        }
    }

    /// 已安装桌面 App 的查找候选；`nil` 表示没有对应桌面 App（Pi）。
    var installedAppCandidate: MacAppIconCandidate? {
        switch self {
        case .codex:
            MacAppIconCandidate(
                bundleIdentifiers: ["com.openai.codex", "com.openai.chat"],
                appNames: ["ChatGPT.app", "Codex.app"]
            )
        case .claude:
            MacAppIconCandidate(
                bundleIdentifiers: ["com.anthropic.claudefordesktop"],
                appNames: ["Claude.app", "Claude Code.app"]
            )
        case .antigravity:
            MacAppIconCandidate(
                bundleIdentifiers: ["com.google.antigravity"],
                appNames: ["Antigravity.app"]
            )
        case .cursor:
            MacAppIconCandidate(
                bundleIdentifiers: ["com.todesktop.230313mzl4w4u92"],
                appNames: ["Cursor.app"]
            )
        case .commandCode:
            MacAppIconCandidate(bundleIdentifiers: [], appNames: ["Command Code.app"])
        case .opencode:
            MacAppIconCandidate(
                bundleIdentifiers: ["ai.opencode.desktop"],
                appNames: ["OpenCode.app"]
            )
        case .kimi:
            MacAppIconCandidate(
                bundleIdentifiers: ["com.kimi.code.desktop"],
                appNames: ["Kimi Code.app"]
            )
        case .dsh:
            MacAppIconCandidate(bundleIdentifiers: [], appNames: ["DSH Desktop.app"])
        case .pi:
            nil
        }
    }

    /// 从资源名反查；`commandcode` 映射回 `.commandCode`。
    init?(logoName: String) {
        switch logoName {
        case "codex": self = .codex
        case "claude": self = .claude
        case "antigravity": self = .antigravity
        case "cursor": self = .cursor
        case "commandcode": self = .commandCode
        case "opencode": self = .opencode
        case "kimi": self = .kimi
        case "pi": self = .pi
        case "dsh": self = .dsh
        default: return nil
        }
    }
}

nonisolated enum BrandColorMode: String, CaseIterable, Codable, Hashable, Sendable {
    case brand
    case custom
}

nonisolated struct BrandColorPreference: Codable, Equatable, Sendable {
    var mode: BrandColorMode
    var customHex: String?

    static let brand = BrandColorPreference(mode: .brand, customHex: nil)
}

nonisolated struct MacAppIconCandidate: Equatable, Sendable {
    let bundleIdentifiers: [String]
    let appNames: [String]
}

extension QuotaApp {
    var brand: ServiceBrand {
        switch self {
        case .codex: .codex
        case .claude: .claude
        case .antigravity: .antigravity
        case .cursor: .cursor
        case .commandCode: .commandCode
        case .opencodeGo: .opencode
        case .kimi: .kimi
        }
    }
}

extension UsageApp {
    var brand: ServiceBrand {
        switch self {
        case .codex: .codex
        case .claude: .claude
        case .cursor: .cursor
        case .pi: .pi
        case .opencode: .opencode
        case .dsh: .dsh
        case .antigravity: .antigravity
        case .kimi: .kimi
        }
    }
}
