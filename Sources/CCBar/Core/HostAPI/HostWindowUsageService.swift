import AppKit
import CryptoKit
import Foundation

enum HostUsageCostPrecision { case standard, precise, whole }

@MainActor
struct HostWindowUsageActions {
    var copyConversationID: (String) throws -> Void
    var revealProject: (String) throws -> Void
    var refreshUsage: () async -> Void
    var loadCursorHistory: (Range<Date>) async -> Void
    var formatCost: (Decimal, HostUsageCostPrecision) -> String = { value, precision in
        switch precision {
        case .standard: CurrencyFormatter.amount(value)
        case .precise: CurrencyFormatter.precise(value)
        case .whole: CurrencyFormatter.whole(value)
        }
    }
    var costDisplayRate: () -> Decimal = { CurrencyStore.shared.convert(1) ?? 1 }
    var formatDisplayCost: (Decimal) -> String = { value in
        let source = CurrencyStore.shared.convert(1) == nil ? "USD" : SettingsStore.shared.displayCurrency.code
        return CurrencyFormatter.amount(value, from: source)
    }

    static func live(state: AppState) -> Self {
        Self(
            copyConversationID: { id in
                NSPasteboard.general.clearContents()
                guard NSPasteboard.general.setString(id, forType: .string) else {
                    throw HostError(code: "operation_failed", message: "Could not copy the conversation ID")
                }
            },
            revealProject: { path in
                guard !path.isEmpty else { throw HostError(code: "invalid_params", message: "Unknown project") }
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            },
            refreshUsage: { await state.usageService.scanNow() },
            loadCursorHistory: { await state.loadCursorUsageHistory(for: $0) }
        )
    }
}

@MainActor
final class HostWindowUsageService {
    static let methods: Set<String> = [
        "window.usage.overview",
        "window.usage.dashboard",
        "window.usage.requests",
        "window.usage.heatmap",
        "usage.refresh",
        "conversations.list",
        "conversations.detail",
        "conversations.copyID",
        "projects.list",
        "projects.detail",
        "projects.reveal",
        "quota.analytics",
    ]

    let state: AppState
    let settings: SettingsStore
    let actions: HostWindowUsageActions
    let now: () -> Date
    // Test fixtures may select an isolated SQLite store; production uses UsageService's store.
    var dashboardStore: UsageRequestIndexStore?
    var dashboardStatusProvider: (() -> UsageRequestIndexStatus)?
    private let overviewCache = StatsOverviewCache()
    private let projectPageCache = ProjectPageCache()
    private var opaqueIDs: [String: String] = [:]
    private var rawIDs: [String: String] = [:]
    private var aliases: [String: Int] = [:]
    private struct CursorRequest: Hashable {
        let accountID: String
        let from: Date
        let to: Date
        var range: Range<Date> { from..<to }
        func contains(_ other: Self) -> Bool {
            accountID == other.accountID && from <= other.from && to >= other.to
        }
    }
    private var cursorTask: Task<Void, Never>?
    private var activeCursorRequest: CursorRequest?
    private var pendingCursorRequest: CursorRequest?
    private var cursorAttempts: [CursorRequest: Date] = [:]
    private var refreshTask: Task<Void, Never>?
    private(set) var generation = 0
    /// The owning Host API uses this for invalidation after background operations.
    var didChange: (() -> Void)?
    var refreshingUsage: Bool { refreshTask != nil }

    init(state: AppState, settings: SettingsStore) {
        self.state = state
        self.settings = settings
        self.actions = .live(state: state)
        self.now = Date.init
    }

    init(state: AppState, settings: SettingsStore, actions: HostWindowUsageActions, now: @escaping () -> Date = Date.init) {
        self.state = state
        self.settings = settings
        self.actions = actions
        self.now = now
    }

    deinit {
        cursorTask?.cancel()
        refreshTask?.cancel()
    }

    func invalidate() {
        generation += 1
        cursorTask?.cancel(); cursorTask = nil
        refreshTask?.cancel(); refreshTask = nil
        activeCursorRequest = nil
        pendingCursorRequest = nil
        cursorAttempts.removeAll()
    }

    static func quotaAccountID(service: String, kind: String, rawID: String? = nil) -> String {
        if kind == "primary" { return "quota.\(service).primary" }
        let digest = SHA256.hash(data: Data((rawID ?? "").utf8)).map { String(format: "%02x", $0) }.joined()
        return "quota.\(service).imported.\(digest)"
    }

    func handle(_ method: String, params: [String: HostJSON]) async throws -> HostJSON {
        guard Self.methods.contains(method) else {
            throw HostError(code: "unknown_method", message: "Unknown method")
        }
        switch method {
        case "window.usage.overview": return try await overview(params)
        case "window.usage.dashboard": return try await dashboard(params)
        case "window.usage.requests": return try await dashboardRequests(params)
        case "window.usage.heatmap": return try await dashboardHeatmap(params)
        case "usage.refresh": return try await refresh(params)
        case "conversations.list": return try conversationList(params)
        case "conversations.detail": return try conversationDetail(params)
        case "conversations.copyID": return try copyConversationID(params)
        case "projects.list": return try await projectList(params)
        case "projects.detail": return try projectDetail(params)
        case "projects.reveal": return try revealProject(params)
        case "quota.analytics": return try await quotaAnalytics(params)
        default: throw HostError(code: "unknown_method", message: "Unknown method")
        }
    }

    // MARK: - Queries

