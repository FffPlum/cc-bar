import Foundation
import TOMLKit

/// Installation discovery never reads credential contents or executes unidentified commands.
public struct ApplicationDiscovery: Sendable {
    private let environment: ApplicationDiscoveryEnvironment
    private let execute: ApplicationCommandExecutor

    public init(environment: ApplicationDiscoveryEnvironment = .init(),
                execute: @escaping ApplicationCommandExecutor = { try await ApplicationCommandRunner.run($0, $1) }) {
        self.environment = environment
        self.execute = execute
    }

    @concurrent
    public func scan(_ definitions: [ManagedApplicationDefinition]) async -> [String: ApplicationDiscoveryResult] {
        await withTaskGroup(of: (String, ApplicationDiscoveryResult).self) { group in
            var iterator = definitions.makeIterator()
            for _ in 0..<4 {
                if let definition = iterator.next() { group.addTask { (definition.id, await scanOne(definition)) } }
            }
            var results: [String: ApplicationDiscoveryResult] = [:]
            for await (id, result) in group {
                results[id] = result
                if !Task.isCancelled, let definition = iterator.next() {
                    group.addTask { (definition.id, await scanOne(definition)) }
                }
            }
            return results
        }
    }

    public func executableDirectories() -> [URL] {
        var directories = (environment.environment["PATH"] ?? "").split(separator: ":")
            .filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: String($0)) }
        directories += environment.standardExecutableDirectories
        let home = environment.home
        directories += [home.appendingPathComponent(".local/bin"), home.appendingPathComponent(".cargo/bin")]
        for (key, fallback) in [("BUN_INSTALL", ".bun"), ("VOLTA_HOME", ".volta"), ("NPM_CONFIG_PREFIX", ".npm-global")] {
            directories.append(root(key, fallback).appendingPathComponent("bin"))
        }
        for key in ["UV_TOOL_BIN_DIR", "PIPX_BIN_DIR"] {
            if let path = absoluteEnvironment(key) { directories.append(path) }
        }
        if let prefix = absoluteEnvironment("npm_config_prefix") { directories.append(prefix.appendingPathComponent("bin")) }
        if let multishell = absoluteEnvironment("FNM_MULTISHELL_PATH") { directories.append(multishell.appendingPathComponent("bin")) }
        let versionTrees: [(URL, String)] = [
            (root("NVM_DIR", ".nvm").appendingPathComponent("versions/node"), "bin"),
            (root("FNM_DIR", ".local/share/fnm").appendingPathComponent("node-versions"), "installation/bin"),
            (home.appendingPathComponent(".fnm/node-versions"), "installation/bin"),
            (home.appendingPathComponent("Library/Application Support/fnm/node-versions"), "installation/bin"),
            (root("MISE_DATA_DIR", ".local/share/mise").appendingPathComponent("installs/node"), "bin"),
            (root("ASDF_DATA_DIR", ".asdf").appendingPathComponent("installs/nodejs"), "bin"),
            (root("VOLTA_HOME", ".volta").appendingPathComponent("tools/image/node"), "bin"),
            (uvToolsRoot, "bin"),
            (root("PIPX_HOME", ".local/share/pipx").appendingPathComponent("venvs"), "bin"),
            (home.appendingPathComponent(".local/pipx/venvs"), "bin")
        ]
        for (directory, suffix) in versionTrees { directories += children(directory).map { $0.appendingPathComponent(suffix) } }
        directories += [root("MISE_DATA_DIR", ".local/share/mise").appendingPathComponent("shims"),
                        root("ASDF_DATA_DIR", ".asdf").appendingPathComponent("shims")]
        return uniqueURLs(directories)
    }

    private var uvToolsRoot: URL {
        absoluteEnvironment("UV_TOOL_DIR") ?? (absoluteEnvironment("XDG_DATA_HOME") ?? environment.home.appendingPathComponent(".local/share"))
            .appendingPathComponent("uv/tools")
    }

    private func scanOne(_ definition: ManagedApplicationDefinition) async -> ApplicationDiscoveryResult {
        let configurationFound = definition.configurationPaths.contains { path in
            expanded(path).contains { FileManager.default.fileExists(atPath: $0.path) }
        }
        if definition.kind == .desktop { return desktopInstallations(definition, configurationFound: configurationFound) }
        let directories = executableDirectories()
        var candidates = directories.flatMap { directory in definition.commands.map { directory.appendingPathComponent($0) } }
        if let package = definition.npmPackage {
            let image = root("VOLTA_HOME", ".volta").appendingPathComponent("tools/image/packages/" + package)
            for release in children(image) {
                candidates += definition.commands.map { release.appendingPathComponent("bin/" + $0) }
            }
        }
        let nativeRoots = definition.nativeRoots.flatMap(expanded)
        for root in nativeRoots {
            if isExecutable(root) { candidates.append(root) }
            else {
                candidates += definition.commands.flatMap { [root.appendingPathComponent($0), root.appendingPathComponent("bin/" + $0)] }
            }
            if definition.id == "hermes" { candidates.append(root.appendingPathComponent(".hermes/bin/hermes")) }
        }
        candidates = uniqueURLs(candidates).filter(isExecutable)
        let pathDirectories = (environment.environment["PATH"] ?? "").split(separator: ":")
            .filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: String($0)) }
        let preferredPath = pathDirectories.flatMap { directory in definition.commands.map { directory.appendingPathComponent($0) } }
            .first(where: isExecutable)?.standardizedFileURL.path
        var installations: [ApplicationInstallation] = []
        var seen: Set<String> = []
        var unidentified = false
        for candidate in candidates {
            if Task.isCancelled { break }
            let real = candidate.resolvingSymlinksInPath().standardizedFileURL
            guard let evidence = evidence(for: definition, entry: candidate, real: real, nativeRoots: nativeRoots, directories: directories) else {
                unidentified = true
                continue
            }
            let key = evidence.source == .native ? (evidence.ownershipRoot ?? real.path) : real.path
            guard seen.insert(key).inserted else { continue }
            var installation = ApplicationInstallation(catalogID: definition.id, path: candidate.path, resolvedPath: real.path,
                source: evidence.source, managerPath: evidence.manager, package: evidence.package,
                ownershipRoot: evidence.ownershipRoot,
                active: candidate.path == preferredPath)
            var commandEnvironment = environment.environment
            commandEnvironment["HOME"] = environment.home.path
            commandEnvironment["PATH"] = uniqueURLs([candidate.deletingLastPathComponent()] + directories).map(\.path).joined(separator: ":")
            commandEnvironment["NO_COLOR"] = "1"
            do {
                // A package can wrap a separately updated binary; only this entry's runtime is authoritative.
                let result = try await execute(ApplicationCommand(candidate.path, ["--version"], environment: commandEnvironment), 3)
                if result.timedOut { installation.versionError = "Version check timed out." }
                else if result.exitCode != 0 { installation.versionError = "The installed application could not report its version." }
                else if let version = version(in: result.output, definition: definition) { installation.version = version }
                else { installation.versionError = "The installed application returned no recognizable application version." }
            } catch is CancellationError { break }
            catch { installation.versionError = "The installed application could not be started for a version check." }
            installations.append(installation)
        }
        return ApplicationDiscoveryResult(installations: installations, configurationFound: configurationFound,
            error: unidentified ? "A same-named executable was found, but its application identity could not be verified." : nil)
    }

    private struct Evidence {
        var source: ApplicationInstallationSource
        var manager: String? = nil
        var package: String? = nil
        var ownershipRoot: String? = nil
    }

    private func evidence(for definition: ManagedApplicationDefinition, entry: URL, real: URL,
                          nativeRoots: [URL], directories: [URL]) -> Evidence? {
        let npm = npmMetadata(definition, real: real)
        let components = real.pathComponents
        if let marker = components.firstIndex(where: { $0 == "Cellar" || $0 == "Caskroom" }), marker + 1 < components.count {
            let owner = components[marker + 1]
            let expected = definition.brewPackage?.split(separator: "/").last.map(String.init)
            let isClaudeAlias = definition.id == "claude" && owner == "claude-code@latest"
            if owner == expected || isClaudeAlias {
                let prefix = URL(fileURLWithPath: NSString.path(withComponents: Array(components[..<marker])))
                let brew = prefix.appendingPathComponent("bin/brew")
                return Evidence(source: .homebrew, manager: isExecutable(brew) ? brew.path : nil,
                                package: owner)
            }
            // A formula's bundled Node package is never owned by a neighbouring npm.
            if let npm { return Evidence(source: .unknown, package: npm.name) }
            return nil
        }
        if let npm {
            if isInside(real, root("VOLTA_HOME", ".volta").appendingPathComponent("tools/image/packages")) {
                return Evidence(source: .unknown, package: npm.name)
            }
            let prefix = entry.deletingLastPathComponent().deletingLastPathComponent()
            let expected = prefix.appendingPathComponent("lib/node_modules/" + npm.name).resolvingSymlinksInPath()
            let modules = npm.name.hasPrefix("@") ? npm.root.deletingLastPathComponent().deletingLastPathComponent() : npm.root.deletingLastPathComponent()
            let ownerPrefix: URL?
            if entry.deletingLastPathComponent().lastPathComponent == "bin", expected.standardizedFileURL == npm.root {
                ownerPrefix = prefix
            } else if modules.lastPathComponent == "node_modules", modules.deletingLastPathComponent().lastPathComponent == "lib" {
                ownerPrefix = modules.deletingLastPathComponent().deletingLastPathComponent()
            } else { ownerPrefix = nil }
            if let ownerPrefix {
                let npmExecutable = ownerPrefix.appendingPathComponent("bin/npm")
                return Evidence(source: .npm, manager: isExecutable(npmExecutable) ? npmExecutable.path : nil,
                                package: npm.name)
            }
            return Evidence(source: .unknown, package: npm.name)
        }
        if let python = pythonEvidence(definition, real: real, directories: directories) { return python }
        if definition.id == "hermes", let hermes = hermesEvidence(entry: entry, nativeRoots: nativeRoots) { return hermes }
        if definition.id == "mcode", let mcode = miniMaxEvidence(real: real) { return mcode }
        if nativeRoots.contains(where: { root in
            // An arbitrary target behind an official-looking launcher is not proof of ownership.
            let attributes = try? FileManager.default.attributesOfItem(atPath: root.path)
            if attributes?[.type] as? FileAttributeType == .typeSymbolicLink { return false }
            let resolved = root.resolvingSymlinksInPath().standardizedFileURL
            let sharedBin = [".local/bin", ".bun/bin", ".cargo/bin", ".volta/bin"].contains {
                environment.home.appendingPathComponent($0).resolvingSymlinksInPath().standardizedFileURL == resolved
            }
            return real == resolved || (!sharedBin && isInside(real, resolved))
        }), isNativeBinary(real) {
            return Evidence(source: .native)
        }
        return nil
    }

    private struct NPMMetadata { let name: String; let root: URL }
    private func npmMetadata(_ definition: ManagedApplicationDefinition, real: URL) -> NPMMetadata? {
        guard let expected = definition.npmPackage else { return nil }
        var names = Set([expected])
        if definition.id == "pi" { names.insert("@badlogic/pi-coding-agent") }
        var directory = real.deletingLastPathComponent()
        for _ in 0..<14 {
            if let object = json(directory.appendingPathComponent("package.json")),
               let name = object["name"] as? String, names.contains(name) {
                return NPMMetadata(name: name, root: directory.standardizedFileURL)
            }
            let parent = directory.deletingLastPathComponent()
            if parent == directory { break }
            directory = parent
        }
        return nil
    }

    private func pythonEvidence(_ definition: ManagedApplicationDefinition, real: URL, directories: [URL]) -> Evidence? {
        guard let package = definition.pythonPackage, real.deletingLastPathComponent().lastPathComponent == "bin" else { return nil }
        let venv = real.deletingLastPathComponent().deletingLastPathComponent()
        guard hasPythonMetadata(package, venv: venv) else { return nil }
        let receipt = venv.appendingPathComponent("uv-receipt.toml")
        if isInside(venv, uvToolsRoot), let data = boundedData(receipt), let content = String(data: data, encoding: .utf8),
           let table = try? TOMLTable(string: content),
           let convertedData = table.convert(to: .json).data(using: .utf8),
           let object = (try? JSONSerialization.jsonObject(with: convertedData)) as? [String: Any],
           let tool = object["tool"] as? [String: Any], let requirements = tool["requirements"] as? [[String: Any]],
           requirements.contains(where: { normalizedPackage($0["name"] as? String ?? "") == normalizedPackage(package) }) {
            return Evidence(source: .uv, manager: manager("uv", directories: directories), package: package)
        }
        if let receipt = json(venv.appendingPathComponent("pipx_metadata.json")),
           let main = receipt["main_package"] as? [String: Any],
           normalizedPackage(main["package"] as? String ?? "") == normalizedPackage(package) {
            return Evidence(source: .pipx, manager: manager("pipx", directories: directories), package: package)
        }
        return Evidence(source: .unknown, package: package)
    }

    private func hasPythonMetadata(_ package: String, venv: URL) -> Bool {
        for python in children(venv.appendingPathComponent("lib")) where python.lastPathComponent.hasPrefix("python") {
            for distribution in children(python.appendingPathComponent("site-packages")) where distribution.pathExtension == "dist-info" {
                guard let data = boundedData(distribution.appendingPathComponent("METADATA")),
                      let text = String(data: data, encoding: .utf8) else { continue }
                let lines = text.split(separator: "\n")
                let name = lines.first(where: { $0.hasPrefix("Name: ") }).map { String($0.dropFirst(6)) } ?? ""
                if normalizedPackage(name) == normalizedPackage(package) {
                    return true
                }
            }
        }
        return false
    }

    private func desktopInstallations(_ definition: ManagedApplicationDefinition, configurationFound: Bool) -> ApplicationDiscoveryResult {
        var candidates = environment.applicationDirectories.flatMap { root in
            children(root).filter { $0.pathExtension.lowercased() == "app" } + definition.bundleNames.map { root.appendingPathComponent($0) }
        }
        candidates = uniqueURLs(candidates)
        var installations: [ApplicationInstallation] = []
        var seen: Set<String> = []
        for candidate in candidates {
            let real = candidate.resolvingSymlinksInPath().standardizedFileURL
            guard let data = boundedData(real.appendingPathComponent("Contents/Info.plist")),
                  let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
                  let id = plist["CFBundleIdentifier"] as? String, definition.bundleIDs.contains(id),
                  let executable = plist["CFBundleExecutable"] as? String, !executable.isEmpty,
                  !executable.contains("/"), executable != ".", executable != ".." else { continue }
            let binary = real.appendingPathComponent("Contents/MacOS/" + executable)
            guard isExecutable(binary), isInside(binary.resolvingSymlinksInPath(), real), seen.insert(real.path).inserted else { continue }
            let version = cleanVersion(plist["CFBundleShortVersionString"] as? String) ?? cleanVersion(plist["CFBundleVersion"] as? String)
            let owner = desktopHomebrewOwner(definition, bundle: real)
            installations.append(ApplicationInstallation(catalogID: definition.id, path: candidate.path, resolvedPath: real.path,
                version: version, versionError: version == nil ? "The application bundle has no version metadata." : nil,
                source: owner == nil ? .bundle : .homebrew, managerPath: owner?.manager, package: owner?.package ?? id))
        }
        return ApplicationDiscoveryResult(installations: installations, configurationFound: configurationFound)
    }

    private func desktopHomebrewOwner(_ definition: ManagedApplicationDefinition, bundle: URL) -> Evidence? {
        guard let token = definition.brewPackage?.split(separator: "/").last.map(String.init) else { return nil }
        var prefixes = executableDirectories().filter { $0.lastPathComponent == "bin" }.map { $0.deletingLastPathComponent() }
        if let configured = absoluteEnvironment("HOMEBREW_PREFIX") { prefixes.insert(configured, at: 0) }
        for prefix in uniqueURLs(prefixes) {
            for release in children(prefix.appendingPathComponent("Caskroom/" + token)) {
                // Homebrew moves the app and retains an artifact link to that exact destination.
                let artifacts = children(release).filter { $0.pathExtension == "app" }
                    + definition.bundleNames.map { release.appendingPathComponent($0) }
                if artifacts.contains(where: { FileManager.default.fileExists(atPath: $0.path)
                    && $0.resolvingSymlinksInPath().standardizedFileURL.path == bundle.path }) {
                    let brew = prefix.appendingPathComponent("bin/brew")
                    return Evidence(source: .homebrew, manager: isExecutable(brew) ? brew.path : nil, package: token)
                }
            }
        }
        return nil
    }

    private func hermesEvidence(entry: URL, nativeRoots: [URL]) -> Evidence? {
        for root in nativeRoots where root.lastPathComponent == "hermes-agent" {
            let repository = root.resolvingSymlinksInPath().standardizedFileURL
            let local = repository.appendingPathComponent(".hermes/bin/hermes")
            if entry.resolvingSymlinksInPath().standardizedFileURL != local {
                guard let outer = textFile(entry), let words = launcherWords(outer), words.count == 3,
                      words[0] == "exec", words[2] == "$@",
                      URL(fileURLWithPath: words[1]).resolvingSymlinksInPath().standardizedFileURL == local else { continue }
            }
            guard isExecutable(local), let launcher = textFile(local), let command = launcherWords(launcher),
                  command.count == 6, command[0] == "exec", command[2] == "-I", command[3] == "-c", command[5] == "$@",
                  command[1].hasPrefix("/"), isExecutable(URL(fileURLWithPath: command[1])),
                  command[4].contains("import hermes_bootstrap"), command[4].contains("from hermes_cli.main import main"),
                  ["'", "\""].contains(where: { quote in
                      let literal = repository.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: quote, with: "\\" + quote)
                      return command[4].contains("sys.path.insert(0, " + quote + literal + quote + ")")
                  }),
                  let manifest = toml(repository.appendingPathComponent("pyproject.toml")),
                  let project = manifest["project"] as? [String: Any], project["name"] as? String == "hermes-agent",
                  let scripts = project["scripts"] as? [String: Any], scripts["hermes"] as? String == "hermes_cli.main:main",
                  ["hermes_cli/main.py", "hermes_bootstrap.py"].allSatisfy({ path in
                      let file = repository.appendingPathComponent(path)
                      return isInside(file, repository) && (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                  }) else { continue }
            // The source project's 0.0.0 is a packaging placeholder; ask the verified launcher.
            return Evidence(source: .native, package: "hermes-agent", ownershipRoot: repository.path)
        }
        return nil
    }

    private func miniMaxEvidence(real: URL) -> Evidence? {
        guard real.lastPathComponent == "mcode", real.deletingLastPathComponent().lastPathComponent == "bin" else { return nil }
        let root = real.deletingLastPathComponent().deletingLastPathComponent()
        guard let receipt = json(root.appendingPathComponent("install.json")),
              receipt["schemaVersion"] as? Int == 2, receipt["layoutVersion"] as? Int == 2,
              receipt["product"] as? String == "minimax-code", receipt["updateOwner"] as? String == "npm-prefix",
              receipt["packageName"] as? String == "@minimax-ai/code", receipt["packageManager"] as? String == "npm",
              let prefix = receipt["prefix"] as? String, URL(fileURLWithPath: prefix).resolvingSymlinksInPath().standardizedFileURL == root,
              let current = textFile(root.appendingPathComponent("current"))?.trimmingCharacters(in: .whitespacesAndNewlines),
              current != ".", current != "..", current.range(of: #"^[0-9A-Za-z._-]+$"#, options: .regularExpression) != nil,
              let launcher = textFile(real), launcher == Self.miniMaxLauncher else { return nil }
        let release = root.appendingPathComponent("releases/" + current)
        let packageRoot = release.appendingPathComponent("lib/node_modules/@minimax-ai/code")
        guard isInside(release, root), isInside(packageRoot, release),
              let package = json(packageRoot.appendingPathComponent("package.json")), package["name"] as? String == "@minimax-ai/code",
              let bins = package["bin"] as? [String: Any], let entry = bins["mcode"] as? String,
              !entry.hasPrefix("/"), !entry.split(separator: "/").contains(".."),
              let node = receipt["nodeExecutable"] as? String, node.hasPrefix("/"), isExecutable(URL(fileURLWithPath: node)),
              isExecutable(release.appendingPathComponent(".mcode-launcher")),
              let inner = textFile(release.appendingPathComponent(".mcode-launcher")),
              inner.hasPrefix("#!/bin/sh\nset -eu\nroot=$(CDPATH= cd -- \"$(dirname -- \"$0\")\" && pwd -P)\n"),
              inner.contains("\nnode='" + node.replacingOccurrences(of: "'", with: "'\"'\"'") + "'\n") else { return nil }
        let file = packageRoot.appendingPathComponent(entry)
        let relative = "lib/node_modules/@minimax-ai/code/" + entry
        let escaped = relative.replacingOccurrences(of: "\\", with: "/").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$").replacingOccurrences(of: "`", with: "\\`")
        guard isInside(file, packageRoot), FileManager.default.fileExists(atPath: file.path),
              inner.hasSuffix("exec \"$node\" \"$root/" + escaped + "\" \"$@\"\n") else { return nil }
        return Evidence(source: .native, package: "@minimax-ai/code", ownershipRoot: root.path)
    }

    private static let miniMaxLauncher = #"""
    #!/bin/sh
    set -eu
    root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
    release=$(tr -d '\r\n' < "$root/current")
    case "$release" in ""|*[!0-9A-Za-z._-]*) echo "Invalid MCode current release pointer." >&2; exit 1;; esac
    exec "$root/releases/$release/.mcode-launcher" "$@"
    """# + "\n"

    /// Parses only the quoted argv form emitted by the official Hermes launcher writer.
    private func launcherWords(_ value: String) -> [String]? {
        guard value.hasPrefix("#!/bin/sh\n") else { return nil }
        var words: [String] = [], word = "", quote: Character?, escaped = false, started = false
        for character in value.dropFirst("#!/bin/sh\n".count) {
            if escaped { word.append(character); escaped = false; started = true; continue }
            if quote == "'" {
                if character == "'" { quote = nil } else { word.append(character) }
                continue
            }
            if character == "\\" { escaped = true; started = true; continue }
            if let current = quote {
                if character == current { quote = nil } else { word.append(character) }
            } else if character == "'" || character == "\"" { quote = character; started = true }
            else if character.isWhitespace {
                if started { words.append(word); word = ""; started = false }
            } else {
                guard !";|&<>`$".contains(character) else { return nil }
                word.append(character); started = true
            }
        }
        guard quote == nil, !escaped else { return nil }
        if started { words.append(word) }
        return words
    }

    private func textFile(_ url: URL) -> String? { boundedData(url).flatMap { String(data: $0, encoding: .utf8) } }
    private func toml(_ url: URL) -> [String: Any]? {
        guard let text = textFile(url), let table = try? TOMLTable(string: text), let data = table.convert(to: .json).data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func manager(_ command: String, directories: [URL]) -> String? {
        directories.map { $0.appendingPathComponent(command) }.first(where: isExecutable)?.path
    }
    private func root(_ key: String, _ fallback: String) -> URL { absoluteEnvironment(key) ?? environment.home.appendingPathComponent(fallback) }
    private func absoluteEnvironment(_ key: String) -> URL? {
        guard let value = environment.environment[key], value.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: value)
    }
    private func expanded(_ path: String) -> [URL] {
        let absolute = path.hasPrefix("~/") ? environment.home.appendingPathComponent(String(path.dropFirst(2))).path
            : path.hasPrefix("/") ? path : environment.home.appendingPathComponent(path).path
        var roots = [URL(fileURLWithPath: "/")]
        for component in absolute.split(separator: "/") {
            if component == "*" { roots = roots.flatMap(children) }
            else { roots = roots.map { $0.appendingPathComponent(String(component)) } }
        }
        return roots.map(\.standardizedFileURL)
    }
    private func children(_ url: URL) -> [URL] {
        Array(((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }.prefix(512))
    }
    private func isExecutable(_ url: URL) -> Bool {
        let real = url.resolvingSymlinksInPath()
        return (try? real.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            && FileManager.default.isExecutableFile(atPath: real.path)
    }
    private func isNativeBinary(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4) else { return false }
        let signatures: [[UInt8]] = [[0xcf, 0xfa, 0xed, 0xfe], [0xfe, 0xed, 0xfa, 0xcf], [0xce, 0xfa, 0xed, 0xfe],
                [0xfe, 0xed, 0xfa, 0xce], [0xca, 0xfe, 0xba, 0xbe], [0xbe, 0xba, 0xfe, 0xca],
                [0xca, 0xfe, 0xba, 0xbf], [0xbf, 0xba, 0xfe, 0xca],
                [0x7f, 0x45, 0x4c, 0x46]]
        return signatures.contains(Array(data))
    }
    private func isInside(_ child: URL, _ parent: URL) -> Bool {
        let root = parent.resolvingSymlinksInPath().standardizedFileURL.path
        return child.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root == "/" ? root : root + "/")
    }
    private func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        return urls.map(\.standardizedFileURL).filter { seen.insert($0.path).inserted }
    }
    private func boundedData(_ url: URL) -> Data? {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= 1_048_576,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: 1_048_576)
    }
    private func json(_ url: URL) -> [String: Any]? {
        guard let data = boundedData(url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    private func normalizedPackage(_ value: String) -> String { value.lowercased().replacingOccurrences(of: "_", with: "-").replacingOccurrences(of: ".", with: "-") }
    private func cleanVersion(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty, value.count <= 128,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return value
    }
    private func version(in output: String, definition: ManagedApplicationDefinition) -> String? {
        let text = String(output.prefix(4096)).replacingOccurrences(of: #"\x1B\[[0-?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let semver = #"(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?)"#
        let names = ([definition.name] + definition.commands).map { name in
            name.split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "_" })
                .map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: #"[\s_-]+"#)
        }.filter { !$0.isEmpty }.joined(separator: "|")
        let label = "(?:" + names + #")(?:[\s_-]+(?:cli|code|agent))?"#
        let patterns = [
            #"^[^\p{L}\p{N}]*"# + label + #"(?:\s*[,=:@]\s*|\s+)(?:version\s*[:=]?\s*)?v?"# + semver + #"(?=$|\s|\()"#,
            #"^v?"# + semver + #"\s+\("# + label + #"\)(?:\s.*)?$"#
        ]
        // Explicit application labels win over bare version lines, including runtime startup noise.
        for pattern in patterns {
            for line in lines {
                if let value = capturedVersion(pattern, line: line) { return value }
            }
        }
        for line in lines {
            if let value = capturedVersion("^v?" + semver + "$", line: line) { return value }
        }
        return nil
    }
    private func capturedVersion(_ pattern: String, line: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else { return nil }
        return String(line[range])
    }
}
