import XCTest
@testable import CCBar

@MainActor
final class HostWindowUsageTests: XCTestCase {
    func testVisibleServicesFilterConversationsBeforePagingAndInvalidateCachedQueries() async throws {
        let fixture = try UsageWindowFixture()
        defer { fixture.cleanup() }
        fixture.show([.codex])
        let codex = fixture.info("codex-conversation", app: .codex, project: "visible-project")
        let claude = fixture.info("claude-conversation", app: .claude, project: "hidden-project")
        fixture.load(infos: [codex, claude], buckets: [fixture.bucket(codex, tokens: 10), fixture.bucket(claude, tokens: 90)])
        let service = fixture.service()
        var query = fixture.query()
        query["limit"] = .number(1)
        let first = try object(await service.handle("conversations.list", params: query))
        XCTAssertEqual(first["total"], .number(1))
        let firstRows = try array(first["rows"])
        let row = try object(XCTUnwrap(firstRows.first))
        XCTAssertEqual(row["service"], .string("codex"))
        XCTAssertEqual(try array(first["projects"]).count, 1)
        let conversationID = try XCTUnwrap(row["id"])

        fixture.show([.claude])
        let changed = try object(await service.handle("conversations.list", params: query))
        XCTAssertEqual(changed["total"], .number(1))
        XCTAssertEqual(try object(XCTUnwrap(array(changed["rows"]).first))["service"], .string("claude"))
        await assertError("not_found") { try await service.handle("conversations.detail", params: ["id": conversationID]) }
        await assertError("not_found") { try await service.handle("conversations.copyID", params: ["id": conversationID]) }
        query["service"] = .string("codex")
        let hidden = try object(await service.handle("conversations.list", params: query))
        XCTAssertEqual(hidden["total"], .number(0))
        XCTAssertEqual(try array(hidden["projects"]).count, 0)
    }

    func testOverviewUsesNativeCalendarAndKeepsTotalsAcrossGranularities() async throws {
        let fixture = try UsageWindowFixture()
        defer { fixture.cleanup() }
        fixture.show([.codex])
        let info = fixture.info("calendar", app: .codex, project: "calendar-project")
        fixture.load(infos: [info], buckets: [
            fixture.bucket(info, day: fixture.day(2), tokens: 2),
            fixture.bucket(info, day: fixture.day(8), tokens: 8),
            fixture.bucket(info, day: fixture.day(9), tokens: 9),
            fixture.bucket(info, day: fixture.day(10), tokens: 100),
        ])
        let service = fixture.service()
        for granularity in ["day", "week", "month"] {
            let response = try object(await service.handle("window.usage.overview", params: fixture.query(granularity: granularity)))
            XCTAssertEqual(try object(response["totals"])["totalTokens"], .number(19))
            XCTAssertEqual(try object(response["totals"])["costDisplay"], .string("USD 19"))
            XCTAssertEqual(response["previousTotals"], .null)
            let range = try object(response["range"])
            XCTAssertEqual(range["from"], service.dateJSON(fixture.day(2)))
            XCTAssertEqual(range["to"], service.dateJSON(fixture.day(10)))
            let samples = try array(response["samples"]).map { try object($0) }
            XCTAssertEqual(try samples.reduce(Decimal.zero) { total, sample in
                try total + number(object(sample["totals"])["totalTokens"])
            }, 19)
            if granularity == "week" {
                XCTAssertEqual(samples.map { $0["start"] }, [service.dateJSON(fixture.day(2)), service.dateJSON(fixture.day(9))])
                XCTAssertEqual(try object(samples[0]["totals"])["totalTokens"], .number(10))
            }
        }
        let projects = try object(await service.handle("projects.list", params: fixture.query()))
        let project = try object(XCTUnwrap(array(projects["rows"]).first))
        let identity = try object(project["identity"])
        var detailQuery = fixture.query(granularity: "week")
        detailQuery["projectKey"] = identity["key"]
        let detail = try object(await service.handle("projects.detail", params: detailQuery))
        XCTAssertEqual(detail["activeDays"], .number(3))
        XCTAssertEqual(detail["rangeDayCount"], .number(8))
        XCTAssertEqual(try array(detail["daily"]).count, 2)
        XCTAssertEqual(try object(detail["allTimeTotals"])["totalTokens"], .number(119))
    }

    func testMalformedDatesAndLargeIntegersAreRejectedWithoutMutations() async throws {
        let fixture = try UsageWindowFixture()
        defer { fixture.cleanup() }
        let service = fixture.service()
        var badDate = fixture.query()
        badDate["customFrom"] = .string("2026-02-30")
        await assertError("invalid_params") { try await service.handle("window.usage.overview", params: badDate) }
        await assertError("invalid_params") { try await service.handle("window.usage.overview", params: ["range": .string("today"), "granularity": .string("month")]) }
        for raw in ["9223372036854775808", "-9223372036854775809", "1.5", "10000001"] {
            var query = fixture.query()
            query["offset"] = .number(try XCTUnwrap(Decimal(string: raw)))
            await assertError("invalid_params") { try await service.handle("conversations.list", params: query) }
        }
        await assertError("invalid_params") { try await service.handle("usage.refresh", params: ["unexpected": .bool(true)]) }
        XCTAssertTrue(fixture.copied.isEmpty)
        XCTAssertTrue(fixture.revealed.isEmpty)
    }

    func testPrivacyRedactsEveryStatisticSurfaceAndRevalidatesNativeActions() async throws {
        let fixture = try UsageWindowFixture()
        defer { fixture.cleanup() }
        fixture.show([.codex])
        let info = fixture.info("private-conversation-id", app: .codex, project: "private-project")
        fixture.load(infos: [info], buckets: [fixture.bucket(info, tokens: 10), fixture.bucket(info, day: fixture.day(10), tokens: 20)])
        let service = fixture.service()
        let list = try object(await service.handle("conversations.list", params: fixture.query()))
        let row = try object(XCTUnwrap(array(list["rows"]).first))
        let id = try XCTUnwrap(row["id"])
        let projectKey = try XCTUnwrap(object(row["project"])["key"])
        let detail = try object(await service.handle("conversations.detail", params: ["id": id]))
        XCTAssertEqual(try object(object(detail["summary"])["totals"])["totalTokens"], .number(30))
        _ = try await service.handle("conversations.copyID", params: ["id": id])
        _ = try await service.handle("projects.reveal", params: ["projectKey": projectKey])
        XCTAssertEqual(fixture.copied, [info.conversationID])
        XCTAssertEqual(fixture.revealed, [info.projectPath])

        fixture.settings.privacyMode = true
        var projectQuery = fixture.query()
        projectQuery["projectKey"] = projectKey
        let responses = try await [
            service.handle("window.usage.overview", params: fixture.query()),
            service.handle("conversations.list", params: fixture.query()),
            service.handle("conversations.detail", params: ["id": id]),
            service.handle("projects.list", params: fixture.query()),
            service.handle("projects.detail", params: projectQuery),
        ]
        for response in responses {
            let wire = String(decoding: try JSONEncoder().encode(response), as: UTF8.self)
            for secret in [info.conversationID, info.title!, info.projectPath, info.projectName, info.gitBranch!, info.sourcePaths[0]] {
                XCTAssertFalse(wire.contains(secret), "Private identity escaped in response")
            }
            XCTAssertFalse(wire.contains("sourcePaths"))
        }
        let privateRows = try array(object(responses[1])["rows"])
        XCTAssertEqual(try object(XCTUnwrap(privateRows.first))["id"], id)
        await assertError("permission_denied") { try await service.handle("conversations.copyID", params: ["id": id]) }
        await assertError("permission_denied") { try await service.handle("projects.reveal", params: ["projectKey": projectKey]) }
        fixture.settings.privacyMode = false
        await assertError("not_found") { try await service.handle("conversations.detail", params: ["id": projectKey]) }
        await assertError("not_found") { try await service.handle("projects.reveal", params: ["projectKey": .string(info.projectPath)]) }
        XCTAssertEqual(fixture.copied.count, 1)
        XCTAssertEqual(fixture.revealed.count, 1)
    }

