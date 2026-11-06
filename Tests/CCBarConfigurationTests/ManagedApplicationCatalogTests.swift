import Foundation
import Testing
@testable import CCBarConfiguration

struct ManagedApplicationCatalogTests {
    @Test func includesEveryReferenceApplicationAndExistingDesktopProduct() {
        let expected: Set<String> = ["claude", "claude-desktop", "codex", "gemini", "grokbuild", "opencode",
                                     "openclaw", "hermes", "pi", "mcode", "kimi", "dsh", "agy", "omp",
                                     "cursor", "commandCode", "antigravity", "codex-desktop"]
        #expect(Set(ManagedApplicationCatalog.all.map(\.id)) == expected)
        #expect(ManagedApplicationCatalog.all.count == expected.count)
        #expect(ManagedApplicationCatalog.application("missing") == nil)
    }

    @Test func desktopAndCLIIdentitiesRemainDistinct() throws {
        let claude = try #require(ManagedApplicationCatalog.application("claude-desktop"))
        #expect(claude.kind == .desktop)
        #expect(claude.configurationApplication == nil)
        #expect(claude.commands.isEmpty)
        #expect(claude.bundleIDs == ["com.anthropic.claudefordesktop"])
        let codex = try #require(ManagedApplicationCatalog.application("codex-desktop"))
        #expect(codex.bundleIDs == ["com.openai.codex"])
        #expect(!codex.bundleIDs.contains("com.openai.chat"))
        #expect(ManagedApplicationCatalog.application("grokbuild")?.configurationApplication == .grok)
        #expect(ManagedApplicationCatalog.application("agy")?.configurationApplication == .antigravity)
        #expect(ManagedApplicationCatalog.application("antigravity")?.commands.isEmpty == true)
    }

    @Test func currentPackagesAndInstallerScriptsAreExplicit() throws {
        #expect(ManagedApplicationCatalog.application("kimi")?.npmPackage == "@moonshot-ai/kimi-code")
        #expect(ManagedApplicationCatalog.application("pi")?.npmPackage == "@earendil-works/pi-coding-agent")
        #expect(ManagedApplicationCatalog.application("commandCode")?.commands == ["command-code", "cmd"])
        #expect(ManagedApplicationCatalog.application("omp")?.installScript == "https://omp.sh/install")
        for application in ManagedApplicationCatalog.all {
            if let script = application.installScript {
                let url = try #require(URL(string: script))
                #expect(url.scheme == "https")
                #expect(url.user == nil && url.password == nil && url.query == nil)
                #expect(!script.contains(" "))
            }
            if let source = application.releaseSource {
                #expect(try ApplicationVersionClient.url(for: source).scheme == "https")
            }
            #expect(!application.nativeRoots.contains(".local/bin"))
            #expect(!application.nativeRoots.contains(".bun/bin"))
        }
    }
}
