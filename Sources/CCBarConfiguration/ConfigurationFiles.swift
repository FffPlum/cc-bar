import Foundation
import Darwin

/// Own files and backups are private. A symbolic link is never followed on a write.
enum ConfigurationFiles {
    static func read(_ url: URL) throws -> Data? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw ConfigurationError.unsafePath
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_size <= 5_000_000 else {
            throw ConfigurationError.unsafePath
        }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw ConfigurationError.unsafePath }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, opened.st_dev == info.st_dev, opened.st_ino == info.st_ino,
              opened.st_uid == geteuid(), opened.st_mode & S_IFMT == S_IFREG,
              opened.st_size <= 5_000_000 else { throw ConfigurationError.unsafePath }
        return try handle.readToEnd() ?? Data()
    }

    static func apply(_ plan: ConfigurationPlan, backupRoot: URL) throws -> URL? {
        guard !plan.changes.isEmpty else { return nil }
        let locks = try plan.changes.map { change -> FileLock in
            try prepareDirectory(change.url.deletingLastPathComponent())
            return try FileLock(url: change.url.appendingPathExtension("ccbar-lock"))
        }
        defer { withExtendedLifetime(locks) {} }
        for change in plan.changes {
            guard try read(change.url) == change.before else { throw ConfigurationError.changedOnDisk }
        }
        let backup = backupRoot.appendingPathComponent(UUID().uuidString)
        try prepareDirectory(backup)
        for (index, change) in plan.changes.enumerated() {
            if let before = change.before { try write(before, to: backup.appendingPathComponent("\(index).original")) }
        }
        let paths = plan.changes.map { ["path": $0.url.path, "existed": $0.before != nil] as [String: Any] }
        try write(JSONSerialization.data(withJSONObject: paths, options: [.prettyPrinted]), to: backup.appendingPathComponent("files.json"))
        var applied: [ConfigurationPlan.FileChange] = []
        do {
            for change in plan.changes {
                guard try read(change.url) == change.before else { throw ConfigurationError.changedOnDisk }
                try write(change.after, to: change.url)
                applied.append(change)
            }
        } catch {
            // Do not roll over an external edit made after our write.
            for change in applied.reversed() where (try? read(change.url)) == change.after {
                if let before = change.before { try? write(before, to: change.url) }
                else { try? FileManager.default.removeItem(at: change.url) }
            }
            throw error
        }
        return backup
    }

    private static func prepareDirectory(_ directory: URL) throws {
        var cursor = directory.standardizedFileURL
        while cursor.path != "/" {
            var info = stat()
            if lstat(cursor.path, &info) == 0, info.st_mode & S_IFMT != S_IFDIR {
                // Foundation canonicalizes /private/var back to /var on macOS.
                // Permit only the OS-owned aliases, never a user-controlled directory link.
                let systemAliases = ["/var": "private/var", "/tmp": "private/tmp"]
                guard info.st_uid == 0, info.st_mode & S_IFMT == S_IFLNK,
                      let destination = systemAliases[cursor.path],
                      (try? FileManager.default.destinationOfSymbolicLink(atPath: cursor.path)) == destination else {
                    throw ConfigurationError.unsafePath
                }
            }
            cursor.deleteLastPathComponent()
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    private static func write(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".ccbar-\(UUID().uuidString)")
        let descriptor = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw ConfigurationError.writeFailed }
        defer { close(descriptor); unlink(temporary.path) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw ConfigurationError.writeFailed }
                offset += count
            }
        }
        guard fsync(descriptor) == 0, rename(temporary.path, url.path) == 0 else { throw ConfigurationError.writeFailed }
    }
}

private final class FileLock {
    let descriptor: Int32
    init(url: URL) throws {
        descriptor = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw ConfigurationError.unsafePath }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw ConfigurationError.changedOnDisk
        }
    }
    deinit { close(descriptor) }
}
