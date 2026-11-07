import AppKit
import CryptoKit
import Foundation

/// Manages only catalogued macOS bundles. Application data and preferences are never removed.
public enum ApplicationDesktopLifecycle {
    public enum Failure: Error, Equatable, LocalizedError {
        case unsupportedApplication, invalidTarget, invalidManifest, invalidBundle, invalidSignature
        case applicationRunning, downloadTooLarge, checksumMismatch, commandFailed
        case signingTeamChanged, rollbackFailed(String)

        public var errorDescription: String? {
            switch self {
            case .unsupportedApplication: "This desktop application is not supported."
            case .invalidTarget: "Choose a real application in /Applications or your Applications folder."
            case .invalidManifest: "The download service did not provide a supported macOS release."
            case .invalidBundle: "The downloaded application does not match the selected application."
            case .invalidSignature: "The application's developer signature could not be verified."
            case .applicationRunning: "Quit the application before installing, updating, or uninstalling it."
            case .downloadTooLarge: "The application download exceeded the size limit."
            case .checksumMismatch: "The downloaded file did not match its published checksum."
            case .commandFailed: "The application archive could not be opened or verified."
            case .signingTeamChanged: "The new application's signing team differs from the installed application."
            case .rollbackFailed(let path): "Installation failed. The previous application is preserved at \(path)."
            }
        }
    }

    public static func install(cask: String, bundleIDs: [String], target: String,
                               execute: @escaping ApplicationCommandExecutor, session: URLSession = .shared) async throws -> String {
        guard let definition = ManagedApplicationCatalog.all.first(where: {
            $0.kind == .desktop && $0.brewPackage == cask && Set($0.bundleIDs) == Set(bundleIDs)
        }), !bundleIDs.isEmpty else { throw Failure.unsupportedApplication }
        let destination = try validateTarget(target)
        try requireNotRunning(bundleIDs)
        let manager = FileManager.default
        var previousIdentity: BundleIdentity?
        var previousTeam: String?
        if manager.fileExists(atPath: destination.path) {
            previousIdentity = try bundleIdentity(at: destination, permittedIDs: bundleIDs)
            previousTeam = try await signingTeam(at: destination, execute: execute)
        }

        let temporary = manager.temporaryDirectory.appendingPathComponent("ccbar-desktop-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: temporary, withIntermediateDirectories: false,
                                    attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: temporary) }
        let manifestURL = try ApplicationVersionClient.url(for: .homebrew(cask, cask: true))
        let manifestFile = temporary.appendingPathComponent("manifest.json")
        try await download(manifestURL, to: manifestFile, maximumBytes: 1_048_576, allowedHosts: ["formulae.brew.sh"], session: session)
        let release = try parseManifest(Data(contentsOf: manifestFile), cask: cask)
        let archive = temporary.appendingPathComponent("application.\(release.format)")
        try await download(release.url, to: archive, maximumBytes: 2_147_483_648, allowedHosts: release.allowedHosts, session: session)
        if let expected = release.sha256, try checksum(of: archive) != expected { throw Failure.checksumMismatch }

