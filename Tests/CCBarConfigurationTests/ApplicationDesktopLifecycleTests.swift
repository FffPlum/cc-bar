import Foundation
import Darwin
import Testing
@testable import CCBarConfiguration

struct ApplicationDesktopLifecycleTests {
    @Test func caskManifestSelectsTheActualArchitecture() throws {
        let data = try manifest([
            "variations": ["sonoma": ["url": "https://persistent.oaistatic.com/Codex-x64.zip",
                                        "sha256": String(repeating: "b", count: 64)]]
        ])
        let arm = try ApplicationDesktopLifecycle.parseManifest(data, cask: "codex-app", architecture: "arm64", macOSMajorVersion: 14)
        let intel = try ApplicationDesktopLifecycle.parseManifest(data, cask: "codex-app", architecture: "x86_64", macOSMajorVersion: 14)
        #expect(arm.url.lastPathComponent == "Codex-arm64.zip")
        #expect(intel.url.lastPathComponent == "Codex-x64.zip")
        #expect(arm.sha256 == String(repeating: "a", count: 64))
        #expect(intel.sha256 == String(repeating: "b", count: 64))
        #expect(throws: ApplicationDesktopLifecycle.Failure.invalidManifest) {
            try ApplicationDesktopLifecycle.parseManifest(data, cask: "codex-app", architecture: "x86_64", macOSMajorVersion: 999)
        }
    }

    @Test func manifestCannotRedirectToAnUnrelatedProductOrUnsecuredDownload() throws {
        let invalid: [[String: Any]] = [
            ["token": "cursor"], ["url": "http://persistent.oaistatic.com/Codex.zip"],
            ["url": "https://persistent.oaistatic.com.evil.test/Codex.zip"],
            ["url": "https://name:secret@persistent.oaistatic.com/Codex.zip"],
            ["url": "https://persistent.oaistatic.com/install.pkg"], ["sha256": "bad-digest"]
        ]
        for patch in invalid {
            #expect(throws: ApplicationDesktopLifecycle.Failure.invalidManifest) {
                try ApplicationDesktopLifecycle.parseManifest(manifest(patch), cask: "codex-app", architecture: "arm64")
            }
        }
        let unchecked = try ApplicationDesktopLifecycle.parseManifest(manifest(["sha256": "no_check"]),
                                                                       cask: "codex-app", architecture: "arm64")
        #expect(unchecked.sha256 == nil)
    }

    @Test func applicationTargetsMustBeDirectChildrenAndCannotUseSymlinks() throws {
        let fixture = try DesktopFixture()
        defer { fixture.remove() }
        let applications = fixture.root.appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: false)
        let target = applications.appendingPathComponent("Codex.app")
        #expect(try ApplicationDesktopLifecycle.validateTarget(target.path, applicationDirectories: [applications]) == target)
        #expect(throws: ApplicationDesktopLifecycle.Failure.invalidTarget) {
            try ApplicationDesktopLifecycle.validateTarget(applications.appendingPathComponent("nested/Codex.app").path,
                                                          applicationDirectories: [applications])
        }
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: fixture.root)
        #expect(throws: ApplicationDesktopLifecycle.Failure.invalidTarget) {
            try ApplicationDesktopLifecycle.validateTarget(target.path, applicationDirectories: [applications])
        }
    }

    @Test func bundleValidationRequiresExactIDAndAnExecutableInsideTheBundle() throws {
        let fixture = try DesktopFixture()
        defer { fixture.remove() }
        let bundle = try fixture.makeBundle(identifier: "com.openai.codex")
        #expect(try ApplicationDesktopLifecycle.bundleIdentity(at: bundle, permittedIDs: ["com.openai.codex"]).id == "com.openai.codex")
        #expect(throws: ApplicationDesktopLifecycle.Failure.invalidBundle) {
            try ApplicationDesktopLifecycle.bundleIdentity(at: bundle, permittedIDs: ["com.anthropic.claudefordesktop"])
        }
        let executable = bundle.appendingPathComponent("Contents/MacOS/Fixture")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        #expect(throws: ApplicationDesktopLifecycle.Failure.invalidBundle) {
            try ApplicationDesktopLifecycle.bundleIdentity(at: bundle, permittedIDs: ["com.openai.codex"])
        }
        try FileManager.default.removeItem(at: executable)
        let outside = fixture.root.appendingPathComponent("outside")
        try Data([0xcf, 0xfa, 0xed, 0xfe]).write(to: outside)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: outside.path)
        try FileManager.default.createSymbolicLink(at: executable, withDestinationURL: outside)
        #expect(throws: ApplicationDesktopLifecycle.Failure.invalidBundle) {
            try ApplicationDesktopLifecycle.bundleIdentity(at: bundle, permittedIDs: ["com.openai.codex"])
        }
    }

    @Test func publicOperationsRejectMismatchedIdentityBeforeAnyCommandOrDownload() async {
        await #expect(throws: ApplicationDesktopLifecycle.Failure.unsupportedApplication) {
            try await ApplicationDesktopLifecycle.install(cask: "codex-app", bundleIDs: ["com.openai.chat"],
                                                           target: "/Applications/Codex.app") { _, _ in
                Issue.record("An invalid product must not execute a command.")
                throw ApplicationDesktopLifecycle.Failure.commandFailed
            }
        }
        #expect(throws: ApplicationDesktopLifecycle.Failure.invalidTarget) {
            try ApplicationDesktopLifecycle.uninstall(path: "/tmp/Codex.app", bundleID: "com.openai.codex")
        }
    }

    private func manifest(_ patch: [String: Any] = [:]) throws -> Data {
        var object: [String: Any] = ["token": "codex-app", "version": "26.623.141536",
                                     "url": "https://persistent.oaistatic.com/Codex-arm64.zip",
                                     "sha256": String(repeating: "a", count: 64), "variations": [:]]
        object.merge(patch) { _, replacement in replacement }
        return try JSONSerialization.data(withJSONObject: object)
    }
}

private struct DesktopFixture {
    let root: URL
    init() throws {
        // Foundation deliberately preserves macOS's /var alias; realpath gives the no-symlink fixture root.
        let resolved = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(resolved) }
        root = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
            .appendingPathComponent("desktop-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func makeBundle(identifier: String) throws -> URL {
        let bundle = root.appendingPathComponent("Fixture.app", isDirectory: true)
        let executable = bundle.appendingPathComponent("Contents/MacOS/Fixture")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0xcf, 0xfa, 0xed, 0xfe]).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let plist: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleExecutable": "Fixture", "CFBundleShortVersionString": "1.2.3"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        return bundle
    }
}
