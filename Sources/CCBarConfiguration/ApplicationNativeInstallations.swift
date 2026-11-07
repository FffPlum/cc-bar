import Darwin
import Foundation

/// A deletion capability for one verified MiniMax installer release, not an arbitrary directory.
public struct ApplicationNativePackageIdentity: Sendable, Equatable {
    public let path: String
    private let root: String
    private let receipt: ApplicationFileIdentity
    private let rootIdentity: NativeDirectoryIdentity
    private let parentIdentity: NativeDirectoryIdentity
    private let entries: [NativeEntryIdentity]

    public init(path: String, ownershipRoot: String) throws {
        _ = try NativeDirectoryIdentity(path: path)
        let root = try NativeInstallationFiles.canonical(ownershipRoot)
        let release = try NativeInstallationFiles.canonical(path)
        let parent = URL(fileURLWithPath: root).appendingPathComponent("releases").path
        guard URL(fileURLWithPath: release).deletingLastPathComponent().path == parent,
              NativeInstallationFiles.validRelease(URL(fileURLWithPath: release).lastPathComponent),
              try NativeInstallationFiles.canonical(parent) == parent else { throw ApplicationLifecycleError.changedInstallation }
        _ = try NativeInstallationFiles.receipt(at: root)
        try NativeInstallationFiles.verifyPackage(in: release)
        self.path = release; self.root = root
        receipt = try ApplicationFileIdentity(path: root + "/install.json")
        rootIdentity = try NativeDirectoryIdentity(path: root)
        parentIdentity = try NativeDirectoryIdentity(path: parent)
        entries = try NativeInstallationFiles.tree(at: release)
    }

    public func validate() throws {
        try receipt.validate()
        guard try NativeDirectoryIdentity(path: root) == rootIdentity,
              try NativeDirectoryIdentity(path: URL(fileURLWithPath: path).deletingLastPathComponent().path) == parentIdentity,
              try Self(path: path, ownershipRoot: root) == self else { throw ApplicationLifecycleError.changedInstallation }
    }

    public func remove() throws {
        try validate()
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        let descriptor = open(parent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ApplicationLifecycleError.changedInstallation }
        defer { close(descriptor) }
        guard try NativeDirectoryIdentity(descriptor: descriptor) == parentIdentity else {
            throw ApplicationLifecycleError.changedInstallation
        }
        // All traversal stays relative to open directory descriptors; symlinks are only unlinked.
        try NativeInstallationFiles.removeDirectory(named: URL(fileURLWithPath: path).lastPathComponent,
                                                    parent: descriptor, relative: "", expected: entries)
    }
}

