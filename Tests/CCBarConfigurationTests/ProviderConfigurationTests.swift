import Foundation
import Testing
@testable import CCBarConfiguration

struct ProviderConfigurationTests {
    @Test func supplierMatchingDoesNotTrustLookalikeHosts() {
        #expect(ModelSupplier.identify(endpoint: "https://api.deepseek.com/v1") == .deepseek)
        #expect(ModelSupplier.identify(endpoint: "https://api.deepseek.com.evil.test") == .custom)
        #expect(ModelSupplier.identify(endpoint: "https://api.openai.com@evil.test") == .custom)
    }

    @Test func codexSwitchPreservesLoginAndUnrelatedConfiguration() throws {
        let fixture = try ConfigurationFixture()
        defer { fixture.remove() }
        try fixture.write(".codex/config.toml", "model = 'old'\n[projects.'/work']\ntrust_level = 'trusted'\n")
        try fixture.write(".codex/auth.json", "{\"tokens\":{\"access_token\":\"test-login\"}}")
        let repository = ConfigurationRepository(homeDirectory: fixture.root, environment: [:])
        let original = try repository.read(.codex)
        let provider = ApplicationProvider(application: .codex, name: "Example", supplier: .custom,
                                            endpoint: "https://example.test/v1", model: "test-model", api: .responses)
        let plan = try repository.plan(provider: provider, credential: "test-api-key", snapshot: original)
        try repository.apply(plan)
        let after = try repository.read(.codex)
        #expect(after.providers.contains { $0.provider.model == "test-model" && $0.isActive })
        #expect(try fixture.read(".codex/auth.json") == "{\"tokens\":{\"access_token\":\"test-login\"}}")
        #expect(try fixture.read(".codex/config.toml").contains("trusted"))
    }

    @Test func concurrentEditRejectsSwitchWithoutOverwriting() throws {
        let fixture = try ConfigurationFixture()
        defer { fixture.remove() }
        try fixture.write(".claude/settings.json", "{\"permissions\":{\"allow\":[\"Read\"]}}")
        let repository = ConfigurationRepository(homeDirectory: fixture.root, environment: [:])
        let snapshot = try repository.read(.claude)
        let provider = ApplicationProvider(application: .claude, name: "Claude", supplier: .anthropic,
                                          endpoint: "https://api.anthropic.com", model: "claude-test", api: .anthropic)
        let plan = try repository.plan(provider: provider, credential: "test-key", snapshot: snapshot)
        let newer = "{\"permissions\":{\"allow\":[\"Read\",\"Write\"]}}"
        try fixture.write(".claude/settings.json", newer)
        #expect(throws: ConfigurationError.changedOnDisk) { try repository.apply(plan) }
        #expect(try fixture.read(".claude/settings.json") == newer)
    }

