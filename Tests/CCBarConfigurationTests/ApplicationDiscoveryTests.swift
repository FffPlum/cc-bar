import Foundation
import Testing
@testable import CCBarConfiguration

struct ApplicationDiscoveryTests {
    @Test func configurationAndSameNamedDirectoriesAreNotInstallations() async throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.remove() }
        try fixture.write(".fixture/auth.json", "do not read these credentials")
        try FileManager.default.createDirectory(at: fixture.url("bin/fixture"), withIntermediateDirectories: true)
        let probe = DiscoveryProbe()
        let definition = fixture.definition(configurationPaths: ["~/.fixture/auth.json"])
        let results = await fixture.discovery(probe: probe).scan([definition])
        #expect(results[definition.id]?.configurationFound == true)
        #expect(results[definition.id]?.installations.isEmpty == true)
        #expect(await probe.calls.isEmpty)
    }

    @Test func verifiedNPMInstallationsPreservePathPriorityAndDeduplicateAliases() async throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.remove() }
        try fixture.npm(prefix: "first", version: "1.2.3")
        try fixture.npm(prefix: "second", version: "2.0.0")
        try fixture.symlink("alias/fixture", to: "first/lib/node_modules/@fixture/tool/bin/fixture.js")
        let probe = DiscoveryProbe(resultsByPath: [fixture.url("second/bin/fixture").path: .init(exitCode: 0, output: "fixture 2.0.0")])
        let environment = fixture.environment(path: ["second/bin", "first/bin", "alias", "first/bin"])
        let results = await ApplicationDiscovery(environment: environment, execute: { try await probe.execute($0, $1) }).scan([fixture.definition()])
        let installations = try #require(results["fixture"]?.installations)
        #expect(installations.count == 2)
        #expect(installations.map(\.version) == ["2.0.0", "1.2.3"])
        #expect(installations.map(\.active) == [true, false])
        #expect(installations.allSatisfy { $0.source == .npm && $0.managerPath?.hasSuffix("/bin/npm") == true })
        #expect(await probe.calls.count == 2)
    }

    @Test func rejectsForeignCommandAndUnrelatedPackageWithoutExecutingThem() async throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.remove() }
        try fixture.npm(prefix: "foreign", package: "@unrelated/tool")
        let probe = DiscoveryProbe()
        let results = await ApplicationDiscovery(environment: fixture.environment(path: ["foreign/bin"]), execute: { try await probe.execute($0, $1) })
            .scan([fixture.definition()])
        #expect(results["fixture"]?.installations.isEmpty == true)
        #expect(results["fixture"]?.error != nil)
        #expect(await probe.calls.isEmpty)
    }

    @Test func npmManagerCannotComeFromAnotherNodePrefix() async throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.remove() }
        try fixture.npm(prefix: "selected")
        try FileManager.default.removeItem(at: fixture.url("selected/bin/npm"))
        try fixture.executable("another/bin/npm")
        let probe = DiscoveryProbe()
        let results = await ApplicationDiscovery(environment: fixture.environment(path: ["selected/bin", "another/bin"]), execute: { try await probe.execute($0, $1) })
            .scan([fixture.definition()])
        let installation = try #require(results["fixture"]?.installations.first)
        #expect(installation.source == .npm)
        #expect(installation.managerPath == nil)
        #expect(installation.version == "1.2.3")
        #expect(await probe.calls.count == 1)
    }

    @Test func voltaPackageImagesAreNotClaimedByAnUnrelatedNPM() async throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.remove() }
        let prefix = ".volta/tools/image/packages/@fixture/tool/1.2.3"
        try fixture.npm(prefix: prefix)
        try fixture.executable("another/bin/npm")
        let probe = DiscoveryProbe()
        let results = await ApplicationDiscovery(environment: fixture.environment(path: ["another/bin"]), execute: { try await probe.execute($0, $1) })
            .scan([fixture.definition()])
        let installation = try #require(results["fixture"]?.installations.first)
        #expect(installation.source == .unknown)
        #expect(installation.managerPath == nil)
        #expect(installation.version == "1.2.3")
        #expect(await probe.calls.count == 1)
    }

    @Test func homebrewOwnershipPrecedesBundledNPMAndUsesTheMatchingBrew() async throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.remove() }
        try fixture.write("brew/Cellar/fixture/1.0/libexec/lib/node_modules/@fixture/tool/package.json", #"{"name":"@fixture/tool","version":"3.2.1"}"#)
        try fixture.executable("brew/Cellar/fixture/1.0/libexec/lib/node_modules/@fixture/tool/bin/fixture.js")
        try fixture.symlink("brew/bin/fixture", to: "brew/Cellar/fixture/1.0/libexec/lib/node_modules/@fixture/tool/bin/fixture.js")
        try fixture.executable("brew/bin/brew")
        let probe = DiscoveryProbe(result: .init(exitCode: 0, output: "fixture 3.2.1"))
        let results = await ApplicationDiscovery(environment: fixture.environment(path: ["brew/bin"]), execute: { try await probe.execute($0, $1) })
            .scan([fixture.definition(brew: "vendor/tap/fixture")])
        let installation = try #require(results["fixture"]?.installations.first)
        #expect(installation.source == .homebrew)
        #expect(installation.managerPath == fixture.url("brew/bin/brew").path)
        #expect(installation.package == "fixture")
        #expect(installation.version == "3.2.1")
        #expect(await probe.calls.count == 1)
    }

    @Test func unrelatedBrewFormulaDoesNotProveApplicationIdentity() async throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.remove() }
        try fixture.executable("brew/Cellar/another/1/bin/fixture", native: true)
        try fixture.symlink("brew/bin/fixture", to: "brew/Cellar/another/1/bin/fixture")
        let probe = DiscoveryProbe()
        let results = await ApplicationDiscovery(environment: fixture.environment(path: ["brew/bin"]), execute: { try await probe.execute($0, $1) })
            .scan([fixture.definition(brew: "fixture")])
        #expect(results["fixture"]?.installations.isEmpty == true)
        #expect(await probe.calls.isEmpty)
    }

    @Test(arguments: [("Cellar", "claude-code"), ("Caskroom", "claude-code@latest")])
    func homebrewUsesTheActualHistoricalChannelAndExplicitAlias(channel: String, token: String) async throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.remove() }
        try fixture.executable("brew/" + channel + "/" + token + "/1.0/claude", native: true)
        try fixture.symlink("brew/bin/claude", to: "brew/" + channel + "/" + token + "/1.0/claude")
        try fixture.executable("brew/bin/brew")
        let definition = ManagedApplicationDefinition(id: "claude", name: "Claude", website: "https://example.test",
            commands: ["claude"], brewPackage: "claude-code", brewCask: true)
        let probe = DiscoveryProbe()
        let results = await ApplicationDiscovery(environment: fixture.environment(path: ["brew/bin"]), execute: { try await probe.execute($0, $1) }).scan([definition])
        let installation = try #require(results["claude"]?.installations.first)
        #expect(installation.source == .homebrew)
        #expect(installation.package == token)
        #expect(installation.resolvedPath.contains("/" + channel + "/"))
    }

    @Test func nativeVersionTimeoutDoesNotTurnAnInstallationIntoMissing() async throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.remove() }
        try fixture.executable(".local/bin/fixture", native: true)
        let probe = DiscoveryProbe(result: ApplicationCommandResult(exitCode: 9, output: "", timedOut: true))
        let results = await fixture.discovery(probe: probe).scan([fixture.definition(nativeRoots: ["~/.local/bin/fixture"])])
        let installation = try #require(results["fixture"]?.installations.first)
        #expect(installation.source == .native)
        #expect(installation.version == nil)
        #expect(installation.versionError?.contains("timed out") == true)
        let call = try #require(await probe.calls.first)
        #expect(call.0.executable == fixture.url(".local/bin/fixture").path)
        #expect(call.0.arguments == ["--version"])
        #expect(call.0.environment["PATH"]?.hasPrefix(fixture.url(".local/bin").path + ":") == true)
        #expect(call.1 == 3)
    }

    @Test func packageUpgradeCannotMasqueradeAsAnUpdatedRunningBinary() async throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.remove() }
        try fixture.npm(prefix: "installed", version: "2.0.0")
        let probe = DiscoveryProbe(result: .init(exitCode: 0, output: "fixture 1.0.0"))
        let results = await ApplicationDiscovery(environment: fixture.environment(path: ["installed/bin"]), execute: { try await probe.execute($0, $1) })
            .scan([fixture.definition()])
        let installation = try #require(results["fixture"]?.installations.first)
        #expect(installation.version == "1.0.0")
        #expect(installation.versionError == nil)
        let call = try #require(await probe.calls.first)
        #expect(call.0.executable == fixture.url("installed/bin/fixture").path)
        #expect(call.0.arguments == ["--version"])
        #expect(call.1 == 3)
    }

    @Test(arguments: [ApplicationCommandResult(exitCode: 0, output: "", timedOut: true),
                      ApplicationCommandResult(exitCode: 1, output: "fixture 2.0.0"),
                      ApplicationCommandResult(exitCode: 0, output: "Node.js v24.0.0\nPython 3.14.0\nWarning: fixture requires Node.js 24.0.0")])
    func runtimeFailureKeepsInstallationWithoutUsingItsPackageVersion(result: ApplicationCommandResult) async throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.remove() }
        try fixture.npm(prefix: "installed", version: "2.0.0")
        let probe = DiscoveryProbe(result: result)
        let results = await ApplicationDiscovery(environment: fixture.environment(path: ["installed/bin"]), execute: { try await probe.execute($0, $1) })
            .scan([fixture.definition()])
        let installation = try #require(results["fixture"]?.installations.first)
        #expect(installation.source == .npm)
        #expect(installation.version == nil)
        #expect(installation.versionError != nil)
        #expect(await probe.calls.count == 1)
    }

    @Test(arguments: [
        ("Fixture", "Node.js v24.0.0\nPython 3.14.0\nfixture, version 1.2.3", "1.2.3"),
        ("Fixture", "v24.0.0\nfixture v1.2.3", "1.2.3"),
        ("Fixture", "Node.js v24.0.0\nv1.2.3-beta.1+build.2", "1.2.3-beta.1+build.2"),
        ("Claude Code", "Node.js v24.0.0\n2.1.32 (Claude Code)", "2.1.32"),
        ("Codex CLI", "codex-cli 0.99.0", "0.99.0"),
        ("Hermes Agent", "Hermes Agent v0.22.1+238.g8211bb9 (2026.9.24) · upstream 8211bb96", "0.22.1+238.g8211bb9"),
        ("OpenClaw", "🦞 OpenClaw 2026.11.6 (deadbeef)", "2026.11.6"),
        ("Fixture", "\u{1B}[32mfixture 1.2.3\u{1B}[0m", "1.2.3")
    ])
    func runtimeVersionUsesApplicationLinesBeforeBareVersions(name: String, output: String, expected: String) async throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.remove() }
        try fixture.npm(prefix: "installed", version: "9.9.9")
        let definition = ManagedApplicationDefinition(id: "fixture", name: name, website: "https://example.test",
            commands: ["fixture"], npmPackage: "@fixture/tool")
        let probe = DiscoveryProbe(result: .init(exitCode: 0, output: output))
        let results = await ApplicationDiscovery(environment: fixture.environment(path: ["installed/bin"]), execute: { try await probe.execute($0, $1) }).scan([definition])
        #expect(results["fixture"]?.installations.first?.version == expected)
        #expect(results["fixture"]?.installations.first?.versionError == nil)
    }

    @Test func officialLookingSymlinkCannotClaimAnArbitraryNativeTarget() async throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.remove() }
        try fixture.executable("unrelated/program", native: true)
        try fixture.symlink(".local/bin/fixture", to: "unrelated/program")
        let probe = DiscoveryProbe()
        let results = await fixture.discovery(probe: probe).scan([fixture.definition(nativeRoots: ["~/.local/bin/fixture"])])
        #expect(results["fixture"]?.installations.isEmpty == true)
        #expect(await probe.calls.isEmpty)
    }

    @Test func renamedDesktopBundleRequiresExactIdentityAndExecutable() async throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.remove() }
        try fixture.bundle("Apps/Expected.app", id: "unrelated.app")
        try fixture.bundle("Apps/Renamed.app", id: "fixture.app")
        try fixture.bundle("Apps/Incomplete.app", id: "fixture.app", withExecutable: false)
        let definition = ManagedApplicationDefinition(id: "desktop", name: "Desktop", kind: .desktop, website: "https://example.test",
            bundleIDs: ["fixture.app"], bundleNames: ["Expected.app"])
        let probe = DiscoveryProbe()
        let results = await fixture.discovery(probe: probe).scan([definition])
        let installations = try #require(results["desktop"]?.installations)
        #expect(installations.count == 1)
        #expect(installations.first?.path == fixture.url("Apps/Renamed.app").path)
        #expect(installations.first?.version == "4.5.6")
        #expect(installations.first?.active == false)
        #expect(await probe.calls.isEmpty)
    }

    @Test(arguments: [true, false])
    func desktopHomebrewOwnershipRequiresTheExactCaskArtifact(owned: Bool) async throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.remove() }
        try fixture.bundle("Apps/Fixture.app", id: "fixture.app")
        try fixture.executable("brew/bin/brew")
        let token = owned ? "fixture-desktop" : "unrelated"
        try fixture.symlink("brew/Caskroom/" + token + "/4.5.6/Fixture.app", to: "Apps/Fixture.app")
        let definition = ManagedApplicationDefinition(id: "desktop", name: "Desktop", kind: .desktop, website: "https://example.test",
            bundleIDs: ["fixture.app"], bundleNames: ["Fixture.app"], brewPackage: "fixture-desktop", brewCask: true)
        let probe = DiscoveryProbe()
        let results = await ApplicationDiscovery(environment: fixture.environment(path: ["brew/bin"]), execute: { try await probe.execute($0, $1) }).scan([definition])
        let installation = try #require(results["desktop"]?.installations.first)
        #expect(installation.source == (owned ? .homebrew : .bundle))
        #expect(installation.managerPath == (owned ? fixture.url("brew/bin/brew").path : nil))
        #expect(installation.package == (owned ? "fixture-desktop" : "fixture.app"))
        #expect(!installation.active)
        #expect(await probe.calls.isEmpty)
    }

    @Test(arguments: [true, false])
    func hermesLaunchersRequireMatchingSourceMetadataAndCollapseToOneInstallation(valid: Bool) async throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.remove() }
        let repository = fixture.url(".hermes/hermes-agent").resolvingSymlinksInPath().path
        try fixture.executable("runtime/python")
        try fixture.write(".hermes/hermes-agent/pyproject.toml", "[project]\nname='\(valid ? "hermes-agent" : "unrelated")'\n[project.scripts]\nhermes='hermes_cli.main:main'\n")
        try fixture.write(".hermes/hermes-agent/hermes_cli/main.py", "")
        try fixture.write(".hermes/hermes-agent/hermes_bootstrap.py", "")
        let code = "import os, re, sys\nsys.path.insert(0, '\(repository)')\nimport hermes_bootstrap\nfrom hermes_cli.main import main\nsys.exit(main())\n"
        try fixture.script(".hermes/hermes-agent/.hermes/bin/hermes", "#!/bin/sh\nexec \(shellQuote(fixture.url("runtime/python").path)) -I -c \(shellQuote(code)) \"$@\"\n")
        try fixture.script(".local/bin/hermes", "#!/bin/sh\nexec \(shellQuote(repository + "/.hermes/bin/hermes")) \"$@\"\n")
        let definition = ManagedApplicationDefinition(id: "hermes", name: "Hermes", website: "https://example.test", commands: ["hermes"],
            nativeRoots: [".hermes/hermes-agent", ".local/bin/hermes"], pythonPackage: "hermes-agent")
        let probe = DiscoveryProbe()
        let results = await ApplicationDiscovery(environment: fixture.environment(path: [".local/bin"]), execute: { try await probe.execute($0, $1) }).scan([definition])
        let installations = try #require(results["hermes"]?.installations)
        #expect(installations.count == (valid ? 1 : 0))
        if valid {
            let installation = try #require(installations.first)
            #expect(installation.source == .native)
            #expect(installation.ownershipRoot == repository)
            #expect(installation.path == fixture.url(".local/bin/hermes").path)
            #expect(installation.resolvedPath == fixture.url(".local/bin/hermes").resolvingSymlinksInPath().path)
            #expect(installation.active)
        }
        #expect(await probe.calls.count == (valid ? 1 : 0))
    }

    @Test(arguments: [true, false])
    func miniMaxReleaseLayoutRequiresReceiptAndExactLauncher(valid: Bool) async throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.remove() }
        let root = fixture.url(".minimax-code").resolvingSymlinksInPath().path
        let node = fixture.url("runtime/node").path
        try fixture.executable("runtime/node")
        let receipt: [String: Any] = ["schemaVersion": 2, "layoutVersion": 2, "product": "minimax-code", "updateOwner": "npm-prefix",
            "packageName": "@minimax-ai/code", "packageManager": "npm", "prefix": root, "nodeExecutable": node]
        try fixture.write(".minimax-code/install.json", String(decoding: JSONSerialization.data(withJSONObject: receipt), as: UTF8.self))
        try fixture.write(".minimax-code/current", "1.2.3\n")
        try fixture.write(".minimax-code/releases/1.2.3/lib/node_modules/@minimax-ai/code/package.json", #"{"name":"@minimax-ai/code","version":"1.2.3","bin":{"mcode":"bin/index.js"}}"#)
        try fixture.write(".minimax-code/releases/1.2.3/lib/node_modules/@minimax-ai/code/bin/index.js", "")
        let stable = #"""
        #!/bin/sh
        set -eu
        root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
        release=$(tr -d '\r\n' < "$root/current")
        case "$release" in ""|*[!0-9A-Za-z._-]*) echo "Invalid MCode current release pointer." >&2; exit 1;; esac
        exec "$root/releases/$release/.mcode-launcher" "$@"
        """# + "\n"
        try fixture.script(".minimax-code/bin/mcode", valid ? stable : "#!/bin/sh\nexit 0\n")
        try fixture.script(".minimax-code/releases/1.2.3/.mcode-launcher", "#!/bin/sh\nset -eu\nroot=$(CDPATH= cd -- \"$(dirname -- \"$0\")\" && pwd -P)\nnode='\(node)'\nexec \"$node\" \"$root/lib/node_modules/@minimax-ai/code/bin/index.js\" \"$@\"\n")
        let definition = ManagedApplicationDefinition(id: "mcode", name: "MiniMax", website: "https://example.test", commands: ["mcode"],
            nativeRoots: [".minimax-code/bin"], npmPackage: "@minimax-ai/code")
        let probe = DiscoveryProbe()
        let results = await fixture.discovery(probe: probe).scan([definition])
        #expect(results["mcode"]?.installations.count == (valid ? 1 : 0))
        if valid {
            let installation = try #require(results["mcode"]?.installations.first)
            #expect(installation.source == .native)
            #expect(installation.version == "1.2.3")
            #expect(installation.ownershipRoot == root)
        }
        #expect(await probe.calls.count == (valid ? 1 : 0))
    }

    @Test(arguments: ["uv", "pipx"])
    func pythonManagersRequireReceiptAndMatchingDistribution(manager: String) async throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.remove() }
        let venv = manager == "uv" ? ".local/share/uv/tools/fixture-tool" : ".local/share/pipx/venvs/fixture-tool"
        try fixture.executable(venv + "/bin/fixture")
        try fixture.symlink(".local/bin/fixture", to: venv + "/bin/fixture")
        try fixture.executable(".local/bin/" + manager)
        try fixture.write(venv + "/lib/python3.13/site-packages/fixture_tool-1.0.dist-info/METADATA", "Name: fixture-tool\nVersion: 1.0.0\n")
        if manager == "uv" {
            try fixture.write(venv + "/uv-receipt.toml", "[tool]\nrequirements = [{ name = 'fixture-tool' }]\n")
        } else {
            try fixture.write(venv + "/pipx_metadata.json", #"{"main_package":{"package":"fixture-tool"}}"#)
        }
        let definition = ManagedApplicationDefinition(id: "fixture", name: "Fixture", website: "https://example.test", commands: ["fixture"], pythonPackage: "fixture-tool")
        let probe = DiscoveryProbe(result: .init(exitCode: 0, output: "fixture 1.0.0"))
        let results = await fixture.discovery(probe: probe).scan([definition])
        let installation = try #require(results["fixture"]?.installations.first)
        #expect(installation.source.rawValue == manager)
        #expect(installation.version == "1.0.0")
        #expect(installation.managerPath == fixture.url(".local/bin/" + manager).path)
        #expect(results["fixture"]?.installations.count == 1)
        #expect(await probe.calls.count == 1)
    }

    @Test func nvmInstallationsAreFoundOutsideInheritedPath() async throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.remove() }
        try fixture.npm(prefix: ".nvm/versions/node/v24.0.0")
        let probe = DiscoveryProbe()
        let results = await fixture.discovery(probe: probe).scan([fixture.definition()])
        #expect(results["fixture"]?.installations.first?.source == .npm)
        #expect(results["fixture"]?.installations.allSatisfy { !$0.active } == true)
        #expect(await probe.calls.count == 1)
    }

    @Test func concurrentVersionChecksAreBounded() async throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.remove() }
        let definitions = try (0..<10).map { index in
            let command = "fixture-\(index)"
            try fixture.executable(".local/bin/" + command, native: true)
            return ManagedApplicationDefinition(id: command, name: command, website: "https://example.test",
                commands: [command], nativeRoots: ["~/.local/bin/" + command])
        }
        let probe = DiscoveryProbe(delay: true)
        let results = await fixture.discovery(probe: probe).scan(definitions)
        #expect(results.count == 10)
        #expect(await probe.maximumConcurrent <= 4)
        #expect(await probe.calls.count == 10)
    }
}

private func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }

private actor DiscoveryProbe {
    private(set) var calls: [(ApplicationCommand, TimeInterval)] = []
    private(set) var maximumConcurrent = 0
    private var concurrent = 0
    private let result: ApplicationCommandResult
    private let resultsByPath: [String: ApplicationCommandResult]
    private let delay: Bool
    init(result: ApplicationCommandResult = .init(exitCode: 0, output: "1.2.3"), delay: Bool = false,
         resultsByPath: [String: ApplicationCommandResult] = [:]) {
        self.result = result; self.delay = delay; self.resultsByPath = resultsByPath
    }
    func execute(_ command: ApplicationCommand, _ timeout: TimeInterval) async throws -> ApplicationCommandResult {
        calls.append((command, timeout)); concurrent += 1
        maximumConcurrent = max(maximumConcurrent, concurrent)
        defer { concurrent -= 1 }
        if delay { try await Task.sleep(for: .milliseconds(20)) }
        return resultsByPath[command.executable] ?? result
    }
}

private struct DiscoveryFixture {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ccbar-discovery-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func url(_ path: String) -> URL { root.appendingPathComponent(path) }
    func write(_ path: String, _ value: String) throws {
        try FileManager.default.createDirectory(at: url(path).deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(value.utf8).write(to: url(path))
    }
    func executable(_ path: String, native: Bool = false) throws {
        try write(path, "#!/bin/sh\nexit 0\n")
        if native { try Data([0xcf, 0xfa, 0xed, 0xfe, 0, 0, 0, 0]).write(to: url(path)) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url(path).path)
    }
    func script(_ path: String, _ value: String) throws {
        try write(path, value)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url(path).path)
    }
    func symlink(_ path: String, to target: String) throws {
        try FileManager.default.createDirectory(at: url(path).deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: url(path), withDestinationURL: url(target))
    }
    func npm(prefix: String, version: String = "1.2.3", package: String = "@fixture/tool") throws {
        let directory = prefix + "/lib/node_modules/" + package
        try write(directory + "/package.json", "{\"name\":\"\(package)\",\"version\":\"\(version)\"}")
        try executable(directory + "/bin/fixture.js")
        try symlink(prefix + "/bin/fixture", to: directory + "/bin/fixture.js")
        try executable(prefix + "/bin/npm")
    }
    func bundle(_ path: String, id: String, withExecutable: Bool = true) throws {
        let plist: [String: String] = ["CFBundleIdentifier": id, "CFBundleExecutable": "fixture", "CFBundleShortVersionString": "4.5.6"]
        try write(path + "/Contents/Info.plist", "")
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url(path + "/Contents/Info.plist"))
        if withExecutable { try executable(path + "/Contents/MacOS/fixture") }
    }
    func environment(path: [String] = ["bin"]) -> ApplicationDiscoveryEnvironment {
        .init(home: root, environment: ["PATH": path.map { url($0).path }.joined(separator: ":")],
              applicationDirectories: [url("Apps")], standardExecutableDirectories: [])
    }
    func definition(configurationPaths: [String] = [], nativeRoots: [String] = [], brew: String? = nil) -> ManagedApplicationDefinition {
        .init(id: "fixture", name: "Fixture", website: "https://example.test", commands: ["fixture"],
              configurationPaths: configurationPaths, nativeRoots: nativeRoots, npmPackage: "@fixture/tool", brewPackage: brew)
    }
    func discovery(probe: DiscoveryProbe) -> ApplicationDiscovery { .init(environment: environment(), execute: { try await probe.execute($0, $1) }) }
}
