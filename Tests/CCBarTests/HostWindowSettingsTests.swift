import Foundation
import XCTest
@testable import CCBar

@MainActor
final class HostWindowSettingsTests: XCTestCase {
    func testPatchValidationIsAtomicIncludingCrossFieldRules() async throws {
        let fixture = try SettingsFixture()
        defer { fixture.cleanup() }
        let service = fixture.service()
        let invalid: [[String: HostJSON]] = [
            ["privacyMode": .bool(true), "currency": .string("EUR")],
            ["floatingEnabled": .bool(true), "quotaAlertThresholdPercent": .number(17)],
            ["verboseLogging": .bool(true), "proxyPort": .number(Decimal(string: "12.5")!)],
            ["quotaAlertFiveHourEnabled": .bool(false), "quotaAlertWeeklyEnabled": .bool(false), "quotaAlertBillingCycleEnabled": .bool(false)],
            ["privacyMode": .bool(true), "brandColor": .object(["brand": .string("codex"), "mode": .string("custom"), "customHex": .string("#nope00")])],
            ["privacyMode": .bool(true), "unknown": .bool(true)],
            ["showServiceStatus": .string("false")]
        ]
        for patch in invalid {
            await expectError("invalid_params") { try await service.handle("window.settings.update", params: ["patch": .object(patch)]) }
        }
        XCTAssertFalse(fixture.settings.privacyMode)
        XCTAssertFalse(fixture.settings.floatingEnabled)
        XCTAssertTrue(fixture.settings.quotaAlertFiveHourEnabled)
        XCTAssertTrue(fixture.settings.quotaAlertWeeklyEnabled)
        XCTAssertTrue(fixture.settings.quotaAlertBillingCycleEnabled)
        XCTAssertEqual(fixture.settings.displayCurrency, .usd)
        XCTAssertTrue(fixture.calls.isEmpty)
        XCTAssertFalse(SettingsStore(defaults: fixture.defaults).privacyMode)
    }

    func testSettingsReadAndUpdateUseInjectedSystemState() async throws {
        let fixture = try SettingsFixture()
        defer { fixture.cleanup() }
        fixture.launch = (true, true)
        let service = fixture.service()
        let first = try await service.handle("window.settings.get", params: [:])
        if let output = ProcessInfo.processInfo.environment["CCBAR_WINDOW_SETTINGS_FIXTURE_OUTPUT"] {
            try JSONEncoder().encode(first).write(to: URL(fileURLWithPath: output), options: .atomic)
        }
        XCTAssertEqual(value(first, "general", "launchAtLogin"), .bool(true))
        XCTAssertEqual(value(first, "general", "launchAtLoginRequiresApproval"), .bool(true))
        XCTAssertEqual(value(first, "data", "piTimingGuide", "copyText"), .string("isolated Pi instructions"))
        XCTAssertEqual(value(first, "data", "currency", "rates", "CNY"), .string("7.125"))
        XCTAssertNil(value(first, "data", "currency", "rates", "UNSUPPORTED"))
        _ = try await service.handle("window.settings.get", params: [:])
        XCTAssertEqual(fixture.calls, ["permission.read"])
        let changed = try await service.handle("window.settings.update", params: ["patch": .object([
            "menuBarWindow": .string("both"), "resetTimeDisplay": .string("absolute"),
            "statsRankMetric": .string("cost"), "quotaInterval": .string("m10"), "usageInterval": .string("m1"),
            "proxyMode": .string("manual"), "proxyType": .string("socks5"), "proxyHost": .string("127.0.0.1"),
            "proxyPort": .number(7890), "currency": .string("JPY"), "language": .string("en"),
            "useInstalledAppIcons": .bool(true), "floatingEnabled": .bool(true), "privacyMode": .bool(true),
            "cycleIncludesOtherAgents": .bool(true), "piEstimatedOutputSpeed": .bool(true), "showServiceStatus": .bool(false)
        ])])
        XCTAssertEqual(value(changed, "appearance", "menuBarWindow"), .string("both"))
        XCTAssertEqual(value(changed, "data", "currency", "selected"), .string("JPY"))
        XCTAssertEqual(value(changed, "data", "usage"), fixture.usage)
        XCTAssertEqual(value(changed, "general", "updates"), fixture.updates)
        XCTAssertEqual(fixture.calls, ["permission.read", "intervals.apply", "floating.sync"])
        let restored = SettingsStore(defaults: fixture.defaults)
        XCTAssertEqual(restored.proxyPort, 7890)
        XCTAssertEqual(restored.displayCurrency, .jpy)
        XCTAssertEqual(restored.appLanguage, .en)
        XCTAssertTrue(restored.piEstimatedOutputSpeed)
    }

