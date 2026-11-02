import Foundation
import Testing
import CCBarConfiguration
@testable import CCBar

@Suite(.serialized) @MainActor
struct HostWindowApplicationsTests {
    private func fixture(_ body: (AppState, SettingsStore, HostWindowApplicationsService, URL) throws -> Void) throws {
        let suite = "CCBarTests.window-applications.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let authorization = AuthorizationStore(directory: directory)
        authorization.load()
        let state = AppState(authorizations: authorization, applications: ApplicationStore(defaults: defaults))
        state.applications.updateDetectedApplications([.codex, .kimi, .gemini])
        let settings = SettingsStore(defaults: defaults)
        let host = HostWindowApplicationsService(state: state, settings: settings, detect: {})
        try body(state, settings, host, directory)
    }

    @Test func savedKeyIsNeverReturnedAndProfileDoesNotChangeNativeConfiguration() throws {
        try fixture { state, _, host, _ in
            let secret = "private-fixture-key-for-host"
            let choice = try host.handle("authorizations.saveAPIKey", params: [
                "supplier": .string("openai"), "name": .string("Fixture"),
                "endpoint": .string("https://api.openai.com/v1"), "key": .string(secret)
            ])
            guard case .object(let fields) = choice, let id = fields["id"] else { Issue.record("Missing API key choice"); return }
            let result = try host.handle("providers.add", params: [
                "application": .string("codex"), "authorizationID": id, "name": .string("Fixture profile"),
                "supplier": .string("openai"), "endpoint": .string("https://api.openai.com/v1"),
                "model": .string("fixture-model"), "protocol": .string("responses"), "contextWindow": .number(128000)
            ])
            #expect(state.authorizations.providers.count == 1)
            #expect(state.applications.snapshots.isEmpty)
            #expect(state.applications.lastBackup == nil)
            let catalog = try host.handle("providers.catalog", params: ["application": .string("codex")])
            for dto in [choice, result, catalog] {
                let encoded = String(decoding: try JSONEncoder().encode(dto), as: UTF8.self)
                #expect(!encoded.contains(secret))
                #expect(!encoded.contains("fingerprint"))
            }
        }
    }

    @Test func foreignOriginAndUnsupportedProtocolCannotUseSavedCredential() throws {
        try fixture { state, _, host, _ in
            let key = try state.authorizations.saveAccount(supplier: .openai, name: "Fixture", endpoint: "https://api.openai.com/v1", key: "private-fixture-key")
            var params: [String: HostJSON] = [
                "application": .string("codex"), "authorizationID": .string(key.id), "name": .string("Fixture"),
                "supplier": .string("openai"), "endpoint": .string("https://unrelated.invalid/v1"),
                "model": .string("fixture-model"), "protocol": .string("responses"), "contextWindow": .number(128000)
            ]
            #expect(throws: HostError.self) { try host.handle("providers.add", params: params) }
            params["endpoint"] = .string("https://api.openai.com/v1")
            params["protocol"] = .string("anthropic")
            #expect(throws: HostError.self) { try host.handle("providers.add", params: params) }
            #expect(state.authorizations.providers.isEmpty)
        }
    }

    @Test func visibilityPatchValidatesBeforeMutationAndRepairsCurrentRoute() throws {
        try fixture { state, settings, host, _ in
            state.mainTab = .application(.codex)
            #expect(throws: HostError.self) {
                try host.handle("applications.setVisibility", params: ["application": .string("codex"),
                    "patch": .object(["addedToSidebar": .bool(false), "usageVisible": .string("bad")])])
            }
            #expect(state.applications.addedApplications.contains(.codex))
            _ = try host.handle("applications.setVisibility", params: ["application": .string("codex"),
                "patch": .object(["addedToSidebar": .bool(false), "usageVisible": .bool(false)])])
            #expect(state.mainTab == .applications)
            #expect(!settings.isUsageServiceVisible(.codex))
            #expect(state.applications.detected.contains(.codex))
            #expect(throws: HostError.self) {
                try host.handle("applications.setVisibility", params: ["application": .string("gemini"),
                    "patch": .object(["addedToSidebar": .bool(false), "usageVisible": .bool(true)])])
            }
            #expect(state.applications.addedApplications.contains(.gemini))
        }
    }

    @Test func integerValidationRejectsOverflowAndFractionBeforeConversion() throws {
        for value in [Decimal(string: "9223372036854775808")!, Decimal(string: "1.5")!, Decimal(-1)] {
            #expect(throws: HostError.self) { try HostWindowValidation.int(["value": .number(value)], "value") }
        }
        #expect(try HostWindowValidation.int(["value": .number(128000)], "value") == 128000)
    }
}
