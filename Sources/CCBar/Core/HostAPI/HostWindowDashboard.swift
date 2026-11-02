import Foundation
import CryptoKit

// Daily snapshots contain no request timestamps. Keep that limitation explicit until a
// transactional request index can supply event-level records and coverage.
struct DashboardPartition: Hashable {
        let app: UsageApp
        let model: String
        let speed: UsageSpeed
        let day: Date
}

extension HostWindowUsageService {
    private struct DashboardQuery {
        var from: Date
        var to: Date
        var asOf: Date
        var service: UsageApp?
        var source: String?
        var model: String?
        let metric: String
        let hourly: Bool
        let naturalDays: Bool
        let allTime: Bool
    }

    private func dashboardQuery(_ params: [String: HostJSON], extra: Set<String> = []) throws -> DashboardQuery {
        try validateKeys(params, allowed: Set(["range", "customFrom", "customTo", "followNow", "service", "sourceID", "modelID", "metric"]).union(extra))
        func string(_ key: String) throws -> String? {
            guard let value = params[key] else { return nil }
            guard case .string(let s) = value, !s.isEmpty, s.count <= 512 else { throw invalidParams() }
            return s
        }
        let range = try string("range") ?? ""
        let metric = try string("metric") ?? ""
        guard ["cost", "requests", "tokens", "cacheHitRate"].contains(metric) else { throw invalidParams() }
        let service = try string("service").map { raw -> UsageApp in
            guard let app = UsageApp(rawValue: raw) else { throw invalidParams() }; return app
        }
        var follow = false
        if let value = params["followNow"] {
            guard case .bool(let b) = value else { throw invalidParams() }; follow = b
        }
        let instant = now()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: instant)
        let from: Date
        var to = instant
        switch range {
        case "today": from = today
        case "last24h": from = instant.addingTimeInterval(-86400)
        case "last7", "last14", "last30":
            let count = range == "last7" ? 7 : (range == "last14" ? 14 : 30)
            from = calendar.date(byAdding: .day, value: 1 - count, to: today) ?? today
        case "all": from = state.usageService.aggregator.snapshot().map(\.day).min() ?? today
        case "custom":
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            func parse(_ s: String) -> Date? {
                if let date = formatter.date(from: s) { return date }
                formatter.formatOptions = [.withInternetDateTime]
                defer { formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds] }
                return formatter.date(from: s)
            }
            guard let rawFrom = try string("customFrom"), let start = parse(rawFrom) else { throw invalidParams() }
            from = start
            if !follow {
                guard let rawTo = try string("customTo"), let end = parse(rawTo) else { throw invalidParams() }
                to = end
            }
        default: throw invalidParams()
        }
        if range != "custom", params["customFrom"] != nil || params["customTo"] != nil || follow { throw invalidParams() }
        guard from < to, to.timeIntervalSince(from) <= 100 * 366 * 86400 else { throw invalidParams() }
        return DashboardQuery(from: from, to: to, asOf: instant, service: service, source: try string("sourceID"), model: try string("modelID"), metric: metric, hourly: range == "today" || range == "last24h" || (range == "custom" && to.timeIntervalSince(from) <= 86400 * 2), naturalDays: ["today", "last7", "last14", "last30", "all"].contains(range), allTime: range == "all")
    }

    private func partition(_ entry: UsageEntry) -> DashboardPartition { DashboardPartition(app: entry.app, model: entry.model, speed: entry.speed, day: entry.day) }
    private func partition(_ bucket: UsageBucket) -> DashboardPartition { DashboardPartition(app: bucket.app, model: bucket.model, speed: bucket.speed, day: bucket.day) }
    private func eventBucket(_ entry: UsageEntry) -> UsageBucket {
        var timing = GenerationTiming.zero
        timing.add(entry.timing, outputTokens: entry.outputTokens)
        return UsageBucket(app: entry.app, model: entry.model, speed: entry.speed, day: entry.day,
            inputTokens: entry.inputTokens, outputTokens: entry.outputTokens, cacheReadTokens: entry.cacheReadTokens,
            cacheCreationTokens: entry.cacheCreationTokens, costUSD: entry.costUSD ?? 0,
            requestCount: entry.requestCount, hasUnpricedUsage: entry.costUSD == nil, costIncomplete: dashboardPricingMismatch.contains(partition(entry)), timing: timing)
    }
    private func verifiedRecords() -> [UsageRequestRecord] {
        guard let index = dashboardIndex else { return [] }
        let cacheKey = "\(state.usageService.aggregator.revision):\(index.revision)"
        if dashboardVerifiedCacheKey == cacheKey, let cached = dashboardVerifiedCache { return cached }
        let canonical = Dictionary(grouping: state.usageService.aggregator.snapshot(), by: { partition($0) })
        let groups = Dictionary(grouping: index.records, by: { partition($0.entry) })
        var accepted: [DashboardPartition: [UsageRequestRecord]] = [:]
        var pending = Set<DashboardPartition>()
        var pricingMismatch = Set<DashboardPartition>()
        for (key, records) in groups {
            guard let buckets = canonical[key] else { continue }
            let expected = dashboardTotal(buckets)
            func fits(_ records: [UsageRequestRecord]) -> Bool {
                let actual = dashboardTotal(records.map { eventBucket($0.entry) })
                return actual.inputTokens <= expected.inputTokens && actual.outputTokens <= expected.outputTokens
                    && actual.cacheReadTokens <= expected.cacheReadTokens && actual.cacheCreationTokens <= expected.cacheCreationTokens
                    && actual.requestCount <= expected.requestCount
            }
            if fits(records) { accepted[key] = records }
            else {
                pending.insert(key)
                if let previous = dashboardPreviousPartitions[key], fits(previous) { accepted[key] = previous }
            }
            if let chosen = accepted[key] {
                let actual = dashboardTotal(chosen.map { eventBucket($0.entry) })
                if actual.costUSD != expected.costUSD { pricingMismatch.insert(key) }
            }
        }
        dashboardPreviousPartitions = accepted
        dashboardPendingPartitions = pending
        dashboardPricingMismatch = pricingMismatch
        let verified = accepted.values.flatMap { $0 }
        dashboardVerifiedCache = verified
        dashboardVerifiedCacheKey = cacheKey
        return verified
    }
    private func selectedEvents(_ q: DashboardQuery, from: Date, to: Date, applyModel: Bool = true, applySource: Bool = true) -> [UsageRequestRecord] {
        verifiedRecords().filter { record in
            let e = record.entry
            return settings.visibleUsageApps.contains(e.app) && (q.service == nil || q.service == e.app)
                && (!applySource || q.source == nil || q.source == dashboardSource(e.app))
                && (!applyModel || q.model == nil || q.model == e.model) && e.timestamp >= from && e.timestamp < to
        }
    }
    private func selectedBuckets(_ q: DashboardQuery, from: Date, to: Date, applyModel: Bool = true, applySource: Bool = true) -> [UsageBucket] {
        let complete = dashboardBuckets(q, from: from, to: to, applyModel: applyModel, applySource: applySource)
        let calendar = Calendar.current
        let partial = selectedEvents(q, from: from, to: to, applyModel: applyModel, applySource: applySource).filter { record in
            let day = record.entry.day
            guard let end = calendar.date(byAdding: .day, value: 1, to: day) else { return false }
            return !(day >= from && (end <= to || (q.naturalDays && day == calendar.startOfDay(for: q.asOf) && to >= q.asOf)))
        }.map { eventBucket($0.entry) }
        return complete + partial
    }
    private func dashboardSourceTitle(_ app: UsageApp) -> String {
        let name: String
        switch app {
        case .codex: name = "Codex"
        case .claude: name = "Claude Code"
        case .cursor: name = "Cursor"
        case .pi: name = "Pi"
        case .opencode: name = "OpenCode"
        case .dsh: name = "DSH"
        case .antigravity: name = "Antigravity"
        case .kimi: name = "Kimi Code"
        }
        return "\(name) · \(app == .cursor ? tr("Remote metering", "远端计量") : tr("Session logs", "会话日志"))"
    }
    private func dashboardSource(_ app: UsageApp) -> String { "\(app.rawValue).\(app == .cursor ? "remoteDashboard" : "localLogs")" }
    private func dashboardBuckets(_ q: DashboardQuery, from: Date, to: Date, applyModel: Bool = true, applySource: Bool = true) -> [UsageBucket] {
        let calendar = Calendar.current
        return state.usageService.aggregator.snapshot().filter { b in
            guard settings.visibleUsageApps.contains(b.app), q.service == nil || q.service == b.app,
                  !applySource || q.source == nil || q.source == dashboardSource(b.app),
                  !applyModel || q.model == nil || q.model == b.model,
                  let end = calendar.date(byAdding: .day, value: 1, to: b.day) else { return false }
            return b.day >= from && (end <= to || (q.naturalDays && b.day == calendar.startOfDay(for: q.asOf) && to >= q.asOf))
        }
    }
    private func dashboardTotal(_ buckets: [UsageBucket]) -> UsageTotals {
        var result = UsageTotals.zero
        for b in buckets { result.add(b) }
        return result
    }
    private func dashboardRange(_ q: DashboardQuery) -> HostJSON {
        .object(["from": dateJSON(q.from), "to": dateJSON(q.to), "timeZone": .string(TimeZone.current.identifier), "granularity": .string(q.hourly ? "hour" : (q.to.timeIntervalSince(q.from) > 730 * 86400 ? "month" : "day")), "asOf": dateJSON(q.asOf)])
    }
    private func dashboardCoverage(_ q: DashboardQuery, from: Date, to: Date, includeCompleteDays: Bool) -> HostJSON {
        let calendar = Calendar.current
        let candidates = state.usageService.aggregator.snapshot().filter { b in
            guard settings.visibleUsageApps.contains(b.app), q.service == nil || q.service == b.app,
                  q.source == nil || q.source == dashboardSource(b.app), q.model == nil || q.model == b.model,
                  let end = calendar.date(byAdding: .day, value: 1, to: b.day) else { return false }
            return b.day < to && end > from && (includeCompleteDays || !(b.day >= from && end <= to))
        }
        let groups = Dictionary(grouping: verifiedRecords(), by: { partition($0.entry) })
        var residual = UsageTotals.zero
        for b in candidates {
            let known = dashboardTotal((groups[partition(b)] ?? []).map { eventBucket($0.entry) })
            var rest = UsageTotals.zero
            rest.inputTokens = max(0, b.inputTokens - known.inputTokens)
            rest.outputTokens = max(0, b.outputTokens - known.outputTokens)
            rest.cacheReadTokens = max(0, b.cacheReadTokens - known.cacheReadTokens)
            rest.cacheCreationTokens = max(0, b.cacheCreationTokens - known.cacheCreationTokens)
            rest.requestCount = max(0, b.requestCount - known.requestCount)
            rest.costUSD = max(0, b.costUSD - known.costUSD)
            rest.hasUnpricedUsage = b.hasUnpricedUsage
            rest.costIncomplete = b.costIncomplete
            residual.add(rest)
        }
        let hasResidual = residual.totalTokens > 0 || residual.requestCount > 0
        let selected = selectedEvents(q, from: from, to: to)
        let unavailable = dashboardIndex?.incompleteApps.contains(where: { app in
            candidates.contains(where: { $0.app == app })
        }) ?? true
        let pending = candidates.contains { dashboardPendingPartitions.contains(partition($0)) }
        let refreshing = dashboardIndex?.isRefreshing ?? true
        let incomplete = hasResidual || unavailable || pending || refreshing
        let precision = hasResidual ? (selected.isEmpty ? "day" : "mixed") : "event"
        return .object(["precision": .string(precision), "incomplete": .bool(incomplete), "refreshing": .bool(refreshing), "unlocatedTotals": totalsJSON(residual), "message": incomplete ? .string(tr("Some historical usage has no verified request timestamp.", "部分历史用量缺少可核验的请求时间。")) : .null])
    }
    private func dashboardValue(_ t: UsageTotals, metric: String) -> Double {
        switch metric {
        case "cost": return NSDecimalNumber(decimal: t.costUSD).doubleValue
        case "requests": return Double(t.requestCount)
        case "tokens": return Double(t.totalTokens)
        default: return t.cacheHitRate
        }
    }
    private func dashboardLabel(_ t: UsageTotals, metric: String) -> String {
        switch metric {
        case "cost": return actions.formatCost(t.costUSD, .standard)
        case "requests": return String(t.requestCount)
        case "tokens": return StatsFormatter.compactToken(t.totalTokens)
        default: return String(format: "%.1f%%", t.cacheHitRate * 100)
        }
    }
    private func dashboardFacet(_ id: String, title: String, buckets: [UsageBucket]) -> HostJSON {
        .object(["id": .string(id), "title": .string(title), "requestCount": .number(Decimal(dashboardTotal(buckets).requestCount))])
    }
    private func dashboardRow(_ id: String, title: String, app: UsageApp, model: String?, buckets: [UsageBucket]) -> HostJSON {
        .object(["id": .string(id), "title": .string(title), "service": .string(app.rawValue), "sourceID": .string(dashboardSource(app)), "modelID": model.map(HostJSON.string) ?? .null, "totals": totalsJSON(dashboardTotal(buckets)), "successRate": .null])
    }
    private func dashboardPrepareCursor(_ q: DashboardQuery, from: Date, to: Date) {
        guard q.source == nil || q.source == dashboardSource(.cursor), from < to else { return }
        let bounds = (from: from, to: to)
        prepareCursorHistory(query: HostStatsQuery(range: .custom, granularity: .day, service: q.service,
            current: bounds, previous: nil, chart: bounds, highlightedPeriodStart: nil))
    }
    private func dashboardRevision() -> String { "\(state.usageService.aggregator.revision):\(dashboardIndex?.revision ?? "none")" }

    func dashboard(_ params: [String: HostJSON]) async throws -> HostJSON {
        if let provider = dashboardIndexProvider { dashboardIndex = await provider() }
        else { dashboardIndex = state.usageService.requestIndexSnapshotForDisplay() }
        let q = try dashboardQuery(params)
        let windowStart = Calendar.current.date(byAdding: .day, value: -371, to: q.to) ?? q.from
        dashboardPrepareCursor(q, from: max(q.from, windowStart), to: q.to)
        let buckets = selectedBuckets(q, from: q.from, to: q.to)
        var allServicesQuery = q
        allServicesQuery.service = nil
        allServicesQuery.source = nil
        allServicesQuery.model = nil
        let allFacetBuckets = selectedBuckets(allServicesQuery, from: q.from, to: q.to)
        let apps = Array(Set(allFacetBuckets.map(\.app))).sorted { $0.rawValue < $1.rawValue }
        let sourceBuckets = selectedBuckets(q, from: q.from, to: q.to, applyModel: false, applySource: false)
        let sources = Array(Set(sourceBuckets.map(\.app))).sorted { $0.rawValue < $1.rawValue }
        let models = Array(Set(sourceBuckets.map(\.model))).sorted()
        let sourceFacets: [HostJSON] = sources.map { app in
            let rows = sourceBuckets.filter { $0.app == app }
            let ms = Array(Set(rows.map(\.model))).sorted()
            return .object(["id": .string(dashboardSource(app)), "title": .string(dashboardSourceTitle(app)), "service": .string(app.rawValue), "requestCount": .number(Decimal(dashboardTotal(rows).requestCount)), "models": .array(ms.map { m in dashboardFacet(m, title: m, buckets: rows.filter { $0.model == m }) })])
        }
        let selectedApps = Array(Set(buckets.map(\.app))).sorted { $0.rawValue < $1.rawValue }
        let providerRows = selectedApps.map { app in dashboardRow(dashboardSource(app), title: dashboardSourceTitle(app), app: app, model: nil, buckets: buckets.filter { $0.app == app }) }
        let modelRows = selectedApps.flatMap { app in
            Array(Set(buckets.filter { $0.app == app }.map(\.model))).sorted().map { m in dashboardRow("\(dashboardSource(app))|\(m)", title: m, app: app, model: m, buckets: buckets.filter { $0.app == app && $0.model == m }) }
        }
        let total = dashboardTotal(buckets)
        let calendar = Calendar.current
        let monthly = !q.hourly && q.to.timeIntervalSince(q.from) > 730 * 86400
        let component: Calendar.Component = q.hourly ? .hour : (monthly ? .month : .day)
        var day = calendar.dateInterval(of: component, for: q.from)?.start ?? q.from
        let hourlyEvents = q.hourly ? selectedEvents(q, from: q.from, to: q.to) : []
        let eventGroups = Dictionary(grouping: hourlyEvents) { record in
            calendar.dateInterval(of: component, for: record.entry.timestamp)?.start ?? record.entry.timestamp
        }
        let bucketGroups = Dictionary(grouping: buckets) { bucket in
            calendar.dateInterval(of: component, for: bucket.day)?.start ?? bucket.day
        }
        var sampleData: [(Date, [UsageBucket])] = []
        while day < q.to {
            guard let next = calendar.date(byAdding: component, value: 1, to: day), next > day else { break }
            let rows = q.hourly ? (eventGroups[day] ?? []).map { eventBucket($0.entry) } : (bucketGroups[day] ?? [])
            sampleData.append((day, rows)); day = next
        }
        let maxValue = sampleData.map { dashboardValue(dashboardTotal($0.1), metric: q.metric) }.max() ?? 0
        let samples: [HostJSON] = sampleData.map { day, rows in
            let totals = dashboardTotal(rows)
            let value = dashboardValue(totals, metric: q.metric)
            let segments: [HostJSON] = settings.visibleUsageApps.compactMap { app in
                let appRows = rows.filter { $0.app == app }
                guard !appRows.isEmpty else { return nil }
                let appTotals = dashboardTotal(appRows)
                let contribution: Double
                let share: Double
                let label: String
                if q.metric == "cacheHitRate" {
                    contribution = totals.inputWithCacheTokens > 0 ? Double(appTotals.cacheReadTokens) / Double(totals.inputWithCacheTokens) : 0
                    share = totals.cacheReadTokens > 0 ? Double(appTotals.cacheReadTokens) / Double(totals.cacheReadTokens) : 0
                    label = String(format: tr("%.1f pp", "%.1f 个百分点"), contribution * 100)
                } else {
                    contribution = dashboardValue(appTotals, metric: q.metric)
                    share = value > 0 ? contribution / value : 0
                    label = dashboardLabel(appTotals, metric: q.metric)
                }
                return .object(["service": .string(app.rawValue), "totals": totalsJSON(appTotals), "value": numberJSON(contribution), "label": .string(label), "share": numberJSON(share)])
            }
            return .object(["key": dateJSON(day), "start": dateJSON(day), "totals": totalsJSON(totals), "value": numberJSON(value), "label": .string(dashboardLabel(totals, metric: q.metric)), "normalizedValue": numberJSON(maxValue > 0 ? value / maxValue : 0), "segments": .array(segments)])
        }
        let axisTicks: [HostJSON] = [0.0, 0.5, 1.0].map { position in
            let value = maxValue * position
            let label: String
            switch q.metric {
            case "cost": label = actions.formatCost(Decimal(value), .standard)
            case "cacheHitRate": label = String(format: "%.1f%%", value * 100)
            default: label = StatsFormatter.compactToken(Int(value.rounded()))
            }
            return .object(["position": numberJSON(position), "label": .string(label)])
        }
        let integerFormatter = NumberFormatter()
        integerFormatter.numberStyle = .decimal
        func formatted(_ value: Int) -> String { integerFormatter.string(from: NSNumber(value: value)) ?? String(value) }
        let kpiDisplay: HostJSON = .object(["cost": .string(actions.formatCost(total.costUSD, .standard)), "requests": .string(formatted(total.requestCount)), "tokens": .string(StatsFormatter.compactToken(total.totalTokens)), "cacheHitRate": .string(String(format: "%.1f%%", total.cacheHitRate * 100))])
        return .object(["kpiDisplay": kpiDisplay, "revision": .string(dashboardRevision()), "resolvedRange": dashboardRange(q), "coverage": dashboardCoverage(q, from: q.from, to: q.to, includeCompleteDays: q.hourly), "totals": totalsJSON(total), "facets": .object(["services": .array(apps.map { app in dashboardFacet(app.rawValue, title: app.rawValue, buckets: allFacetBuckets.filter { $0.app == app }) }), "sources": .array(sourceFacets), "models": .array(models.map { m in dashboardFacet(m, title: m, buckets: sourceBuckets.filter { $0.model == m }) })]), "providerRows": .array(providerRows), "modelRows": .array(modelRows), "samples": .array(samples), "axisTicks": .array(axisTicks), "status": statusJSON()])
    }

    private struct RequestCursor: Codable {
        let revision: String
        let fingerprint: String
        let from: Date
        let to: Date
        let asOf: Date
        let offset: Int
    }
    private func requestFingerprint(_ params: [String: HostJSON]) -> String {
        let keys = ["range", "customFrom", "customTo", "followNow", "service", "sourceID", "modelID", "metric", "sort", "direction"]
        let raw = keys.map { "\($0)=\(String(describing: params[$0]))" }.joined(separator: "|") + "|apps=" + settings.visibleUsageApps.map(\.rawValue).sorted().joined(separator: ",") + "|tz=" + TimeZone.current.identifier
        return SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func dashboardRequests(_ params: [String: HostJSON]) async throws -> HostJSON {
        if let provider = dashboardIndexProvider { dashboardIndex = await provider() }
        else { dashboardIndex = state.usageService.requestIndexSnapshotForDisplay() }
        var q = try dashboardQuery(params, extra: ["cursor", "limit", "sort", "direction"])
        var limit = 100
        if let raw = params["limit"] {
            guard case .number(let value) = raw, let n = Int(exactly: NSDecimalNumber(decimal: value)), (1...500).contains(n) else { throw invalidParams() }
            limit = n
        }
        dashboardPrepareCursor(q, from: max(q.from, q.to.addingTimeInterval(-371 * 86400)), to: q.to)
        let fingerprint = requestFingerprint(params)
        let revision = dashboardRevision()
        var offset = 0
        if let raw = params["cursor"] {
            guard case .string(let encoded) = raw, encoded.count <= 4096, let data = Data(base64Encoded: encoded),
                  let cursor = try? JSONDecoder().decode(RequestCursor.self, from: data), cursor.revision == revision,
                  cursor.fingerprint == fingerprint, cursor.offset >= 0, cursor.from < cursor.to else {
                throw HostError(code: "invalid_cursor", message: "Request history changed; reload the first page")
            }
            q.from = cursor.from; q.to = cursor.to; q.asOf = cursor.asOf; offset = cursor.offset
        }
        func option(_ key: String, fallback: String, allowed: Set<String>) throws -> String {
            guard let raw = params[key] else { return fallback }
            guard case .string(let value) = raw, allowed.contains(value) else { throw invalidParams() }
            return value
        }
        let sort = try option("sort", fallback: "time", allowed: ["time", "cost", "tokens"])
        let descending = try option("direction", fallback: "desc", allowed: ["asc", "desc"]) == "desc"
        let records = selectedEvents(q, from: q.from, to: q.to).filter { $0.entry.requestCount > 0 }.sorted { lhs, rhs in
            let a = lhs.entry, b = rhs.entry
            let order: ComparisonResult
            switch sort {
            case "cost": order = NSDecimalNumber(decimal: a.costUSD ?? 0).compare(NSDecimalNumber(decimal: b.costUSD ?? 0))
            case "tokens":
                let x = a.inputTokens + a.outputTokens + a.cacheReadTokens + a.cacheCreationTokens
                let y = b.inputTokens + b.outputTokens + b.cacheReadTokens + b.cacheCreationTokens
                order = x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending)
            default: order = a.timestamp == b.timestamp ? .orderedSame : (a.timestamp < b.timestamp ? .orderedAscending : .orderedDescending)
            }
            if order == .orderedSame { return lhs.id < rhs.id }
            return descending ? order == .orderedDescending : order == .orderedAscending
        }
        guard offset <= records.count else { throw HostError(code: "invalid_cursor", message: "Invalid request cursor") }
        let rows: [HostJSON] = records.dropFirst(offset).prefix(limit).map { record in
            let e = record.entry
            return .object(["id": .string(record.id), "timestamp": dateJSON(e.timestamp), "service": .string(e.app.rawValue),
                "sourceID": .string(dashboardSource(e.app)), "modelID": .string(e.model),
                "totals": totalsJSON(dashboardTotal([eventBucket(e)])), "status": .string("unknown"),
                "conversationID": state.usageService.conversationAggregator.detail(key: e.conversationKey, metric: settings.statsRankMetric) == nil ? .null : .string(opaqueID(e.conversationKey, category: "conversation"))])
        }
        let nextOffset = offset + rows.count
        let cursor: HostJSON
        if nextOffset < records.count {
            let state = RequestCursor(revision: revision, fingerprint: fingerprint, from: q.from, to: q.to, asOf: q.asOf, offset: nextOffset)
            cursor = .string(try JSONEncoder().encode(state).base64EncodedString())
        } else { cursor = .null }
        return .object(["revision": .string(revision), "resolvedRange": dashboardRange(q), "totalCount": .number(Decimal(records.count)), "rows": .array(rows), "nextCursor": cursor, "coverage": dashboardCoverage(q, from: q.from, to: q.to, includeCompleteDays: true), "status": statusJSON()])
    }

    func dashboardHeatmap(_ params: [String: HostJSON]) async throws -> HostJSON {
        if let provider = dashboardIndexProvider { dashboardIndex = await provider() }
        else { dashboardIndex = state.usageService.requestIndexSnapshotForDisplay() }
        let q = try dashboardQuery(params, extra: ["beforeDay"])
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        let end: Date
        if let value = params["beforeDay"] {
            guard case .string(let raw) = value, let parsed = formatter.date(from: raw), formatter.string(from: parsed) == raw,
                  calendar.component(.weekday, from: parsed) == 2 else { throw invalidParams() }
            end = parsed
        } else {
            let day = calendar.startOfDay(for: min(q.to, q.asOf))
            let weekday = calendar.component(.weekday, from: day)
            let delta = (weekday + 5) % 7
            let monday = calendar.date(byAdding: .day, value: -delta, to: day) ?? day
            end = calendar.date(byAdding: .day, value: 7, to: monday) ?? monday
        }
        guard let start = calendar.date(byAdding: .day, value: -371, to: end) else { throw invalidParams() }
        let pageFrom = q.allTime ? start : max(start, q.from)
        let pageTo = min(end, q.to)
        dashboardPrepareCursor(q, from: pageFrom, to: pageTo)
        let buckets = selectedBuckets(q, from: pageFrom, to: pageTo)
        var items: [(Date, UsageTotals)] = []
        var day = start
        while day < end, let next = calendar.date(byAdding: .day, value: 1, to: day) {
            items.append((day, dashboardTotal(buckets.filter { $0.day == day })))
            day = next
        }
        let maximum = items.map { dashboardValue($0.1, metric: q.metric) }.max() ?? 0
        let days: [HostJSON] = items.map { date, totals in
            let value = dashboardValue(totals, metric: q.metric)
            return .object(["day": .string(formatter.string(from: date)), "totals": totalsJSON(totals), "value": numberJSON(value), "label": .string(dashboardLabel(totals, metric: q.metric)), "normalizedValue": numberJSON(maximum > 0 ? value / maximum : 0)])
        }
        let total = dashboardTotal(buckets)
        let earliest = state.usageService.aggregator.snapshot().map(\.day).min()
        let cursorHistoryUnknown = q.allTime && state.cursorAccount?.userID != nil
            && settings.isUsageServiceEffectivelyVisible(.cursor)
            && (q.service == nil || q.service == .cursor)
            && (q.source == nil || q.source == dashboardSource(.cursor))
        let hasOlder = cursorHistoryUnknown || (earliest.map { $0 < start } ?? false)
        return .object(["fromDay": .string(formatter.string(from: start)), "toDay": .string(formatter.string(from: end)), "timeZone": .string(calendar.timeZone.identifier), "days": .array(days), "totals": totalsJSON(total), "nextBeforeDay": hasOlder ? .string(formatter.string(from: start)) : .null, "coverage": dashboardCoverage(q, from: pageFrom, to: pageTo, includeCompleteDays: false), "status": statusJSON()])
    }
}
