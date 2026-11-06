import Foundation

/// Installation metadata is independent of configuration, usage, and quota providers.
public enum ManagedApplicationCatalog {
    public static let all: [ManagedApplicationDefinition] = [
        .init(id: "claude", name: "Claude Code", configurationApplication: .claude,
              website: "https://code.claude.com/", commands: ["claude"],
              configurationPaths: [".claude"],
              nativeRoots: [".local/share/claude", ".local/bin/claude"],
              npmPackage: "@anthropic-ai/claude-code", brewPackage: "claude-code", brewCask: true,
              installScript: "https://claude.ai/install.sh", updateArguments: ["update"],
              releaseSource: .npm("@anthropic-ai/claude-code")),
        .init(id: "claude-desktop", name: "Claude Desktop", kind: .desktop,
              website: "https://claude.com/download", bundleIDs: ["com.anthropic.claudefordesktop"],
              bundleNames: ["Claude.app"], configurationPaths: ["Library/Application Support/Claude"],
              brewPackage: "claude", brewCask: true, releaseSource: .homebrew("claude", cask: true)),
        .init(id: "codex", name: "Codex CLI", configurationApplication: .codex,
              website: "https://developers.openai.com/codex/cli/", commands: ["codex"],
              configurationPaths: [".codex"],
              nativeRoots: [".codex/packages/standalone", ".local/bin/codex"],
              npmPackage: "@openai/codex", brewPackage: "codex", brewCask: true,
              installScript: "https://chatgpt.com/codex/install.sh", updateArguments: ["update"],
              releaseSource: .npm("@openai/codex")),
        .init(id: "gemini", name: "Gemini CLI", configurationApplication: .gemini,
              website: "https://geminicli.com/", commands: ["gemini"], configurationPaths: [".gemini"],
              npmPackage: "@google/gemini-cli", brewPackage: "gemini-cli",
              releaseSource: .npm("@google/gemini-cli")),
        .init(id: "grokbuild", name: "Grok Build", configurationApplication: .grok,
              website: "https://x.ai/cli", commands: ["grok"], configurationPaths: [".grok"],
              nativeRoots: [".grok/bin"], npmPackage: "@xai-official/grok",
              installScript: "https://x.ai/cli/install.sh", updateArguments: ["update"],
              releaseSource: .npm("@xai-official/grok")),
        .init(id: "opencode", name: "OpenCode", configurationApplication: .opencode,
              website: "https://opencode.ai/", commands: ["opencode"],
              configurationPaths: [".config/opencode"], nativeRoots: [".opencode/bin"],
              npmPackage: "opencode-ai", brewPackage: "opencode",
              installScript: "https://opencode.ai/install", updateArguments: ["upgrade"],
              releaseSource: .npm("opencode-ai")),
        .init(id: "openclaw", name: "OpenClaw", website: "https://openclaw.ai/",
              commands: ["openclaw"], configurationPaths: [".openclaw"], npmPackage: "openclaw",
              updateArguments: ["update", "--yes"], releaseSource: .npm("openclaw")),
        .init(id: "hermes", name: "Hermes Agent", website: "https://hermes-agent.nousresearch.com/",
              commands: ["hermes"], configurationPaths: [".hermes"],
              nativeRoots: [".hermes/hermes-agent", ".local/bin/hermes"], pythonPackage: "hermes-agent",
              installScript: "https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh",
              updateArguments: ["update"], releaseSource: .github("NousResearch/hermes-agent")),
        .init(id: "pi", name: "Pi", configurationApplication: .pi,
              website: "https://pi.dev/", commands: ["pi"], configurationPaths: [".pi/agent"],
              npmPackage: "@earendil-works/pi-coding-agent",
              releaseSource: .npm("@earendil-works/pi-coding-agent")),
        .init(id: "mcode", name: "MiniMax Code", website: "https://code.minimax.io/",
              commands: ["mcode"], configurationPaths: [".minimax"], nativeRoots: [".minimax-code/bin"],
              npmPackage: "@minimax-ai/code", installScript: "https://filecdn.minimax.chat/public/install.sh",
              releaseSource: .npm("@minimax-ai/code")),
        .init(id: "kimi", name: "Kimi Code", configurationApplication: .kimi,
              website: "https://code.kimi.com/", commands: ["kimi"], configurationPaths: [".kimi"],
              nativeRoots: [".kimi-code/bin"], npmPackage: "@moonshot-ai/kimi-code", pythonPackage: "kimi-cli",
              installScript: "https://code.kimi.com/kimi-code/install.sh", updateArguments: ["upgrade", "--yes"],
              releaseSource: .npm("@moonshot-ai/kimi-code")),
        .init(id: "dsh", name: "DeepSeek Harness", configurationApplication: .dsh,
              website: "https://github.com/deepseek-ai/DeepSeek-Harness", commands: ["dsh"],
              configurationPaths: [".dsh"], npmPackage: "@deepseek-ai/dsh",
              releaseSource: .npm("@deepseek-ai/dsh")),
        .init(id: "agy", name: "Antigravity CLI", configurationApplication: .antigravity,
              website: "https://antigravity.google/product/antigravity-cli", commands: ["agy"],
              configurationPaths: [".gemini/antigravity-cli"], nativeRoots: [".local/bin/agy"],
              brewPackage: "antigravity-cli", brewCask: true,
              installScript: "https://antigravity.google/cli/install.sh", updateArguments: ["update"],
              releaseSource: .manifest(antigravityManifestURL)),
        .init(id: "omp", name: "Oh My Pi", website: "https://omp.sh/", commands: ["omp"],
              configurationPaths: [".omp"], nativeRoots: [".local/bin/omp"],
              npmPackage: "@oh-my-pi/pi-coding-agent", installScript: "https://omp.sh/install",
              updateArguments: ["update"], releaseSource: .npm("@oh-my-pi/pi-coding-agent")),
        .init(id: "cursor", name: "Cursor", kind: .desktop, configurationApplication: .cursor,
              website: "https://cursor.com/", bundleIDs: ["com.todesktop.230313mzl4w4u92"],
              bundleNames: ["Cursor.app"], configurationPaths: ["Library/Application Support/Cursor"],
              brewPackage: "cursor", brewCask: true, releaseSource: .homebrew("cursor", cask: true)),
        .init(id: "commandCode", name: "Command Code", configurationApplication: .commandCode,
              website: "https://commandcode.ai/", commands: ["command-code", "cmd"],
              configurationPaths: [".commandcode"], npmPackage: "command-code",
              updateArguments: ["update"], releaseSource: .npm("command-code")),
        .init(id: "antigravity", name: "Antigravity", kind: .desktop,
              website: "https://antigravity.google/product/antigravity-2", bundleIDs: ["com.google.antigravity"],
              bundleNames: ["Antigravity.app"], configurationPaths: [".gemini/antigravity"],
              brewPackage: "antigravity", brewCask: true, releaseSource: .homebrew("antigravity", cask: true)),
        .init(id: "codex-desktop", name: "Codex Desktop", kind: .desktop,
              website: "https://openai.com/codex/", bundleIDs: ["com.openai.codex"],
              bundleNames: ["Codex.app"], configurationPaths: ["Library/Application Support/Codex"],
              brewPackage: "codex-app", brewCask: true, releaseSource: .homebrew("codex-app", cask: true))
    ]

    public static func application(_ id: String) -> ManagedApplicationDefinition? {
        all.first { $0.id == id }
    }

    static let antigravityManifestBaseURL =
        "https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/"

    static var antigravityManifestURL: String {
        #if arch(arm64)
        antigravityManifestBaseURL + "darwin_arm64.json"
        #else
        antigravityManifestBaseURL + "darwin_amd64.json"
        #endif
    }
}