public enum ApplicationNativeInstallations {
    public static func miniMaxPlan(definition: ManagedApplicationDefinition, installation: ApplicationInstallation,
                                   action: ApplicationLifecycleAction, environment: ApplicationDiscoveryEnvironment) throws -> [ApplicationLifecycleStep] {
        guard definition.id == "mcode", installation.catalogID == "mcode", installation.source == .native,
              let root = installation.ownershipRoot else { throw ApplicationLifecycleError.changedInstallation }
        let layout = try miniMaxInstallation(root: root, launcher: installation.resolvedPath)
        guard try NativeInstallationFiles.canonical(installation.path) == layout.root + "/bin/mcode" else {
            throw ApplicationLifecycleError.changedInstallation
        }
        switch action {
        case .install:
            throw ApplicationLifecycleError.changedInstallation
        case .upgrade:
            let official = "https://filecdn.minimax.chat/public/install.sh"
            guard definition.installScript == official else { throw ApplicationLifecycleError.changedInstallation }
            var values = environment.environment
            values["HOME"] = environment.home.path
            values["MCODE_INSTALL_DIR"] = layout.root
            // The installer chooses its own runtime; never execute paths supplied by the receipt.
            let base = values["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
            values["PATH"] = layout.root + "/bin:" + base
            return [.installer(url: official, shell: "/bin/bash", environment: values)]
        case .uninstall:
            let releases = URL(fileURLWithPath: layout.root).appendingPathComponent("releases")
            let children = try FileManager.default.contentsOfDirectory(at: releases, includingPropertiesForKeys: nil)
            var packages: [ApplicationNativePackageIdentity] = []
            for child in children.sorted(by: { $0.path < $1.path }) {
                guard NativeInstallationFiles.validRelease(child.lastPathComponent) else { continue }
                // Unknown files or user-created directories are retained; the current release must validate.
                if let identity = try? ApplicationNativePackageIdentity(path: child.path, ownershipRoot: layout.root) {
                    packages.append(identity)
                } else if child.lastPathComponent == layout.currentRelease {
                    throw ApplicationLifecycleError.changedInstallation
                }
            }
            guard packages.contains(where: { URL(fileURLWithPath: $0.path).lastPathComponent == layout.currentRelease }) else {
                throw ApplicationLifecycleError.changedInstallation
            }
            var paths = layout.entryFiles
            if installation.path != installation.resolvedPath {
                var link = stat()
                guard lstat(installation.path, &link) == 0, link.st_mode & S_IFMT == S_IFLNK,
                      link.st_uid == geteuid() else { throw ApplicationLifecycleError.changedInstallation }
                paths.append(installation.path)
            }
            let receipt = layout.root + "/install.json"
            let files = try Array(Set(paths)).filter { $0 != receipt }.sorted().map(ApplicationFileIdentity.init(path:))
                + [ApplicationFileIdentity(path: receipt)]
            return [.removeNativePackages(packages), .removeFiles(files)]
        }
    }

    struct MiniMaxInstallation {
        let root: String
        let currentRelease: String
        let entryFiles: [String]
    }

    static func miniMaxInstallation(root: String, launcher: String) throws -> MiniMaxInstallation {
        let root = try NativeInstallationFiles.canonical(root)
        _ = try NativeDirectoryIdentity(path: root)
        _ = try NativeInstallationFiles.receipt(at: root)
        guard try NativeInstallationFiles.canonical(launcher) == root + "/bin/mcode" else {
            throw ApplicationLifecycleError.changedInstallation
        }
        let currentPath = root + "/current"
        let current = try NativeInstallationFiles.text(at: currentPath)
            .replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
        guard NativeInstallationFiles.validRelease(current) else { throw ApplicationLifecycleError.changedInstallation }
        let release = root + "/releases/" + current
        _ = try ApplicationNativePackageIdentity(path: release, ownershipRoot: root)
        var files = [root + "/bin/mcode", currentPath, root + "/install.json"]
        for name in ["mcode", "mcode-tools"] {
            let path = root + "/bin/" + name
            if !FileManager.default.fileExists(atPath: path), name == "mcode-tools" { continue }
            let content = try NativeInstallationFiles.text(at: path)
            guard [stableLauncher(name), stableLauncher(name) + "\n"].contains(content),
                  FileManager.default.isExecutableFile(atPath: path) else {
                throw ApplicationLifecycleError.changedInstallation
            }
            if name == "mcode-tools" { files.append(path) }
        }
        return MiniMaxInstallation(root: root, currentRelease: current, entryFiles: files)
    }

    static func stableLauncher(_ command: String) -> String {
        """
        #!/bin/sh
        set -eu
        root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
        release=$(tr -d '\\r\\n' < "$root/current")
        case "$release" in ""|*[!0-9A-Za-z._-]*) echo "Invalid MCode current release pointer." >&2; exit 1;; esac
        exec "$root/releases/$release/.\(command)-launcher" "$@"
        """
    }
}

private struct NativeDirectoryIdentity: Sendable, Equatable {
    let device: UInt64
    let inode: UInt64
    init(path: String) throws {
        var value = stat()
        guard lstat(path, &value) == 0 else { throw ApplicationLifecycleError.changedInstallation }
        try self.init(value)
    }
    init(descriptor: Int32) throws {
        var value = stat()
        guard fstat(descriptor, &value) == 0 else { throw ApplicationLifecycleError.changedInstallation }
        try self.init(value)
    }
    private init(_ value: stat) throws {
        guard value.st_mode & S_IFMT == S_IFDIR, value.st_uid == geteuid() else { throw ApplicationLifecycleError.changedInstallation }
        device = UInt64(value.st_dev); inode = UInt64(value.st_ino)
    }
}

private struct NativeEntryIdentity: Sendable, Equatable {
    let relative: String
    let device: UInt64
    let inode: UInt64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let size: Int64
    let kind: UInt16
    init(relative: String, value: stat) throws {
        guard value.st_uid == geteuid(), [S_IFREG, S_IFDIR, S_IFLNK].contains(value.st_mode & S_IFMT) else {
            throw ApplicationLifecycleError.changedInstallation
        }
        self.relative = relative; device = UInt64(value.st_dev); inode = UInt64(value.st_ino)
        modifiedSeconds = Int64(value.st_mtimespec.tv_sec); modifiedNanoseconds = Int64(value.st_mtimespec.tv_nsec)
        size = value.st_size; kind = value.st_mode & S_IFMT
    }
}

private enum NativeInstallationFiles {
    static let packageName = "@minimax-ai/code"

    static func canonical(_ path: String) throws -> String {
        guard path.hasPrefix("/"), let value = realpath(path, nil) else { throw ApplicationLifecycleError.changedInstallation }
        defer { free(value) }
        return String(cString: value)
    }

    static func validRelease(_ value: String) -> Bool {
        value != "." && value != ".." && !value.hasPrefix(".") && value.range(of: #"^[0-9A-Za-z][0-9A-Za-z._-]*$"#,
                                                                                         options: .regularExpression) != nil
    }