    func testBrandColorRecentHistoryAndResetPersist() async throws {
        let fixture = try SettingsFixture()
        defer { fixture.cleanup() }
        let service = fixture.service()
        for hex in ["#abc001", "#ABC002", "#ABC003", "#ABC004", "#ABC005", "#ABC006", "#abc003"] {
            _ = try await service.handle("window.settings.update", params: ["patch": .object([
                "brandColor": .object(["brand": .string("codex"), "mode": .string("custom"), "customHex": .string(hex)])
            ])])
        }
        XCTAssertEqual(fixture.settings.recentBrandColors, ["#ABC003", "#ABC006", "#ABC005", "#ABC004", "#ABC002"])
        XCTAssertEqual(fixture.settings.customColorHex(for: .codex), "#ABC003")
        XCTAssertEqual(SettingsStore(defaults: fixture.defaults).colorMode(for: .codex), .custom)
        _ = try await service.handle("settings.resetBrandColors", params: [:])
        XCTAssertEqual(fixture.settings.colorMode(for: .codex), .brand)
        XCTAssertNil(fixture.settings.customColorHex(for: .codex))
        XCTAssertEqual(fixture.settings.recentBrandColors.count, 5)
    }

    func testNotificationPreferencesAndPermissionsAreSeparateAndLaunchFailureDoesNotLie() async throws {
        let fixture = try SettingsFixture()
        defer { fixture.cleanup() }
        let service = fixture.service()
        _ = try await service.handle("window.settings.update", params: ["patch": .object([
            "quotaAlertsEnabled": .bool(true), "quotaAlertSoundEnabled": .bool(true), "quotaAlertThresholdPercent": .number(35)
        ])])
        XCTAssertEqual(fixture.calls, ["notifications.changed"])
        let result = try await service.handle("notifications.requestPermission", params: [:])
        XCTAssertEqual(value(result, "general", "notifications", "authorization"), .string("denied"))
        XCTAssertTrue(fixture.settings.quotaAlertsEnabled)
        XCTAssertEqual(fixture.calls.last, "permission.request")
        fixture.launchFails = true
        await expectError("operation_failed") { try await service.handle("window.settings.setLaunchAtLogin", params: ["enabled": .bool(true)]) }
        fixture.launchFails = false
        let launch = try await service.handle("window.settings.setLaunchAtLogin", params: ["enabled": .bool(true)])
        XCTAssertEqual(value(launch, "general", "launchAtLogin"), .bool(true))
        XCTAssertEqual(value(launch, "general", "launchAtLoginRequiresApproval"), .bool(true))
        _ = try await service.handle("notifications.openSettings", params: [:])
        _ = try await service.handle("window.settings.get", params: [:])
        XCTAssertEqual(Array(fixture.calls.suffix(2)), ["notifications.open", "permission.read"])
    }

