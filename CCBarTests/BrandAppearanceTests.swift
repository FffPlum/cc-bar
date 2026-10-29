import AppKit
import XCTest
@testable import CCBar

/// OpenBrand 品牌外观更新测试。
///
/// 覆盖 ServiceBrand 九套默认明暗色、Hex 解析、品牌 / 自定义配色持久化、
/// 重置、OpenCode Go 与 OpenCode 共用品牌，以及 QuotaApp / UsageApp → ServiceBrand 完整映射。
/// 生产侧契约见 `Main/DesignSystem.swift` 的 `BrandColorResolver`、`Core/Branding` 的
/// `ServiceBrand`，以及 `SettingsStore` 的品牌配色 API。
@MainActor
final class BrandAppearanceTests: XCTestCase {
    // MARK: - Helpers

    /// 用独立 UserDefaults 域跑一段断言，结束后清理。
    private func withIsolatedDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "brand-appearance-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    /// 归一化 Hex 比较：去掉前后空白与可选 `#`，统一大写。兼容 `#RRGGBB` 与 `RRGGBB`。
    private func normalizedHex(_ hex: String?) -> String {
        guard let hex else { return "INVALID" }
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        return value.uppercased()
    }

    // MARK: - ServiceBrand defaults

    func testServiceBrandDefaultsMatchContract() {
        let expected: [(ServiceBrand, light: String, dark: String)] = [
            (.codex, "#000000", "#FFFFFF"),
            (.claude, "#D97757", "#D97757"),
            (.antigravity, "#2F88F8", "#2F88F8"),
            (.cursor, "#14120B", "#F7F7F4"),
            (.commandCode, "#000000", "#FFFFFF"),
            (.opencode, "#080808", "#F7F7F7"),
            (.kimi, "#1783FF", "#1783FF"),
            (.pi, "#4D9ABF", "#4D9ABF"),
            (.dsh, "#4D6BFE", "#4D6BFE"),
        ]
        XCTAssertEqual(ServiceBrand.allCases.count, expected.count)
        for (brand, light, dark) in expected {
            XCTAssertEqual(normalizedHex(brand.defaultLightHex), normalizedHex(light), "\(brand) light")
            XCTAssertEqual(normalizedHex(brand.defaultDarkHex), normalizedHex(dark), "\(brand) dark")
        }
    }

    func testServiceBrandLogoNameMapping() {
        let expected: [(ServiceBrand, String)] = [
            (.codex, "codex"),
            (.claude, "claude"),
            (.antigravity, "antigravity"),
            (.cursor, "cursor"),
            (.commandCode, "commandcode"),
            (.opencode, "opencode"),
            (.kimi, "kimi"),
            (.pi, "pi"),
            (.dsh, "dsh"),
        ]
        for (brand, logoName) in expected {
            XCTAssertEqual(brand.logoName, logoName, "\(brand)")
        }
    }

    // MARK: - QuotaApp / UsageApp brand mapping

    func testQuotaAppBrandMapping() {
        XCTAssertEqual(QuotaApp.codex.brand, .codex)
        XCTAssertEqual(QuotaApp.claude.brand, .claude)
        XCTAssertEqual(QuotaApp.antigravity.brand, .antigravity)
        XCTAssertEqual(QuotaApp.cursor.brand, .cursor)
        XCTAssertEqual(QuotaApp.commandCode.brand, .commandCode)
        XCTAssertEqual(QuotaApp.opencodeGo.brand, .opencode)
        XCTAssertEqual(QuotaApp.kimi.brand, .kimi)
    }

    func testUsageAppBrandMapping() {
        XCTAssertEqual(UsageApp.codex.brand, .codex)
        XCTAssertEqual(UsageApp.claude.brand, .claude)
        XCTAssertEqual(UsageApp.cursor.brand, .cursor)
        XCTAssertEqual(UsageApp.pi.brand, .pi)
        XCTAssertEqual(UsageApp.opencode.brand, .opencode)
        XCTAssertEqual(UsageApp.dsh.brand, .dsh)
        XCTAssertEqual(UsageApp.antigravity.brand, .antigravity)
        XCTAssertEqual(UsageApp.kimi.brand, .kimi)
    }

    func testOpenCodeGoSharesOpencodeBrand() {
        XCTAssertEqual(QuotaApp.opencodeGo.brand, .opencode)
        XCTAssertEqual(UsageApp.opencode.brand, .opencode)
        XCTAssertEqual(QuotaApp.opencodeGo.brand.logoName, UsageApp.opencode.brand.logoName)
    }

    // MARK: - Brand color preferences persistence

    func testBrandColorPreferencesDefaultToBrandModeWithNoCustomHex() throws {
        try withIsolatedDefaults { defaults in
            let settings = SettingsStore(defaults: defaults)
            for brand in ServiceBrand.allCases {
                XCTAssertEqual(settings.colorMode(for: brand), .brand)
                XCTAssertNil(settings.customColorHex(for: brand))
            }
        }
    }

