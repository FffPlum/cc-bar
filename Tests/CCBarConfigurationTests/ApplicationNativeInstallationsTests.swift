import Darwin
import Foundation
import Testing
@testable import CCBarConfiguration

struct ApplicationNativeInstallationsTests {
    @Test func upgradeIsAnchoredToVerifiedRootAndIgnoresReceiptExecutablePaths() throws {
        let fixture = try MiniMaxFixture()
        defer { fixture.remove() }
        let steps = try fixture.plan(.upgrade)
        guard case .installer(let url, let shell, let environment) = try #require(steps.first) else {
            Issue.record("Expected the official installer."); return
        }
        #expect(url == "https://filecdn.minimax.chat/public/install.sh")
        #expect(shell == "/bin/bash")
        #expect(environment["MCODE_INSTALL_DIR"] == fixture.installationRoot.path)
        #expect(!environment.values.contains("/untrusted/npm"))
        #expect(FileManager.default.fileExists(atPath: fixture.installationRoot.appendingPathComponent("bin/mcode").path))
    }

    @Test func uninstallRemovesVerifiedReleasesAndEntriesWhilePreservingOtherData() async throws {
        let fixture = try MiniMaxFixture()
        defer { fixture.remove() }
        try fixture.release("0.9.0")
        let keep = [".minimax/settings.json", ".minimax-code/runtime/node/README", ".minimax-code/notes.txt",
                    ".minimax-code/releases/user-notes/notes.txt"]
        for path in keep { try fixture.write(path, "retain this") }
        let steps = try fixture.plan(.uninstall)
        guard case .removeNativePackages(let packages) = try #require(steps.first) else {
            Issue.record("Expected verified package removal."); return
        }
        #expect(Set(packages.map { URL(fileURLWithPath: $0.path).lastPathComponent }) == ["1.0.0", "0.9.0"])
        let plan = ApplicationLifecyclePlan(catalogID: "mcode", installation: fixture.installation,
                                            action: .uninstall, sourceLabel: "Official installer", steps: steps)
        _ = try await ApplicationLifecycleExecutor(execute: { _, _ in
            Issue.record("Uninstall must not run an arbitrary command.")
            throw ApplicationLifecycleError.changedInstallation
        }).run(plan)
        for path in keep { #expect(try String(contentsOf: fixture.home.appendingPathComponent(path), encoding: .utf8) == "retain this") }
        for path in ["bin/mcode", "bin/mcode-tools", "current", "install.json", "releases/1.0.0", "releases/0.9.0"] {
            #expect(!FileManager.default.fileExists(atPath: fixture.installationRoot.appendingPathComponent(path).path))
        }
        #expect(FileManager.default.fileExists(atPath: fixture.installationRoot.path))
    }

    @Test func changedReceiptOrWrapperCannotCreateAnUpgradeOrUninstallPlan() throws {
        let fixture = try MiniMaxFixture()
        defer { fixture.remove() }
        try fixture.write(".minimax-code/bin/mcode", "#!/bin/sh\nexec /untrusted/mcode \"$@\"\n", executable: true)
        #expect(throws: ApplicationLifecycleError.self) { try fixture.plan(.upgrade) }
        try fixture.write(".minimax-code/bin/mcode", ApplicationNativeInstallations.stableLauncher("mcode") + "\n", executable: true)
        try fixture.receipt(prefix: fixture.home.path)
        #expect(throws: ApplicationLifecycleError.self) { try fixture.plan(.uninstall) }
    }

    @Test func packageCapabilityRejectsWrongPackageAndSymlinkEscapes() throws {
        let fixture = try MiniMaxFixture()
        defer { fixture.remove() }
        let release = fixture.installationRoot.appendingPathComponent("releases/1.0.0")
        let unrelated = fixture.home.appendingPathComponent("unrelated")
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        #expect(throws: ApplicationLifecycleError.self) {
            try ApplicationNativePackageIdentity(path: unrelated.path, ownershipRoot: fixture.installationRoot.path)
        }
        let alias = fixture.installationRoot.appendingPathComponent("releases/alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: release)
        #expect(throws: ApplicationLifecycleError.self) {
            try ApplicationNativePackageIdentity(path: alias.path, ownershipRoot: fixture.installationRoot.path)
        }
        try FileManager.default.createSymbolicLink(at: release.appendingPathComponent("escape"), withDestinationURL: unrelated)
        #expect(throws: ApplicationLifecycleError.self) {
            try ApplicationNativePackageIdentity(path: release.path, ownershipRoot: fixture.installationRoot.path)
        }
        try FileManager.default.removeItem(at: release.appendingPathComponent("escape"))
        try fixture.write(".minimax-code/releases/1.0.0/lib/node_modules/@minimax-ai/code/package.json",
                          #"{"name":"another-package","bin":{"mcode":"bin/cli.js"}}"#)
        #expect(throws: ApplicationLifecycleError.self) { try fixture.plan(.uninstall) }
    }

    @Test func packageChangesAfterPlanningPreventAnyDeletion() throws {
        let fixture = try MiniMaxFixture()
        defer { fixture.remove() }
        let release = fixture.installationRoot.appendingPathComponent("releases/1.0.0")
        let identity = try ApplicationNativePackageIdentity(path: release.path, ownershipRoot: fixture.installationRoot.path)
        try fixture.write(".minimax-code/releases/1.0.0/lib/node_modules/@minimax-ai/code/bin/cli.js", "changed after confirmation")
        #expect(throws: ApplicationLifecycleError.self) { try identity.remove() }
        #expect(FileManager.default.fileExists(atPath: release.path))
        #expect(FileManager.default.fileExists(atPath: fixture.installationRoot.appendingPathComponent("install.json").path))
    }

    @Test func internalDependencySymlinkIsRemovedWithoutFollowingItsTarget() throws {
        let fixture = try MiniMaxFixture()
        defer { fixture.remove() }
        let release = fixture.installationRoot.appendingPathComponent("releases/1.0.0")
        let package = release.appendingPathComponent("lib/node_modules/@minimax-ai/code")
        try FileManager.default.createSymbolicLink(at: release.appendingPathComponent("package-link"), withDestinationURL: package)
        let identity = try ApplicationNativePackageIdentity(path: release.path, ownershipRoot: fixture.installationRoot.path)
        try identity.remove()
        #expect(!FileManager.default.fileExists(atPath: release.path))
        #expect(FileManager.default.fileExists(atPath: fixture.installationRoot.appendingPathComponent("install.json").path))
    }
}

