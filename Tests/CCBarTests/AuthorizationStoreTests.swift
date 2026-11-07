import Foundation
import Testing
import CCBarConfiguration
@testable import CCBar

@Suite(.serialized) @MainActor
struct AuthorizationStoreTests {
    @Test func metadataContainsReferencesAndImportIsIdempotent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AuthorizationStore(directory: directory)
        store.load()
        let account = try store.saveAccount(supplier: .grok, name: "Fixture", endpoint: "https://api.x.ai/v1",
                                             key: "private-fixture-key", source: .grok)
        let same = try store.saveAccount(supplier: .grok, name: "Fixture", endpoint: "https://api.x.ai/v1",
                                          key: "private-fixture-key", source: .grok)
        #expect(account.id == same.id)
        #expect(store.accounts.count == 1)
        let provider = ApplicationProvider(application: .grok, name: "Fixture", supplier: .grok,
                                          endpoint: account.endpoint, model: "fixture", api: .responses, authorizationID: account.id)
        try store.saveProvider(provider)
        let metadata = try String(contentsOf: directory.appendingPathComponent("authorizations.json"), encoding: .utf8)
        #expect(!metadata.contains("private-fixture-key"))
        #expect(throws: (any Error).self) { try store.removeAccount(account) }
        #expect(store.key(for: account.id) == "private-fixture-key")
        try store.removeProvider(provider.id)
        try store.removeAccount(account)
        let restored = AuthorizationStore(directory: directory)
        restored.load()
        #expect(restored.accounts.isEmpty)
        #expect(restored.key(for: account.id) == nil)
    }

    @Test func damagedMetadataIsNotOverwrittenByAnImport() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("authorizations.json")
        let original = Data("invalid-metadata".utf8)
        try original.write(to: path)
        let store = AuthorizationStore(directory: directory)
        store.load()
        #expect(throws: (any Error).self) {
            try store.saveAccount(supplier: .openai, name: "Fixture", endpoint: "https://api.openai.com/v1", key: "fixture-key")
        }
        #expect(try Data(contentsOf: path) == original)
        #expect(store.accounts.isEmpty)
    }

    @Test func usageAndAuthorizationVisibilityStayIndependentAfterRelaunch() throws {
        let name = "CCBarTests.authorization-settings.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let initial = SettingsStore(defaults: defaults)
        initial.setProviderEnabled(false, for: .codex)
        initial.setUsageServiceVisible(true, for: .codex)
        let restored = SettingsStore(defaults: defaults)
        #expect(!restored.isProviderEnabled(.codex))
        #expect(restored.isUsageServiceVisible(.codex))
        restored.setProviderEnabled(true, for: .codex)
        restored.setUsageServiceVisible(false, for: .codex)
        let again = SettingsStore(defaults: defaults)
        #expect(again.isProviderEnabled(.codex))
        #expect(!again.isUsageServiceVisible(.codex))
    }

    @Test func oldImportedAccountsDecodeAndCanShowOnlyInMenuBar() throws {
        let data = Data(#"{"id":"fixture","alias":"","visibleInPopover":false,"addedAt":0}"#.utf8)
        var account = try JSONDecoder().decode(ImportedCodexAccount.self, from: data)
        #expect(account.showInMenuBar == nil)
        #expect(!account.isVisible)
        account.showInMenuBar = true
        #expect(account.isVisible)
    }
}

@Suite(.serialized) @MainActor
struct ApplicationNavigationTests {
    @Test func sidebarSelectionPersistsWithoutChangingDetectedApps() throws {
        let name = "CCBarTests.sidebar.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = ApplicationStore(defaults: defaults)
        store.updateDetectedApplications([.codex, .kimi])
        #expect(Set(store.sidebarApplications) == [.codex, .kimi])
        store.setAdded(false, application: .kimi)
        let restored = ApplicationStore(defaults: defaults)
        restored.updateDetectedApplications([.codex, .kimi, .dsh])
        #expect(restored.sidebarApplications == [.codex])
        #expect(restored.detected == [.codex, .kimi, .dsh])
        restored.setAdded(true, application: .dsh)
        #expect(Set(restored.sidebarApplications) == [.codex, .dsh])
        restored.setAdded(false, application: .codex)
        restored.setAdded(false, application: .dsh)
        restored.updateDetectedApplications([.codex, .kimi, .dsh])
        #expect(restored.sidebarApplications.isEmpty)
    }

    @Test func legacyAPIKeysStayAvailableButLoginGrantsAreNotProviderKeys() {
        let state = AppState()
        state.deepSeekAccounts = [
            DeepSeekAccount(id: "key", name: "DeepSeek in Kimi", kind: .apiKey, credentialFingerprint: "key", sourceApplication: "kimi"),
            DeepSeekAccount(id: "login", name: "DSH", kind: .account, credentialFingerprint: "login", sourceApplication: "dsh")
        ]
        #expect(state.apiKeyProviders.map(\.id) == ["deepseek:key"])
        #expect(state.apiKeyProviders.first?.sourceApplications == [.kimi])
        #expect(state.deepSeekQuotaAccounts.map(\.id) == ["login"])
    }
}

@Suite(.serialized) @MainActor
struct APIKeyQuotaBoundaryTests {
    @Test func oldKeyQuotaSettingsCannotReenableAPIKeyBalances() throws {
        let name = "CCBarTests.key-quota.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(defaults: defaults)
        for app in [QuotaApp.commandCode, .opencodeGo] {
            settings.setProviderEnabled(true, for: app)
            settings.setProviderShownInMenuBar(true, for: app)
            settings.setProviderShownInFloatingHUD(true, for: app)
            #expect(!settings.isProviderEnabled(app))
            #expect(!settings.effectiveMenuBarVisibility(for: app))
            #expect(!settings.effectiveFloatingVisibility(for: app))
        }
    }

    @Test func detectedServiceKeysAreAvailableToProviderProfiles() throws {
        let state = AppState()
        state.opencodeGoAccount = OpenCodeGoAuthSession(apiKey: "fixture-go", source: .opencode)
        state.commandCodeAccount = CommandCodeAuthSession(accessToken: "fixture-command", source: .pi)
        #expect(Set(state.apiKeyProviders.map(\.id)) == ["opencode-go", "command-code-key"])
        #expect(!state.quotaAccountProviders.contains { $0.app.usesAPIKey })
        let provider = ApplicationProvider(application: .pi, name: "Go", supplier: .custom,
                                           endpoint: "https://opencode.ai/zen/go/v1", model: "fixture",
                                           api: .chatCompletions, authorizationID: "opencode-go")
        #expect(try state.providerCredential(for: provider) == "fixture-go")
    }
}