    func testRecentBrandColorsPersistDeduplicatedAndLimitedToFive() throws {
        try withIsolatedDefaults { defaults in
            let settings = SettingsStore(defaults: defaults)
            for color in ["#111111", "#222222", "#333333", "#444444", "#555555", "#666666", "#222222"] {
                settings.recordRecentBrandColor(color)
            }
            settings.recordRecentBrandColor("#INVALID")
            let expected = ["#222222", "#666666", "#555555", "#444444", "#333333"]
            XCTAssertEqual(settings.recentBrandColors, expected)
            XCTAssertEqual(SettingsStore(defaults: defaults).recentBrandColors, expected)
        }
    }

    func testTransparentCustomColorAndHistoryPersist() throws {
        try withIsolatedDefaults { defaults in
            let settings = SettingsStore(defaults: defaults)
            settings.applyCustomBrandColor("#12345680", for: .kimi)
            settings.recordRecentBrandColor("#12345680")

            let restored = SettingsStore(defaults: defaults)
            XCTAssertEqual(restored.colorMode(for: .kimi), .custom)
            XCTAssertEqual(restored.customColorHex(for: .kimi), "#12345680")
            XCTAssertEqual(restored.recentBrandColors, ["#12345680"])
            let color = BrandColorResolver.color(for: .kimi, settings: restored)
            XCTAssertEqual(BrandColorResolver.hexString(for: color), "#12345680")
        }
    }

    func testColorInputFormatsValidateRangesAndTransparency() throws {
        guard case .hex(let hex) = try XCTUnwrap(BrandColorResolver.parseInput(" #12ab3480 ", format: .hex)) else {
            return XCTFail("Expected hexadecimal color")
        }
        XCTAssertEqual(hex, "12AB3480")
        guard case .rgb(let red, let green, let blue) = try XCTUnwrap(BrandColorResolver.parseInput("255, 128, 0", format: .rgb)) else {
            return XCTFail("Expected RGB color")
        }
        XCTAssertEqual([red, green, blue], [255, 128, 0])
        guard case .hsb(let hue, let saturation, let brightness) = try XCTUnwrap(BrandColorResolver.parseInput("360, 50, 75", format: .hsb)) else {
            return XCTFail("Expected HSB color")
        }
        XCTAssertEqual([hue, saturation, brightness], [360, 50, 75])
        XCTAssertNil(BrandColorResolver.parseInput("#1234567", format: .hex))
        XCTAssertNil(BrandColorResolver.parseInput("256, 0, 0", format: .rgb))
        XCTAssertNil(BrandColorResolver.parseInput("0, 101, 0", format: .hsb))
        XCTAssertNil(BrandColorResolver.parseInput("NaN, 0, 0", format: .rgb))
    }

    func testBrandColorModeAndCustomHexPersist() throws {
        try withIsolatedDefaults { defaults in
            let settings = SettingsStore(defaults: defaults)
            settings.setColorMode(.custom, for: .kimi)
            settings.setCustomColorHex("#FF0000", for: .kimi)

            let restored = SettingsStore(defaults: defaults)
            XCTAssertEqual(restored.colorMode(for: .kimi), .custom)
            XCTAssertEqual(
                normalizedHex(try XCTUnwrap(restored.customColorHex(for: .kimi))),
                "FF0000"
            )
            // 其他品牌不受影响
            XCTAssertEqual(restored.colorMode(for: .codex), .brand)
            XCTAssertNil(restored.customColorHex(for: .codex))
        }
    }

    func testBrandColorPreferencesPersistUnderVersionedKey() throws {
        try withIsolatedDefaults { defaults in
            let settings = SettingsStore(defaults: defaults)
            settings.setColorMode(.custom, for: .codex)
            settings.setCustomColorHex("#123ABC", for: .codex)

            let data = try XCTUnwrap(defaults.data(forKey: "ccbar.settings.brandColorPreferences.v1"))
            let decoded = try JSONDecoder().decode([String: BrandColorPreference].self, from: data)
            XCTAssertEqual(decoded["codex"]?.mode, .custom)
            XCTAssertEqual(decoded["codex"]?.customHex.map(normalizedHex), "123ABC")
        }
    }

    func testResetBrandColorsClearsAllCustomization() throws {
        try withIsolatedDefaults { defaults in
            let settings = SettingsStore(defaults: defaults)
            settings.setColorMode(.custom, for: .kimi)
            settings.setCustomColorHex("#FF0000", for: .kimi)
            settings.setColorMode(.custom, for: .dsh)

            settings.resetBrandColors()

            for brand in ServiceBrand.allCases {
                XCTAssertEqual(settings.colorMode(for: brand), .brand)
                XCTAssertNil(settings.customColorHex(for: brand))
            }

            let restored = SettingsStore(defaults: defaults)
            XCTAssertEqual(restored.colorMode(for: .kimi), .brand)
            XCTAssertNil(restored.customColorHex(for: .kimi))
            XCTAssertEqual(restored.colorMode(for: .dsh), .brand)
        }
    }

