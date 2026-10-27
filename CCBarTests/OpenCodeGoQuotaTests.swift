import XCTest
@testable import CCBar

final class OpenCodeGoQuotaTests: XCTestCase {
    private var tempHome: URL!

    override func setUpWithError() throws {
        tempHome = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempHome)
    }

    // MARK: - 能力与默认值

    func testQuotaAppCapabilitiesAndOrder() {
        XCTAssertNil(QuotaApp.opencodeGo.usageApp, "OpenCode Go 额度不作为本地用量数据源")

        let desc = QuotaProviderDescriptor.descriptor(for: .opencodeGo)
        XCTAssertEqual(desc?.title, "OpenCode Go")
        XCTAssertEqual(desc?.showsCost, false)
        XCTAssertEqual(desc?.supportsMenuBar, true)
        XCTAssertEqual(desc?.supportsFloatingHUD, true)

        let order = QuotaProviderDescriptor.allProviders.map(\.app)
        XCTAssertEqual(order.last, .kimi)
        XCTAssertEqual(order.firstIndex(of: .opencodeGo), order.firstIndex(of: .commandCode).map { $0 + 1 })
        XCTAssertEqual(order.firstIndex(of: .kimi), order.firstIndex(of: .opencodeGo).map { $0 + 1 })
    }

    func testDefaultsMatchCommandCode() {
        let defaults = ProviderDisplaySettings.defaults(for: .opencodeGo)
        XCTAssertFalse(defaults.enabled, "首次默认关闭，开启前不联网")
        XCTAssertTrue(defaults.menuBar)
        XCTAssertTrue(defaults.floatingHUD)
    }

    func testRefreshPlanFollowsSwitch() {
        let off = QuotaRefreshPlan.make(showCodex: false, showClaude: false, showCursor: false, hasVisibleImported: false)
        XCTAssertFalse(off.refreshOpenCodeGo)
        let on = QuotaRefreshPlan.make(
            showCodex: false, showClaude: false, showCursor: false, showOpenCodeGo: true, hasVisibleImported: false
        )
        XCTAssertTrue(on.refreshOpenCodeGo)
    }

    // MARK: - 凭据

    func testReadsOpenCodeAuthFile() throws {
        try writeJSON(#"{"opencode-go": {"type": "api", "key": "  sk-opencode-go-111  "}}"#,
                      to: ".local/share/opencode/auth.json")
        let session = OpenCodeGoAuth.load(homeDirectory: tempHome, environment: [:])
        XCTAssertEqual(session?.source, .opencode)
        XCTAssertEqual(session?.apiKey, "sk-opencode-go-111")
    }

    func testOpenCodeTakesPriorityOverPiAndEnvironment() throws {
        try writeJSON(#"{"opencode-go": {"type": "api", "key": "sk-opencode-go-111"}}"#,
                      to: ".local/share/opencode/auth.json")
        try writeJSON(#"{"opencode-go": {"type": "api_key", "key": "sk-pi-go-222222"}}"#,
                      to: ".pi/agent/auth.json")
        let session = OpenCodeGoAuth.load(homeDirectory: tempHome, environment: ["OPENCODE_API_KEY": "sk-env-go-333333"])
        XCTAssertEqual(session?.source, .opencode)
    }

    func testFallsBackToPiThenEnvironment() throws {
        try writeJSON(#"{"anthropic": {"type": "api", "key": "sk-ant-unrelated"}}"#,
                      to: ".local/share/opencode/auth.json")
        try writeJSON(#"{"opencode-go": {"type": "api_key", "apiKey": "sk-pi-go-222222"}}"#,
                      to: ".pi/agent/auth.json")
        var session = OpenCodeGoAuth.load(homeDirectory: tempHome, environment: ["OPENCODE_API_KEY": "sk-env-go-333333"])
        XCTAssertEqual(session?.source, .pi)
        XCTAssertEqual(session?.apiKey, "sk-pi-go-222222")

        try FileManager.default.removeItem(at: tempHome.appendingPathComponent(".pi/agent/auth.json"))
        session = OpenCodeGoAuth.load(homeDirectory: tempHome, environment: ["OPENCODE_API_KEY": "sk-env-go-333333"])
        XCTAssertEqual(session?.source, .environment)
        XCTAssertEqual(session?.apiKey, "sk-env-go-333333")
    }

    func testHonorsXDGDataHome() throws {
        let xdg = tempHome.appendingPathComponent("xdg-data")
        try writeJSON(#"{"opencode-go": {"type": "api", "key": "sk-xdg-go-444444"}}"#,
                      to: "xdg-data/opencode/auth.json")
        let session = OpenCodeGoAuth.load(homeDirectory: tempHome, environment: ["XDG_DATA_HOME": xdg.path])
        XCTAssertEqual(session?.source, .opencode)
        XCTAssertEqual(session?.apiKey, "sk-xdg-go-444444")
        XCTAssertEqual(
            OpenCodeGoAuth.openCodeAuthURL(homeDirectory: tempHome, environment: ["XDG_DATA_HOME": "relative/path"]),
            tempHome.appendingPathComponent(".local/share/opencode/auth.json"),
            "相对路径的 XDG_DATA_HOME 不可信，回到默认位置"
        )
    }

    func testRejectsInvalidKeys() throws {
        XCTAssertNil(OpenCodeGoAuth.sanitizeKey("short"))
        XCTAssertNil(OpenCodeGoAuth.sanitizeKey("sk-has\u{0}control-char"))
        XCTAssertEqual(OpenCodeGoAuth.sanitizeKey("\n sk-opencode-go-111 \t"), "sk-opencode-go-111")

        try writeJSON(#"{"opencode-go": {"type": "api", "key": "short"}}"#, to: ".local/share/opencode/auth.json")
        let session = OpenCodeGoAuth.load(homeDirectory: tempHome, environment: ["OPENCODE_API_KEY": "sk-env-go-333333"])
        XCTAssertEqual(session?.source, .environment, "无效 key 不采用，继续找下一个来源")
    }

    func testAccountKeyIsFullDigestWithoutKeyFragments() {
        let session = OpenCodeGoAuthSession(apiKey: "sk-opencode-go-111", source: .opencode)
        XCTAssertEqual(session.accountKey.count, 64)
        XCTAssertFalse(session.accountKey.contains("opencode"))
        XCTAssertNotEqual(session.accountKey, OpenCodeGoAuthSession(apiKey: "sk-opencode-go-112", source: .opencode).accountKey)
    }

    // MARK: - 响应解析

    func testParsesAllThreeWindows() throws {
        let snapshot = try XCTUnwrap(OpenCodeGoQuotaClient.parse(root: usage(
            rolling: ["status": "ok", "percent": 4, "resetsAt": "2026-08-13T16:27:38.287Z"],
            weekly: ["status": "ok", "percent": 3.5, "resetsAt": "2026-08-17T00:00:00Z"],
            monthly: ["status": "ok", "percent": 1, "resetsAt": "2026-09-13T06:06:01.287Z"]
        )))
        XCTAssertEqual(snapshot.app, .opencodeGo)
        XCTAssertNil(snapshot.planType)

        let rolling = try XCTUnwrap(snapshot.primaryLimit)
        XCTAssertEqual(rolling.id, "opencode-go-rolling")
        XCTAssertEqual(rolling.kind, .fiveHour)
        XCTAssertEqual(rolling.window.usedPercent, 4)
        XCTAssertEqual(rolling.window.remainingPercent, 96)
        XCTAssertEqual(rolling.window.windowSeconds, 18_000)
        XCTAssertEqual(try XCTUnwrap(rolling.window.resetsAt).timeIntervalSince1970, 1_786_638_458.287, accuracy: 0.001)

        let weekly = try XCTUnwrap(snapshot.secondaryLimit)
        XCTAssertEqual(weekly.id, "opencode-go-weekly")
        XCTAssertEqual(weekly.kind, .weekly)
        XCTAssertEqual(weekly.window.usedPercent, 3.5)
        XCTAssertNotNil(weekly.window.resetsAt, "不带毫秒的 ISO8601 也要能解析")

        XCTAssertEqual(snapshot.auxiliaryLimits.map(\.id), ["opencode-go-monthly"])
        XCTAssertEqual(snapshot.auxiliaryLimits.first?.kind, .unknown)
        XCTAssertEqual(snapshot.auxiliaryLimits.first?.displayName, "MONTHLY")
    }

    func testRateLimitedWindowIsFullyUsed() throws {
        let snapshot = try XCTUnwrap(OpenCodeGoQuotaClient.parse(root: usage(
            rolling: ["status": "rate-limited", "percent": 87],
            weekly: ["status": "rate-limited"],
            monthly: ["status": "ok", "percent": 20]
        )))
        XCTAssertEqual(snapshot.primaryLimit?.window.usedPercent, 100)
        XCTAssertEqual(snapshot.secondaryLimit?.window.usedPercent, 100, "rate-limited 即使缺 percent 也按用完处理")
        XCTAssertEqual(snapshot.auxiliaryLimits.first?.window.usedPercent, 20)
    }

    func testClampsAndSkipsInvalidWindows() throws {
        let snapshot = try XCTUnwrap(OpenCodeGoQuotaClient.parse(root: usage(
            rolling: ["status": "ok", "percent": 140],
            weekly: ["status": "ok", "percent": "not-a-number"],
            monthly: ["status": "ok", "percent": true]
        )))
        XCTAssertEqual(snapshot.primaryLimit?.window.usedPercent, 100)
        XCTAssertNil(snapshot.secondaryLimit, "无法解析的窗口不伪造 0%")
        XCTAssertTrue(snapshot.auxiliaryLimits.isEmpty, "布尔值不能当成百分比")

        let negative = try XCTUnwrap(OpenCodeGoQuotaClient.parse(root: usage(rolling: ["percent": -5])))
        XCTAssertEqual(negative.primaryLimit?.window.usedPercent, 0)
        XCTAssertNil(negative.primaryLimit?.window.resetsAt)
    }

    func testReturnsNilWhenNoWindowParses() {
        XCTAssertNil(OpenCodeGoQuotaClient.parse(root: [:]))
        XCTAssertNil(OpenCodeGoQuotaClient.parse(root: ["usage": "unexpected"]))
        XCTAssertNil(OpenCodeGoQuotaClient.parse(root: usage(rolling: ["status": "ok"])))
    }

    // MARK: - Helpers

    private func usage(
        rolling: [String: Any]? = nil,
        weekly: [String: Any]? = nil,
        monthly: [String: Any]? = nil
    ) -> [String: Any] {
        var usage: [String: Any] = [:]
        usage["rolling"] = rolling
        usage["weekly"] = weekly
        usage["monthly"] = monthly
        return ["usage": usage]
    }

    private func writeJSON(_ json: String, to relativePath: String) throws {
        let url = tempHome.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url)
    }
}
