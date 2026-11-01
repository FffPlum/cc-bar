import XCTest
import WebKit
@testable import CCBar

@MainActor
final class HostAPITests: XCTestCase {
    func testWireFixtureAndOriginChecks() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("packages/host-api/fixtures/wire.json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let requestData = try JSONSerialization.data(withJSONObject: XCTUnwrap(object["request"]))
        let request = try JSONDecoder().decode(HostRequest.self, from: requestData)
        XCTAssertEqual(request.method, "settings.get")
        let success = HostResponse(id: "fixture-1", result: .object(["privacyMode": .bool(false), "useInstalledAppIcons": .bool(true)]))
        let error = HostResponse(id: "fixture-1", error: HostError(code: "invalid_params", message: "Invalid parameters"))
        let event = HostEvent(revision: "1", domains: ["settings"])
        for (key, encoded) in [("success", try JSONEncoder().encode(success)), ("error", try JSONEncoder().encode(error)), ("event", try JSONEncoder().encode(event))] {
            let actual = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? NSDictionary)
            let expected = try XCTUnwrap(object[key] as? NSDictionary)
            XCTAssertEqual(actual, expected)
        }
        let trusted = try XCTUnwrap(URL(string: "https://localhost:8443/app"))
        XCTAssertTrue(MacOSWebKitTransport.isTrusted(mainFrame: true, url: trusted, trustedURL: trusted))
        XCTAssertFalse(MacOSWebKitTransport.isTrusted(mainFrame: false, url: trusted, trustedURL: trusted))
        XCTAssertFalse(MacOSWebKitTransport.isTrusted(mainFrame: true, url: URL(string: "https://evil.example/app"), trustedURL: trusted))
        XCTAssertFalse(MacOSWebKitTransport.isTrusted(mainFrame: true, url: URL(string: "https://localhost/app"), trustedURL: trusted))
    }

    func testSettingsAndErrorsAndPlatform() async throws {
        let suite = "HostAPITests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        let actions = HostPlatformActions(capabilities: ["platform.pickDirectory"], pickDirectory: { nil }, revealPath: { _ in XCTFail() }, setLaunchAtLogin: { _ in XCTFail(); return (false, false) })
        let service = MacOSHostService(state: AppState(), settings: settings, platform: actions)
        func request(_ method: String, _ params: [String: HostJSON] = [:], version: Int = 1) -> HostRequest {
            HostRequest(version: version, id: "1", method: method, params: params)
        }
        let old = settings.privacyMode
        let bad = await service.handle(request("settings.update", ["patch": .object(["privacyMode": .bool(!old), "useInstalledAppIcons": .string("bad")])]))
        XCTAssertEqual(bad.error?.code, "invalid_params")
        XCTAssertEqual(settings.privacyMode, old)
        let good = await service.handle(request("settings.update", ["patch": .object(["privacyMode": .bool(!old)])]))
        XCTAssertNil(good.error)
        XCTAssertEqual(SettingsStore(defaults: defaults).privacyMode, !old)
        let cancelled = await service.handle(request("platform.pickDirectory"))
        XCTAssertEqual(cancelled.result, .object(["path": .null]))
        let denied = await service.handle(request("platform.revealPath", ["path": .string("/tmp")]))
        XCTAssertEqual(denied.error?.code, "unavailable")
        let unknown = await service.handle(request("unknown"))
        XCTAssertEqual(unknown.error?.code, "unknown_method")
        let version = await service.handle(request("settings.get", version: 2))
        XCTAssertEqual(version.error?.code, "unsupported_version")
    }

    func testSubscriptionObservesExternalChangeAndStops() async throws {
        let suite = "HostAPITests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        let service = MacOSHostService(state: AppState(), settings: settings)
        let changed = expectation(description: "external settings write")
        var count = 0
        let id = service.subscribe { _ in count += 1; changed.fulfill() }
        settings.privacyMode.toggle()
        await fulfillment(of: [changed], timeout: 2)
        service.unsubscribe(id)
        settings.privacyMode.toggle()
        await Task.yield()
        XCTAssertEqual(count, 1)
    }
    func testPlatformActionsAndDescribe() async throws {
        let suite = "HostAPITests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var selected = 0
        var revealed: [String] = []
        var launchValues: [Bool] = []
        var shouldFail = false
        let actions = HostPlatformActions(
            capabilities: ["platform.pickDirectory", "platform.revealPath", "platform.setLaunchAtLogin"],
            pickDirectory: { selected += 1; return "/chosen" },
            revealPath: { path in
                revealed.append(path)
                if shouldFail { throw NSError(domain: "private diagnostic", code: 1) }
            },
            setLaunchAtLogin: { enabled in launchValues.append(enabled); return (false, true) }
        )
        let service = MacOSHostService(state: AppState(), settings: SettingsStore(defaults: defaults), platform: actions)
        func request(_ method: String, _ params: [String: HostJSON] = [:]) -> HostRequest {
            HostRequest(version: 1, id: "platform", method: method, params: params)
        }
        let describe = await service.handle(request("host.describe"))
        guard case .object(let description) = describe.result, case .array(let capabilities) = description["capabilities"] else {
            return XCTFail("Missing host description")
        }
        XCTAssertEqual(description["platform"], .string("macos"))
        XCTAssertEqual(description["timeZone"], .string(TimeZone.current.identifier))
        XCTAssertEqual(Set(capabilities.compactMap { if case .string(let value) = $0 { return value }; return nil }),
                       Set(["host.describe", "usage.overview", "quota.snapshot", "quota.refresh", "settings.get", "settings.update", "platform.pickDirectory", "platform.revealPath", "platform.setLaunchAtLogin"]))
        let pick = await service.handle(request("platform.pickDirectory"))
        XCTAssertEqual(pick.result, .object(["path": .string("/chosen")]))
        XCTAssertEqual(selected, 1)
        let reveal = await service.handle(request("platform.revealPath", ["path": .string("/chosen")]))
        XCTAssertEqual(reveal.result, .object([:]))
        XCTAssertEqual(revealed, ["/chosen"])
        let launch = await service.handle(request("platform.setLaunchAtLogin", ["enabled": .bool(true)]))
        XCTAssertEqual(launch.result, .object(["enabled": .bool(false), "requiresApproval": .bool(true)]))
        XCTAssertEqual(launchValues, [true])
        let invalid = await service.handle(request("platform.setLaunchAtLogin", ["enabled": .string("true")]))
        XCTAssertEqual(invalid.error?.code, "invalid_params")
        XCTAssertEqual(launchValues, [true])
        let invalidReveal = await service.handle(request("platform.revealPath", ["path": .bool(true)]))
        XCTAssertEqual(invalidReveal.error?.code, "invalid_params")
        XCTAssertEqual(revealed, ["/chosen"])
        shouldFail = true
        let failed = await service.handle(request("platform.revealPath", ["path": .string("/chosen")]))
        XCTAssertEqual(failed.error, HostError(code: "operation_failed", message: "Native operation failed"))
    }

    func testUsageMapsExistingModelAndFilter() async throws {
        let suite = "HostAPITests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.setUsageServiceVisible(true, for: .codex)
        settings.setUsageServiceVisible(true, for: .claude)
        let state = AppState()
        let day = Calendar.current.startOfDay(for: Date())
        let next = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 1, to: day))
        let buckets = [
            UsageBucket(app: .codex, model: "gpt", speed: .standard, day: day, inputTokens: 10, outputTokens: 4, cacheReadTokens: 7, cacheCreationTokens: 2, costUSD: Decimal(string: "1.25")!, requestCount: 2, hasUnpricedUsage: true, costIncomplete: true),
            UsageBucket(app: .claude, model: "claude", speed: .standard, day: day, inputTokens: 100, outputTokens: 1, cacheReadTokens: 0, cacheCreationTokens: 0, costUSD: 5, requestCount: 1, hasUnpricedUsage: false)
        ]
        state.usageService.aggregator.load(from: buckets)
        let interval = StatsDateInterval(from: day, to: next)
        let model = StatsOverviewModel.build(buckets: buckets, input: StatsOverviewInput(revision: 1, current: interval, previous: nil, chart: interval, granularity: .day, serviceApp: .codex, visibleApps: settings.visibleUsageApps, highlightedPeriodStart: nil))
        let formatter = ISO8601DateFormatter()
        let params: [String: HostJSON] = ["from": .string(formatter.string(from: day)), "to": .string(formatter.string(from: next)), "service": .string("codex")]
        let response = await MacOSHostService(state: state, settings: settings).handle(HostRequest(version: 1, id: "x", method: "usage.overview", params: params))
        guard case .object(let result) = response.result, case .object(let totals) = result["totals"], case .array(let samples) = result["samples"] else { return XCTFail("Unexpected result") }
        XCTAssertEqual(totals["totalTokens"], .number(Decimal(model.totalsAll.totalTokens)))
        XCTAssertEqual(totals["cacheReadTokens"], .number(7))
        XCTAssertEqual(totals["cacheCreationTokens"], .number(2))
        XCTAssertEqual(totals["costUSD"], .string("1.25"))
        XCTAssertEqual(totals["hasUnpricedUsage"], .bool(true))
        XCTAssertEqual(totals["costIncomplete"], .bool(true))
        XCTAssertEqual(samples.count, model.samples.count)
        let bad = await MacOSHostService(state: state, settings: settings).handle(HostRequest(version: 1, id: "x", method: "usage.overview", params: ["from": .string(formatter.string(from: day.addingTimeInterval(3600))), "to": .string(formatter.string(from: next))]))
        XCTAssertEqual(bad.error?.code, "invalid_params")
    }

    func testQuotaRefreshAndBackgroundObservation() async throws {
        let suite = "HostAPITests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState()
        let old = QuotaSnapshot(app: .codex, primaryLimit: nil, secondaryLimit: nil, planType: nil, fetchedAt: Date())
        var primary = PrimaryQuotaState()
        primary.snapshot = old
        primary.refresh.backoffUntil = Date().addingTimeInterval(600)
        primary.refresh.lastError = "private error"
        state.primaryQuotaStates[.codex] = primary
        var calls = 0
        let service = MacOSHostService(state: state, settings: SettingsStore(defaults: defaults), refreshQuota: { calls += 1 })
        let changed = expectation(description: "background usage")
        let id = service.subscribe { _ in changed.fulfill() }
        state.usageService.aggregator.load(from: [])
        await fulfillment(of: [changed], timeout: 2)
        service.unsubscribe(id)
        let again = expectation(description: "background quota")
        let second = service.subscribe { _ in again.fulfill() }
        state.primaryQuotaStates[.codex] = primary
        await fulfillment(of: [again], timeout: 2)
        service.unsubscribe(second)
        let response = await service.handle(HostRequest(version: 1, id: "q", method: "quota.refresh", params: [:]))
        XCTAssertEqual(calls, 1)
        guard case .object(let result) = response.result, case .array(let services) = result["services"], case .object(let codex) = services.first, case .object(let refresh) = codex["refresh"] else { return XCTFail("Unexpected quota") }
        XCTAssertNotEqual(codex["snapshot"], .null)
        XCTAssertEqual(refresh["failed"], .bool(true))
        XCTAssertNotEqual(refresh["backoffUntil"], .null)
        XCTAssertNil(refresh["lastError"])
    }

    func testWebKitRoundTripEventAndUninstall() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("index.html")
        try "<html><body>host test</body></html>".write(to: file, atomically: true, encoding: .utf8)
        let suite = "HostAPITests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        let service = MacOSHostService(state: AppState(), settings: settings)
        let webView = WKWebView(frame: .zero)
        let navigation = HostNavigationDelegate()
        webView.navigationDelegate = navigation
        let loaded = expectation(description: "loaded")
        navigation.didLoad = { loaded.fulfill() }
        let bridge = MacOSWebKitTransport(service: service, trustedURL: file)
        XCTAssertTrue(bridge.install(on: webView))
        let competing = MacOSWebKitTransport(service: service, trustedURL: file)
        XCTAssertFalse(competing.install(on: webView))
        competing.uninstall()
        webView.loadFileURL(file, allowingReadAccessTo: dir)
        await fulfillment(of: [loaded], timeout: 10)
        let response = try await webView.callAsyncJavaScript("return await window.webkit.messageHandlers.ccbarHost.postMessage({version:1,id:'w',method:'settings.get',params:{}})", arguments: [:], in: nil, contentWorld: .page)
        let value = try XCTUnwrap(response as? [String: Any])
        XCTAssertEqual(value["id"] as? String, "w")
        _ = try await webView.callAsyncJavaScript("window.__ccbarHostReceiveEvent = e => { window.receivedHostEvent = e; };", arguments: [:], in: nil, contentWorld: .page)
        settings.privacyMode.toggle()
        let event = expectation(description: "event")
        Task { @MainActor in
            for _ in 0..<100 {
                if let value = try? await webView.callAsyncJavaScript("return window.receivedHostEvent?.event", arguments: [:], in: nil, contentWorld: .page), value as? String == "state.changed" { event.fulfill(); return }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        await fulfillment(of: [event], timeout: 5)
        bridge.uninstall()
        // Reinstallation would fail if the old handler had not been removed.
        XCTAssertTrue(competing.install(on: webView))
        bridge.uninstall()
        XCTAssertFalse(bridge.install(on: webView))
        competing.uninstall()
        XCTAssertTrue(bridge.install(on: webView))
        bridge.uninstall()
    }

}


@MainActor
private final class HostNavigationDelegate: NSObject, WKNavigationDelegate {
    var didLoad: (() -> Void)?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { didLoad?() }
}