    func testCursorHistoryIsBackgroundDeduplicatedAndIncludesComparisonContext() async throws {
        let fixture = try UsageWindowFixture()
        defer { fixture.cleanup() }
        fixture.show([.cursor])
        let oldDetected = SettingsStore.shared.cursorAccountDetected
        defer { SettingsStore.shared.cursorAccountDetected = oldDetected }
        fixture.state.cursorAccount = CursorAuthSession(accessToken: "fixture-token", subject: "fixture", userID: "fixture-user", email: nil, expiresAt: .distantFuture)
        let gate = UsageWindowGate()
        var requests: [Range<Date>] = []
        var actions = fixture.actions()
        actions.loadCursorHistory = { range in requests.append(range); await gate.wait() }
        let service = fixture.service(actions: actions)
        defer { service.invalidate(); gate.release() }
        let query: [String: HostJSON] = ["range": .string("today"), "granularity": .string("day")]
        let response = try object(await service.handle("window.usage.overview", params: query))
        XCTAssertNotNil(response["totals"])
        await fulfillment(of: [gate.started], timeout: 2)
        _ = try await service.handle("window.usage.overview", params: query)
        _ = try await service.handle("projects.list", params: query)
        XCTAssertEqual(requests.count, 1)
        let calendar = StatsRange.weekStartMondayCalendar
        let today = calendar.startOfDay(for: fixture.now)
        // Native day charts retain 30 periods; week/month charts retain 14.
        XCTAssertEqual(requests.first?.lowerBound, calendar.date(byAdding: .day, value: -29, to: today))
        XCTAssertEqual(requests.first?.upperBound, calendar.date(byAdding: .day, value: 1, to: today))
        let finished = expectation(description: "background history invalidation")
        service.didChange = { finished.fulfill() }
        gate.release()
        await fulfillment(of: [finished], timeout: 2)
        _ = try await service.handle("window.usage.overview", params: query)
        _ = try await service.handle("window.usage.overview", params: ["range": .string("all"), "granularity": .string("day")])
        XCTAssertEqual(requests.count, 1, "Uncovered failed ranges must not be immediately requested again")
    }

    func testDashboardDisplaysDailyCacheWhileIndexRefreshes() async throws {
        let fixture = try UsageWindowFixture()
        defer { fixture.cleanup() }
        fixture.show([.codex])
        let day = Calendar.current.startOfDay(for: fixture.now)
        let entry = UsageEntry(app: .codex, conversationKey: "", model: "cached", speed: .standard,
            day: day, timestamp: fixture.now.addingTimeInterval(-60), inputTokens: 7, outputTokens: 0,
            cacheReadTokens: 0, cacheCreationTokens: 0, costUSD: 0, costBreakdown: nil)
        fixture.state.usageService.aggregator.ingestLocal([entry])
        let service = fixture.service()
        let initial = try object(await service.handle("window.usage.dashboard", params: ["range": .string("today"), "metric": .string("tokens")]))
        XCTAssertEqual(try object(initial["totals"])["totalTokens"], .number(7))
        XCTAssertEqual(initial["requestLogCount"], .null)
        XCTAssertEqual(try object(initial["coverage"])["refreshing"], .bool(true))
        XCTAssertEqual(try object(initial["coverage"])["incomplete"], .bool(true))
        try fixture.index(service, records: [UsageRequestRecord(id: "cached", entry: entry)], revision: "ready")
        let ready = try object(await service.handle("window.usage.requests", params: ["range": .string("today"), "metric": .string("tokens")]))
        XCTAssertEqual(try object(ready["coverage"])["refreshing"], .bool(false))
        XCTAssertEqual(try object(XCTUnwrap(array(ready["rows"]).first))["conversationID"], .null)
    }

    func testDashboardSamplesStackVisibleServicesAndCacheContributions() async throws {
        let fixture = try UsageWindowFixture()
        defer { fixture.cleanup() }
        fixture.show([.codex, .claude])
        let day = Calendar.current.startOfDay(for: fixture.now)
        func entry(_ app: UsageApp, _ input: Int, _ read: Int, _ cost: Decimal) -> UsageEntry {
            UsageEntry(app: app, conversationKey: "test", model: "model", speed: .standard,
                day: day, timestamp: fixture.now.addingTimeInterval(-60), inputTokens: input, outputTokens: 0,
                cacheReadTokens: read, cacheCreationTokens: 0, costUSD: cost, costBreakdown: nil)
        }
        let entries = [entry(.codex, 60, 40, 2), entry(.claude, 40, 10, 3)]
        fixture.state.usageService.aggregator.ingestLocal(entries)
        let service = fixture.service()
        try fixture.index(service, records: entries.enumerated().map {
            UsageRequestRecord(id: String($0.offset), entry: $0.element)
        }, revision: "segments")
        func numeric(_ value: HostJSON?) throws -> Double {
            guard case .number(let n) = value else { throw XCTUnwrapError.unexpectedJSON }
            return NSDecimalNumber(decimal: n).doubleValue
        }
        for range in ["today", "last7"] {
            for metric in ["cost", "requests", "tokens", "cacheHitRate"] {
                let response = try object(await service.handle("window.usage.dashboard", params: ["range": .string(range), "metric": .string(metric)]))
                let samples = try array(response["samples"]).map { try object($0) }
                let sample = try XCTUnwrap(samples.first { (try? numeric($0["value"])) ?? 0 > 0 })
                let segments = try array(sample["segments"]).map { try object($0) }
                XCTAssertEqual(segments.map { $0["service"] }, [.string("codex"), .string("claude")])
                let values = try segments.map { try numeric($0["value"]) }
                let shares = try segments.map { try numeric($0["share"]) }
                XCTAssertEqual(values.reduce(0, +), try numeric(sample["value"]), accuracy: 1e-10)
                XCTAssertEqual(shares.reduce(0, +), 1, accuracy: 1e-10)
                if metric == "cacheHitRate" {
                    XCTAssertEqual(values[0], 40.0 / 150.0, accuracy: 1e-10)
                    XCTAssertEqual(shares[0], 0.8, accuracy: 1e-10)
                    XCTAssertEqual(try numeric(object(segments[0]["totals"])["cacheHitRate"]), 0.4, accuracy: 1e-10)
                }
            }
        }
        let filtered = try object(await service.handle("window.usage.dashboard", params: ["range": .string("today"), "metric": .string("tokens"), "service": .string("claude")]))
        let filteredSamples = try array(filtered["samples"]).map { try object($0) }
        let nonempty = try XCTUnwrap(filteredSamples.first { (try? array($0["segments"]).isEmpty) == false })
        XCTAssertEqual(try array(nonempty["segments"]).count, 1)
        fixture.show([.codex])
        let hidden = try object(await service.handle("window.usage.dashboard", params: ["range": .string("today"), "metric": .string("tokens")]))
        let hiddenSamples = try array(hidden["samples"]).map { try object($0) }
        let hiddenNonempty = try XCTUnwrap(hiddenSamples.first { (try? array($0["segments"]).isEmpty) == false })
        XCTAssertEqual(try object(XCTUnwrap(array(hiddenNonempty["segments"]).first))["service"], .string("codex"))
        let outputOnly = UsageEntry(app: .codex, conversationKey: "zero", model: "zero", speed: .standard,
            day: day, timestamp: fixture.now.addingTimeInterval(-60), inputTokens: 0, outputTokens: 5,
            cacheReadTokens: 0, cacheCreationTokens: 0, costUSD: 0, costBreakdown: nil)
        fixture.state.usageService.aggregator.ingestLocal([outputOnly])
        try fixture.index(service, records: [UsageRequestRecord(id: "zero", entry: outputOnly)], revision: "zero")
        let zero = try object(await service.handle("window.usage.dashboard", params: ["range": .string("today"), "metric": .string("cacheHitRate"), "modelID": .string("zero")]))
        let zeroSamples = try array(zero["samples"]).map { try object($0) }
        let zeroSample = try XCTUnwrap(zeroSamples.first { (try? array($0["segments"]).isEmpty) == false })
        let zeroSegment = try object(XCTUnwrap(array(zeroSample["segments"]).first))
        XCTAssertEqual(try numeric(zeroSample["value"]), 0)
        XCTAssertEqual(try numeric(zeroSegment["value"]), 0)
        XCTAssertEqual(try numeric(zeroSegment["share"]), 0)
    }