    private func overview(_ params: [String: HostJSON]) async throws -> HostJSON {
        let query = try statsQuery(params)
        prepareCursorHistory(query: query)
        let model = overviewModel(query)
        return .object([
            "revision": .string("\(state.usageService.aggregator.revision):\(state.usageService.conversationAggregator.revision)"),
            "range": .object([
                "from": dateJSON(query.current.from),
                "to": dateJSON(query.current.to),
                "previousFrom": query.previous.map { dateJSON($0.from) } ?? .null,
                "previousTo": query.previous.map { dateJSON($0.to) } ?? .null,
                "chartFrom": dateJSON(query.chart.from),
                "chartTo": dateJSON(query.chart.to),
            ]),
            "visibleServices": .array(model.visibleApps.map { .string($0.rawValue) }),
            "totals": totalsJSON(model.totalsAll),
            "previousTotals": query.previous == nil ? .null : totalsJSON(model.previousTotalsAll),
            "comparison": comparisonJSON(current: model.totalsAll, previous: query.previous == nil ? nil : model.previousTotalsAll),
            "speed": speedJSON(model.speedAll),
            "services": .array(model.visibleApps.map { app in
                let current = model.totals(app)
                let previous = query.previous == nil ? nil : model.previousTotals(app)
                return .object([
                    "service": .string(app.rawValue),
                    "totals": totalsJSON(current),
                    "previousTotals": previous.map { totalsJSON($0) } ?? .null,
                    "comparison": comparisonJSON(current: current, previous: previous),
                    "speed": speedJSON(model.speed(app)),
                    "models": .array(model.modelRows(app).map { modelJSON($0, app: app) }),
                ])
            }),
            "samples": .array(model.samples.map { sample in
                sampleJSON(
                    key: sample.key,
                    start: sample.day,
                    totals: sample.totalUsage,
                    byService: Dictionary(uniqueKeysWithValues: model.visibleApps.map { ($0, sample.totals(for: $0)) }),
                    highlighted: model.highlightedPeriodStart == sample.day
                )
            }),
            "barWidth": .number(Decimal(Double(model.barWidth))),
            "composition": .object(Dictionary(uniqueKeysWithValues: CompositionDimension.allCases.map { dimension in
                (dimension.wireName, .array((model.composition[dimension] ?? []).map { compositionJSON($0, model: model) }))
            })),
            "unattributed": totalsJSON(model.unattributed),
            "topConversations": .array(model.topConversations.map { topConversationJSON($0, total: model.totalsAll) }),
            "topConversationsShare": model.topConversationsShare.map(numberJSON) ?? .null,
            "models": .array(model.visibleApps.flatMap { app in
                model.modelRows(app).map { modelJSON($0, app: app) }
            }),
            "status": statusJSON(),
        ])
    }

    private func refresh(_ params: [String: HostJSON]) async throws -> HostJSON {
        try validateKeys(params, allowed: [])
        guard refreshTask == nil else { return statusJSON() }
        let currentGeneration = generation
        refreshTask = Task { [weak self, refresh = actions.refreshUsage] in
            await refresh()
            guard let self, self.generation == currentGeneration, !Task.isCancelled else { return }
            self.refreshTask = nil
            self.didChange?()
        }
        didChange?()
        return statusJSON()
    }

    private func conversationList(_ params: [String: HostJSON]) throws -> HostJSON {
        let query = try statsQuery(params, additional: ["search", "projectKey", "sort", "offset", "limit"])
        let search = try optionalString(params, key: "search", maximumLength: 500) ?? ""
        let sort = try optionalString(params, key: "sort").map { raw -> ConversationQuerySort in
            guard let value = ConversationQuerySort(rawValue: raw) else { throw invalidParams() }
            return value
        } ?? .recent
        let projectKey = try optionalString(params, key: "projectKey").map { try rawID($0, category: "project") }
        let page = try pagination(params)
        let aggregator = state.usageService.conversationAggregator
        let result = aggregator.query(ConversationQueryRequest(
            revision: aggregator.revision,
            app: query.service,
            projectKey: projectKey,
            from: query.current.from,
            to: query.current.to,
            search: search,
            sort: sort,
            apps: selectedApps(query)
        ))
        return .object([
            "rows": .array(result.rows.dropFirst(page.offset).prefix(page.limit).map { conversationJSON($0) }),
            "total": .number(Decimal(result.rows.count)),
            "offset": .number(Decimal(page.offset)),
            "limit": .number(Decimal(page.limit)),
            "projects": .array(result.projectOptions.sorted(by: { $0.lastAt > $1.lastAt }).map { option in
                .object([
                    "key": .string(opaqueID(option.key, category: "project")),
                    "name": .string(projectName(option.name, key: option.key, status: option.status)),
                    "path": .string(projectPath(option.path, status: option.status)),
                    "status": .string(option.status.rawValue),
                    "conversationCount": .number(Decimal(option.conversationCount)),
                    "lastAt": dateJSON(option.lastAt),
                    "duplicateName": .bool(result.duplicateProjectNames.contains(option.name)),
                ])
            }),
            "status": statusJSON(),
        ])
    }

    private func conversationDetail(_ params: [String: HostJSON]) throws -> HostJSON {
        try validateKeys(params, allowed: ["id", "metric"])
        let id = try requiredString(params, key: "id")
        let key = try rawID(id, category: "conversation")
        let metric = try optionalString(params, key: "metric").map { raw -> StatsRankMetric in
            guard let value = StatsRankMetric(rawValue: raw) else { throw invalidParams() }
            return value
        } ?? settings.statsRankMetric
        guard let detail = state.usageService.conversationAggregator.detail(key: key, metric: metric),
              settings.visibleUsageApps.contains(detail.info.app) else {
            throw HostError(code: "not_found", message: "Unknown conversation")
        }
        let summary = ConversationSummary(
            info: detail.info,
            totals: detail.totals,
            costs: detail.costs,
            speed: detail.speed,
            models: detail.models.map(\.model),
            rangeLastAt: detail.info.lastAt
        )
        return .object([
            "summary": conversationJSON(summary),
            "models": .array(detail.models.map { item in
                var object = modelFields(model: item.model, app: detail.info.app, totals: item.totals, speed: item.speed)
                object["costs"] = costsJSON(item.costs)
                return .object(object)
            }),
        ])
    }