        let extracted = temporary.appendingPathComponent("extracted", isDirectory: true)
        try manager.createDirectory(at: extracted, withIntermediateDirectories: false)
        let source: URL
        if release.format == "dmg" {
            let mount = temporary.appendingPathComponent("mounted", isDirectory: true)
            try manager.createDirectory(at: mount, withIntermediateDirectories: false)
            try await run(ApplicationCommand("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount.path, archive.path]), execute: execute)
            do {
                let mountedBundle = try findBundle(in: mount, permittedIDs: bundleIDs)
                source = extracted.appendingPathComponent(mountedBundle.lastPathComponent)
                try manager.copyItem(at: mountedBundle, to: source)
            } catch {
                _ = await detach(mount, execute: execute)
                throw error
            }
            guard await detach(mount, execute: execute) else { throw Failure.commandFailed }
        } else {
            try await run(ApplicationCommand("/usr/bin/ditto", ["-x", "-k", archive.path, extracted.path]), execute: execute)
            source = try findBundle(in: extracted, permittedIDs: bundleIDs)
        }
        let identity = try bundleIdentity(at: source, permittedIDs: bundleIDs)
        guard let installedVersion = identity.version,
              ApplicationVersionClient.compare(installed: installedVersion, latest: release.version) == .orderedSame else {
            throw Failure.invalidBundle
        }
        let team = try await signingTeam(at: source, execute: execute)
        if let previousIdentity, previousIdentity.id != identity.id { throw Failure.invalidBundle }
        if let previousTeam, previousTeam != team { throw Failure.signingTeamChanged }
        try requireNotRunning(bundleIDs)

        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try validateTarget(target)
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".ccbar-install-\(UUID().uuidString).app")
        let backup = destination.deletingLastPathComponent().appendingPathComponent(".ccbar-backup-\(UUID().uuidString).app")
        defer { try? manager.removeItem(at: staging) }
        try manager.copyItem(at: source, to: staging)
        _ = try bundleIdentity(at: staging, permittedIDs: bundleIDs)
        guard try await signingTeam(at: staging, execute: execute) == team else { throw Failure.invalidSignature }
        // Revalidate immediately before changing the destination, after network and extraction waits.
        if let previousIdentity {
            guard try bundleIdentity(at: destination, permittedIDs: bundleIDs) == previousIdentity,
                  try await signingTeam(at: destination, execute: execute) == previousTeam else { throw Failure.invalidTarget }
        } else if manager.fileExists(atPath: destination.path) {
            throw Failure.invalidTarget
        }
        try requireNotRunning(bundleIDs)
        var movedPrevious = false
        do {
            if previousIdentity != nil {
                try manager.moveItem(at: destination, to: backup)
                movedPrevious = true
            }
            try manager.moveItem(at: staging, to: destination)
        } catch {
            if movedPrevious {
                do { try manager.moveItem(at: backup, to: destination) }
                catch { throw Failure.rollbackFailed(backup.path) }
            }
            throw error
        }
        if movedPrevious { try? manager.trashItem(at: backup, resultingItemURL: nil) }
        return "Installed \(definition.name) \(release.version)."
    }

    public static func uninstall(path: String, bundleID: String) throws {
        guard ManagedApplicationCatalog.all.contains(where: { $0.kind == .desktop && $0.bundleIDs.contains(bundleID) }) else {
            throw Failure.unsupportedApplication
        }
        let target = try validateTarget(path)
        _ = try bundleIdentity(at: target, permittedIDs: [bundleID])
        try requireNotRunning([bundleID])
        try FileManager.default.trashItem(at: target, resultingItemURL: nil)
    }

    struct DesktopRelease {
        let url: URL
        let version: String
        let sha256: String?
        let format: String
        let allowedHosts: Set<String>
    }

