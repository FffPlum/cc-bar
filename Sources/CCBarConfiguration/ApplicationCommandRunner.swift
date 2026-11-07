import Foundation
import Darwin

/// Executes an already resolved command. Output is drained even after the capture limit.
public enum ApplicationCommandRunner {
    public static func run(_ command: ApplicationCommand, _ timeout: TimeInterval) async throws -> ApplicationCommandResult {
        let cancellation = CommandCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                // Process launch, descriptor reads and reaping must never occupy MainActor.
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(with: Result { try execute(command, timeout: timeout, cancellation: cancellation) })
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func execute(_ command: ApplicationCommand, timeout: TimeInterval,
                                cancellation: CommandCancellation) throws -> ApplicationCommandResult {
        guard command.executable.hasPrefix("/"), timeout.isFinite, timeout >= 0 else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        if cancellation.isCancelled { throw CancellationError() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.environment = ProcessInfo.processInfo.environment.merging(command.environment) { _, explicit in explicit }
        if let directory = command.workingDirectory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
        let stdout = Pipe(), stderr = Pipe()
        var ownedProcessGroup: Int32?
        var stopped = false
        let input = try FileHandle(forReadingFrom: URL(fileURLWithPath: "/dev/null"))
        process.standardInput = input
        process.standardOutput = stdout
        process.standardError = stderr
        defer {
            if stopped, let group = ownedProcessGroup { _ = Darwin.kill(-group, SIGKILL) }
            if process.isRunning { signal(process, SIGKILL) }
            try? input.close()
            try? stdout.fileHandleForReading.close()
            try? stdout.fileHandleForWriting.close()
            try? stderr.fileHandleForReading.close()
            try? stderr.fileHandleForWriting.close()
        }
        let descriptors = [stdout.fileHandleForReading.fileDescriptor, stderr.fileHandleForReading.fileDescriptor]
        for descriptor in descriptors {
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
                throw POSIXError(.EIO)
            }
        }
        try process.run()
        if getpgid(process.processIdentifier) == process.processIdentifier { ownedProcessGroup = process.processIdentifier }
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
        try? input.close()
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var terminationStarted: TimeInterval?
        var exitedAt: TimeInterval?
        var timedOut = false
        var captured = [Data(), Data()]
        var truncated = false
        let limit = 64 * 1024
        while true {
            let now = ProcessInfo.processInfo.systemUptime
            if terminationStarted == nil, cancellation.isCancelled || now >= deadline, process.isRunning {
                timedOut = !cancellation.isCancelled
                stopped = true
                terminationStarted = now
                signal(process, SIGTERM)
            }
            if let started = terminationStarted, now - started >= 0.25, process.isRunning {
                signal(process, SIGKILL)
            }
            var drained = false
            for (index, descriptor) in descriptors.enumerated() {
                // Bound each drain pass so a noisy child cannot starve cancellation / timeout.
                var buffer = [UInt8](repeating: 0, count: 4096)
                for _ in 0..<16 {
                    let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
                    if count <= 0 { break }
                    drained = true
                    let available = max(0, limit - captured[index].count)
                    captured[index].append(contentsOf: buffer.prefix(min(count, available)))
                    if count > available { truncated = true }
                }
            }
            if !process.isRunning {
                if exitedAt == nil { exitedAt = now }
                // A background descendant may retain the pipe: never wait for its EOF.
                if !drained || now - (exitedAt ?? now) >= 0.05 { break }
                continue
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        if cancellation.isCancelled { stopped = true; throw CancellationError() }
        // Retain diagnostics from both streams even when stdout fills its allowance first.
        if captured.reduce(0, { $0 + $1.count }) > limit { truncated = true }
        let stderrBudget = min(captured[1].count, max(limit / 2, limit - captured[0].count))
        var output = Data(captured[0].prefix(limit - stderrBudget))
        output.append(captured[1].prefix(stderrBudget))
        if truncated {
            let marker = Data("\n[Output truncated]\n".utf8)
            output = Data(output.prefix(limit - marker.count))
            output.append(marker)
        }
        let decoded = String(decoding: output, as: UTF8.self)
        let utf8 = Data(decoded.utf8.prefix(limit))
        // Lossy decoding can expand invalid bytes; keep the returned UTF-8 bounded too.
        let text = (0...3).compactMap { String(data: utf8.dropLast(min($0, utf8.count)), encoding: .utf8) }.first ?? ""
        return ApplicationCommandResult(exitCode: process.terminationStatus, output: text, timedOut: timedOut)
    }

    private static func signal(_ process: Process, _ signal: Int32) {
        let pid = process.processIdentifier
        guard pid > 0, process.isRunning else { return }
        // Foundation normally creates a process group. Never signal our own group.
        if getpgid(pid) == pid { _ = Darwin.kill(-pid, signal) }
        else { _ = Darwin.kill(pid, signal) }
    }
}

/// Cancellation is set by the task handler and read by the process worker.
private final class CommandCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}
