import AppKit
import XCTest
@testable import CCBar

@MainActor
final class ServiceIconTests: XCTestCase {
    // MARK: - Preference persistence

    func testInstalledAppIconPreferenceDefaultsOffAndPersists() throws {
        let suite = "service-icons-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = SettingsStore(defaults: defaults)
        XCTAssertFalse(settings.useInstalledAppIcons)
        settings.useInstalledAppIcons = true

        let restored = SettingsStore(defaults: defaults)
        XCTAssertTrue(restored.useInstalledAppIcons)
    }

    // MARK: - Resolver behavior (ServiceIconResolver in Main/DesignSystem.swift)

    func testResolverPrefersInstalledAppWhenEnabled() throws {
        let appIcon = NSImage()
        let resolved = try XCTUnwrap(ServiceIconResolver.resolve(
            brand: .codex,
            useInstalledAppIcons: true,
            installedAppImage: { brand in
                XCTAssertEqual(brand, .codex)
                return appIcon
            },
            faviconImage: { _ in
                XCTFail("Installed app icon should win")
                return nil
            },
            brandImage: { _ in nil }
        ))

        XCTAssertEqual(resolved.kind, .installedApp)
        XCTAssertTrue(resolved.image === appIcon)
        XCTAssertTrue(resolved.fillsTile)
    }

    func testInstalledAppUsesFullTileForEveryBrand() {
        let image = NSImage()
        for brand in ServiceBrand.allCases {
            let app = ServiceIconResolver.resolve(
                brand: brand,
                useInstalledAppIcons: true,
                installedAppImage: { _ in image },
                faviconImage: { _ in image },
                brandImage: { _ in nil }
            )
            let favicon = ServiceIconResolver.resolve(
                brand: brand,
                useInstalledAppIcons: false,
                installedAppImage: { _ in nil },
                faviconImage: { _ in image },
                brandImage: { _ in nil }
            )
            XCTAssertEqual(app?.kind, .installedApp, "\(brand)")
            XCTAssertEqual(favicon?.kind, .favicon, "\(brand)")
            XCTAssertEqual(app?.fillsTile, true, "\(brand)")
            XCTAssertEqual(favicon?.fillsTile, brand.faviconFillsTile, "\(brand)")
        }
    }

    func testResolverFallsBackToFaviconWhenAppIsUnavailable() throws {
        let favicon = NSImage()
        let resolved = try XCTUnwrap(ServiceIconResolver.resolve(
            brand: .claude,
            useInstalledAppIcons: true,
            installedAppImage: { _ in nil },
            faviconImage: { name in
                XCTAssertEqual(name, "claude")
                return favicon
            },
            brandImage: { _ in nil }
        ))

        XCTAssertEqual(resolved.kind, .favicon)
        XCTAssertTrue(resolved.image === favicon)
        XCTAssertFalse(resolved.fillsTile)
    }

    func testResolverFallsBackToBrandWhenFaviconIsMissing() throws {
        let brand = NSImage()
        let resolved = try XCTUnwrap(ServiceIconResolver.resolve(
            brand: .kimi,
            useInstalledAppIcons: false,
            installedAppImage: { _ in nil },
            faviconImage: { _ in nil },
            brandImage: { _ in brand }
        ))

        XCTAssertEqual(resolved.kind, .brand)
        XCTAssertTrue(resolved.image === brand)
        XCTAssertFalse(resolved.fillsTile)
    }

    func testResolverUsesInstalledKimiAppThroughBrandCatalog() throws {
        let appIcon = NSImage()
        let resolved = try XCTUnwrap(ServiceIconResolver.resolve(
            brand: .kimi,
            useInstalledAppIcons: true,
            installedAppImage: { brand in
                XCTAssertEqual(brand.installedAppCandidate?.bundleIdentifiers, ["com.kimi.code.desktop"])
                return appIcon
            },
            faviconImage: { _ in nil },
            brandImage: { _ in nil }
        ))

        XCTAssertEqual(resolved.kind, .installedApp)
        XCTAssertTrue(resolved.image === appIcon)
    }

    // MARK: - InstalledAppIconLocator candidate contract

    func testInstalledAppCandidatesMatchContract() {
        func assertCandidate(
            _ brand: ServiceBrand,
            ids: [String],
            names: [String],
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            guard let candidate = brand.installedAppCandidate else {
                XCTFail("Missing installed app candidate for \(brand)", file: file, line: line)
                return
            }
            XCTAssertEqual(candidate.bundleIdentifiers, ids, file: file, line: line)
            XCTAssertEqual(candidate.appNames, names, file: file, line: line)
        }

        assertCandidate(.codex, ids: ["com.openai.codex", "com.openai.chat"], names: ["ChatGPT.app", "Codex.app"])
        assertCandidate(.claude, ids: ["com.anthropic.claudefordesktop"], names: ["Claude.app", "Claude Code.app"])
        assertCandidate(.antigravity, ids: ["com.google.antigravity"], names: ["Antigravity.app"])
        assertCandidate(.cursor, ids: ["com.todesktop.230313mzl4w4u92"], names: ["Cursor.app"])
        assertCandidate(.commandCode, ids: [], names: ["Command Code.app"])
        assertCandidate(.opencode, ids: ["ai.opencode.desktop"], names: ["OpenCode.app"])
        assertCandidate(.kimi, ids: ["com.kimi.code.desktop"], names: ["Kimi Code.app"])
        assertCandidate(.dsh, ids: [], names: ["DSH Desktop.app"])
        XCTAssertNil(ServiceBrand.pi.installedAppCandidate)
    }