    func testDashboardAbsoluteRangeAndFilterIntersection() async throws {
        let fixture = try UsageWindowFixture()
        defer { fixture.cleanup() }
        fixture.show([.codex, .claude])
        let iso = ISO8601DateFormatter()
        let start = try XCTUnwrap(iso.date(from: "2026-11-01T05:00:00Z"))
        let end = try XCTUnwrap(iso.date(from: "2026-11-01T07:00:00Z"))
        func entry(_ app: UsageApp, _ model: String, _ timestamp: Date, _ tokens: Int) -> UsageEntry {
            UsageEntry(app: app, conversationKey: "test", model: model, speed: .standard,
                day: Calendar.current.startOfDay(for: timestamp), timestamp: timestamp,
                inputTokens: tokens, outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0,
                costUSD: 0, costBreakdown: nil)
        }
        let entries = [entry(.codex, "a", start, 1), entry(.codex, "a", start.addingTimeInterval(3600), 2),
            entry(.codex, "a", end, 4), entry(.codex, "b", start, 8), entry(.claude, "a", start, 16),
            entry(.claude, "c", start, 32)]
        fixture.state.usageService.aggregator.ingestLocal(entries)
        let service = fixture.service()
        try fixture.index(service, records: entries.enumerated().map {
            UsageRequestRecord(id: String($0.offset), entry: $0.element)
        }, revision: "boundaries")
        var query: [String: HostJSON] = ["range": .string("custom"), "metric": .string("tokens"),
            "customFrom": .string("2026-11-01T05:00:00Z"), "customTo": .string("2026-11-01T07:00:00Z"),
            "service": .string("codex"), "sourceID": .string("codex.localLogs"), "modelID": .string("a")]
        let result = try object(await service.handle("window.usage.dashboard", params: query))
        XCTAssertEqual(try object(result["totals"])["totalTokens"], .number(3))
        let samples = try array(result["samples"]).map { try object($0) }
        let keys = try samples.map { try XCTUnwrap($0["key"]) }
        XCTAssertEqual(keys.count, 2)
        XCTAssertNotEqual(keys[0], keys[1])
        query.removeValue(forKey: "service")
        let sourceSelected = try object(await service.handle("window.usage.dashboard", params: query))
        XCTAssertEqual(try object(sourceSelected["totals"])["totalTokens"], .number(3))
        let facets = try object(sourceSelected["facets"])
        let models = try array(facets["models"]).map { try object($0) }
        let sharedModel = try XCTUnwrap(models.first { $0["id"] == .string("a") })
        XCTAssertEqual(sharedModel["requestCount"], .number(3))
        XCTAssertTrue(models.contains { $0["id"] == .string("c") })
        query["service"] = .string("codex")
        query["sourceID"] = .string("claude.localLogs")
        let mismatch = try object(await service.handle("window.usage.dashboard", params: query))
        XCTAssertEqual(try object(mismatch["totals"])["totalTokens"], .number(0))
        query["sourceID"] = .string("codex.localLogs")
        query["modelID"] = .string("missing")
        let missing = try object(await service.handle("window.usage.dashboard", params: query))
        XCTAssertEqual(try object(missing["totals"])["totalTokens"], .number(0))
        query["modelID"] = .string("a")
        fixture.show([.claude])
        let hidden = try object(await service.handle("window.usage.dashboard", params: query))
        XCTAssertEqual(try object(hidden["totals"])["totalTokens"], .number(0))
        let recent = try object(await service.handle("window.usage.dashboard", params: ["range": .string("last24h"), "metric": .string("tokens")]))
        let range = try object(recent["resolvedRange"])
        XCTAssertEqual(range["from"], service.dateJSON(fixture.now.addingTimeInterval(-86400)))
        XCTAssertEqual(range["to"], service.dateJSON(fixture.now))
    }

