import Foundation
import Darwin

public enum ApplicationLifecycleAction: String, Sendable, Codable { case install, upgrade, uninstall }

public enum ApplicationLifecycleError: Error, LocalizedError {
    case unavailable(String), changedInstallation, failed(String)
    public var errorDescription: String? {
        switch self {
        case .unavailable(let message), .failed(let message): message
        case .changedInstallation: "安装信息已变化，请重新检查并确认操作。"
        }
    }
}

public struct ApplicationFileIdentity: Sendable, Equatable {
    public let path: String
    private let device: UInt64
    private let inode: UInt64
    private let modified: Int64
    private let size: Int64
    public init(path: String) throws {
        var value = stat()
        guard lstat(path, &value) == 0, value.st_uid == geteuid(),
              [S_IFREG, S_IFLNK].contains(value.st_mode & S_IFMT) else {
            throw ApplicationLifecycleError.changedInstallation
        }
        self.path = path; device = UInt64(value.st_dev); inode = UInt64(value.st_ino)
        modified = Int64(value.st_mtimespec.tv_sec) ^ Int64(value.st_mtimespec.tv_nsec)
        size = value.st_size
    }
    public func validate() throws {
        guard try Self(path: path) == self else { throw ApplicationLifecycleError.changedInstallation }
    }
}

public enum ApplicationLifecycleStep: Sendable, Equatable {
    case command(ApplicationCommand)
    case installer(url: String, shell: String, environment: [String: String])
    case removeFiles([ApplicationFileIdentity])
    case removeNativePackages([ApplicationNativePackageIdentity])
    case desktopInstall(cask: String, bundleIDs: [String], target: String)
    case trashBundle(path: String, bundleID: String)
    public var description: String {
        switch self {
        case .command(let command): command.display
        case .installer(let url, _, _): "Download and run the official installer: \(url)"
        case .removeFiles(let files): "Remove only these program files: " + files.map(\.path).joined(separator: ", ")
        case .removeNativePackages(let packages): "Remove verified application packages: " + packages.map(\.path).joined(separator: ", ")
        case .desktopInstall(_, _, let target): "Download and verify the application, then install to: " + target
        case .trashBundle(let path, _): "Move the application to Trash; keep settings and history: " + path
        }
    }
}

public struct ApplicationLifecyclePlan: Sendable, Equatable {
    public let catalogID: String
    public let installation: ApplicationInstallation?
    public let action: ApplicationLifecycleAction
    public let sourceLabel: String
    public let steps: [ApplicationLifecycleStep]
}

/// Plans contain native-owned arguments. RPC clients can confirm an opaque plan ID,
/// but cannot supply an executable, package, installation path, or shell program.
public struct ApplicationLifecyclePlanner: Sendable {
    public let environment: ApplicationDiscoveryEnvironment
    private let directories: [URL]
    public init(environment: ApplicationDiscoveryEnvironment = .init()) {
        self.environment = environment
        directories = ApplicationDiscovery(environment: environment).executableDirectories()
    }