    static func parseManifest(_ data: Data, cask: String, architecture: String = currentArchitecture,
                              macOSMajorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion) throws -> DesktopRelease {
        guard var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              ["claude", "codex-app", "cursor", "antigravity"].contains(cask),
              let token = object["token"] as? String, token == cask else { throw Failure.invalidManifest }
        let variants = object["variations"] as? [String: [String: Any]] ?? [:]
        let osName: String? = [11: "big_sur", 12: "monterey", 13: "ventura", 14: "sonoma",
                              15: "sequoia", 26: "tahoe", 27: "golden_gate"][macOSMajorVersion]
        if let osName, let variation = variants[architecture == "arm64" ? "arm64_\(osName)" : osName] {
            object.merge(variation) { _, replacement in replacement }
        } else if architecture != "arm64", variants.keys.contains(where: { !$0.contains("linux") && !$0.hasPrefix("arm64_") }) {
            throw Failure.invalidManifest
        }
        guard ["arm64", "x86_64"].contains(architecture), let address = object["url"] as? String,
              let url = URL(string: address), url.scheme == "https", url.user == nil, url.password == nil,
              let version = object["version"] as? String, !version.isEmpty,
              let digest = object["sha256"] as? String else { throw Failure.invalidManifest }
        let allowed: Set<String> = switch cask {
        case "claude": ["downloads.claude.ai"]
        case "codex-app": ["persistent.oaistatic.com"]
        case "cursor": ["downloads.cursor.com"]
        case "antigravity": ["storage.googleapis.com"]
        default: []
        }
        guard let host = url.host, allowed.contains(host), ["dmg", "zip"].contains(url.pathExtension.lowercased()),
              cask != "antigravity" || url.path.hasPrefix("/antigravity-public/") else { throw Failure.invalidManifest }
        guard digest == "no_check" || digest.range(of: #"^[a-fA-F0-9]{64}$"#, options: .regularExpression) != nil else {
            throw Failure.invalidManifest
        }
        return DesktopRelease(url: url, version: version.components(separatedBy: ",")[0],
                              sha256: digest == "no_check" ? nil : digest.lowercased(),
                              format: url.pathExtension.lowercased(), allowedHosts: allowed)
    }