    func testPricingPreservesDecimalPricesFormattingAndPartialOutcome() async throws {
        let fixture = try SettingsFixture()
        defer { fixture.cleanup() }
        let service = fixture.service()
        let catalog = try await service.handle("pricing.catalog", params: [:])
        guard case .array(let providers) = value(catalog, "providers"),
              case .array(let models) = value(providers[0], "models") else { return XCTFail("Missing provider catalog") }
        XCTAssertEqual(value(models[0], "price", "input"), .string("0.123456789"))
        XCTAssertEqual(value(models[0], "displayPrice", "input"), .string("formatted:0.123456789"))
        XCTAssertEqual(value(catalog, "refreshFailed"), .bool(true))
        let partial = try await service.handle("pricing.refreshAndRecalculate", params: [:])
        XCTAssertEqual(value(partial, "started"), .bool(true))
        XCTAssertEqual(value(partial, "ok"), .bool(false))
        XCTAssertEqual(value(partial, "usage"), fixture.usage)
        let currency = try await service.handle("settings.refreshCurrency", params: [:])
        XCTAssertNotEqual(value(currency, "data", "currency", "lastRefreshFailedAt"), .null)
        XCTAssertEqual(value(currency, "data", "currency", "rates", "CNY"), .string("7.125"))
        XCTAssertEqual(fixture.calls, ["pricing.load", "pricing.recalculate", "currency.refresh"])
    }

    func testSystemCommandsValidateBeforeInjectedSideEffects() async throws {
        let fixture = try SettingsFixture()
        defer { fixture.cleanup() }
        let service = fixture.service()
        for raw in ["file:///tmp/secret", "javascript:alert(1)", "https://user:secret@example.com", "http://", "https://example.com/\nsecret"] {
            await expectError("invalid_params") { try await service.handle("platform.openExternal", params: ["url": .string(raw)]) }
        }
        await expectError("invalid_params") { try await service.handle("diagnostics.export", params: ["path": .string("/private")]) }
        await expectError("invalid_params") { try await service.handle("updates.setAutomatic", params: ["enabled": .string("true")]) }
        XCTAssertTrue(fixture.calls.isEmpty)
        _ = try await service.handle("platform.openExternal", params: ["url": .string("https://models.dev")])
        _ = try await service.handle("settings.copyPiTimingGuide", params: [:])
        let exported = try await service.handle("diagnostics.export", params: [:])
        XCTAssertEqual(value(exported, "path"), .string("/isolated/diagnostics.zip"))
        _ = try await service.handle("diagnostics.revealLogs", params: [:])
        _ = try await service.handle("updates.check", params: [:])
        _ = try await service.handle("updates.setAutomatic", params: ["enabled": .bool(false)])
        _ = try await service.handle("window.settings.update", params: ["patch": .object(["verboseLogging": .bool(true)])])
        XCTAssertEqual(fixture.calls, ["open:https://models.dev", "copy:isolated Pi instructions", "diagnostics.export", "logs.reveal", "updates.check", "updates.auto:false", "verbose:true"])
    }

    func testProxyReportsConfigurationFailureWithoutNavigationCopy() async throws {
        let fixture = try SettingsFixture()
        defer { fixture.cleanup() }
        fixture.settings.appLanguage = .en
        let service = fixture.service()
        let response = try await service.handle("settings.testProxy", params: [:])
        XCTAssertEqual(value(response, "ok"), .bool(false))
        XCTAssertEqual(value(response, "message"), .string("Port must be between 1 and 65535"))
        XCTAssertEqual(fixture.calls, ["proxy.test"])
    }

    private func value(_ object: HostJSON?, _ path: String...) -> HostJSON? {
        path.reduce(object) { current, key in
            guard case .object(let values) = current else { return nil }
            return values[key]
        }
    }

    private func expectError(_ code: String, operation: () async throws -> HostJSON) async {
        do { _ = try await operation(); XCTFail("Expected \(code)") }
        catch let error as HostError { XCTAssertEqual(error.code, code) }
        catch { XCTFail("Unexpected error: \(error)") }
    }
}