    @Test func unsupportedProtocolsAreRejectedBeforeWriting() throws {
        let fixture = try ConfigurationFixture()
        defer { fixture.remove() }
        let repository = ConfigurationRepository(homeDirectory: fixture.root, environment: [:])
        let snapshot = try repository.read(.codex)
        let provider = ApplicationProvider(application: .codex, name: "Unsupported", supplier: .deepseek,
                                           endpoint: "https://api.deepseek.com", model: "test", api: .chatCompletions)
        #expect(throws: ConfigurationError.unsupportedProtocol) {
            try repository.plan(provider: provider, credential: "test-key", snapshot: snapshot)
        }
    }

    @Test func credentialsStayOnTheirIssuerOrigin() throws {
        let issuer = try APIEndpoint("https://api.deepseek.com")
        #expect(try APIEndpoint("https://api.deepseek.com:443/v1").acceptsCredential(issuedFor: issuer))
        #expect(try !APIEndpoint("https://api.deepseek.com.evil.test").acceptsCredential(issuedFor: issuer))
        #expect(try !APIEndpoint("https://api.deepseek.com:444").acceptsCredential(issuedFor: issuer))
        #expect(throws: ConfigurationError.invalidProvider) { try APIEndpoint("https://token@api.deepseek.com") }
        #expect(throws: ConfigurationError.invalidProvider) { try APIEndpoint("http://api.deepseek.com") }
    }

    @Test func malformedExistingTableIsNotReplaced() throws {
        let fixture = try ConfigurationFixture()
        defer { fixture.remove() }
        let original = #"{"env":"managed-elsewhere","permissions":{"allow":["Read"]}}"#
        try fixture.write(".claude/settings.json", original)
        let repository = ConfigurationRepository(homeDirectory: fixture.root, environment: [:])
        let provider = ApplicationProvider(application: .claude, name: "Test", supplier: .anthropic,
                                          endpoint: "https://api.anthropic.com", model: "test", api: .anthropic)
        #expect(throws: ConfigurationError.invalidFile) {
            try repository.plan(provider: provider, credential: "fixture-key", snapshot: repository.read(.claude))
        }
        #expect(try fixture.read(".claude/settings.json") == original)
    }

    @Test func geminiWritesBothFilesAndPreservesLoginAndOtherSettings() throws {
        let fixture = try ConfigurationFixture()
        defer { fixture.remove() }
        try fixture.write(".gemini/.env", "# keep this\nUNRELATED=value\n")
        try fixture.write(".gemini/settings.json", #"{"ui":{"theme":"dark"},"security":{"auth":{"selectedType":"oauth-personal"}}}"#)
        try fixture.write(".gemini/google_accounts.json", #"{"active":"fixture@example.test","old":[]}"#)
        let repository = ConfigurationRepository(homeDirectory: fixture.root, environment: [:])
        let provider = ApplicationProvider(application: .gemini, name: "Gemini", supplier: .gemini,
                                          endpoint: "https://generativelanguage.googleapis.com", model: "fixture-model", api: .gemini)
        let plan = try repository.plan(provider: provider, credential: "fixture-key", snapshot: repository.read(.gemini))
        #expect(plan.changes.count == 2)
        let backup = try #require(try repository.apply(plan))
        #expect(FileManager.default.fileExists(atPath: backup.appendingPathComponent("files.json").path))
        let snapshot = try repository.read(.gemini)
        #expect(snapshot.providers.contains { $0.isActive && $0.credential == "fixture-key" })
        #expect(try fixture.read(".gemini/.env").contains("# keep this\nUNRELATED=value"))
        #expect(try fixture.read(".gemini/settings.json").contains("dark"))
        #expect(try repository.detectedLogin(for: .gemini)?.accountName == "fixture@example.test")
        #expect(try repository.plan(provider: provider, credential: "fixture-key", snapshot: snapshot).changes.isEmpty)
    }

    @Test func dshPreservesGrantsAndCreatesCoexistingProviderIdempotently() throws {
        let fixture = try ConfigurationFixture()
        defer { fixture.remove() }
        try fixture.write(".dsh/.credentials.yaml", """
        version: 1
        refs:
          ORIGINAL: original-key
        records:
          deepseek-account-platform/default:
            kind: grant
            payload:
              issuer: https://platform.deepseek.com
              token: fixture-grant
        """)
        let repository = ConfigurationRepository(homeDirectory: fixture.root, environment: [:])
        let provider = ApplicationProvider(application: .dsh, name: "Fixture", supplier: .deepseek,
                                          endpoint: "https://api.deepseek.com", model: "deepseek-chat", api: .chatCompletions)
        try repository.apply(repository.plan(provider: provider, credential: "fixture-key", snapshot: repository.read(.dsh)))
        #expect(try repository.deepSeekAccountGrant() == "fixture-grant")
        #expect(try fixture.read(".dsh/.credentials.yaml").contains("original-key"))
        let snapshot = try repository.read(.dsh)
        #expect(snapshot.providers.count == 1)
        #expect(snapshot.providers.first?.credential == "fixture-key")
        #expect(try repository.plan(provider: provider, credential: "fixture-key", snapshot: snapshot).changes.isEmpty)
    }

    @Test func openCodeUsesExistingJSONCWithoutCreatingCompetingFile() throws {
        let fixture = try ConfigurationFixture()
        defer { fixture.remove() }
        try fixture.write(".config/opencode/opencode.jsonc", "{\n// existing options\n\"autoupdate\":false,\n}")
        let repository = ConfigurationRepository(homeDirectory: fixture.root, environment: [:])
        let provider = ApplicationProvider(application: .opencode, name: "Fixture", supplier: .deepseek,
                                          endpoint: "https://api.deepseek.com", model: "deepseek-chat", api: .chatCompletions)
        try repository.apply(repository.plan(provider: provider, credential: "fixture-key", snapshot: repository.read(.opencode)))
        #expect(try fixture.read(".config/opencode/opencode.jsonc").contains("autoupdate"))
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(".config/opencode/opencode.json").path))
        #expect(try repository.read(.opencode).providers.first?.provider.model == "deepseek-chat")
    }

    @Test func symlinkConfigIsNeverWritten() throws {
        let fixture = try ConfigurationFixture()
        defer { fixture.remove() }
        try fixture.write("original.json", "{}")
        try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent(".claude/settings.json"),
                                                   withDestinationURL: fixture.root.appendingPathComponent("original.json"))
        let repository = ConfigurationRepository(homeDirectory: fixture.root, environment: [:])
        #expect(throws: ConfigurationError.unsafePath) { try repository.read(.claude) }
        #expect(try fixture.read("original.json") == "{}")
    }

    @Test func grokLoginDetectionDoesNotExposeTokens() throws {
        let fixture = try ConfigurationFixture()
        defer { fixture.remove() }
        try fixture.write(".grok/auth.json", #"{"https://auth.x.ai::fixture":{"key":"private-fixture-token","expires_at":"2020-01-01T00:00:00Z"}}"#)
        let repository = ConfigurationRepository(homeDirectory: fixture.root, environment: [:])
        let login = try #require(try repository.detectedLogin(for: .grok))
        #expect(login.application == .grok)
        #expect(login.needsRefresh)
        #expect(!String(describing: login).contains("private-fixture-token"))
    }

    @Test func codexOfficialSelectionDropsThirdPartyModelOverride() throws {
        let fixture = try ConfigurationFixture()
        defer { fixture.remove() }
        try fixture.write(".codex/config.toml", """
        model = "third-party-only"
        model_provider = "custom"
        [model_providers.custom]
        name = "Custom"
        base_url = "https://example.test/v1"
        wire_api = "responses"
        """)
        let repository = ConfigurationRepository(homeDirectory: fixture.root, environment: [:])
        let snapshot = try repository.read(.codex)
        let official = try #require(snapshot.providers.first { $0.provider.isOfficial })
        try repository.apply(repository.planSelecting(official, snapshot: snapshot))
        let after = try repository.read(.codex)
        #expect(after.providers.first?.isActive == true)
        #expect(after.providers.first?.provider.model.isEmpty == true)
        #expect(try fixture.read(".codex/config.toml").contains("model_providers"))
    }

    @Test func piPreservesLargeIntegersAndNeverImportsCredentialCommands() throws {
        let fixture = try ConfigurationFixture()
        defer { fixture.remove() }
        try fixture.write(".pi/agent/models.json", #"{"revision":9007199254740993,"providers":{"existing":{"baseUrl":"https://example.test","apiKey":"!echo secret","models":[{"id":"old"}]}}}"#)
        let repository = ConfigurationRepository(homeDirectory: fixture.root, environment: [:])
        let before = try repository.read(.pi)
        #expect(before.providers.first?.credential == nil)
        let provider = ApplicationProvider(application: .pi, name: "Fixture", supplier: .deepseek,
                                          endpoint: "https://api.deepseek.com", model: "deepseek-chat", api: .chatCompletions)
        try repository.apply(repository.plan(provider: provider, credential: "fixture-key", snapshot: before))
        let output = try fixture.read(".pi/agent/models.json")
        #expect(output.contains("9007199254740993"))
        #expect(output.contains("!echo secret"))
        let after = try repository.read(.pi)
        #expect(after.providers.count == 2)
        #expect(try repository.plan(provider: provider, credential: "fixture-key", snapshot: after).changes.isEmpty)
    }

    @Test func grokOfficialAndCustomRoundTripKeepsUnrelatedConfiguration() throws {
        let fixture = try ConfigurationFixture()
        defer { fixture.remove() }
        try fixture.write(".grok/config.toml", "theme = 'dark'\n")
        try fixture.write(".grok/auth.json", #"{"https://auth.x.ai::fixture":{"key":"fixture-login"}}"#)
        let repository = ConfigurationRepository(homeDirectory: fixture.root, environment: [:])
        let provider = ApplicationProvider(application: .grok, name: "Fixture", supplier: .grok,
                                          endpoint: "https://api.x.ai/v1", model: "fixture-model", api: .responses)
        try repository.apply(repository.plan(provider: provider, credential: "fixture-key", snapshot: repository.read(.grok)))
        let custom = try repository.read(.grok)
        #expect(custom.providers.contains { $0.isActive && !$0.provider.isOfficial })
        let official = try #require(custom.providers.first { $0.provider.isOfficial })
        try repository.apply(repository.planSelecting(official, snapshot: custom))
        #expect(try repository.read(.grok).providers.first?.isActive == true)
        try repository.apply(repository.plan(provider: provider, credential: "fixture-key", snapshot: repository.read(.grok)))
        #expect(try fixture.read(".grok/config.toml").contains("dark"))
        #expect(try fixture.read(".grok/auth.json").contains("fixture-login"))
    }

    @Test func kimiSelectsExistingModelWithoutReplacingOAuthReference() throws {
        let fixture = try ConfigurationFixture()
        defer { fixture.remove() }
        try fixture.write(".kimi-code/config.toml", """
        default_model = "first"
        [providers."managed:kimi-code"]
        type = "kimi"
        base_url = "https://api.kimi.com/coding/v1"
        [providers."managed:kimi-code".oauth]
        key = "native-profile"
        [models.first]
        provider = "managed:kimi-code"
        model = "kimi-first"
        max_context_size = 128000
        [models.second]
        provider = "managed:kimi-code"
        model = "kimi-second"
        max_context_size = 128000
        """)
        let repository = ConfigurationRepository(homeDirectory: fixture.root, environment: [:])
        let snapshot = try repository.read(.kimi)
        let second = try #require(snapshot.providers.first { $0.provider.model == "kimi-second" })
        let plan = try repository.planSelecting(second, snapshot: snapshot)
        try repository.apply(plan)
        #expect(try repository.read(.kimi).providers.contains { $0.isActive && $0.provider.model == "kimi-second" })
        #expect(try fixture.read(".kimi-code/config.toml").contains("native-profile"))
    }
}

private struct ConfigurationFixture {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func write(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    func read(_ path: String) throws -> String { try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

@Suite struct ProviderConnectionTests {
    @Test func modelsShareOneCardAndNativeProfilesDoNotDuplicateIt() {
        let first = ApplicationProvider(id: "native:kimi:first", application: .kimi, name: "DeepSeek", supplier: .deepseek,
                                        endpoint: "https://api.deepseek.com", model: "chat", api: .chatCompletions, nativeID: "deepseek")
        var second = first; second.id = "native:kimi:second"; second.model = "reasoner"
        var saved = first; saved.id = "saved"; saved.authorizationID = "key"
        var otherApp = first; otherApp.id = "other"; otherApp.application = .codex
        let list = ProviderConnection.list(application: .kimi,
                                            native: [NativeProvider(provider: first, isActive: false, credential: nil, modelKey: "chat"),
                                                     NativeProvider(provider: second, isActive: true, credential: nil, modelKey: "reasoner")],
                                            saved: [first, second, saved, otherApp])
        #expect(list.count == 1)
        #expect(list.first?.models == ["chat", "reasoner"])
        #expect(list.first?.isActive == true)
    }
}