    private func copyConversationID(_ params: [String: HostJSON]) throws -> HostJSON {
        try validateKeys(params, allowed: ["id"])
        guard !settings.privacyMode else { throw privacyDenied() }
        let key = try rawID(requiredString(params, key: "id"), category: "conversation")
        guard let detail = state.usageService.conversationAggregator.detail(key: key, metric: settings.statsRankMetric),
              settings.visibleUsageApps.contains(detail.info.app) else {
            throw HostError(code: "not_found", message: "Unknown conversation")
        }
        try actions.copyConversationID(detail.info.conversationID)
        return mutationJSON()
    }

    private func projectList(_ params: [String: HostJSON]) async throws -> HostJSON {
        let query = try statsQuery(params, additional: ["search", "sort", "offset", "limit"])
        let search = (try optionalString(params, key: "search", maximumLength: 500) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let sort = try optionalString(params, key: "sort").map { raw -> ProjectListSort in
            switch raw {
            case "cost": return .cost
            case "tokens": return .tokens
            case "recent": return .recent
            default: throw invalidParams()
            }
        } ?? ProjectListSort(settings.statsRankMetric)
        let rowMetric: StatsRankMetric = switch sort {
        case .cost: .cost
        case .tokens: .tokens
        case .recent: settings.statsRankMetric
        }
        let page = try pagination(params)
        prepareCursorHistory(query: query)
        let output = projectOutput(query)
        let filtered = output.overview.projects.filter { row in
            guard !search.isEmpty else { return true }
            let title = row.isSpecial
                ? projectName(row.name, key: row.key, status: row.status)
                : row.name
            return "\(title) \(row.path)".lowercased().contains(search)
        }.sorted { lhs, rhs in
            if lhs.isSpecial != rhs.isSpecial { return !lhs.isSpecial }
            if lhs.isSpecial { return lhs.status == .unassigned && rhs.status != .unassigned }
            switch sort {
            case .cost:
                return ConversationAggregator.projectOrder(lhs, rhs, by: .cost)
            case .tokens:
                if lhs.totals.totalTokens == rhs.totals.totalTokens {
                    return ConversationAggregator.projectOrder(lhs, rhs, by: .tokens)
                }
                return lhs.totals.totalTokens > rhs.totals.totalTokens
            case .recent:
                if lhs.lastAt == rhs.lastAt { return ConversationAggregator.projectOrder(lhs, rhs, by: settings.statsRankMetric) }
                return lhs.lastAt > rhs.lastAt
            }
        }
        return .object([
            "rows": .array(filtered.dropFirst(page.offset).prefix(page.limit).map { row in
                .object([
                    "identity": projectJSON(StatsProjectIdentity(key: row.key, name: row.name, path: row.path, status: row.status)),
                    "totals": totalsJSON(row.totals),
                    "speed": speedJSON(row.speed),
                    "totalsByService": totalsByServiceJSON(row.totalsByApp),
                    "sharesByService": sharesByServiceJSON(row.totalsByApp, total: row.totals, metric: rowMetric),
                    "conversationCount": .number(Decimal(row.conversationCount)),
                    "lastAt": dateJSON(row.lastAt),
                    "worktreeCount": .number(Decimal(row.worktreeCount)),
                ])
            }),
            "total": .number(Decimal(filtered.count)),
            "offset": .number(Decimal(page.offset)),
            "limit": .number(Decimal(page.limit)),
            "unattributed": unattributedJSON(output.unattributed, granularity: query.granularity),
            "status": statusJSON(),
        ])
    }

    private func projectDetail(_ params: [String: HostJSON]) throws -> HostJSON {
        let query = try statsQuery(params, additional: ["projectKey"])
        let projectKey = try rawID(requiredString(params, key: "projectKey"), category: "project")
        let aggregator = state.usageService.conversationAggregator
        guard let detail = aggregator.projectDetail(ProjectDetailRequest(
            revision: aggregator.revision,
            projectKey: projectKey,
            from: query.current.from,
            to: query.current.to,
            previous: query.previous.map { $0.from..<$0.to },
            apps: selectedApps(query),
            metric: settings.statsRankMetric
        )) else {
            throw HostError(code: "not_found", message: "Unknown project")
        }
        return .object([
            "project": projectJSON(detail.project),
            "totals": totalsJSON(detail.totals),
            "previousTotals": detail.previousTotals.map { totalsJSON($0) } ?? .null,
            "comparison": comparisonJSON(current: detail.totals, previous: detail.previousTotals),
            "conversationCount": .number(Decimal(detail.conversationCount)),
            "activeDays": .number(Decimal(detail.activeDays)),
            "rangeDayCount": .number(Decimal(rangeDayCount(query: query, firstUsedDay: detail.firstUsedDay))),
            "daily": .array(projectDailyJSON(detail.dailyByApp, granularity: query.granularity)),
            "totalsByService": totalsByServiceJSON(detail.totalsByApp),
            "sharesByService": sharesByServiceJSON(detail.totalsByApp, total: detail.totals, metric: settings.statsRankMetric),
            "models": .array(detail.models.map { model in
                .object([
                    "model": .string(model.model),
                    "services": .array(UsageApp.displayOrdered(model.apps, preferred: settings.visibleUsageApps).map { .string($0.rawValue) }),
                    "totals": totalsJSON(model.totals),
                ])
            }),
            "branches": .array(detail.branches.map { branch in
                .object([
                    "branch": settings.privacyMode ? .null : branch.branch.map(HostJSON.string) ?? .null,
                    "conversationCount": .number(Decimal(branch.conversationCount)),
                    "totals": totalsJSON(branch.totals),
                ])
            }),
            "topConversations": .array(detail.topConversations.map { topConversationJSON($0, total: detail.totals) }),
            "worktrees": .array(detail.worktrees.map { worktree in
                .object([
                    "path": settings.privacyMode ? .string("") : .string(worktree.path),
                    "branch": settings.privacyMode ? .null : worktree.branch.map(HostJSON.string) ?? .null,
                    "main": .bool(worktree.isMain),
                    "totals": totalsJSON(worktree.totals),
                ])
            }),
            "allTimeTotals": totalsJSON(detail.allTimeTotals),
            "firstUsedDay": detail.firstUsedDay.map { dateJSON($0) } ?? .null,
            "gitRepository": detail.project.status == .available
                ? aggregator.isGitRepository(detail.project.path).map(HostJSON.bool) ?? .null
                : .null,
        ])
    }

    private func revealProject(_ params: [String: HostJSON]) throws -> HostJSON {
        try validateKeys(params, allowed: ["projectKey"])
        guard !settings.privacyMode else { throw privacyDenied() }
        let projectKey = try rawID(requiredString(params, key: "projectKey"), category: "project")
        let aggregator = state.usageService.conversationAggregator
        let overview = aggregator.overviewBreakdown(ConversationOverviewRequest(
            revision: aggregator.revision,
            from: .distantPast,
            to: .distantFuture,
            apps: Set(settings.visibleUsageApps),
            topConversationLimit: 0,
            metric: settings.statsRankMetric
        ))
        guard let project = overview.projects.first(where: { $0.key == projectKey }),
              project.status == .available || project.status == .unverified,
              !project.path.isEmpty else {
            throw HostError(code: "not_found", message: "Unknown or unavailable project")
        }
        try actions.revealProject(project.path)
        return mutationJSON()
    }

    private func quotaAnalytics(_ params: [String: HostJSON]) async throws -> HostJSON {
        try validateKeys(params, allowed: ["accountID", "kind"])
        let accountID = try requiredString(params, key: "accountID")
        let rawKind = try requiredString(params, key: "kind")
        guard let kind = QuotaLimitKind(rawValue: rawKind),
              let account = quotaAccounts().first(where: { $0.id == accountID }),
              settings.visibleUsageApps.contains(account.app) else {
            throw invalidParams()
        }
        let currentDate = now()
        guard let historyKey = account.historyKey else {
            return .object([
                "account": quotaAccountJSON(account),
                "cycles": .array([]),
                "timeline": .array([]),
                "window": .null,
                "dailyUsage": dailyUsageJSON(try await quotaDailyUsage(account: account, kind: kind, at: currentDate)),
                "status": statusJSON(),
            ])
        }
        let summaries = state.usageService.cycleAggregator.summaries(
            cycles: state.quotaCycles.records,
            kind: kind,
            app: account.app,
            includeOtherAgents: settings.cycleIncludesOtherAgents,
            now: currentDate
        ).filter { $0.cycle.accountKey == historyKey }
            .sorted { lhs, rhs in
                let leftCurrent = lhs.cycle.isCurrent(at: currentDate), rightCurrent = rhs.cycle.isCurrent(at: currentDate)
                if leftCurrent != rightCurrent { return leftCurrent }
                if leftCurrent {
                    let leftSample = lhs.cycle.lastSampleAt ?? .distantPast
                    let rightSample = rhs.cycle.lastSampleAt ?? .distantPast
                    if leftSample != rightSample { return leftSample > rightSample }
                    if lhs.cycle.boundaryQuality != rhs.cycle.boundaryQuality {
                        return lhs.cycle.boundaryQuality == .observed
                    }
                }
                return lhs.cycle.endAt > rhs.cycle.endAt
            }
        let periods = QuotaHistoryStore.timelinePeriods(
            payload: state.quotaHistory,
            accountKey: historyKey,
            limitKind: kind,
            now: currentDate
        )
        let daily = try await quotaDailyUsage(account: account, kind: kind, at: currentDate)
        return .object([
            "account": quotaAccountJSON(account),
            "window": quotaTimelineWindowJSON(account: account, historyKey: historyKey, kind: kind),
            "cycles": .array(summaries.map { cycleSummaryJSON($0) }),
            "dailyUsage": dailyUsageJSON(daily),
            "timeline": .array(periods.map { period in
                .object([
                    "id": .string(opaqueID(period.id, category: "quota-period")),
                    "kind": .string(period.kind.rawValue),
                    "start": dateJSON(period.start),
                    "end": dateJSON(period.end),
                    "totalDelta": .number(Decimal(period.totalDelta)),
                    "entries": .array(period.entries.map { entry in
                        .object([
                            "id": .string(opaqueID(entry.id, category: "quota-entry")),
                            "source": .string(entry.source == .change ? "change" : "sample"),
                            "sampledAt": dateJSON(entry.sampledAt),
                            "remainingPercent": .number(Decimal(entry.remainingPercent)),
                            "deltaPercent": entry.deltaPercent.map { .number(Decimal($0)) } ?? .null,
                            "resetsAt": entry.resetsAt.map { dateJSON($0) } ?? .null,
                            "windowIndex": .number(Decimal(entry.windowIndex)),
                        ])
                    }),
                ])
            }),
            "status": statusJSON(),
        ])
    }

    private func quotaDailyUsage(account: QuotaAnalyticsAccount, kind: QuotaLimitKind, at date: Date) async throws -> CycleDailyUsage {
        guard kind == .weekly else { return CycleDailyUsage(state: .unavailable, points: []) }
        let payload = state.quotaCycles
        let includeOthers = settings.cycleIncludesOtherAgents
        let privacy = settings.privacyMode
        let visible = settings.visibleUsageApps
        let contextGeneration = generation
        let plan = CycleDailyUsage.plan(app: account.app, accountKey: account.historyKey ?? "",
            payload: payload, buckets: state.usageService.cycleAggregator.snapshot(),
            includeOtherAgents: includeOthers, now: date)
        guard account.historyKey != nil, plan.slices.contains(where: \.selectedAccount) else {
            return plan.empty(.unavailable)
        }
        let data: DashboardData?
        do {
            data = try await queryDetails(plan.queries)
        } catch let error as HostError where error.code == "usage_unavailable" {
            // Request-index availability must not hide a valid official quota card.
            // Cancellation and changed identity/privacy contexts still reject the query.
            data = nil
        }
        guard !Task.isCancelled, generation == contextGeneration,
              settings.privacyMode == privacy, settings.visibleUsageApps == visible,
              settings.cycleIncludesOtherAgents == includeOthers, state.quotaCycles == payload,
              quotaAccounts().first(where: { $0.id == account.id })?.historyKey == account.historyKey else {
            throw HostError(code: "cancelled", message: "Quota query context changed")
        }
        guard let data else { return plan.empty(.unavailable) }
        guard data.status.isReady else { return plan.empty(.loading) }
        return CycleDailyUsage.resolve(plan, results: data.results, canonical: data.canonical, status: data.status)
    }

    // MARK: - Existing business models

    private func overviewModel(_ query: HostStatsQuery) -> StatsOverviewModel {
        let aggregator = state.usageService.aggregator
        let conversations = state.usageService.conversationAggregator
        let input = StatsOverviewInput(
            revision: aggregator.revision,
            current: StatsDateInterval(from: query.current.from, to: query.current.to),
            previous: query.previous.map { StatsDateInterval(from: $0.from, to: $0.to) },
            chart: StatsDateInterval(from: query.chart.from, to: query.chart.to),
            granularity: query.granularity,
            serviceApp: query.service,
            visibleApps: settings.visibleUsageApps,
            highlightedPeriodStart: query.highlightedPeriodStart,
            conversationRevision: conversations.revision,
            rankMetric: settings.statsRankMetric
        )
        return overviewCache.model(
            for: input,
            buckets: { aggregator.snapshot() },
            conversationOverview: {
                conversations.overviewBreakdown(ConversationOverviewRequest(
                    revision: conversations.revision,
                    from: query.current.from,
                    to: query.current.to,
                    apps: selectedApps(query),
                    topConversationLimit: 5,
                    metric: settings.statsRankMetric
                ))
            }
        )
    }

    private func projectOutput(_ query: HostStatsQuery) -> ProjectPageCache.Output {
        let aggregator = state.usageService.aggregator
        let conversations = state.usageService.conversationAggregator
        let input = ProjectPageCache.Input(
            usageRevision: aggregator.revision,
            conversationRevision: conversations.revision,
            from: query.current.from,
            to: query.current.to,
            apps: selectedApps(query),
            metric: settings.statsRankMetric
        )
        return projectPageCache.output(for: input) {
            let overview = conversations.overviewBreakdown(ConversationOverviewRequest(
                revision: conversations.revision,
                from: query.current.from,
                to: query.current.to,
                apps: selectedApps(query),
                topConversationLimit: 5,
                metric: settings.statsRankMetric
            ))
            let unattributed = UnattributedBreakdown.build(
                buckets: aggregator.snapshot(),
                apps: selectedApps(query),
                from: query.current.from,
                to: query.current.to,
                attributedByDayApp: overview.attributedByDayApp
            )
            return ProjectPageCache.Output(overview: overview, unattributed: unattributed)
        }
    }

    private func selectedApps(_ query: HostStatsQuery) -> Set<UsageApp> {
        Set(settings.visibleUsageApps.filter { query.service == nil || $0 == query.service })
    }

    private func rangeDayCount(query: HostStatsQuery, firstUsedDay: Date?) -> Int {
        let calendar = StatsRange.weekStartMondayCalendar
        let instant = now()
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: instant)) ?? instant
        var from = query.current.from
        if query.range == .all { from = firstUsedDay ?? calendar.startOfDay(for: instant) }
        let to = min(query.current.to, tomorrow)
        guard to > from else { return 0 }
        return max(1, calendar.dateComponents([.day], from: calendar.startOfDay(for: from), to: to).day ?? 0)
    }

    func prepareCursorHistory(query: HostStatsQuery) {
        guard query.range != .all,
              let accountID = state.cursorAccount?.userID,
              settings.isUsageServiceEffectivelyVisible(.cursor),
              query.service == nil || query.service == .cursor
        else { return }
        let from = min(query.current.from, query.previous?.from ?? query.current.from, query.chart.from)
        let requested = CursorRequest(accountID: accountID, from: from, to: query.current.to)
        guard !state.usageService.isCursorRemoteUsageCovered(requested.range),
              activeCursorRequest?.contains(requested) != true else { return }
        let instant = now()
        cursorAttempts = cursorAttempts.filter { instant.timeIntervalSince($0.value) < 30 }
        guard cursorAttempts[requested] == nil else { return }
        if activeCursorRequest != nil {
            if let pending = pendingCursorRequest, pending.accountID == accountID {
                pendingCursorRequest = CursorRequest(accountID: accountID, from: min(pending.from, from), to: max(pending.to, query.current.to))
            } else {
                pendingCursorRequest = requested
            }
        } else {
            startCursorHistory(requested)
        }
    }

    private func startCursorHistory(_ request: CursorRequest) {
        guard state.cursorAccount?.userID == request.accountID,
              settings.isUsageServiceEffectivelyVisible(.cursor),
              !state.usageService.isCursorRemoteUsageCovered(request.range) else { return }
        activeCursorRequest = request
        cursorAttempts[request] = now()
        let currentGeneration = generation
        cursorTask = Task { [weak self, load = actions.loadCursorHistory] in
            await load(request.range)
            guard let self, self.generation == currentGeneration, !Task.isCancelled else { return }
            self.cursorTask = nil
            self.activeCursorRequest = nil
            let pending = self.pendingCursorRequest
            self.pendingCursorRequest = nil
            if let pending { self.startCursorHistory(pending) }
            self.didChange?()
        }
    }

    // MARK: - Accounts

    struct QuotaAnalyticsAccount {
        var id: String
        var historyKey: String?
        var app: UsageApp
        var kind: String
        var service: String
        var name: String
        var subtitle: String
        var plan: String?
        var region: String?
        var detected: Bool
        var current: Bool
        var personalAccessToken: Bool
        var enabled: Bool
        var showInMenuBar: Bool
        var showInFloatingHUD: Bool
        var supportsMenuBar: Bool
        var supportsFloatingHUD: Bool
        var keychainAccessBlocked: Bool
        var authorizationRequired: String?
        var sourceLines: [String]
        var snapshot: QuotaSnapshot?
        var refresh: QuotaRefreshState
        var error: String?
    }

    private func quotaAccounts() -> [QuotaAnalyticsAccount] {
        var result: [QuotaAnalyticsAccount] = []
        let codexKey = QuotaHistoryAccountKey.codexPrimary(accountId: state.codexAccount?.accountId)
        result.append(primaryAccount(
            id: "quota.codex.primary",
            historyKey: state.codexAccount == nil ? nil : codexKey,
            app: .codex,
            quotaApp: .codex,
            detected: state.codexAccount != nil,
            name: accountName("Codex", key: codexKey, visible: state.codexAccount?.email),
            plan: state.codexPlanName,
            personalAccessToken: state.codexAccount?.isPersonalAccessToken == true,
            sourceLines: [tr("Codex CLI credentials", "Codex CLI 凭据")]
        ))
        for account in state.importedCodexAccounts {
            let mirrorsPrimary = state.codexAccount != nil && state.importedCodexAccountMirrorsPrimary(account)
            let key = mirrorsPrimary ? codexKey : QuotaHistoryAccountKey.codexImported(id: account.id)
            let visibleName = !account.alias.isEmpty ? account.alias : account.email
            result.append(QuotaAnalyticsAccount(
                id: importedAccountID(service: "codex", rawID: account.id),
                historyKey: key,
                app: .codex,
                kind: "importedCodex",
                service: "codex",
                name: accountName("Codex", key: key, visible: visibleName),
                subtitle: account.planType ?? tr("Imported Codex account", "导入的 Codex 账号"),
                plan: CodexAccount.planName(account.planType ?? state.importedCodexQuota(for: account)?.planType),
                region: nil,
                detected: true,
                current: mirrorsPrimary,
                personalAccessToken: account.isPersonalAccessToken == true,
                enabled: account.visibleInPopover,
                showInMenuBar: account.showInMenuBar == true,
                showInFloatingHUD: account.showInFloatingHUD == true,
                supportsMenuBar: true,
                supportsFloatingHUD: true,
                keychainAccessBlocked: false,
                authorizationRequired: nil,
                sourceLines: [tr("Imported Codex account", "导入的 Codex 账号")],
                snapshot: state.importedCodexQuota(for: account),
                refresh: state.importedCodexRefreshState(for: account),
                error: state.importedCodexError(for: account)
            ))
        }
        let claudeKey = QuotaHistoryAccountKey.claudePrimary(
            email: state.claudeAccount?.email,
            accountUuid: state.claudeAccount?.accountUuid
        )
        result.append(primaryAccount(
            id: "quota.claude.primary",
            historyKey: state.claudeAccount == nil ? nil : claudeKey,
            app: .claude,
            quotaApp: .claude,
            detected: state.claudeAccount != nil,
            name: accountName("Claude Code", key: claudeKey, visible: state.claudeDisplayEmail),
            plan: state.claudePlanName,
            personalAccessToken: false,
            sourceLines: [tr("Claude Code credentials", "Claude Code 凭据")]
        ))
        let kimiKey = QuotaHistoryAccountKey.kimiPrimary(accountKey: state.kimiAccount?.accountKey)
        result.append(primaryAccount(
            id: "quota.kimi.primary",
            historyKey: state.kimiAccount == nil ? nil : kimiKey,
            app: .kimi,
            quotaApp: .kimi,
            detected: state.kimiAccount != nil,
            name: accountName("Kimi Code", key: kimiKey, visible: state.kimiNickname ?? state.kimiEmail),
            plan: state.kimiPlanName ?? state.kimiQuota?.planType,
            personalAccessToken: false,
            sourceLines: [tr("Kimi Code CLI credentials", "Kimi Code CLI 凭据")],
            region: state.kimiCLIRegion?.rawValue
        ))
        for account in state.kimiManagedAccounts {
            let mirrorsPrimary = state.kimiAccount != nil && state.kimiManagedMirrorsCLI(account)
            let key = mirrorsPrimary ? kimiKey : state.kimiManagedQuotaCacheRecords[account.id]?.accountID
            result.append(QuotaAnalyticsAccount(
                id: importedAccountID(service: "kimi", rawID: account.id),
                historyKey: key,
                app: .kimi,
                kind: "managedKimi",
                service: "kimi",
                name: accountName("Kimi Code", key: account.id, visible: account.nickname),
                subtitle: settings.privacyMode
                    ? (account.userLevelName ?? state.kimiManagedQuotas[account.id]?.planType ?? tr("Signed in", "已登录"))
                    : state.kimiManagedSubtitle(account),
                plan: account.userLevelName ?? state.kimiManagedQuotas[account.id]?.planType,
                region: account.region.rawValue,
                detected: true,
                current: mirrorsPrimary,
                personalAccessToken: false,
                enabled: account.visibleInPopover,
                showInMenuBar: account.showInMenuBar,
                showInFloatingHUD: account.showInFloatingHUD,
                supportsMenuBar: true,
                supportsFloatingHUD: true,
                keychainAccessBlocked: false,
                authorizationRequired: nil,
                sourceLines: [tr("CCBar managed Kimi account", "CCBar 托管的 Kimi 账号")],
                snapshot: state.kimiManagedQuotas[account.id],
                refresh: state.kimiManagedRefreshStates[account.id] ?? QuotaRefreshState(),
                error: state.kimiManagedErrors[account.id]
            ))
        }
        return result
    }

    private func primaryAccount(
        id: String,
        historyKey: String?,
        app: UsageApp,
        quotaApp: QuotaApp,
        detected: Bool,
        name: String,
        plan: String?,
        personalAccessToken: Bool,
        sourceLines: [String],
        region: String? = nil
    ) -> QuotaAnalyticsAccount {
        let descriptor = QuotaProviderDescriptor.descriptor(for: quotaApp)
        return QuotaAnalyticsAccount(
            id: id,
            historyKey: historyKey,
            app: app,
            kind: "primary",
            service: app.rawValue,
            name: name,
            subtitle: plan ?? (detected ? tr("Signed in", "已登录") : tr("Not signed in", "未登录")),
            plan: plan,
            region: region,
            detected: detected,
            current: true,
            personalAccessToken: personalAccessToken,
            enabled: settings.isProviderEnabled(quotaApp),
            showInMenuBar: settings.isProviderShownInMenuBar(quotaApp),
            showInFloatingHUD: settings.isProviderShownInFloatingHUD(quotaApp),
            supportsMenuBar: descriptor?.supportsMenuBar ?? false,
            supportsFloatingHUD: descriptor?.supportsFloatingHUD ?? false,
            keychainAccessBlocked: quotaApp == .claude && state.claudeDesktopAccessDenied,
            authorizationRequired: quotaApp == .claude && state.claudeDesktopAccessDenied ? "claudeDesktop" : nil,
            sourceLines: sourceLines,
            snapshot: state.quotaSnapshot(for: quotaApp),
            refresh: state.refreshState(for: quotaApp),
            error: state.quotaError(for: quotaApp)
        )
    }

    private func importedAccountID(service: String, rawID: String) -> String {
        Self.quotaAccountID(service: service, kind: "imported", rawID: rawID)
    }

    private func accountName(_ service: String, key: String, visible: String?) -> String {
        if settings.privacyMode { return "\(service) · \(alias(key, category: "account"))" }
        guard let visible = visible?.trimmingCharacters(in: .whitespacesAndNewlines), !visible.isEmpty else {
            return service
        }
        return visible
    }

    // MARK: - Opaque IDs and privacy

    func opaqueID(_ raw: String, category: String) -> String {
        let key = "\(category)|\(raw)"
        if let existing = opaqueIDs[key] { return existing }
        let id = "\(category).\(UUID().uuidString.lowercased())"
        opaqueIDs[key] = id
        rawIDs[id] = key
        return id
    }

    func rawID(_ id: String, category: String) throws -> String {
        guard let key = rawIDs[id], key.hasPrefix("\(category)|") else {
            throw HostError(code: "not_found", message: "Unknown \(category)")
        }
        return String(key.dropFirst(category.count + 1))
    }

    func alias(_ raw: String, category: String) -> String {
        let key = "\(category)|\(raw)"
        let number: Int
        if let existing = aliases[key] {
            number = existing
        } else {
            number = aliases.filter { $0.key.hasPrefix("\(category)|") }.count + 1
            aliases[key] = number
        }
        let suffix = String(format: "%02d", number)
        switch category {
        case "project": return tr("Project \(suffix)", "项目 \(suffix)")
        case "conversation": return tr("Conversation \(suffix)", "对话 \(suffix)")
        default: return tr("Account \(suffix)", "账号 \(suffix)")
        }
    }

    func projectName(_ name: String, key: String, status: ConversationProjectStatus) -> String {
        switch status {
        case .unassigned: return tr("No project", "无明确项目")
        case .system: return tr("CCBar system tasks", "CCBar 系统任务")
        case .available, .unavailable, .unverified:
            return settings.privacyMode ? alias(key, category: "project") : name
        }
    }

    func projectPath(_ path: String, status: ConversationProjectStatus) -> String {
        settings.privacyMode && status.isPathBased ? "" : path
    }

    func privateText(_ value: String?) -> String? {
        guard let value else { return nil }
        return settings.privacyMode
            ? tr("Operation failed. Turn off privacy mode to view details.", "操作失败，关闭隐私模式可查看详情。")
            : Redact.scrub(value)
    }

    // MARK: - Validation

    struct HostStatsQuery {
        var range: StatsRange
        var granularity: StatsGranularity
        var service: UsageApp?
        var current: (from: Date, to: Date)
        var previous: (from: Date, to: Date)?
        var chart: (from: Date, to: Date)
        var highlightedPeriodStart: Date?
    }

    private func statsQuery(
        _ params: [String: HostJSON],
        additional: Set<String> = []
    ) throws -> HostStatsQuery {
        try validateKeys(params, allowed: Set(["range", "granularity", "customFrom", "customTo", "service"]).union(additional))
        let range = try statsRange(requiredString(params, key: "range"))
        let granularity = try statsGranularity(requiredString(params, key: "granularity"))
        guard granularity.ranges.contains(range) else { throw invalidParams() }
        let service = try optionalString(params, key: "service").map { raw -> UsageApp in
            guard let app = UsageApp(rawValue: raw) else { throw invalidParams() }
            return app
        }
        var customFrom = Date()
        var customTo = Date()
        if range == .custom {
            guard let fromString = try optionalString(params, key: "customFrom"),
                  let toString = try optionalString(params, key: "customTo"),
                  let from = localDate(fromString),
                  let to = localDate(toString),
                  from <= to else { throw invalidParams() }
            customFrom = from
            customTo = to
        } else if params["customFrom"] != nil || params["customTo"] != nil {
            throw invalidParams()
        }
        let now = now()
        let current = range.bounds(now: now, customFrom: customFrom, customTo: customTo)
        guard current.from < current.to else { throw invalidParams() }
        let previous = range.previousBounds(now: now, customFrom: customFrom, customTo: customTo)
        let highlighted = highlightedPeriod(range: range, granularity: granularity, current: current)
        let chart = chartBounds(
            range: range,
            granularity: granularity,
            current: current,
            highlightedPeriodStart: highlighted
        )
        return HostStatsQuery(
            range: range,
            granularity: granularity,
            service: service,
            current: current,
            previous: previous,
            chart: chart,
            highlightedPeriodStart: highlighted
        )
    }

    private func highlightedPeriod(
        range: StatsRange,
        granularity: StatsGranularity,
        current: (from: Date, to: Date)
    ) -> Date? {
        guard range != .all else { return nil }
        let calendar = StatsRange.weekStartMondayCalendar
        let first = granularity.bucketStart(for: calendar.startOfDay(for: current.from))
        let lastDay = calendar.startOfDay(for: current.to.addingTimeInterval(-1))
        return first == granularity.bucketStart(for: lastDay) ? first : nil
    }

    private func chartBounds(
        range: StatsRange,
        granularity: StatsGranularity,
        current: (from: Date, to: Date),
        highlightedPeriodStart: Date?
    ) -> (from: Date, to: Date) {
        guard range != .all, let highlightedPeriodStart else { return current }
        let from = StatsRange.weekStartMondayCalendar.date(
            byAdding: granularity.contextWindowComponent,
            value: -(granularity.contextWindowPeriods - 1),
            to: highlightedPeriodStart
        ) ?? current.from
        return (min(from, current.from), current.to)
    }

    private func statsRange(_ raw: String) throws -> StatsRange {
        switch raw {
        case "today": return .today
        case "yesterday": return .yesterday
        case "last7": return .last7
        case "last30": return .last30
        case "thisWeek": return .thisWeek
        case "lastWeek": return .lastWeek
        case "last4Weeks": return .last4Weeks
        case "last12Weeks": return .last12Weeks
        case "thisMonth": return .thisMonth
        case "lastMonth": return .lastMonth
        case "last6Months": return .last6Months
        case "thisYear": return .thisYear
        case "all": return .all
        case "custom": return .custom
        default: throw invalidParams()
        }
    }

    private func statsGranularity(_ raw: String) throws -> StatsGranularity {
        switch raw {
        case "day": return .day
        case "week": return .week
        case "month": return .month
        default: throw invalidParams()
        }
    }

    private func localDate(_ raw: String) -> Date? {
        guard raw.count == 10 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = StatsRange.weekStartMondayCalendar
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: raw), formatter.string(from: date) == raw else { return nil }
        return StatsRange.weekStartMondayCalendar.startOfDay(for: date)
    }

    private func pagination(_ params: [String: HostJSON]) throws -> (offset: Int, limit: Int) {
        let offset = try optionalInteger(params, key: "offset") ?? 0
        let limit = try optionalInteger(params, key: "limit") ?? 200
        guard (0...10_000_000).contains(offset), (1...500).contains(limit) else { throw invalidParams() }
        return (offset, limit)
    }

    private func optionalInteger(_ params: [String: HostJSON], key: String) throws -> Int? {
        guard let value = params[key] else { return nil }
        guard case .number(let decimal) = value else { throw invalidParams() }
        // Converting via Double rounds Int.max to 2^63 and can trap in Int(...).
        guard let integer = Int(exactly: NSDecimalNumber(decimal: decimal)) else { throw invalidParams() }
        return integer
    }

    private func requiredString(_ params: [String: HostJSON], key: String) throws -> String {
        guard case .string(let value)? = params[key], !value.isEmpty else { throw invalidParams() }
        return value
    }

    private func optionalString(
        _ params: [String: HostJSON],
        key: String,
        maximumLength: Int? = nil
    ) throws -> String? {
        guard let value = params[key] else { return nil }
        guard case .string(let string) = value, maximumLength.map({ string.count <= $0 }) ?? true else {
            throw invalidParams()
        }
        return string
    }

    func validateKeys(_ params: [String: HostJSON], allowed: Set<String>) throws {
        guard Set(params.keys).isSubset(of: allowed) else { throw invalidParams() }
    }

    func invalidParams() -> HostError {
        HostError(code: "invalid_params", message: "Invalid parameters")
    }

    private func privacyDenied() -> HostError {
        HostError(code: "permission_denied", message: "This action is unavailable in privacy mode")
    }

    private func mutationJSON() -> HostJSON {
        .object(["ok": .bool(true)])
    }
}