    func testAllTimeHeatmapRequestsCursorPagesBeyondCachedHistory() async throws {
        let fixture = try UsageWindowFixture()
        defer { fixture.cleanup() }
        fixture.show([.cursor])
        let oldDetected = SettingsStore.shared.cursorAccountDetected
        defer { SettingsStore.shared.cursorAccountDetected = oldDetected }
        fixture.state.cursorAccount = CursorAuthSession(accessToken: "fixture-token", subject: "fixture", userID: "fixture-user", email: nil, expiresAt: .distantFuture)
        let calendar = Calendar.current
        let cachedDay = calendar.date(byAdding: .day, value: -30, to: calendar.startOfDay(for: fixture.now))!
        let entry = UsageEntry(app: .cursor, conversationKey: "cached", model: "test", speed: .standard,
            day: cachedDay, timestamp: cachedDay, inputTokens: 1, outputTokens: 0,
            cacheReadTokens: 0, cacheCreationTokens: 0, costUSD: 0, costBreakdown: nil)
        fixture.state.usageService.aggregator.ingestLocal([entry])
        let gate = UsageWindowGate()
        var requests: [Range<Date>] = []
        var actions = fixture.actions()
        actions.loadCursorHistory = { range in requests.append(range); await gate.wait() }
        let service = fixture.service(actions: actions)
        defer { service.invalidate(); gate.release() }
        let query: [String: HostJSON] = ["range": .string("all"), "metric": .string("tokens")]
        let first = try object(await service.handle("window.usage.heatmap", params: query))
        await fulfillment(of: [gate.started], timeout: 2)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        guard case .string(let firstDay) = first["fromDay"],
              case .string(let next) = first["nextBeforeDay"],
              let firstStart = formatter.date(from: firstDay) else { return XCTFail("Missing page boundary") }
        XCTAssertEqual(next, firstDay)
        XCTAssertEqual(requests.first?.lowerBound, firstStart)
        XCTAssertEqual(requests.first?.upperBound, fixture.now)
        var olderQuery = query
        olderQuery["beforeDay"] = .string(next)
        let older = try object(await service.handle("window.usage.heatmap", params: olderQuery))
        let finished = expectation(description: "first page finished")
        service.didChange = { finished.fulfill() }
        gate.release()
        await fulfillment(of: [finished], timeout: 2)
        for _ in 0..<20 where requests.count < 2 { await Task.yield() }
        guard case .string(let olderDay) = older["fromDay"], let olderStart = formatter.date(from: olderDay) else { return XCTFail("Missing older boundary") }
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.last?.lowerBound, olderStart)
        XCTAssertEqual(requests.last?.upperBound, firstStart)
    }

    func testRefreshReturnsStatusAndCoalescesUntilCompletion() async throws {
        let fixture = try UsageWindowFixture()
        defer { fixture.cleanup() }
        let gate = UsageWindowGate()
        var calls = 0
        var actions = fixture.actions()
        actions.refreshUsage = { calls += 1; await gate.wait() }
        let service = fixture.service(actions: actions)
        defer { service.invalidate(); gate.release() }
        let first = try object(await service.handle("usage.refresh", params: [:]))
        XCTAssertEqual(first["scanning"], .bool(true))
        await fulfillment(of: [gate.started], timeout: 2)
        let second = try object(await service.handle("usage.refresh", params: [:]))
        XCTAssertEqual(second["scanning"], .bool(true))
        XCTAssertEqual(calls, 1)
        let finished = expectation(description: "refresh completed")
        service.didChange = { finished.fulfill() }
        gate.release()
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(try object(service.statusJSON())["scanning"], .bool(false))
    }

    func testQuotaAnalyticsUsesAccountIdentityAndNativeSubscriptionFilter() async throws {
        let fixture = try UsageWindowFixture()
        defer { fixture.cleanup() }
        fixture.show([.codex])
        fixture.state.codexAccount = CodexAccount(email: "private@example.invalid", planType: "plus", accountId: "primary-private", chatgptUserId: "primary-user", lastRefresh: nil, expiredGuess: false, rawClaimKeys: [], accessToken: nil, refreshToken: nil, idToken: nil)
        let imported = ImportedCodexAccount(id: "import-private:user", alias: "Imported", email: nil, planType: "pro", visibleInPopover: true, addedAt: fixture.now)
        fixture.state.importedCodexAccounts = [imported]
        let primaryKey = QuotaHistoryAccountKey.codexPrimary(accountId: "primary-private")
        let importedKey = QuotaHistoryAccountKey.codexImported(id: imported.id)
        let primary = fixture.cycle("primary-cycle", accountKey: primaryKey)
        let other = fixture.cycle("imported-cycle", accountKey: importedKey)
        fixture.state.quotaCycles.records = [other, primary]
        fixture.state.usageService.cycleAggregator.load(from: [
            fixture.cycleBucket(primary, app: .codex, model: "gpt-5", tokens: 10),
            fixture.cycleBucket(primary, app: .pi, model: "gpt-5", tokens: 20),
            fixture.cycleBucket(primary, app: .codex, model: "claude-sonnet-4", tokens: 900),
            fixture.cycleBucket(other, app: .codex, model: "gpt-5", tokens: 70),
        ])
        let service = fixture.service()
        let primaryID = HostWindowUsageService.quotaAccountID(service: "codex", kind: "primary")
        let query: [String: HostJSON] = ["accountID": .string(primaryID), "kind": .string("fiveHour")]
        let response = try object(await service.handle("quota.analytics", params: query))
        let cycles = try array(response["cycles"])
        XCTAssertEqual(cycles.count, 1)
        XCTAssertEqual(try object(object(cycles[0])["totals"])["totalTokens"], .number(10))
        XCTAssertEqual(try object(object(cycles[0])["cycle"])["current"], .bool(true))
        fixture.settings.cycleIncludesOtherAgents = true
        let includingOthers = try object(await service.handle("quota.analytics", params: query))
        XCTAssertEqual(try object(object(XCTUnwrap(array(includingOthers["cycles"]).first))["totals"])["totalTokens"], .number(30))

        let importedID = HostWindowUsageService.quotaAccountID(service: "codex", kind: "importedCodex", rawID: imported.id)
        XCTAssertFalse(importedID.contains(imported.id))
        let importedResponse = try object(await service.handle("quota.analytics", params: ["accountID": .string(importedID), "kind": .string("fiveHour")]))
        XCTAssertEqual(try object(importedResponse["account"])["id"], .string(importedID))
        XCTAssertEqual(try object(object(XCTUnwrap(array(importedResponse["cycles"]).first))["totals"])["totalTokens"], .number(70))
        fixture.settings.privacyMode = true
        let privateResponse = try await service.handle("quota.analytics", params: query)
        let wire = String(decoding: try JSONEncoder().encode(privateResponse), as: UTF8.self)
        for identity in ["private@example.invalid", primaryKey, primary.id, "primary-private", "primary-user"] {
            XCTAssertFalse(wire.contains(identity))
        }
        fixture.show([])
        await assertError("invalid_params") { try await service.handle("quota.analytics", params: query) }
    }

    func testRankingSharesAndOptionalSyntheticWireExport() async throws {
        let fixture = try UsageWindowFixture()
        defer { fixture.cleanup() }
        fixture.show([.codex, .claude])
        fixture.settings.statsRankMetric = .cost
        let codex = fixture.info("synthetic-codex", app: .codex, project: "shared-project")
        let claude = fixture.info("synthetic-claude", app: .claude, project: "shared-project")
        var expensive = fixture.bucket(codex, tokens: 10)
        expensive.costUSD = 90
        expensive.inputCostUSD = 90
        fixture.load(infos: [codex, claude], buckets: [expensive, fixture.bucket(claude, tokens: 10)])
        let service = fixture.service()
        let overview = try await service.handle("window.usage.overview", params: fixture.query())
        let top = try array(object(overview)["topConversations"])
        XCTAssertEqual(try object(XCTUnwrap(top.first))["share"], .number(Decimal(0.9)))
        let conversations = try await service.handle("conversations.list", params: fixture.query())
        let conversation = try object(XCTUnwrap(array(object(conversations)["rows"]).first))
        let projects = try await service.handle("projects.list", params: fixture.query())
        let project = try object(XCTUnwrap(array(object(projects)["rows"]).first))
        XCTAssertEqual(try object(project["sharesByService"])["codex"], .number(Decimal(0.9)))
        var projectQuery = fixture.query()
        projectQuery["projectKey"] = try object(project["identity"])["key"]
        let detail = try await service.handle("projects.detail", params: projectQuery)
        XCTAssertEqual(try object(object(detail)["sharesByService"])["codex"], .number(Decimal(0.9)))
        var tokenQuery = fixture.query()
        tokenQuery["sort"] = .string("tokens")
        let tokenProjects = try object(await service.handle("projects.list", params: tokenQuery))
        let tokenProject = try object(XCTUnwrap(array(tokenProjects["rows"]).first))
        XCTAssertEqual(try object(tokenProject["sharesByService"])["codex"], .number(Decimal(0.5)))

        fixture.state.codexAccount = CodexAccount(email: "synthetic@example.invalid", planType: "plus", accountId: "synthetic-account", chatgptUserId: nil, lastRefresh: nil, expiredGuess: false, rawClaimKeys: [], accessToken: nil, refreshToken: nil, idToken: nil)
        let accountKey = QuotaHistoryAccountKey.codexPrimary(accountId: "synthetic-account")
        let cycle = fixture.cycle("synthetic-cycle", accountKey: accountKey)
        fixture.state.quotaCycles.records = [cycle]
        fixture.state.usageService.cycleAggregator.load(from: [fixture.cycleBucket(cycle, app: .codex, model: "gpt-5", tokens: 10)])
        let series = QuotaHistoryStore.seriesKey(accountKey: accountKey, limitKind: .fiveHour)
        fixture.state.quotaHistory.lastSamples[series] = QuotaHistorySample(accountKey: accountKey, app: .codex, kind: .codexPrimary, sampledAt: fixture.now, limitID: "primary", limitKind: .fiveHour, remainingPercent: 75, resetsAt: cycle.endAt)
        fixture.state.quotaHistory.events = [QuotaChangeEvent(id: "synthetic-event", accountKey: accountKey, app: .codex, kind: .codexPrimary, sampledAt: fixture.now.addingTimeInterval(-300), limitID: "primary", limitKind: .fiveHour, beforeRemainingPercent: 85, afterRemainingPercent: 75, deltaPercent: -10, resetsAt: cycle.endAt)]
        let quotaQuery: [String: HostJSON] = ["accountID": .string("quota.codex.primary"), "kind": .string("fiveHour")]
        let quota = try await service.handle("quota.analytics", params: quotaQuery)
        XCTAssertEqual(try object(object(quota)["window"])["remainingPercent"], .number(75))
        XCTAssertEqual(try array(object(quota)["cycles"]).count, 1)
        let period = try object(XCTUnwrap(array(object(quota)["timeline"]).first))
        XCTAssertEqual(period["totalDelta"], .number(-10))
        XCTAssertFalse(try array(period["entries"]).isEmpty)

        // Yesterday's last sample remains the header value while today's chart is empty.
        fixture.state.quotaHistory.events = []
        fixture.state.quotaHistory.lastSamples[series]?.sampledAt = fixture.day(8)
        let stale = try object(await service.handle("quota.analytics", params: quotaQuery))
        XCTAssertEqual(try object(stale["window"])["latestSampleAt"], service.dateJSON(fixture.day(8)))
        let today = try object(XCTUnwrap(array(stale["timeline"]).first))
        XCTAssertTrue(try array(today["entries"]).isEmpty)

        // Opt-in artifact for the SDK's strict runtime validators. All values above
        // are synthetic and every backing store belongs to this temporary fixture.
        if let output = ProcessInfo.processInfo.environment["CCBAR_WINDOW_FIXTURE_OUTPUT"] {
            let conversationDetail = try await service.handle("conversations.detail", params: ["id": try XCTUnwrap(conversation["id"])])
            let values: [String: HostJSON] = [
                "window.usage.overview": overview,
                "conversations.list": conversations,
                "conversations.detail": conversationDetail,
                "projects.list": projects,
                "projects.detail": detail,
                "quota.analytics": quota,
                "usage.refresh": service.statusJSON(),
            ]
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(values).write(to: URL(fileURLWithPath: output), options: .atomic)
        }
    }

    func testHistoryRecoveryNoticeRemainsVisibleWithoutAnError() throws {
        let fixture = try UsageWindowFixture()
        defer { fixture.cleanup() }
        let service = fixture.service()
        XCTAssertEqual(service.historyNoticeJSON(notice: nil, hasError: false), .null)
        var notice = UsageHistoryRecoveryNotice(restoredFromPreviousAt: fixture.now, isRestricted: false, isReadOnly: false)
        let restored = try object(service.historyNoticeJSON(notice: notice, hasError: false))
        XCTAssertEqual(restored["restoredAt"], service.dateJSON(fixture.now))
        XCTAssertEqual(restored["canOpenSettings"], .bool(false))
        XCTAssertNotNil(restored["message"])
        notice.isRestricted = true
        let restricted = try object(service.historyNoticeJSON(notice: notice, hasError: true))
        XCTAssertEqual(restricted["canOpenSettings"], .bool(true))
        XCTAssertNotEqual(restricted["message"], restored["message"])
        notice.isReadOnly = true
        XCTAssertEqual(try object(service.historyNoticeJSON(notice: notice, hasError: true))["canOpenSettings"], .bool(false))
        notice.isReadOnly = false
        notice.isRestricted = false
        notice.isDshFrozen = true
        let frozen = service.historyNoticeJSON(notice: notice, hasError: true)
        XCTAssertEqual(try object(frozen)["canOpenSettings"], .bool(false))
        fixture.settings.privacyMode = true
        XCTAssertEqual(service.historyNoticeJSON(notice: notice, hasError: true), frozen)
    }

    func testDashboardUsesVerifiedEventsAndPreservesUnlocatedDailyUsage() async throws {
        let fixture = try UsageWindowFixture()
        defer { fixture.cleanup() }
        fixture.show([.codex])
        let day = Calendar.current.startOfDay(for: fixture.now)
        let entry = UsageEntry(app: .codex, conversationKey: "private", model: "gpt-test", speed: .standard,
            day: day, timestamp: fixture.now.addingTimeInterval(-3600), inputTokens: 10, outputTokens: 0,
            cacheReadTokens: 0, cacheCreationTokens: 0, costUSD: 1, costBreakdown: nil)
        let extra = UsageEntry(app: .codex, conversationKey: "other", model: "gpt-test", speed: .standard,
            day: day, timestamp: fixture.now.addingTimeInterval(-7200), inputTokens: 5, outputTokens: 0,
            cacheReadTokens: 0, cacheCreationTokens: 0, costUSD: 1, costBreakdown: nil)
        fixture.state.usageService.aggregator.ingestLocal([entry, extra])
        let service = fixture.service()
        try fixture.index(service, records: [UsageRequestRecord(id: "one", entry: entry)], revision: "test")
        let query: [String: HostJSON] = ["range": .string("last24h"), "metric": .string("tokens")]
        let dashboard = try object(await service.handle("window.usage.dashboard", params: query))
        XCTAssertEqual(try object(dashboard["totals"])["totalTokens"], .number(10))
        XCTAssertEqual(dashboard["requestLogCount"], .number(1))
        let coverage = try object(dashboard["coverage"])
        XCTAssertEqual(coverage["incomplete"], .bool(true))
        XCTAssertEqual(try object(coverage["unlocatedTotals"])["totalTokens"], .number(5))
        let today = try object(await service.handle("window.usage.dashboard", params: ["range": .string("today"), "metric": .string("tokens")]))
        XCTAssertEqual(try object(today["totals"])["totalTokens"], .number(15))
        XCTAssertEqual(today["requestLogCount"], .number(1), "Historical aggregate requests are not displayable log rows")
        XCTAssertEqual(try object(today["coverage"])["incomplete"], .bool(true))
        let requests = try object(await service.handle("window.usage.requests", params: query))
        XCTAssertEqual(requests["totalCount"], .number(1))
        XCTAssertEqual(try array(requests["rows"]).count, 1)
        let heatmap = try object(await service.handle("window.usage.heatmap", params: query))
        XCTAssertEqual(try array(heatmap["days"]).count, 371)

        var revision = "page-1"
        try fixture.index(service, records: [UsageRequestRecord(id: "one", entry: entry), UsageRequestRecord(id: "two", entry: extra)], revision: revision)
        var pageQuery = query
        pageQuery["limit"] = .number(1)
        pageQuery["sort"] = .string("tokens")
        pageQuery["direction"] = .string("asc")
        let first = try object(await service.handle("window.usage.requests", params: pageQuery))
        XCTAssertEqual(try object(XCTUnwrap(array(first["rows"]).first))["id"], .string("two"))
        pageQuery["cursor"] = try XCTUnwrap(first["nextCursor"])
        let second = try object(await service.handle("window.usage.requests", params: pageQuery))
        XCTAssertEqual(try object(XCTUnwrap(array(second["rows"]).first))["id"], .string("one"))
        fixture.show([.codex, .claude])
        await assertError("invalid_cursor") { try await service.handle("window.usage.requests", params: pageQuery) }
        fixture.show([.codex])
        revision = "page-2"
        try fixture.index(service, records: [UsageRequestRecord(id: "one", entry: entry), UsageRequestRecord(id: "two", entry: extra)], revision: revision)
        await assertError("invalid_cursor") { try await service.handle("window.usage.requests", params: pageQuery) }

        let exceeding = UsageEntry(app: .codex, conversationKey: "bad", model: "gpt-test", speed: .standard,
            day: day, timestamp: fixture.now.addingTimeInterval(-500), inputTokens: 100, outputTokens: 0,
            cacheReadTokens: 0, cacheCreationTokens: 0, costUSD: 1, costBreakdown: nil)
        try fixture.index(service, records: [UsageRequestRecord(id: "bad", entry: exceeding)], revision: "overflow")
        let rejected = try object(await service.handle("window.usage.requests", params: query))
        XCTAssertEqual(rejected["totalCount"], .number(0), "An invalid on-disk partition must fail closed; background imports retain old valid rows before writing")
        XCTAssertEqual(try object(rejected["coverage"])["incomplete"], .bool(true))
        fixture.state.usageService.aggregator.ingestLocal([exceeding])
        try fixture.index(service, records: [UsageRequestRecord(id: "one", entry: entry), UsageRequestRecord(id: "two", entry: extra), UsageRequestRecord(id: "bad", entry: exceeding)], revision: "committed")
        let committed = try object(await service.handle("window.usage.requests", params: query))
        XCTAssertEqual(committed["totalCount"], .number(3))
        let long: [String: HostJSON] = ["range": .string("custom"), "metric": .string("tokens"), "customFrom": .string("2020-01-01T00:00:00Z"), "customTo": .string("2026-03-10T00:00:00Z")]
        let monthly = try object(await service.handle("window.usage.dashboard", params: long))
        XCTAssertEqual(try object(monthly["resolvedRange"])["granularity"], .string("month"))
        XCTAssertGreaterThan(try array(monthly["samples"]).count, 70)
        XCTAssertLessThan(try array(monthly["samples"]).count, 80)

        fixture.state.usageService.aggregator.load(from: [])
        fixture.state.usageService.aggregator.ingestLocal([entry, extra])
        var advisor = extra
        advisor.requestCount = 0
        advisor.inputTokens = 3
        fixture.state.usageService.aggregator.ingestLocal([advisor])
        try fixture.index(service, records: [UsageRequestRecord(id: "one", entry: entry), UsageRequestRecord(id: "advisor", entry: advisor)], revision: "advisor")
        let advisorDashboard = try object(await service.handle("window.usage.dashboard", params: query))
        XCTAssertEqual(try object(advisorDashboard["totals"])["totalTokens"], .number(13))
        XCTAssertEqual(advisorDashboard["requestLogCount"], .number(1))
        let advisorRequests = try object(await service.handle("window.usage.requests", params: query))
        XCTAssertEqual(advisorRequests["totalCount"], .number(1))
        fixture.state.usageService.aggregator.load(from: [])
        var unpriced = entry
        unpriced.costUSD = nil
        fixture.state.usageService.aggregator.ingestLocal([unpriced])
        try fixture.index(service, records: [UsageRequestRecord(id: "unpriced", entry: unpriced)], revision: "unpriced")
        let unpricedDashboard = try object(await service.handle("window.usage.dashboard", params: query))
        XCTAssertEqual(try object(unpricedDashboard["coverage"])["incomplete"], .bool(false))
        XCTAssertEqual(try object(unpricedDashboard["coverage"])["precision"], .string("event"))
        XCTAssertEqual(try object(unpricedDashboard["totals"])["hasUnpricedUsage"], .bool(true))
    }

    func testNumberedRequestPagesDefaultToTwelveAndClampAfterHistoryShrinks() async throws {
        let fixture = try UsageWindowFixture()
        defer { fixture.cleanup() }
        fixture.show([.codex])
        let day = Calendar.current.startOfDay(for: fixture.now)
        let entries = (1...31).map { n in
            UsageEntry(app: n == 31 ? .claude : .codex, conversationKey: "private", model: n <= 20 ? "first" : "second", speed: .standard,
                day: day, timestamp: fixture.now.addingTimeInterval(Double(-n * 60)), inputTokens: n, outputTokens: 0,
                cacheReadTokens: 0, cacheCreationTokens: 0, costUSD: Decimal(n), costBreakdown: nil)
        }
        fixture.state.usageService.aggregator.ingestLocal(entries)
        let records = entries.enumerated().map { UsageRequestRecord(id: String($0.offset + 1), entry: $0.element) }
        let service = fixture.service()
        try fixture.index(service, records: records, revision: "full")
        let query: [String: HostJSON] = ["range": .string("last24h"), "metric": .string("tokens")]
        let dashboard = try object(await service.handle("window.usage.dashboard", params: query))
        XCTAssertEqual(dashboard["requestLogCount"], .number(30), "Hidden applications must not contribute")
        let first = try object(await service.handle("window.usage.requests", params: query))
        XCTAssertEqual(first["page"], .number(1))
        XCTAssertEqual(first["pageSize"], .number(12))
        XCTAssertEqual(first["totalCount"], dashboard["requestLogCount"])
        XCTAssertEqual(try array(first["rows"]).count, 12)
        var pageQuery = query
        pageQuery["page"] = .number(3)
        let third = try object(await service.handle("window.usage.requests", params: pageQuery))
        XCTAssertEqual(third["page"], .number(3))
        XCTAssertEqual(try array(third["rows"]).count, 6)
        XCTAssertEqual(try object(XCTUnwrap(array(third["rows"]).first))["id"], .string("25"))
        pageQuery["pageSize"] = .number(24)
        let resized = try object(await service.handle("window.usage.requests", params: pageQuery))
        XCTAssertEqual(resized["page"], .number(2))
        XCTAssertEqual(resized["pageSize"], .number(24))
        XCTAssertEqual(try array(resized["rows"]).count, 6)
        var filtered = query
        filtered["modelID"] = .string("first")
        let filteredDashboard = try object(await service.handle("window.usage.dashboard", params: filtered))
        XCTAssertEqual(filteredDashboard["requestLogCount"], .number(20))
        let filteredPage = try object(await service.handle("window.usage.requests", params: filtered))
        XCTAssertEqual(filteredPage["totalCount"], filteredDashboard["requestLogCount"])
        let invalidQueries: [[String: HostJSON]] = [
            ["page": .number(0)], ["page": .number(Decimal(string: "1.5")!)], ["page": .number(10_000_001)],
            ["pageSize": .number(0)], ["pageSize": .number(501)], ["pageSize": .string("12")],
            ["page": .number(1), "limit": .number(12)], ["pageSize": .number(12), "cursor": .string("old")],
        ]
        for invalid in invalidQueries {
            await assertError("invalid_params") {
                try await service.handle("window.usage.requests", params: query.merging(invalid) { _, value in value })
            }
        }
        try fixture.index(service, records: Array(records.prefix(3)), revision: "smaller")
        let clamped = try object(await service.handle("window.usage.requests", params: pageQuery))
        XCTAssertEqual(clamped["page"], .number(1))
        XCTAssertEqual(clamped["totalCount"], .number(3))
        XCTAssertEqual(try array(clamped["rows"]).count, 3)
        filtered["modelID"] = .string("missing")
        filtered["page"] = .number(3)
        let empty = try object(await service.handle("window.usage.requests", params: filtered))
        XCTAssertEqual(empty["page"], .number(1))
        XCTAssertEqual(empty["totalCount"], .number(0))
        XCTAssertTrue(try array(empty["rows"]).isEmpty)
    }

    func testSQLRequestPagesSurviveNewHostAndReadErrorsDoNotReturnEmptySuccess() async throws {
        let fixture = try UsageWindowFixture()
        defer { fixture.cleanup() }
        fixture.show([.codex])
        let info = fixture.info("database-conversation", app: .codex, project: "database-project")
        fixture.load(infos: [info], buckets: [fixture.bucket(info, tokens: 30)])
        let day = Calendar.current.startOfDay(for: fixture.now)
        let entries = (1...3).map { n in
            UsageEntry(app: .codex, conversationKey: info.key, model: "gpt-5", speed: .standard,
                day: day, timestamp: fixture.now.addingTimeInterval(Double(-n * 60)),
                inputTokens: n * 5, outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0,
                costUSD: Decimal(n), costBreakdown: nil)
        }
        fixture.state.usageService.aggregator.load(from: [])
        fixture.state.usageService.aggregator.ingestLocal(entries)
        let writer = fixture.service()
        try fixture.index(writer, records: entries.enumerated().map { UsageRequestRecord(id: String($0.offset), entry: $0.element) }, revision: "persistent-pages")
        let reader = fixture.service()
        reader.dashboardStore = writer.dashboardStore
        reader.dashboardStatusProvider = writer.dashboardStatusProvider
        let query: [String: HostJSON] = ["range": .string("today"), "metric": .string("cost"), "limit": .number(1), "sort": .string("cost")]
        let first = try object(await reader.handle("window.usage.requests", params: query))
        XCTAssertEqual(first["totalCount"], .number(3))
        let rows = try array(first["rows"])
        XCTAssertEqual(rows.count, 1)
        let row = try object(XCTUnwrap(rows.first))
        XCTAssertEqual(row["id"], .string("2"))
        XCTAssertNotEqual(row["conversationID"], .null)
        let wire = String(decoding: try JSONEncoder().encode(HostJSON.object(first)), as: UTF8.self)
        XCTAssertFalse(wire.contains(info.key), "Only opaque conversation identities may cross the Host API")
        let db = fixture.root.appendingPathComponent("query-index/request-index.sqlite3")
        try FileManager.default.removeItem(at: db)
        await assertError("usage_unavailable") { try await reader.handle("window.usage.requests", params: query) }
        await assertError("usage_unavailable") { try await reader.handle("window.usage.dashboard", params: query.filter { $0.key != "limit" && $0.key != "sort" }) }
    }

    func testCancelledSQLQueryDoesNotMarkDatabaseUnavailable() async throws {
        let fixture = try UsageWindowFixture()
        defer { fixture.cleanup() }
        fixture.show([.codex])
        PricingCatalogStore.shared.disableNetworkForTesting()
        await fixture.state.usageService.bootstrap(appState: fixture.state)
        await fixture.state.usageService.synchronizeRequestIndexForTesting()
        let before = fixture.state.usageService.requestIndexStatusForDisplay()
        XCTAssertTrue(before.isReady)
        XCTAssertFalse(before.isUnavailable)
        // Use the actual UsageService store and status, so the failure-recovery path is
        // observable. The task is cancelled before yielding the main actor to its body.
        let service = fixture.service()
        let query: [String: HostJSON] = ["range": .string("today"), "metric": .string("tokens")]
        let task = Task { try await service.handle("window.usage.requests", params: query) }
        task.cancel()
        await assertError("cancelled") { try await task.value }
        XCTAssertFalse(fixture.state.usageService.requestIndexStatusForDisplay().isUnavailable)
        let next = try object(await service.handle("window.usage.requests", params: query))
        XCTAssertEqual(next["totalCount"], .number(0))
    }

    func testDashboardServicesStayInEnabledOrderAcrossEmptyFilters() async throws {
        let fixture = try UsageWindowFixture()
        defer { fixture.cleanup() }
        fixture.show([.codex, .claude, .kimi])
        fixture.settings.serviceOrder = [.quota(.kimi), .quota(.claude), .quota(.codex)]
        let day = Calendar.current.startOfDay(for: fixture.now)
        let entry = UsageEntry(app: .codex, conversationKey: "enabled", model: "model", speed: .standard,
            day: day, timestamp: fixture.now.addingTimeInterval(-60), inputTokens: 7, outputTokens: 0,
            cacheReadTokens: 0, cacheCreationTokens: 0, costUSD: 1, costBreakdown: nil)
        fixture.state.usageService.aggregator.ingestLocal([entry])
        let service = fixture.service()
        try fixture.index(service, records: [UsageRequestRecord(id: "enabled", entry: entry)], revision: "enabled")
        let expected: [HostJSON?] = [.string("kimi"), .string("claude"), .string("codex")]
        let cases: [[String: HostJSON]] = [
            ["range": .string("today"), "metric": .string("tokens")],
            ["range": .string("today"), "metric": .string("tokens"), "service": .string("kimi")],
            ["range": .string("today"), "metric": .string("tokens"), "modelID": .string("missing")],
            ["range": .string("custom"), "metric": .string("tokens"), "customFrom": .string("2025-01-01T00:00:00Z"), "customTo": .string("2025-01-02T00:00:00Z")],
        ]
        for query in cases {
            let result = try object(await service.handle("window.usage.dashboard", params: query))
            let facets = try object(result["facets"])
            let services = try array(facets["services"]).map { try object($0) }
            XCTAssertEqual(services.map { $0["id"] }, expected)
            XCTAssertEqual(services[0]["requestCount"], .number(0))
            XCTAssertEqual(services[1]["requestCount"], .number(0))
            if query["range"] == .string("custom") {
                XCTAssertTrue(try array(facets["sources"]).isEmpty)
                XCTAssertTrue(try array(facets["models"]).isEmpty)
                XCTAssertEqual(services[2]["requestCount"], .number(0))
            }
        }
        fixture.show([.codex, .kimi])
        let hidden = try object(await service.handle("window.usage.dashboard", params: cases[0]))
        let hiddenServices = try array(object(hidden["facets"])["services"]).map { try object($0) }
        XCTAssertEqual(hiddenServices.map { $0["id"] }, [.string("kimi"), .string("codex")])
    }

    func testDashboardUsesNiceAxisAndMatchingBarNormalization() async throws {
        let fixture = try UsageWindowFixture()
        defer { fixture.cleanup() }
        fixture.show([.codex])
        let day = Calendar.current.startOfDay(for: fixture.now)
        let entry = UsageEntry(app: .codex, conversationKey: "nice-axis", model: "model", speed: .standard,
            day: day, timestamp: fixture.now.addingTimeInterval(-60), inputTokens: 837, outputTokens: 0,
            cacheReadTokens: 0, cacheCreationTokens: 0, costUSD: 837, costBreakdown: nil)
        fixture.state.usageService.aggregator.ingestLocal([entry])
        let service = fixture.service()
        try fixture.index(service, records: [UsageRequestRecord(id: "nice-axis", entry: entry)], revision: "nice-axis")
        func numeric(_ value: HostJSON?) throws -> Double {
            NSDecimalNumber(decimal: try number(value)).doubleValue
        }
        for metric in ["tokens", "cost", "requests"] {
            let response = try object(await service.handle("window.usage.dashboard", params: ["range": .string("today"), "metric": .string(metric)]))
            let axis = try array(response["axisTicks"]).map { try object($0) }
            let expected: [HostJSON?] = switch metric {
            case "cost": [.string("USD 0"), .string("USD 450"), .string("USD 900")]
            case "requests": [.string("0"), .string("0.5"), .string("1")]
            default: [.string("0"), .string("450"), .string("900")]
            }
            XCTAssertEqual(axis.map { $0["label"] }, expected)
            let samples = try array(response["samples"]).map { try object($0) }
            let sample = try XCTUnwrap(samples.first { (try? numeric($0["value"])) ?? 0 > 0 })
            let expectedRatio = metric == "requests" ? 1 : 837.0 / 900.0
            XCTAssertEqual(try numeric(sample["normalizedValue"]), expectedRatio, accuracy: 1e-10)
        }
    }

    func testDashboardCostAxisUsesDisplayCurrencyBeforeRounding() async throws {
        let fixture = try UsageWindowFixture()
        defer { fixture.cleanup() }
        fixture.show([.codex])
        let day = Calendar.current.startOfDay(for: fixture.now)
        let entry = UsageEntry(app: .codex, conversationKey: "currency-axis", model: "model", speed: .standard,
            day: day, timestamp: fixture.now.addingTimeInterval(-60), inputTokens: 1, outputTokens: 0,
            cacheReadTokens: 0, cacheCreationTokens: 0, costUSD: 120, costBreakdown: nil)
        fixture.state.usageService.aggregator.ingestLocal([entry])
        var actions = fixture.actions()
        actions.costDisplayRate = { 7 }
        actions.formatDisplayCost = { value in "CNY \(value.asPlainString)" }
        let service = fixture.service(actions: actions)
        try fixture.index(service, records: [UsageRequestRecord(id: "currency-axis", entry: entry)], revision: "currency-axis")
        let response = try object(await service.handle("window.usage.dashboard", params: ["range": .string("today"), "metric": .string("cost")]))
        let axis = try array(response["axisTicks"]).map { try object($0) }
        XCTAssertEqual(axis.map { $0["label"] }, [.string("CNY 0"), .string("CNY 450"), .string("CNY 900")])
        let samples = try array(response["samples"]).map { try object($0) }
        let sample = try XCTUnwrap(samples.first { $0["value"] == .number(120) })
        let normalized = NSDecimalNumber(decimal: try number(sample["normalizedValue"])).doubleValue
        XCTAssertEqual(normalized, 840.0 / 900.0, accuracy: 1e-10)
    }

    func testDashboardCacheAxisUsesMinimumValidRateAndMatchingNormalization() async throws {
        let cases: [(read: Int, ticks: [String], normalized: Double)] = [
            (98, ["95.0%", "97.5%", "100.0%"], 0.6),
            (95, ["90.0%", "95.0%", "100.0%"], 0.5),
            (90, ["85.0%", "92.5%", "100.0%"], 1.0 / 3.0),
            (60, ["0.0%", "50.0%", "100.0%"], 0.6),
        ]
        for testCase in cases {
            let fixture = try UsageWindowFixture()
            defer { fixture.cleanup() }
            fixture.show([.codex])
            let day = Calendar.current.startOfDay(for: fixture.now)
            func entry(_ id: String, input: Int, read: Int, output: Int, timestamp: Date) -> UsageEntry {
                UsageEntry(app: .codex, conversationKey: id, model: "model", speed: .standard,
                    day: day, timestamp: timestamp, inputTokens: input, outputTokens: output,
                    cacheReadTokens: read, cacheCreationTokens: 0, costUSD: 0, costBreakdown: nil)
            }
            let entries = [
                entry("minimum", input: 100 - testCase.read, read: testCase.read, output: 0, timestamp: fixture.now.addingTimeInterval(-60)),
                entry("full", input: 0, read: 100, output: 0, timestamp: fixture.now.addingTimeInterval(-3660)),
                entry("invalid", input: 0, read: 0, output: 5, timestamp: fixture.now.addingTimeInterval(-7320)),
            ]
            fixture.state.usageService.aggregator.ingestLocal(entries)
            let service = fixture.service()
            try fixture.index(service, records: entries.map { UsageRequestRecord(id: $0.conversationKey, entry: $0) }, revision: "cache-axis")
            let response = try object(await service.handle("window.usage.dashboard", params: ["range": .string("today"), "metric": .string("cacheHitRate")]))
            let axis = try array(response["axisTicks"]).map { try object($0) }
            XCTAssertEqual(axis.map { $0["label"] }, testCase.ticks.map { Optional(HostJSON.string($0)) })
            let samples = try array(response["samples"]).map { try object($0) }
            func numeric(_ value: HostJSON?) throws -> Double {
                NSDecimalNumber(decimal: try number(value)).doubleValue
            }
            let minimumRate = Double(testCase.read) / 100
            let minimum = try XCTUnwrap(samples.first { (try? numeric($0["value"])).map { abs($0 - minimumRate) < 1e-10 } == true })
            let full = try XCTUnwrap(samples.first { (try? numeric($0["value"])) == 1 })
            XCTAssertEqual(try numeric(minimum["normalizedValue"]), testCase.normalized, accuracy: 1e-10)
            XCTAssertEqual(try numeric(full["normalizedValue"]), 1, accuracy: 1e-10)
        }
    }

    func testEmptyDashboardUsesDashesAndRetainsZeroSamplesWithReadableAxes() async throws {
        let fixture = try UsageWindowFixture()
        defer { fixture.cleanup() }
        fixture.show([.codex])
        let service = fixture.service()
        try fixture.index(service, records: [], revision: "empty")
        for metric in ["cost", "requests", "tokens", "cacheHitRate"] {
            let result = try object(await service.handle("window.usage.dashboard", params: ["range": .string("last7"), "metric": .string(metric)]))
            let display = try object(result["kpiDisplay"])
            XCTAssertEqual(display, ["cost": .string("—"), "requests": .string("—"), "tokens": .string("—"), "cacheHitRate": .string("—")])
            XCTAssertEqual(try object(result["coverage"])["incomplete"], .bool(false))
            let samples = try array(result["samples"]).map { try object($0) }
            XCTAssertEqual(samples.count, 7, "Keep each day for the X axis even when no usage exists")
            for sample in samples {
                XCTAssertEqual(sample["value"], .number(0))
                XCTAssertEqual(sample["normalizedValue"], .number(0))
                XCTAssertTrue(try array(sample["segments"]).isEmpty)
            }
            let axis = try array(result["axisTicks"]).map { try object($0) }
            let expected: [HostJSON?]
            switch metric {
            case "cost": expected = [.string("USD 0"), .string("USD 1"), .string("USD 2")]
            case "cacheHitRate": expected = [.string("0.0%"), .string("50.0%"), .string("100.0%")]
            default: expected = [.string("0"), .string("1"), .string("2")]
            }
            XCTAssertEqual(axis.map { $0["label"] }, expected)
            XCTAssertTrue(try array(result["providerRows"]).isEmpty)
            XCTAssertTrue(try array(result["modelRows"]).isEmpty)
        }
    }

    func testZeroCostUsageAndRefreshingCoverageAreNotConfirmedEmpty() async throws {
        let fixture = try UsageWindowFixture()
        defer { fixture.cleanup() }
        fixture.show([.codex])
        let service = fixture.service()
        try fixture.index(service, records: [], revision: "warming")
        service.dashboardStatusProvider = {
            UsageRequestIndexStatus(revision: "warming", incompleteApps: [], isRefreshing: true, isReady: true)
        }
        let query: [String: HostJSON] = ["range": .string("today"), "metric": .string("cost")]
        let warming = try object(await service.handle("window.usage.dashboard", params: query))
        XCTAssertEqual(try object(warming["coverage"])["incomplete"], .bool(true))
        XCTAssertNotEqual(try object(warming["kpiDisplay"])["cost"], .string("—"))
        let day = Calendar.current.startOfDay(for: fixture.now)
        let entry = UsageEntry(app: .codex, conversationKey: "zero-cost", model: "free", speed: .standard,
            day: day, timestamp: fixture.now.addingTimeInterval(-60), inputTokens: 5, outputTokens: 0,
            cacheReadTokens: 0, cacheCreationTokens: 0, costUSD: 0, costBreakdown: nil)
        fixture.state.usageService.aggregator.ingestLocal([entry])
        try fixture.index(service, records: [UsageRequestRecord(id: "zero-cost", entry: entry)], revision: "zero-cost")
        let active = try object(await service.handle("window.usage.dashboard", params: query))
        let display = try object(active["kpiDisplay"])
        XCTAssertEqual(display["cost"], .string("USD 0"))
        XCTAssertEqual(display["requests"], .string("1"))
        XCTAssertEqual(display["tokens"], .string("5"))
        XCTAssertEqual(display["cacheHitRate"], .string("0.0%"))
        XCTAssertFalse(try array(active["providerRows"]).isEmpty)
    }

    private func object(_ value: HostJSON?) throws -> [String: HostJSON] {
        guard case .object(let result) = value else { throw XCTUnwrapError.unexpectedJSON }
        return result
    }
    private func array(_ value: HostJSON?) throws -> [HostJSON] {
        guard case .array(let result) = value else { throw XCTUnwrapError.unexpectedJSON }
        return result
    }
    private func number(_ value: HostJSON?) throws -> Decimal {
        guard case .number(let result) = value else { throw XCTUnwrapError.unexpectedJSON }
        return result
    }
    private func assertError(_ code: String, operation: () async throws -> HostJSON, file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await operation(); XCTFail("Expected \(code)", file: file, line: line) }
        catch let error as HostError { XCTAssertEqual(error.code, code, file: file, line: line) }
        catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
    }
    private enum XCTUnwrapError: Error { case unexpectedJSON }
}

