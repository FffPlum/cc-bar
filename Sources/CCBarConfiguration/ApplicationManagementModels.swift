import Foundation
import CryptoKit

/// Installation identity is separate from provider configuration and quota identity.
public struct ManagedApplicationDefinition: Sendable, Identifiable {
    public enum Kind: String, Sendable { case cli, desktop }
    public let id: String
    public let name: String
    public let kind: Kind
    public let configurationApplication: AgentApplication?
    public let website: String
    public let commands: [String]
    public let bundleIDs: [String]
    public let bundleNames: [String]
    public let configurationPaths: [String]
    public let nativeRoots: [String]
    public let npmPackage: String?
    public let brewPackage: String?
    public let brewCask: Bool
    public let pythonPackage: String?
    public let installScript: String?
    public let updateArguments: [String]?
    public let releaseSource: ApplicationReleaseSource?

    public init(id: String, name: String, kind: Kind = .cli,
                configurationApplication: AgentApplication? = nil, website: String,
                commands: [String] = [], bundleIDs: [String] = [], bundleNames: [String] = [],
                configurationPaths: [String] = [], nativeRoots: [String] = [],
                npmPackage: String? = nil, brewPackage: String? = nil, brewCask: Bool = false,
                pythonPackage: String? = nil, installScript: String? = nil,
                updateArguments: [String]? = nil, releaseSource: ApplicationReleaseSource? = nil) {
        self.id = id; self.name = name; self.kind = kind
        self.configurationApplication = configurationApplication; self.website = website
        self.commands = commands; self.bundleIDs = bundleIDs; self.bundleNames = bundleNames
        self.configurationPaths = configurationPaths; self.nativeRoots = nativeRoots
        self.npmPackage = npmPackage; self.brewPackage = brewPackage; self.brewCask = brewCask
        self.pythonPackage = pythonPackage; self.installScript = installScript
        self.updateArguments = updateArguments; self.releaseSource = releaseSource
    }
}

public enum ApplicationReleaseSource: Sendable, Equatable {
    case npm(String), pypi(String), github(String), homebrew(String, cask: Bool)
    case manifest(String)
}

public enum ApplicationInstallationSource: String, Sendable, Codable {
    case npm, homebrew, uv, pipx, native, bundle, unknown
    public var label: String {
        switch self {
        case .npm: "npm"
        case .homebrew: "Homebrew"
        case .uv: "uv"
        case .pipx: "pipx"
        case .native: "Official installer"
        case .bundle: "macOS application"
        case .unknown: "Unknown"
        }
    }
}

public struct ApplicationInstallation: Sendable, Equatable, Identifiable {
    public let id: String
    public let catalogID: String
    public let path: String
    public let resolvedPath: String
    public var version: String?
    public var versionError: String?
    public let source: ApplicationInstallationSource
    public let managerPath: String?
    public let package: String?
    public let ownershipRoot: String?
    public var active: Bool

    public init(catalogID: String, path: String, resolvedPath: String, version: String? = nil,
                versionError: String? = nil, source: ApplicationInstallationSource,
                managerPath: String? = nil, package: String? = nil, ownershipRoot: String? = nil, active: Bool = false) {
        self.id = "installation_" + SHA256.hash(data: Data("\(catalogID)\n\(path)\n\(resolvedPath)".utf8))
            .prefix(12).map { String(format: "%02x", $0) }.joined()
        self.catalogID = catalogID; self.path = path; self.resolvedPath = resolvedPath
        self.version = version; self.versionError = versionError; self.source = source
        self.managerPath = managerPath; self.package = package; self.ownershipRoot = ownershipRoot; self.active = active
    }
}

public struct ApplicationDiscoveryResult: Sendable {
    public var installations: [ApplicationInstallation]
    public var configurationFound: Bool
    public var error: String?
    public init(installations: [ApplicationInstallation] = [], configurationFound: Bool = false, error: String? = nil) {
        self.installations = installations; self.configurationFound = configurationFound; self.error = error
    }
}

public struct ApplicationCommand: Sendable, Equatable {
    public let executable: String
    public let arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: String?
    public init(_ executable: String, _ arguments: [String] = [],
                environment: [String: String] = [:], workingDirectory: String? = nil) {
        self.executable = executable; self.arguments = arguments
        self.environment = environment; self.workingDirectory = workingDirectory
    }
    public var display: String {
        ([executable] + arguments).map(Self.quote).joined(separator: " ")
    }
    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

public struct ApplicationCommandResult: Sendable {
    public let exitCode: Int32
    public let output: String
    public let timedOut: Bool
    public init(exitCode: Int32, output: String, timedOut: Bool = false) {
        self.exitCode = exitCode; self.output = output; self.timedOut = timedOut
    }
}

public typealias ApplicationCommandExecutor = @Sendable (ApplicationCommand, TimeInterval) async throws -> ApplicationCommandResult

public struct ApplicationDiscoveryEnvironment: Sendable {
    public var home: URL
    public var environment: [String: String]
    public var applicationDirectories: [URL]
    public var standardExecutableDirectories: [URL]
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                environment: [String: String] = ProcessInfo.processInfo.environment,
                applicationDirectories: [URL]? = nil, standardExecutableDirectories: [URL]? = nil) {
        self.home = home; self.environment = environment
        self.applicationDirectories = applicationDirectories ?? [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
        self.standardExecutableDirectories = standardExecutableDirectories ?? [
            home.appendingPathComponent(".local/bin"), home.appendingPathComponent(".npm-global/bin"),
            home.appendingPathComponent(".bun/bin"), home.appendingPathComponent(".volta/bin"),
            home.appendingPathComponent(".cargo/bin"), URL(fileURLWithPath: "/opt/homebrew/bin"),
            URL(fileURLWithPath: "/usr/local/bin"), URL(fileURLWithPath: "/usr/bin")]
    }
}