    static var currentArchitecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }

    static func validateTarget(_ path: String, applicationDirectories: [URL]? = nil) throws -> URL {
        let target = URL(fileURLWithPath: path).standardizedFileURL
        let allowed = applicationDirectories ?? [URL(fileURLWithPath: "/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)]
        guard path.hasPrefix("/"), path == target.path, target.pathExtension == "app",
              allowed.contains(where: { $0.standardizedFileURL.path == target.deletingLastPathComponent().standardizedFileURL.path }) else {
            throw Failure.invalidTarget
        }
        var component = URL(fileURLWithPath: "/", isDirectory: true)
        for name in target.pathComponents.dropFirst() {
            component.appendPathComponent(name)
            if let attributes = try? FileManager.default.attributesOfItem(atPath: component.path),
               attributes[.type] as? FileAttributeType == .typeSymbolicLink { throw Failure.invalidTarget }
        }
        return target
    }

    struct BundleIdentity: Equatable {
        let id: String
        let executable: URL
        let version: String?
    }

    static func bundleIdentity(at bundle: URL, permittedIDs: [String]) throws -> BundleIdentity {
        let manager = FileManager.default
        guard let attributes = try? manager.attributesOfItem(atPath: bundle.path),
              attributes[.type] as? FileAttributeType == .typeDirectory, bundle.pathExtension == "app" else {
            throw Failure.invalidBundle
        }
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        let plist = contents.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let id = object["CFBundleIdentifier"] as? String, permittedIDs.contains(id),
              let name = object["CFBundleExecutable"] as? String, !name.isEmpty,
              name != ".", name != "..", !name.contains("/") else { throw Failure.invalidBundle }
        let executable = contents.appendingPathComponent("MacOS", isDirectory: true).appendingPathComponent(name)
        guard executable.resolvingSymlinksInPath().path.hasPrefix(bundle.resolvingSymlinksInPath().path + "/"),
              manager.isExecutableFile(atPath: executable.path),
              let handle = try? FileHandle(forReadingFrom: executable) else { throw Failure.invalidBundle }
        defer { try? handle.close() }
        let magic = Array(try handle.read(upToCount: 4) ?? Data())
        let machO: [[UInt8]] = [[0xcf, 0xfa, 0xed, 0xfe], [0xfe, 0xed, 0xfa, 0xcf],
                               [0xce, 0xfa, 0xed, 0xfe], [0xfe, 0xed, 0xfa, 0xce],
                               [0xca, 0xfe, 0xba, 0xbe], [0xbe, 0xba, 0xfe, 0xca],
                               [0xca, 0xfe, 0xba, 0xbf], [0xbf, 0xba, 0xfe, 0xca]]
        guard machO.contains(magic) else { throw Failure.invalidBundle }
        return BundleIdentity(id: id, executable: executable, version: object["CFBundleShortVersionString"] as? String)
    }

    private static func requireNotRunning(_ bundleIDs: [String]) throws {
        guard bundleIDs.allSatisfy({ NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }) else {
            throw Failure.applicationRunning
        }
    }

    private static func signingTeam(at bundle: URL, execute: ApplicationCommandExecutor) async throws -> String {
        let check = try await execute(ApplicationCommand("/usr/bin/codesign",
            ["--verify", "--deep", "--strict", "-R=anchor apple generic", bundle.path]), 60)
        guard check.exitCode == 0, !check.timedOut else { throw Failure.invalidSignature }
        let details = try await execute(ApplicationCommand("/usr/bin/codesign", ["--display", "--verbose=4", bundle.path]), 30)
        guard details.exitCode == 0, !details.timedOut,
              let line = details.output.components(separatedBy: .newlines).first(where: { $0.hasPrefix("TeamIdentifier=") }) else {
            throw Failure.invalidSignature
        }
        let team = String(line.dropFirst("TeamIdentifier=".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard team.range(of: #"^[A-Z0-9]{10}$"#, options: .regularExpression) != nil else { throw Failure.invalidSignature }
        return team
    }

    private static func findBundle(in directory: URL, permittedIDs: [String]) throws -> URL {
        guard let entries = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey],
                                                           options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            throw Failure.invalidBundle
        }
        var matches: [URL] = []
        for case let url as URL in entries {
            if entries.level > 4 { entries.skipDescendants(); continue }
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                entries.skipDescendants(); continue
            }
            if url.pathExtension == "app", (try? bundleIdentity(at: url, permittedIDs: permittedIDs)) != nil { matches.append(url) }
        }
        guard matches.count == 1, let match = matches.first else { throw Failure.invalidBundle }
        return match
    }

    private static func run(_ command: ApplicationCommand, execute: ApplicationCommandExecutor) async throws {
        let result = try await execute(command, 120)
        guard result.exitCode == 0, !result.timedOut else { throw Failure.commandFailed }
    }

    private static func detach(_ mount: URL, execute: @escaping ApplicationCommandExecutor) async -> Bool {
        // Cleanup must still run if the user cancelled the enclosing installation task.
        let result = await Task.detached {
            try? await execute(ApplicationCommand("/usr/bin/hdiutil", ["detach", mount.path]), 30)
        }.value
        return result?.exitCode == 0 && result?.timedOut == false
    }

    private static func checksum(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func download(_ url: URL, to target: URL, maximumBytes: Int64,
                                 allowedHosts: Set<String>, session baseSession: URLSession) async throws {
        let configuration = baseSession.configuration
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        let delegate = DesktopDownloadLimits(maximumBytes: maximumBytes, allowedHosts: allowedHosts)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (temporary, response) = try await session.download(for: URLRequest(url: url))
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
              let final = response.url, final.scheme == "https", let host = final.host,
              allowedHosts.contains(host) else { throw Failure.invalidManifest }
        let size = try FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? Int64 ?? Int64.max
        guard size <= maximumBytes else { throw Failure.downloadTooLarge }
        try FileManager.default.moveItem(at: temporary, to: target)
    }
}

/// Immutable limits are safe to share with URLSession's delegate queue.
private final class DesktopDownloadLimits: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let maximumBytes: Int64
    let allowedHosts: Set<String>
    init(maximumBytes: Int64, allowedHosts: Set<String>) {
        self.maximumBytes = maximumBytes; self.allowedHosts = allowedHosts
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > maximumBytes || totalBytesExpectedToWrite > maximumBytes { downloadTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, url.scheme == "https", url.user == nil, url.password == nil,
              let host = url.host, allowedHosts.contains(host) else { completionHandler(nil); return }
        completionHandler(request)
    }
}
