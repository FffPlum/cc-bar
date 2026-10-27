import XCTest
@testable import CCBar

final class KimiTimingAuditTests: XCTestCase {
    private struct UsageVector: Equatable {
        var requestCount = 0
        var inputTokens = 0
        var outputTokens = 0
        var cacheReadTokens = 0
        var cacheCreationTokens = 0

        var totalTokens: Int {
            inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens
        }
    }

    func testRealLogTimingUpgradeIsLosslessAndIncrementalScanIsIdempotent() throws {
        guard let outputPath = ProcessInfo.processInfo.environment["CCBar_KIMI_TIMING_AUDIT"],
              !outputPath.isEmpty else {
            throw XCTSkip("Set CCBar_KIMI_TIMING_AUDIT to an output directory to enable the real-log audit.")
        }

        let roots = KimiSessionScanner.defaultRoots()
        let initial = KimiSessionScanner.scan(previous: nil, roots: roots)
        XCTAssertTrue(initial.isComplete)
        let current = try XCTUnwrap(initial.newState)
        let expected = usageVector(KimiSessionScanner.committedEntries(from: current))

        var v1 = current
        v1.version = 1
        for conversation in Array(v1.fileEvents.keys) {
            for path in Array(v1.fileEvents[conversation]?.keys ?? [:].keys) {
                for index in (v1.fileEvents[conversation]?[path] ?? []).indices {
                    v1.fileEvents[conversation]?[path]?[index].timing = nil
                }
            }
        }

        let upgraded = KimiSessionScanner.scan(previous: v1, roots: roots)
        XCTAssertTrue(upgraded.isComplete)
        XCTAssertEqual(upgraded.newState?.version, 2)
        let upgradedState = try XCTUnwrap(upgraded.newState)
        let entries = KimiSessionScanner.committedEntries(from: upgradedState)
        XCTAssertEqual(usageVector(entries), expected)

        let incremental = KimiSessionScanner.scan(previous: upgradedState, roots: roots)
        XCTAssertTrue(incremental.entries.isEmpty)
        XCTAssertEqual(incremental.newState, upgradedState)

        var timing = GenerationTiming.zero
        for entry in entries {
            timing.add(entry.timing, outputTokens: entry.outputTokens)
        }
        let totals = usageVector(entries)
        var summary: [String: Any] = [
            "schemaVersion": 1,
            "validTimingCount": entries.filter { $0.timing != nil }.count,
            "requestCount": totals.requestCount,
            "inputTokens": totals.inputTokens,
            "outputTokens": totals.outputTokens,
            "cacheReadTokens": totals.cacheReadTokens,
            "cacheCreationTokens": totals.cacheCreationTokens,
            "totalTokens": totals.totalTokens,
        ]
        if let mean = timing.averageFirstTokenSeconds {
            summary["ttftMeanSeconds"] = mean
        } else {
            summary["ttftMeanSeconds"] = NSNull()
        }
        if let speed = timing.outputTokensPerSecond {
            summary["exactWeightedOutputTokensPerSecond"] = speed
        } else {
            summary["exactWeightedOutputTokensPerSecond"] = NSNull()
        }

        let outputDirectory = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
        try data.write(
            to: outputDirectory.appendingPathComponent("kimi-timing-audit.json"),
            options: .atomic
        )
    }

    private func usageVector(_ entries: [UsageEntry]) -> UsageVector {
        entries.reduce(into: UsageVector()) { result, entry in
            result.requestCount += entry.requestCount
            result.inputTokens += entry.inputTokens
            result.outputTokens += entry.outputTokens
            result.cacheReadTokens += entry.cacheReadTokens
            result.cacheCreationTokens += entry.cacheCreationTokens
        }
    }
}