    static func text(at path: String) throws -> String {
        var value = stat()
        guard lstat(path, &value) == 0, value.st_uid == geteuid(), value.st_mode & S_IFMT == S_IFREG,
              value.st_size > 0, value.st_size <= 1_048_576,
              let text = String(data: try Data(contentsOf: URL(fileURLWithPath: path)), encoding: .utf8) else {
            throw ApplicationLifecycleError.changedInstallation
        }
        return text
    }

    static func receipt(at root: String) throws -> [String: Any] {
        let data = Data(try text(at: root + "/install.json").utf8)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["product"] as? String == "minimax-code", object["updateOwner"] as? String == "npm-prefix",
              object["packageManager"] as? String == "npm", object["packageName"] as? String == packageName,
              object["schemaVersion"] as? Int == 2, object["layoutVersion"] as? Int == 2,
              object["releasesDirectory"] as? String == "releases", object["currentFile"] as? String == "current",
              let prefix = object["prefix"] as? String, try canonical(prefix) == root else {
            throw ApplicationLifecycleError.changedInstallation
        }
        return object
    }

    static func verifyPackage(in release: String) throws {
        let package = release + "/lib/node_modules/@minimax-ai/code"
        guard try canonical(package) == package else { throw ApplicationLifecycleError.changedInstallation }
        let data = Data(try text(at: package + "/package.json").utf8)
        guard let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              manifest["name"] as? String == packageName, let bins = manifest["bin"] as? [String: String],
              let entry = bins["mcode"], !entry.hasPrefix("/"), !entry.split(separator: "/").contains(".."),
              try canonical(package + "/" + entry).hasPrefix(package + "/"),
              FileManager.default.isExecutableFile(atPath: release + "/.mcode-launcher") else {
            throw ApplicationLifecycleError.changedInstallation
        }
    }

    static func tree(at root: String) throws -> [NativeEntryIdentity] {
        var result: [NativeEntryIdentity] = []
        func visit(_ path: String, relative: String) throws {
            var value = stat()
            guard lstat(path, &value) == 0 else { throw ApplicationLifecycleError.changedInstallation }
            let identity = try NativeEntryIdentity(relative: relative, value: value)
            result.append(identity)
            guard result.count <= 200_000 else { throw ApplicationLifecycleError.changedInstallation }
            if identity.kind == S_IFLNK {
                let resolved = try canonical(path)
                guard resolved.hasPrefix(root + "/") else { throw ApplicationLifecycleError.changedInstallation }
            } else if identity.kind == S_IFDIR {
                for name in try FileManager.default.contentsOfDirectory(atPath: path).sorted() {
                    try visit(path + "/" + name, relative: relative.isEmpty ? name : relative + "/" + name)
                }
            }
        }
        try visit(root, relative: "")
        return result
    }

    static func removeDirectory(named name: String, parent: Int32, relative: String, expected: [NativeEntryIdentity]) throws {
        let known = Dictionary(uniqueKeysWithValues: expected.map { ($0.relative, $0) })
        try removeDirectory(named: name, parent: parent, relative: relative, known: known)
    }

    private static func removeDirectory(named name: String, parent: Int32, relative: String,
                                        known: [String: NativeEntryIdentity]) throws {
        let directory = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw ApplicationLifecycleError.changedInstallation }
        defer { close(directory) }
        var value = stat()
        guard fstat(directory, &value) == 0, try NativeEntryIdentity(relative: relative, value: value) == known[relative] else {
            throw ApplicationLifecycleError.changedInstallation
        }
        let copy = dup(directory)
        guard copy >= 0 else { throw ApplicationLifecycleError.changedInstallation }
        guard let stream = fdopendir(copy) else { close(copy); throw ApplicationLifecycleError.changedInstallation }
        defer { closedir(stream) }
        var names: [String] = []
        while let item = readdir(stream) {
            let child = withUnsafePointer(to: &item.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if child != ".", child != ".." { names.append(child) }
        }
        for child in names {
            let childRelative = relative.isEmpty ? child : relative + "/" + child
            var info = stat()
            guard fstatat(directory, child, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  try NativeEntryIdentity(relative: childRelative, value: info) == known[childRelative] else {
                throw ApplicationLifecycleError.changedInstallation
            }
            if info.st_mode & S_IFMT == S_IFDIR {
                try removeDirectory(named: child, parent: directory, relative: childRelative, known: known)
            } else {
                guard unlinkat(directory, child, 0) == 0 else { throw ApplicationLifecycleError.changedInstallation }
            }
        }
        guard unlinkat(parent, name, AT_REMOVEDIR) == 0 else { throw ApplicationLifecycleError.changedInstallation }
    }
}