    public func plan(_ definition: ManagedApplicationDefinition, action: ApplicationLifecycleAction,
                     installation: ApplicationInstallation? = nil) throws -> ApplicationLifecyclePlan {
        let steps: [ApplicationLifecycleStep]
        let source: String
        if action == .install {
            guard installation == nil else { throw ApplicationLifecycleError.changedInstallation }
            if let url = definition.installScript {
                guard URL(string: url)?.scheme == "https" else { throw ApplicationLifecycleError.changedInstallation }
                source = "Official installer"
                let shell = definition.id == "omp" ? "/bin/sh" : "/bin/bash"
                steps = [.installer(url: url, shell: shell, environment: commandEnvironment())]
            } else if definition.kind == .desktop, let token = definition.brewPackage, let brew = executable("brew") {
                source = "Homebrew"
                steps = [.command(ApplicationCommand(brew, ["install", "--cask", token], environment: commandEnvironment()))]
            } else if definition.kind == .desktop, let token = definition.brewPackage, let name = definition.bundleNames.first {
                source = "Official download"
                let target = environment.home.appendingPathComponent("Applications").appendingPathComponent(name).path
                guard !FileManager.default.fileExists(atPath: target) else { throw ApplicationLifecycleError.changedInstallation }
                steps = [.desktopInstall(cask: token, bundleIDs: definition.bundleIDs, target: target)]
            } else if let package = definition.npmPackage, let npm = executable("npm") {
                source = "npm"
                steps = [.command(ApplicationCommand(npm, ["install", "--global", package + "@latest"] + npmArguments(definition.id), environment: commandEnvironment(manager: npm)))]
            } else if let token = definition.brewPackage, let brew = executable("brew") {
                source = "Homebrew"
                steps = [.command(ApplicationCommand(brew, ["install"] + (definition.brewCask ? ["--cask"] : ["--formula"]) + [token], environment: commandEnvironment()))]
            } else {
                throw ApplicationLifecycleError.unavailable(definition.kind == .desktop
                    ? "需要先安装 Homebrew，才能在这里安装此桌面应用。"
                    : "未找到此应用需要的安装工具，请先安装 Node.js / npm 或 Homebrew。")
            }
        } else {
            guard let installation, installation.catalogID == definition.id,
                  FileManager.default.isExecutableFile(atPath: definition.kind == .desktop ? bundleExecutable(installation.path) : installation.path),
                  URL(fileURLWithPath: installation.path).resolvingSymlinksInPath().path == installation.resolvedPath else {
                throw ApplicationLifecycleError.changedInstallation
            }
            source = installation.source.label
            switch installation.source {
            case .npm:
                guard let npm = installation.managerPath, let package = installation.package,
                      allowedPackage(package, definition: definition),
                      let range = installation.resolvedPath.range(of: "/lib/node_modules/"),
                      FileManager.default.isExecutableFile(atPath: npm) else {
                    throw ApplicationLifecycleError.unavailable("无法确认这处 npm 安装的所属目录，请使用原安装工具管理。")
                }
                let prefix = String(installation.resolvedPath[..<range.lowerBound])
                let args = action == .upgrade
                    ? ["install", "--global", "--prefix", prefix, package + "@latest"] + npmArguments(definition.id)
                    : ["uninstall", "--global", "--prefix", prefix, package]
                var commands: [ApplicationLifecycleStep] = []
                if action == .uninstall, definition.id == "openclaw" {
                    commands.append(.command(ApplicationCommand(installation.path, ["uninstall", "--service", "--yes", "--non-interactive"], environment: commandEnvironment(manager: npm))))
                }
                commands.append(.command(ApplicationCommand(npm, args, environment: commandEnvironment(manager: npm))))
                steps = commands
            case .homebrew:
                guard let brew = installation.managerPath, let package = installation.package,
                      (package == definition.brewPackage || (definition.id == "claude" && package == "claude-code@latest")),
                      FileManager.default.isExecutableFile(atPath: brew) else {
                    throw ApplicationLifecycleError.changedInstallation
                }
                let cask = installation.resolvedPath.contains("/Caskroom/") ? true
                    : installation.resolvedPath.contains("/Cellar/") ? false : definition.brewCask
                steps = [.command(ApplicationCommand(brew, [action == .upgrade ? "upgrade" : "uninstall"]
                    + (cask ? ["--cask"] : ["--formula"]) + [package], environment: commandEnvironment()))]
            case .uv, .pipx:
                guard let manager = installation.managerPath, let package = installation.package,
                      package == definition.pythonPackage, FileManager.default.isExecutableFile(atPath: manager) else {
                    throw ApplicationLifecycleError.changedInstallation
                }
                let args = (installation.source == .uv ? ["tool"] : [])
                    + [action == .upgrade ? "upgrade" : "uninstall", package]
                let venv = URL(fileURLWithPath: installation.resolvedPath).deletingLastPathComponent().deletingLastPathComponent()
                let tools = venv.deletingLastPathComponent()
                var values = commandEnvironment(manager: manager)
                if installation.source == .uv {
                    values["UV_TOOL_DIR"] = tools.path
                } else {
                    guard tools.lastPathComponent == "venvs" else { throw ApplicationLifecycleError.changedInstallation }
                    values["PIPX_HOME"] = tools.deletingLastPathComponent().path
                }
                if !installation.path.hasPrefix(venv.path + "/") {
                    values[installation.source == .uv ? "UV_TOOL_BIN_DIR" : "PIPX_BIN_DIR"] = URL(fileURLWithPath: installation.path).deletingLastPathComponent().path
                }
                steps = [.command(ApplicationCommand(manager, args, environment: values))]
            case .native:
                if definition.id == "mcode" {
                    steps = try ApplicationNativeInstallations.miniMaxPlan(definition: definition, installation: installation, action: action, environment: environment)
                } else if action == .upgrade, definition.id == "codex", let url = definition.installScript,
                   let range = installation.resolvedPath.range(of: "/packages/standalone/") {
                    var values = commandEnvironment(manager: installation.path)
                    values["CODEX_NON_INTERACTIVE"] = "1"
                    values["CODEX_INSTALL_DIR"] = URL(fileURLWithPath: installation.path).deletingLastPathComponent().path
                    values["CODEX_HOME"] = String(installation.resolvedPath[..<range.lowerBound])
                    steps = [.installer(url: url, shell: "/bin/sh", environment: values)]
                } else if action == .upgrade, let arguments = definition.updateArguments, definition.id != "codex" {
                    steps = [.command(ApplicationCommand(installation.path, arguments, environment: commandEnvironment(manager: installation.path)))]
                } else if action == .uninstall, definition.id == "hermes" {
                    steps = [.command(ApplicationCommand(installation.path, ["uninstall", "--yes"], environment: commandEnvironment(manager: installation.path)))]
                } else if action == .uninstall {
                    steps = [.removeFiles(try nativeProgramFiles(definition, installation))]
                } else {
                    throw ApplicationLifecycleError.unavailable("此安装方式暂不支持原地升级，请使用原安装工具。")
                }
            case .bundle:
                let target = URL(fileURLWithPath: installation.path).standardizedFileURL
                let allowed = environment.applicationDirectories.map { $0.standardizedFileURL.path }
                guard allowed.contains(target.deletingLastPathComponent().path), target.pathExtension == "app",
                      let bundleID = Bundle(url: target)?.bundleIdentifier, definition.bundleIDs.contains(bundleID) else {
                    throw ApplicationLifecycleError.changedInstallation
                }
                if action == .uninstall {
                    steps = [.trashBundle(path: target.path, bundleID: bundleID)]
                } else if let cask = definition.brewPackage {
                    steps = [.desktopInstall(cask: cask, bundleIDs: [bundleID], target: target.path)]
                } else {
                    throw ApplicationLifecycleError.unavailable("尚未配置此桌面应用的官方更新来源。")
                }
            case .unknown:
                throw ApplicationLifecycleError.unavailable("无法确认安装来源，请使用原安装工具管理这处安装。")
            }
        }
        return ApplicationLifecyclePlan(catalogID: definition.id, installation: installation,
                                        action: action, sourceLabel: source, steps: steps)
    }

