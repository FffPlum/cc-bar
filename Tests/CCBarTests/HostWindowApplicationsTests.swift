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

@Suite(.serialized) @MainActor
struct ApplicationManagerTests {
    @Test func inventoryAndPlansNeverAcceptCallerSuppliedCommands() async throws {
        let fixture = try ManagementFixture()
        defer { fixture.cleanup() }
        let first = try fixture.host.handle("applications.inventory", params: [:])
        guard case .object(let fields) = first else { Issue.record("Missing inventory"); return }
        #expect(fields["scanning"] == .bool(true))
        try await wait { !fixture.manager.scanning }
        #expect(throws: HostError.self) {
            try fixture.host.handle("applications.planOperation", params: ["catalogID": .string("fixture-tool"),
                "action": .string("install"), "command": .string("arbitrary-command")])
        }
        #expect(throws: HostError.self) {
            try fixture.host.handle("applications.executeOperation", params: ["planID": .string("unknown"), "path": .string("/private")])
        }
        #expect(await fixture.stub.executions == 0)
    }

    @Test func confirmedPlanExecutesOnceAndRefreshesActualInstallation() async throws {
        let fixture = try ManagementFixture()
        defer { fixture.cleanup() }
        fixture.manager.ensureScan()
        try await wait { !fixture.manager.scanning }
        let (id, _, _) = try fixture.manager.prepare(catalogID: "fixture-tool", action: .install, installationID: nil)
        try fixture.manager.execute(planID: id)
        #expect(fixture.manager.hasActiveOperation)
        #expect(throws: HostError.self) { try fixture.manager.execute(planID: id) }
        try await wait { !fixture.manager.hasActiveOperation }
        #expect(fixture.manager.operation?.status == "succeeded")
        #expect(fixture.manager.inventory["fixture-tool"]?.installations.count == 1)
        #expect(await fixture.stub.executions == 1)
        #expect(throws: HostError.self) { try fixture.manager.execute(planID: id) }
    }

    @Test func changedInstallationInvalidatesThePlanBeforeRunningAnything() async throws {
        let fixture = try ManagementFixture()
        defer { fixture.cleanup() }
        fixture.manager.ensureScan()
        try await wait { !fixture.manager.scanning }
        let (id, _, _) = try fixture.manager.prepare(catalogID: "fixture-tool", action: .install, installationID: nil)
        await fixture.stub.setInstalled()
        try fixture.manager.execute(planID: id)
        try await wait { !fixture.manager.hasActiveOperation }
        #expect(fixture.manager.operation?.status == "failed")
        #expect(await fixture.stub.executions == 0)
        #expect(fixture.manager.inventory["fixture-tool"]?.installations.count == 1)
    }

    @Test func failedOperationKeepsItsLockUntilRecoveryScanFinishes() async throws {
        let fixture = try ManagementFixture()
        defer { fixture.cleanup() }
        fixture.manager.ensureScan()
        try await wait { !fixture.manager.scanning }
        let (id, _, _) = try fixture.manager.prepare(catalogID: "fixture-tool", action: .install, installationID: nil)
        await fixture.stub.failAndPauseRecovery()
        try fixture.manager.execute(planID: id)
        for _ in 0..<100 {
            if await fixture.stub.recoveryWaiting { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await fixture.stub.recoveryWaiting)
        #expect(fixture.manager.operation?.status == "running")
        #expect(throws: HostError.self) {
            try fixture.manager.prepare(catalogID: "fixture-tool", action: .install, installationID: nil)
        }
        await fixture.stub.resumeRecovery()
        try await wait { !fixture.manager.hasActiveOperation }
        #expect(fixture.manager.operation?.status == "failed")
    }

    @Test func rescanRecomparesCachedReleaseAfterAnExternalDowngrade() async throws {
        let fixture = try ManagementFixture(source: .native, latestVersion: "2.0.0")
        defer { fixture.cleanup() }
        await fixture.stub.setInstalled(version: "2.0.0")
        fixture.manager.ensureScan()
        try await wait { !fixture.manager.scanning }
        try fixture.manager.checkVersions(catalogID: "fixture-tool")
        try await wait { !fixture.manager.checkingVersions }
        #expect(try versionStatus(fixture.host) == "current")
        await fixture.stub.setInstalled(version: "1.0.0")
        fixture.manager.ensureScan(refresh: true)
        try await wait { !fixture.manager.scanning }
        #expect(try versionStatus(fixture.host) == "updateAvailable")
    }

    private func versionStatus(_ host: HostWindowApplicationsService) throws -> String? {
        guard case .object(let root) = try host.handle("applications.inventory", params: [:]),
              case .array(let applications) = root["applications"], case .object(let app) = applications.first,
              case .array(let installations) = app["installations"], case .object(let installation) = installations.first,
              case .object(let version) = installation["versionCheck"], case .string(let status) = version["status"] else { return nil }
        return status
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition() {
            guard ContinuousClock.now < deadline else { Issue.record("Application task did not settle"); return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

@MainActor
private struct ManagementFixture {
    let suite = "CCBarTests.application-management." + UUID().uuidString
    let directory: URL
    let defaults: UserDefaults
    let stub: ManagementStub
    let manager: ApplicationManager
    let host: HostWindowApplicationsService
    init(source: ApplicationInstallationSource = .unknown, latestVersion: String = "1.0.0") throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defaults = try #require(UserDefaults(suiteName: suite))
        let definition = ManagedApplicationDefinition(id: "fixture-tool", name: "Fixture", website: "https://example.invalid",
            commands: ["fixture-tool"], installScript: "https://example.invalid/install.sh", releaseSource: .npm("fixture-tool"))
        let stub = ManagementStub(directory: directory, source: source)
        self.stub = stub
        manager = ApplicationManager(definitions: [definition],
            environment: ApplicationDiscoveryEnvironment(home: directory, environment: ["PATH": ""], applicationDirectories: [], standardExecutableDirectories: []),
            discover: { _ in await stub.scan() }, latest: { _ in latestVersion }, run: { _ in try await stub.install(); return "Fixture installed" })
        let store = ApplicationStore(defaults: defaults, management: manager)
        let state = AppState(authorizations: AuthorizationStore(directory: directory), applications: store)
        host = HostWindowApplicationsService(state: state, settings: SettingsStore(defaults: defaults), detect: {})
    }
    func cleanup() { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
}

private actor ManagementStub {
    let directory: URL
    let source: ApplicationInstallationSource
    private var version = "1.0.0"
    var installed = false
    private(set) var executions = 0
    private var failInstallation = false
    private var recovery: CheckedContinuation<Void, Never>?
    var recoveryWaiting: Bool { recovery != nil }
    init(directory: URL, source: ApplicationInstallationSource) { self.directory = directory; self.source = source }
    func setInstalled(version: String = "1.0.0") { installed = true; self.version = version }
    func failAndPauseRecovery() { failInstallation = true }
    func resumeRecovery() { recovery?.resume(); recovery = nil; failInstallation = false }
    func install() throws {
        executions += 1
        if failInstallation { throw ApplicationLifecycleError.failed("Fixture failure") }
        installed = true
    }
    func scan() async -> [String: ApplicationDiscoveryResult] {
        if failInstallation, executions > 0 { await withCheckedContinuation { recovery = $0 } }
        let path = directory.appendingPathComponent("bin/fixture-tool").path
        return ["fixture-tool": ApplicationDiscoveryResult(installations: installed
            ? [ApplicationInstallation(catalogID: "fixture-tool", path: path, resolvedPath: path, version: version, source: source)] : [])]
    }
}
