import Foundation
import Testing
@testable import CCBarConfiguration

struct ApplicationLifecycleTests {
    private func fixture(_ body: (URL, ApplicationLifecyclePlanner) throws -> Void) throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("ccbar-lifecycle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let environment = ApplicationDiscoveryEnvironment(home: home, environment: ["PATH": ""],
            applicationDirectories: [home.appendingPathComponent("Applications")], standardExecutableDirectories: [])
        try body(home, ApplicationLifecyclePlanner(environment: environment))
    }
    private func executable(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    @Test func npmOperationUsesSelectedPrefixAndManagerInsteadOfCurrentPATH() throws {
        try fixture { home, planner in
            let prefix = home.appendingPathComponent("node versions/v22")
            let program = prefix.appendingPathComponent("lib/node_modules/@openai/codex/bin/codex.js")
            let npm = prefix.appendingPathComponent("bin/npm")
            let launcher = prefix.appendingPathComponent("bin/codex")
            try executable(program); try executable(npm)
            try FileManager.default.createSymbolicLink(at: launcher, withDestinationURL: program)
            let definition = try #require(ManagedApplicationCatalog.application("codex"))
            let installation = ApplicationInstallation(catalogID: "codex", path: launcher.path,
                resolvedPath: program.path, version: "1.0.0", source: .npm,
                managerPath: npm.path, package: "@openai/codex")
            let plan = try planner.plan(definition, action: .uninstall, installation: installation)
            guard case .command(let command) = try #require(plan.steps.first) else { Issue.record("Missing npm command"); return }
            #expect(command.executable == npm.path)
            #expect(command.arguments == ["uninstall", "--global", "--prefix", prefix.path, "@openai/codex"])
            #expect(command.environment["PATH"]?.hasPrefix(prefix.appendingPathComponent("bin").path) == true)
            #expect(FileManager.default.fileExists(atPath: program.path))
        }
    }

    @Test func unknownOwnershipCannotFallBackToNpmOrDeleteFiles() throws {
        try fixture { home, planner in
            let executableURL = home.appendingPathComponent("bin/codex")
            try executable(executableURL)
            let definition = try #require(ManagedApplicationCatalog.application("codex"))
            let installation = ApplicationInstallation(catalogID: "codex", path: executableURL.path,
                resolvedPath: executableURL.path, source: .unknown)
            for action in [ApplicationLifecycleAction.upgrade, .uninstall] {
                #expect(throws: ApplicationLifecycleError.self) { try planner.plan(definition, action: action, installation: installation) }
            }
            #expect(FileManager.default.fileExists(atPath: executableURL.path))
        }
    }

    @Test func uninstallPlanContainsOnlyProgramFilesAndDetectsReplacement() throws {
        try fixture { home, planner in
            let file = home.appendingPathComponent(".local/bin/agy")
            let settings = home.appendingPathComponent(".gemini/settings.json")
            try executable(file)
            try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("private-settings".utf8).write(to: settings)
            let definition = try #require(ManagedApplicationCatalog.application("agy"))
            let installation = ApplicationInstallation(catalogID: "agy", path: file.path, resolvedPath: file.path, source: .native)
            let plan = try planner.plan(definition, action: .uninstall, installation: installation)
            guard case .removeFiles(let files) = try #require(plan.steps.first) else { Issue.record("Missing file plan"); return }
            #expect(files.map(\.path) == [file.path])
            try Data("changed executable".utf8).write(to: file)
            #expect(throws: ApplicationLifecycleError.self) { try files[0].validate() }
            #expect(try String(contentsOf: settings, encoding: .utf8) == "private-settings")
        }
    }

    @Test func nativeSymlinkOutsideOwnedRootCannotBeRemoved() throws {
        try fixture { home, planner in
            let foreign = home.appendingPathComponent("another-product/agy")
            let launcher = home.appendingPathComponent(".local/bin/agy")
            try executable(foreign)
            try FileManager.default.createDirectory(at: launcher.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: launcher, withDestinationURL: foreign)
            let definition = try #require(ManagedApplicationCatalog.application("agy"))
            let installation = ApplicationInstallation(catalogID: "agy", path: launcher.path, resolvedPath: foreign.path, source: .native)
            #expect(throws: ApplicationLifecycleError.self) { try planner.plan(definition, action: .uninstall, installation: installation) }
        }
    }

    @Test(arguments: [ApplicationInstallationSource.uv, .pipx])
    func pythonOperationsStayInTheSelectedToolRoot(source: ApplicationInstallationSource) throws {
        try fixture { home, planner in
            let tools = home.appendingPathComponent(source == .uv ? "custom-uv/tools" : ".local/pipx/venvs")
            let program = tools.appendingPathComponent("kimi-cli/bin/kimi")
            let launcher = home.appendingPathComponent(".local/bin/kimi")
            let manager = home.appendingPathComponent(".local/bin/" + source.rawValue)
            try executable(program); try executable(manager)
            try FileManager.default.createSymbolicLink(at: launcher, withDestinationURL: program)
            let definition = try #require(ManagedApplicationCatalog.application("kimi"))
            let installation = ApplicationInstallation(catalogID: "kimi", path: launcher.path, resolvedPath: program.path,
                source: source, managerPath: manager.path, package: "kimi-cli")
            let plan = try planner.plan(definition, action: .uninstall, installation: installation)
            guard case .command(let command) = try #require(plan.steps.first) else { Issue.record("Missing Python tool command"); return }
            #expect(command.environment[source == .uv ? "UV_TOOL_DIR" : "PIPX_HOME"] == (source == .uv ? tools.path : tools.deletingLastPathComponent().path))
            #expect(command.environment[source == .uv ? "UV_TOOL_BIN_DIR" : "PIPX_BIN_DIR"] == launcher.deletingLastPathComponent().path)
        }
    }
}
