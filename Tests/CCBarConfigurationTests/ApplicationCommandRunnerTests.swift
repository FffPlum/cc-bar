import Darwin
import Foundation
import Testing
@testable import CCBarConfiguration

struct ApplicationCommandRunnerTests {
    @Test func mergesEnvironmentClosesInputAndUsesWorkingDirectory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ccbar-runner-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try await ApplicationCommandRunner.run(ApplicationCommand("/bin/sh", ["-c", "if read value; then exit 2; fi; printf '%s\\n' \"$CCBAR_FIXTURE\"; pwd"],
            environment: ["CCBAR_FIXTURE": "literal $() ' value"], workingDirectory: directory.path), 3)
        #expect(result.exitCode == 0)
        #expect(result.output.contains("literal $() ' value"))
        #expect(result.output.contains(directory.resolvingSymlinksInPath().path))
        #expect(!result.timedOut)
    }

    @Test func drainsBothStreamsBeyondCaptureLimit() async throws {
        let result = try await ApplicationCommandRunner.run(ApplicationCommand("/bin/sh", ["-c", "i=0; while [ $i -lt 10000 ]; do printf 'stdout0123456789\\n'; printf 'stderr0123456789\\n' >&2; i=$((i+1)); done"]), 5)
        #expect(result.exitCode == 0)
        #expect(!result.timedOut)
        #expect(result.output.contains("stdout"))
        #expect(result.output.contains("stderr"))
        #expect(result.output.utf8.count <= 65_536)
        #expect(result.output.contains("Output truncated"))
    }

    @Test func timeoutKillsAnUnresponsiveCommand() async throws {
        let start = Date()
        let result = try await ApplicationCommandRunner.run(ApplicationCommand("/bin/sh", ["-c", "trap '' TERM; exec /bin/sleep 10"]), 0.1)
        #expect(result.timedOut)
        #expect(Date().timeIntervalSince(start) < 3)
        #expect(result.exitCode != 0)
    }

    @Test func cancellingReapsTheStartedProcess() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ccbar-runner-cancel-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("pid")
        let task = Task {
            try await ApplicationCommandRunner.run(ApplicationCommand("/bin/sh", ["-c", "printf '%s' \"$$\" > \"$1\"; exec /bin/sleep 10", "fixture", pidFile.path]), 20)
        }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: pidFile.path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        do { _ = try await task.value; Issue.record("Expected cancellation") }
        catch is CancellationError {}
        let pid = try #require(Int32(try String(contentsOf: pidFile, encoding: .utf8)))
        #expect(Darwin.kill(pid, 0) == -1)
        #expect(errno == ESRCH)
    }

    @Test func launchFailureThrowsWithoutWaitingForTimeout() async {
        await #expect(throws: (any Error).self) {
            try await ApplicationCommandRunner.run(ApplicationCommand("/ccbar-fixture/no-such-executable"), 3)
        }
    }
}