    private func allowedPackage(_ package: String, definition: ManagedApplicationDefinition) -> Bool {
        package == definition.npmPackage || (definition.id == "pi" && package == "@badlogic/pi-coding-agent")
    }
    private func npmArguments(_ id: String) -> [String] {
        let allowed: [String: String] = ["claude": "@anthropic-ai/claude-code", "grokbuild": "@xai-official/grok",
            "opencode": "opencode-ai", "mcode": "@minimax-ai/code,better-sqlite3"]
        if let package = allowed[id] { return ["--ignore-scripts=false", "--include=optional", "--allow-scripts=" + package] }
        return id == "dsh" ? ["--engine-strict"] : []
    }
    private func executable(_ name: String) -> String? {
        directories.map { $0.appendingPathComponent(name) }.first {
            (try? $0.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                && FileManager.default.isExecutableFile(atPath: $0.path)
        }?.path
    }
    private func commandEnvironment(manager: String? = nil) -> [String: String] {
        var result = environment.environment
        var paths = directories.map(\.path)
        if let manager { paths.insert(URL(fileURLWithPath: manager).deletingLastPathComponent().path, at: 0) }
        result["PATH"] = paths.joined(separator: ":")
        result["HOME"] = environment.home.path
        result["CI"] = "1"
        result["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        result["HOMEBREW_NO_ENV_HINTS"] = "1"
        return result
    }
    private func bundleExecutable(_ path: String) -> String {
        guard let bundle = Bundle(path: path), let executable = bundle.executableURL else { return "" }
        return executable.path
    }
    private func nativeProgramFiles(_ definition: ManagedApplicationDefinition, _ installation: ApplicationInstallation) throws -> [ApplicationFileIdentity] {
        let roots = definition.nativeRoots.map { environment.home.appendingPathComponent($0).standardizedFileURL.path }
        let real = URL(fileURLWithPath: installation.resolvedPath).standardizedFileURL.path
        guard !real.contains("/node_modules/"), roots.contains(where: { real.hasPrefix($0 + "/") || real == $0 }),
              definition.commands.contains(URL(fileURLWithPath: installation.path).lastPathComponent) else {
            throw ApplicationLifecycleError.unavailable("无法确认原生程序文件的归属，未生成卸载操作。")
        }
        // Only individual executable files / links; never remove configuration trees.
        return try Array(Set([installation.path, installation.resolvedPath])).sorted().map(ApplicationFileIdentity.init(path:))
    }
}

public struct ApplicationLifecycleExecutor: Sendable {
    private let execute: ApplicationCommandExecutor
    private let session: URLSession
    public init(execute: @escaping ApplicationCommandExecutor = { try await ApplicationCommandRunner.run($0, $1) }, session: URLSession = .shared) {
        self.execute = execute; self.session = session
    }
    public func run(_ plan: ApplicationLifecyclePlan) async throws -> String {
        var output = ""
        // Check the whole removal plan before deleting its first package or launcher.
        for step in plan.steps {
            switch step {
            case .removeFiles(let files): try files.forEach { try $0.validate() }
            case .removeNativePackages(let packages): try packages.forEach { try $0.validate() }
            default: break
            }
        }
        for step in plan.steps {
            try Task.checkCancellation()
            let result: ApplicationCommandResult?
            switch step {
            case .command(let command): result = try await execute(command, 600)
            case .installer(let address, let shell, let environment):
                guard let url = URL(string: address), url.scheme == "https" else { throw ApplicationLifecycleError.changedInstallation }
                var request = URLRequest(url: url); request.timeoutInterval = 60
                let (bytes, response) = try await session.bytes(for: request)
                defer { bytes.task.cancel() }
                guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                      response.url?.scheme == "https", response.expectedContentLength <= 2_000_000 else {
                    throw ApplicationLifecycleError.failed("官方安装脚本下载失败，请稍后重试。")
                }
                var data = Data()
                for try await byte in bytes {
                    guard data.count < 2_000_000 else { throw ApplicationLifecycleError.failed("官方安装脚本超过大小限制。") }
                    data.append(byte)
                }
                guard !data.isEmpty else { throw ApplicationLifecycleError.failed("官方安装脚本为空，未执行安装。") }
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ccbar-installer-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                defer { try? FileManager.default.removeItem(at: directory) }
                let file = directory.appendingPathComponent("install.sh")
                try data.write(to: file, options: .atomic)
                result = try await execute(ApplicationCommand(shell, [file.path], environment: environment), 600)
            case .removeFiles(let files):
                try files.forEach { try $0.validate() }
                for file in files { try file.validate(); try FileManager.default.removeItem(atPath: file.path) }
                result = nil
            case .removeNativePackages(let packages):
                try packages.forEach { try $0.validate() }
                for package in packages { try package.remove() }
                result = nil
            case .desktopInstall(let cask, let bundleIDs, let target):
                let message = try await ApplicationDesktopLifecycle.install(cask: cask, bundleIDs: bundleIDs, target: target, execute: execute, session: session)
                result = ApplicationCommandResult(exitCode: 0, output: message)
            case .trashBundle(let path, let bundleID):
                try ApplicationDesktopLifecycle.uninstall(path: path, bundleID: bundleID)
                result = nil
            }
            if let result {
                output = String((output + "\n" + result.output).suffix(64_000))
                guard !result.timedOut, result.exitCode == 0 else {
                    throw ApplicationLifecycleError.failed(result.timedOut ? "操作超时，请重新检查安装状态。" : "安装工具执行失败：\n" + String(result.output.suffix(4000)))
                }
            }
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