    // MARK: - Hex parsing / formatting

    func testHexColorParsesValidValues() {
        XCTAssertNotNil(BrandColorResolver.color(fromHex: "#1783FF"))
        XCTAssertNotNil(BrandColorResolver.color(fromHex: "#000000"))
        XCTAssertNotNil(BrandColorResolver.color(fromHex: "#FFFFFF"))
        XCTAssertNotNil(BrandColorResolver.color(fromHex: "#F7F7F7"))
    }

    func testHexColorRejectsInvalidValues() {
        XCTAssertNil(BrandColorResolver.color(fromHex: ""))
        XCTAssertNil(BrandColorResolver.color(fromHex: "   "))
        XCTAssertNil(BrandColorResolver.color(fromHex: "XYZ"))
        XCTAssertNil(BrandColorResolver.color(fromHex: "#FFF"))
        XCTAssertNil(BrandColorResolver.color(fromHex: "#12345"))
        XCTAssertNil(BrandColorResolver.color(fromHex: "#1234567"))
        XCTAssertNil(BrandColorResolver.color(fromHex: "#GGGGGG"))
        XCTAssertNil(BrandColorResolver.color(fromHex: "1783FFZ"))
    }

    func testHexFormattingRoundTrips() throws {
        for hex in ["#1783FF", "#000000", "#FFFFFF", "#F7F7F7", "#4D6BFE"] {
            let color = try XCTUnwrap(BrandColorResolver.color(fromHex: hex))
            XCTAssertEqual(
                normalizedHex(BrandColorResolver.hexString(for: color)),
                normalizedHex(hex),
                "round trip \(hex)"
            )
        }
    }

    // MARK: - Resolver

    func testResolverUsesCustomHexWhenSet() throws {
        try withIsolatedDefaults { defaults in
            let settings = SettingsStore(defaults: defaults)
            settings.setColorMode(.custom, for: .codex)
            settings.setCustomColorHex("#A1B2C3", for: .codex)

            let color = BrandColorResolver.color(for: .codex, settings: settings)
            XCTAssertEqual(normalizedHex(BrandColorResolver.hexString(for: color)), "A1B2C3")
        }
    }

    func testResolverFallsBackToBrandWhenCustomHexMissing() throws {
        try withIsolatedDefaults { defaults in
            let settings = SettingsStore(defaults: defaults)
            settings.setColorMode(.custom, for: .codex)

            let color = BrandColorResolver.color(for: .codex, settings: settings)
            let formatted = normalizedHex(BrandColorResolver.hexString(for: color))
            XCTAssertTrue(
                [normalizedHex(ServiceBrand.codex.defaultLightHex),
                 normalizedHex(ServiceBrand.codex.defaultDarkHex)].contains(formatted),
                "expected codex brand default, got \(formatted)"
            )
        }
    }

    func testResolverFallsBackToBrandForInvalidCustomHex() throws {
        try withIsolatedDefaults { defaults in
            let settings = SettingsStore(defaults: defaults)
            settings.setColorMode(.custom, for: .codex)
            settings.setCustomColorHex("not-a-color", for: .codex)

            let color = BrandColorResolver.color(for: .codex, settings: settings)
            let formatted = normalizedHex(BrandColorResolver.hexString(for: color))
            XCTAssertTrue(
                [normalizedHex(ServiceBrand.codex.defaultLightHex),
                 normalizedHex(ServiceBrand.codex.defaultDarkHex)].contains(formatted),
                "expected codex brand default, got \(formatted)"
            )
        }
    }
}

/// 连续向下拖动时，即使行高没有变化，第二次起拖也必须使用新顺序的位置。
@MainActor
final class ReorderLayoutTests: XCTestCase {
    func testConsecutiveMovesUseCurrentOrderWithUnequalRowHeights() throws {
        let sizes: [AnyHashable: CGRect] = [
            "a": CGRect(x: 0, y: 0, width: 600, height: 60),
            "b": CGRect(x: 0, y: 60, width: 600, height: 180),
            "c": CGRect(x: 0, y: 240, width: 600, height: 60)
        ]
        let firstMove = try XCTUnwrap(ReorderLayout.frames(for: ["b", "c", "a"], measurements: sizes))
        XCTAssertEqual(firstMove["b"]?.minY, 0)
        XCTAssertEqual(firstMove["c"]?.minY, 180)
        XCTAssertEqual(firstMove["a"]?.minY, 240)
        let secondMove = try XCTUnwrap(ReorderLayout.frames(for: ["c", "a", "b"], measurements: sizes))
        XCTAssertEqual(secondMove["c"]?.minY, 0)
        XCTAssertEqual(secondMove["a"]?.minY, 60)
        XCTAssertEqual(secondMove["b"]?.minY, 120)
    }

    func testMissingMeasurementsPreventStartingDrag() {
        XCTAssertNil(ReorderLayout.frames(for: ["a"], measurements: [:]))
    }
}