    func testDefaultApplicationDirectoriesContainSystemAndUserApplications() {
        let paths = InstalledAppIconLocator.defaultApplicationDirectories.map(\.path)
        XCTAssertEqual(paths.count, 2)
        XCTAssertTrue(paths.contains("/Applications"))
        XCTAssertTrue(paths.contains { ($0 as NSString).lastPathComponent == "Applications" && $0 != "/Applications" })
    }

    // MARK: - Bundle-ID lookup validation

    func testKimiBundleIDLookupResolvesAllowedName() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let appURL = try makeFakeApp(named: "Kimi Code.app", bundleID: "com.kimi.code.desktop", in: directory)

        let resolved = try XCTUnwrap(InstalledAppIconLocator.applicationURL(
            for: .kimi,
            applicationURLForBundleID: { bundleID in
                XCTAssertEqual(bundleID, "com.kimi.code.desktop")
                return appURL
            },
            applicationDirectories: []
        ))
        XCTAssertEqual(resolved.path, appURL.path)
    }

    func testChatGPTBundleIDLookupResolvesAllowedName() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let appURL = try makeFakeApp(named: "ChatGPT.app", bundleID: "com.openai.chat", in: directory)

        let resolved = try XCTUnwrap(InstalledAppIconLocator.applicationURL(
            for: .codex,
            applicationURLForBundleID: { bundleID in
                bundleID == "com.openai.chat" ? appURL : nil
            },
            applicationDirectories: []
        ))
        XCTAssertEqual(resolved.path, appURL.path)
    }

    func testBundleIDLookupRejectsWrongFilename() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let appURL = try makeFakeApp(named: "Wrong.app", bundleID: "com.openai.codex", in: directory)

        let resolved = InstalledAppIconLocator.applicationURL(
            for: .codex,
            applicationURLForBundleID: { _ in appURL },
            applicationDirectories: []
        )
        XCTAssertNil(resolved)
    }

    func testBundleIDLookupRejectsClaudeCodeURLHandler() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let handlerURL = try makeFakeApp(
            named: "Claude Code URL Handler.app",
            bundleID: "com.anthropic.claude-code-url-handler",
            in: directory
        )

        let resolved = InstalledAppIconLocator.applicationURL(
            for: .claude,
            applicationURLForBundleID: { _ in handlerURL },
            applicationDirectories: []
        )
        XCTAssertNil(resolved)
    }

    // MARK: - Name fallback

    func testNameFallbackFindsAppWhenCandidateIDsAreEmpty() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let appURL = try makeFakeApp(named: "Command Code.app", bundleID: nil, in: directory)

        let resolved = try XCTUnwrap(InstalledAppIconLocator.applicationURL(
            for: .commandCode,
            applicationURLForBundleID: { _ in nil },
            applicationDirectories: [directory]
        ))
        XCTAssertEqual(resolved.path, appURL.path)
    }

    func testNameFallbackValidatesBundleIDWhenCandidateIDsPresent() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let appURL = try makeFakeApp(named: "Kimi Code.app", bundleID: "com.kimi.code.desktop", in: directory)

        let resolved = try XCTUnwrap(InstalledAppIconLocator.applicationURL(
            for: .kimi,
            applicationURLForBundleID: { _ in nil },
            applicationDirectories: [directory]
        ))
        XCTAssertEqual(resolved.path, appURL.path)
    }

    func testNameFallbackRejectsMismatchedBundleID() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try makeFakeApp(named: "Kimi Code.app", bundleID: "com.example.wrong", in: directory)

        let resolved = InstalledAppIconLocator.applicationURL(
            for: .kimi,
            applicationURLForBundleID: { _ in nil },
            applicationDirectories: [directory]
        )
        XCTAssertNil(resolved)
    }

    func testNameFallbackRejectsClaudeCodeURLHandler() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try makeFakeApp(named: "Claude Code.app", bundleID: "com.anthropic.claude-code-url-handler", in: directory)

        let resolved = InstalledAppIconLocator.applicationURL(
            for: .claude,
            applicationURLForBundleID: { _ in nil },
            applicationDirectories: [directory]
        )
        XCTAssertNil(resolved)
    }

    func testInstalledAppIconNormalizationRemovesTransparentMargins() throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 100,
            pixelsHigh: 100,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        bitmap.bitmapData?.initialize(repeating: 0, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        // 微弱系统阴影不能被当作图标主体边界。
        for y in 10..<90 {
            for x in 10..<90 {
                bitmap.setColor(NSColor.black.withAlphaComponent(0.1), atX: x, y: y)
            }
        }
        for y in 20..<80 {
            for x in 20..<80 {
                bitmap.setColor(.black, atX: x, y: y)
            }
        }
        let image = NSImage(size: NSSize(width: 100, height: 100))
        image.addRepresentation(bitmap)

        let normalized = InstalledAppIconLocator.normalizedAppIcon(image)
        let cgImage = try XCTUnwrap(normalized.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(cgImage.width, 60)
        XCTAssertEqual(cgImage.height, 60)
        XCTAssertFalse(normalized.isTemplate)
    }

    // MARK: - Helpers

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ServiceIconTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func makeFakeApp(named name: String, bundleID: String?, in directory: URL) throws -> URL {
        let appURL = directory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
        if let bundleID {
            let contents = appURL.appendingPathComponent("Contents", isDirectory: true)
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let plist: [String: Any] = ["CFBundleIdentifier": bundleID]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist"))
        }
        return appURL
    }
}
