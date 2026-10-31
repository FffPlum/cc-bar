import Foundation
import Darwin

nonisolated struct PrivateCredentialFileStore: Sendable {
    private let directory: URL
    init(directory: URL) { self.directory = directory }

    func load(accountID: String, legacy: () -> Data?, validate: (Data) -> Bool) -> Data? {
        do {
            try prepareDirectory()
            let credential = url(accountID, suffix: "json")
            let marker = url(accountID, suffix: "migrated")
            if exists(credential) {
                guard let data = try? readSecure(credential), validate(data) else { return nil }
                if !exists(marker) { try writeSecure(Data(), to: marker) }
                return data
            }
            // A missing or damaged file after migration must never revive an old token.
            guard !exists(marker), let lease = try tryLease(accountID: accountID) else { return nil }
            defer { withExtendedLifetime(lease) {} }
            if exists(credential) { return loadExisting(credential, marker: marker, validate: validate) }
            guard !exists(marker), let data = legacy(), validate(data) else { return nil }
            try save(data, accountID: accountID)
            return data
        } catch { return nil }
    }

    private func loadExisting(_ credential: URL, marker: URL, validate: (Data) -> Bool) -> Data? {
        guard let data = try? readSecure(credential), validate(data) else { return nil }
        if !exists(marker), (try? writeSecure(Data(), to: marker)) == nil { return nil }
        return data
    }

    func save(_ data: Data, accountID: String) throws {
        try prepareDirectory()
        try writeSecure(data, to: url(accountID, suffix: "json"))
        try writeSecure(Data(), to: url(accountID, suffix: "migrated"))
    }

    @discardableResult
    func delete(accountID: String) -> Bool {
        do {
            try prepareDirectory()
            try writeSecure(Data(), to: url(accountID, suffix: "migrated"))
            let result = unlink(url(accountID, suffix: "json").path)
            if result != 0 && errno != ENOENT { throw posixError() }
            return true
        } catch {
            AppLog.error(.credentials, "Credential removal failed: \(Redact.error(error))")
            return false
        }
    }

    func hasLocalState(accountID: String) -> Bool {
        exists(url(accountID, suffix: "json")) || exists(url(accountID, suffix: "migrated"))
    }

    func acquireRefreshLease(accountID: String) async throws -> KimiRefreshLease? {
        try prepareDirectory()
        for _ in 0..<300 {
            try Task.checkCancellation()
            if let lease = try tryLease(accountID: accountID) { return lease }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw POSIXError(.ETIMEDOUT)
    }

    private func tryLease(accountID: String) throws -> KimiRefreshLease? {
        let fd = open(url(accountID, suffix: "lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw posixError() }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            if code == EWOULDBLOCK || code == EAGAIN { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return KimiRefreshLease(descriptor: fd)
    }

    private func url(_ accountID: String, suffix: String) -> URL {
        directory.appendingPathComponent(KimiManagedAccount.digest(accountID) + "." + suffix)
    }
    private func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }
    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid() else { throw POSIXError(.EACCES) }
        guard chmod(directory.path, 0o700) == 0 else { throw posixError() }
    }
    private func readSecure(_ url: URL) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw posixError() }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(), (info.st_mode & 0o077) == 0 else { throw POSIXError(.EACCES) }
        return try handle.readToEnd() ?? Data()
    }
    private func writeSecure(_ data: Data, to destination: URL) throws {
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw posixError() }
        defer { close(fd); unlink(temporary.path) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw posixError() }
                offset += written
            }
        }
        guard fsync(fd) == 0 else { throw posixError() }
        guard rename(temporary.path, destination.path) == 0 else { throw posixError() }
    }
    private func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