@MainActor
private final class SettingsFixture {
    let suite = "HostWindowSettingsTests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let settings: SettingsStore
    var calls: [String] = []
    var launch = (enabled: false, requiresApproval: false)
    var launchFails = false
    let usage: HostJSON = .object([
        "scanning": .bool(true), "rebuildingHistory": .bool(false), "rebuildingCycles": .bool(false), "refreshingPricing": .bool(false),
        "lastScanAt": .null, "error": .null, "progress": .object(["service": .string("codex"), "filesCompleted": .number(1), "filesTotal": .number(2), "linesParsed": .number(3)]),
        "lastRebuildOutcome": .string("partiallyCommitted"), "lastRebuildMessage": .string("Fixture rebuilt"), "lastRebuildDiagnostic": .null, "historyNotice": .null
    ])
    let updates: HostJSON = .object(["version": .string("test"), "automaticChecks": .bool(true), "canCheck": .bool(true), "hasUpdate": .bool(true), "isWorking": .bool(false), "lastCheckedAt": .null])

    init() throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        settings = SettingsStore(defaults: defaults)
    }
    func cleanup() { defaults.removePersistentDomain(forName: suite) }
    func service() -> HostWindowSettingsService {
        let actions = HostWindowSettingsActions(
            system: HostWindowSystemActions(
                appearance: { "light" }, syncFloating: { self.calls.append("floating.sync") },
                copyText: { self.calls.append("copy:\($0)") }, openExternal: { self.calls.append("open:\($0.absoluteString)"); return true },
                openNotificationSettings: { self.calls.append("notifications.open") }, revealLogs: { self.calls.append("logs.reveal") },
                exportDiagnostics: { self.calls.append("diagnostics.export"); return "/isolated/diagnostics.zip" },
                updates: { self.updates }, checkUpdates: { self.calls.append("updates.check") },
                setAutomaticUpdates: { self.calls.append("updates.auto:\($0)") }),
            launchStatus: { self.launch },
            setLaunchAtLogin: { enabled in
                self.calls.append("login:\(enabled)")
                if self.launchFails { throw NSError(domain: "private failure", code: 1) }
                self.launch = (enabled, enabled)
            },
            currency: { (ExchangeRateSnapshot(fetchedAt: Date(timeIntervalSince1970: 100), sourceUpdatedAt: nil,
                rates: ["USD": 1, "CNY": Decimal(string: "7.125")!, "UNSUPPORTED": 99]), false, Date(timeIntervalSince1970: 101)) },
            refreshCurrency: { self.calls.append("currency.refresh") },
            notifications: { .object([
                "authorization": .string("denied"), "canSubmit": .bool(false), "alertsAllowed": .bool(false), "soundAllowed": .bool(false),
                "statusText": .string("Notifications disabled in system settings"), "requesting": .bool(false), "authorizationFailed": .bool(false),
                "permissionReadFailed": .bool(false), "storagePaused": .bool(false), "rebuilding": .bool(false)
            ]) },
            refreshPermission: { self.calls.append("permission.read") }, requestPermission: { self.calls.append("permission.request") },
            notificationSettingsChanged: { self.calls.append("notifications.changed") },
            rebuildNotifications: { self.calls.append("notifications.rebuild") },
            pricing: { ([ModelsDevProviderPricing(id: "provider", name: "Provider", models: [ModelsDevModelPricing(id: "model", name: "Model", price: ModelPrice(input: Decimal(string: "0.123456789")!, output: 2, cacheRead: 0, cacheCreation: 3))])], Date(timeIntervalSince1970: 200), true) },
            loadPricing: { self.calls.append("pricing.load") },
            recalculate: { self.calls.append("pricing.recalculate"); return PricingRecalculationResult(modelsDevUpdated: true, rebuildOutcome: .partiallyCommitted("Fixture missing prices")) },
            formatPrice: { "formatted:\(NSDecimalNumber(decimal: $0).stringValue)" },
            testProxy: { self.calls.append("proxy.test"); return .failure(.network(.proxyUnavailable)) },
            proxyResolution: { .unavailable(.invalidPort) }, applyVerboseLogging: { self.calls.append("verbose:\($0)") },
            applyRefreshIntervals: { self.calls.append("intervals.apply") },
            piTimingGuide: { "isolated Pi instructions" }
        )
        return HostWindowSettingsService(settings: settings, usageStatus: { self.usage }, actions: actions)
    }
}