private struct MiniMaxFixture {
    let home: URL
    var installationRoot: URL { home.appendingPathComponent(".minimax-code") }
    var installation: ApplicationInstallation {
        let path = installationRoot.appendingPathComponent("bin/mcode").path
        return ApplicationInstallation(catalogID: "mcode", path: path, resolvedPath: path,
                                       source: .native, package: "@minimax-ai/code", ownershipRoot: installationRoot.path)
    }
    init() throws {
        let resolved = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(resolved) }
        home = URL(fileURLWithPath: String(cString: resolved)).appendingPathComponent("minimax-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
        try release("1.0.0")
        try receipt(prefix: installationRoot.path)
        try write(".minimax-code/current", "1.0.0\n")
        for command in ["mcode", "mcode-tools"] {
            try write(".minimax-code/bin/\(command)", ApplicationNativeInstallations.stableLauncher(command) + "\n", executable: true)
        }
    }
    func remove() { try? FileManager.default.removeItem(at: home) }
    func write(_ path: String, _ content: String, executable: Bool = false) throws {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
        if executable { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path) }
    }
    func release(_ version: String) throws {
        let prefix = ".minimax-code/releases/\(version)"
        try write(prefix + "/lib/node_modules/@minimax-ai/code/package.json", #"{"name":"@minimax-ai/code","bin":{"mcode":"bin/cli.js"}}"#)
        try write(prefix + "/lib/node_modules/@minimax-ai/code/bin/cli.js", "fixture application")
        try write(prefix + "/.mcode-launcher", "#!/bin/sh\nexit 0\n", executable: true)
    }
    func receipt(prefix: String) throws {
        let object: [String: Any] = ["schemaVersion": 2, "layoutVersion": 2, "product": "minimax-code",
                                     "updateOwner": "npm-prefix", "packageManager": "npm", "packageName": "@minimax-ai/code",
                                     "prefix": prefix, "releasesDirectory": "releases", "currentFile": "current",
                                     "npmExecutable": "/untrusted/npm", "nodeExecutable": "/untrusted/node"]
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: installationRoot.appendingPathComponent("install.json"))
    }
    func plan(_ action: ApplicationLifecycleAction) throws -> [ApplicationLifecycleStep] {
        try ApplicationNativeInstallations.miniMaxPlan(definition: #require(ManagedApplicationCatalog.application("mcode")),
            installation: installation, action: action, environment: .init(home: home, environment: ["PATH": "/usr/bin:/bin"]))
    }
}