/// Every store and log root belongs to this temporary directory. These tests never
/// bootstrap AppState, discover credentials, or perform network operations.
/// The cancellation test bootstraps only the isolated UsageService with network disabled.
@MainActor
private final class UsageWindowFixture {
    let suite = "HostWindowUsageTests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let root: URL
    let settings: SettingsStore
    let state: AppState
    let now: Date
    var copied: [String] = []
    var revealed: [String] = []

    init() throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        settings = SettingsStore(defaults: defaults)
        root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let roots = UsageScanRoots(claudeRoot: root.appendingPathComponent("claude"), claudeConversationIndex: { ConversationTitleIndex.ClaudeIndex(titles: [:], projects: [:]) }, codexRoots: [root.appendingPathComponent("codex")], codexTitles: { [:] }, piRoot: root.appendingPathComponent("pi"), opencodeDatabaseURL: root.appendingPathComponent("opencode.db"), dshRoot: root.appendingPathComponent("dsh"))
        let usage = UsageService(historyStore: UsageSnapshotStore(directory: root.appendingPathComponent("history")), roots: roots, legacyLocations: LegacyUsageHistoryLocations(supportDirectory: root.appendingPathComponent("support"), cacheDirectory: root.appendingPathComponent("cache")), backfillURL: root.appendingPathComponent("no-backfill.json"), cursorCacheDirectory: root.appendingPathComponent("cursor-cache"))
        state = AppState(authorizations: AuthorizationStore(directory: root.appendingPathComponent("authorizations")), applications: ApplicationStore(defaults: defaults), usageService: usage)
        state.accountPersistenceDirectory = root
        now = try XCTUnwrap(StatsRange.weekStartMondayCalendar.date(from: DateComponents(year: 2026, month: 3, day: 9, hour: 12)))
    }
    func cleanup() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
    func show(_ apps: Set<UsageApp>) {
        for app in UsageApp.allCases { settings.setUsageServiceVisible(apps.contains(app), for: app) }
        settings.cursorAccountDetected = true
    }
    func actions() -> HostWindowUsageActions {
        HostWindowUsageActions(copyConversationID: { self.copied.append($0) }, revealProject: { self.revealed.append($0) }, refreshUsage: {}, loadCursorHistory: { _ in }, formatCost: { value, _ in "USD \(value.asPlainString)" }, costDisplayRate: { 1 }, formatDisplayCost: { value in "USD \(value.asPlainString)" })
    }
    func service(actions: HostWindowUsageActions? = nil) -> HostWindowUsageService {
        HostWindowUsageService(state: state, settings: settings, actions: actions ?? self.actions(), now: { self.now })
    }
    func index(_ service: HostWindowUsageService, records: [UsageRequestRecord], revision: String) throws {
        let store = UsageRequestIndexStore(directory: root.appendingPathComponent("query-index"))
        let rows = records.map { record in
            let e = record.entry
            return UsageRequestIndexStore.Row(id: record.id, conversationHash: UsageRequestIndexStore.hash(e.conversationKey),
                app: e.app, model: e.model, speed: e.speed, day: e.day, timestamp: e.timestamp,
                input: e.inputTokens, output: e.outputTokens, cacheRead: e.cacheReadTokens,
                cacheCreation: e.cacheCreationTokens, requests: e.requestCount, cost: e.costUSD,
                costInput: e.costBreakdown?.input, costOutput: e.costBreakdown?.output,
                costRead: e.costBreakdown?.cacheRead, costCreation: e.costBreakdown?.cacheCreation, timing: e.timing)
        }
        try store.save(.init(version: 1, sourceKeys: Dictionary(uniqueKeysWithValues: Set(rows.map(\.app)).map { ($0, UsageRequestIndexStore.hash(revision)) }), incompleteApps: [], rows: rows))
        service.dashboardStore = store
        service.dashboardStatusProvider = { UsageRequestIndexStatus(revision: revision, incompleteApps: [], isReady: true) }
    }
    func day(_ day: Int) -> Date {
        StatsRange.weekStartMondayCalendar.date(from: DateComponents(year: 2026, month: 3, day: day))!
    }
    func query(granularity: String = "day") -> [String: HostJSON] {
        ["range": .string("custom"), "granularity": .string(granularity), "customFrom": .string("2026-03-02"), "customTo": .string("2026-03-09")]
    }
    func info(_ key: String, app: UsageApp, project: String) -> ConversationInfo {
        let path = root.appendingPathComponent(project).path
        return ConversationInfo(key: key, conversationID: key, app: app, title: "Title for \(key)", projectKey: "path:\(path)", projectName: project, projectPath: path, projectStatus: .unverified, projectSource: .cwd, gitBranch: "private-branch", sourcePaths: [root.appendingPathComponent("private-source-log.jsonl").path], firstAt: day(2), lastAt: day(10), includesSubtasks: false, cacheCreationAvailable: true)
    }
    func bucket(_ info: ConversationInfo, day date: Date? = nil, tokens: Int) -> ConversationUsageBucket {
        let date = date ?? day(9)
        return ConversationUsageBucket(conversationKey: info.key, app: info.app, day: date, model: "gpt-5", speed: .standard, firstAt: date, lastAt: date, inputTokens: tokens, outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0, requestCount: 1, costUSD: Decimal(tokens), inputCostUSD: Decimal(tokens), outputCostUSD: 0, cacheReadCostUSD: 0, cacheCreationCostUSD: 0, hasUnpricedUsage: false)
    }
    func load(infos: [ConversationInfo], buckets: [ConversationUsageBucket]) {
        state.usageService.conversationAggregator.load(infos: infos, buckets: buckets)
        state.usageService.aggregator.load(from: buckets.map {
            UsageBucket(app: $0.app, model: $0.model, speed: $0.speed, day: $0.day, inputTokens: $0.inputTokens, outputTokens: $0.outputTokens, cacheReadTokens: $0.cacheReadTokens, cacheCreationTokens: $0.cacheCreationTokens, costUSD: $0.costUSD, requestCount: $0.requestCount, hasUnpricedUsage: $0.hasUnpricedUsage)
        })
    }
    func cycle(_ id: String, accountKey: String) -> QuotaCycleRecord {
        QuotaCycleRecord(id: id, accountKey: accountKey, app: .codex, limitID: "primary", limitKind: .fiveHour, startAt: now.addingTimeInterval(-3600), endAt: now.addingTimeInterval(3600), scheduledEndAt: now.addingTimeInterval(3600), firstSampleAt: now.addingTimeInterval(-3600), lastSampleAt: now, latestUsedPercent: 25, allowanceSegments: [QuotaCycleAllowanceSegment(id: "\(id)-segment", startAt: now.addingTimeInterval(-3600), endAt: nil, baselineUsedPercent: 0, latestUsedPercent: 25, maximumUsedPercent: 25, firstSampleAt: now.addingTimeInterval(-3600), lastSampleAt: now, startReason: .initial)], source: .api, boundaryQuality: .observed)
    }
    func cycleBucket(_ cycle: QuotaCycleRecord, app: UsageApp, model: String, tokens: Int) -> CycleUsageBucket {
        CycleUsageBucket(cycleID: cycle.id, allowanceSegmentID: cycle.latestAllowanceSegment?.id, app: app, model: model, speed: .standard, inputTokens: tokens, outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0, costUSD: Decimal(tokens), requestCount: 1, hasUnpricedUsage: false, quality: .exact)
    }
}

@MainActor
private final class UsageWindowGate {
    let started = XCTestExpectation(description: "fake operation started")
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started.fulfill()
        }
    }
    func release() {
        continuation?.resume()
        continuation = nil
    }
}
