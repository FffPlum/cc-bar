import Foundation

@MainActor
extension HostWindowUsageService {
    func dateJSON(_ date: Date) -> HostJSON {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return .string(formatter.string(from: date))
    }

    func numberJSON(_ value: Double) -> HostJSON {
        .number(Decimal(value))
    }

    func decimalJSON(_ value: Decimal) -> HostJSON {
        .string(value.asPlainString)
    }

    func totalsJSON(_ totals: UsageTotals) -> HostJSON {
        let includeEstimated = settings.piEstimatedOutputSpeed
        return .object([
            "inputTokens": .number(Decimal(totals.inputTokens)),
            "outputTokens": .number(Decimal(totals.outputTokens)),
            "cacheReadTokens": .number(Decimal(totals.cacheReadTokens)),
            "cacheCreationTokens": .number(Decimal(totals.cacheCreationTokens)),
            "inputWithCacheTokens": .number(Decimal(totals.inputWithCacheTokens)),
            "totalTokens": .number(Decimal(totals.totalTokens)),
            "costUSD": decimalJSON(totals.costUSD),
            "costDisplay": .string(actions.formatCost(totals.costUSD, .standard)),
            "requestCount": .number(Decimal(totals.requestCount)),
            "cacheHitRate": numberJSON(totals.cacheHitRate),
            "hasUnpricedUsage": .bool(totals.hasUnpricedUsage),
            "costIncomplete": .bool(totals.costIncomplete),
            "averageFirstTokenSeconds": totals.timing.averageFirstTokenSeconds.map(numberJSON) ?? .null,
            "outputTokensPerSecond": totals.timing.outputTokensPerSecond(includingEstimated: includeEstimated).map(numberJSON) ?? .null,
            "usesEstimatedSpeed": .bool(totals.timing.usesEstimatedSpeed(includingEstimated: includeEstimated)),
        ])
    }

    func speedJSON(_ speed: UsageSpeedBreakdown) -> HostJSON {
        .object([
            "summary": .string(speed.summary.rawValue),
            "standard": totalsJSON(speed.standard),
            "fast": totalsJSON(speed.fast),
            "unknown": totalsJSON(speed.unknown),
            "fastBillingEquivalentTokens": decimalJSON(speed.fastBillingEquivalentTokens),
            "fastMinimumMultiplier": speed.fastMinimumMultiplier.map(decimalJSON) ?? .null,
            "fastMaximumMultiplier": speed.fastMaximumMultiplier.map(decimalJSON) ?? .null,
            "hasUnpricedFastEquivalent": .bool(speed.hasUnpricedFastEquivalent),
        ])
    }

    func comparisonJSON(current: UsageTotals, previous: UsageTotals?) -> HostJSON {
        func delta(_ current: Double, _ previous: Double) -> Double? {
            guard previous > 0, current > 0 else { return nil }
            return (current - previous) / previous * 100
        }
        guard let previous else {
            return .object(["tokens": .null, "costUSD": .null, "requests": .null])
        }
        let cost: Decimal?
        if previous.costUSD > 0, current.costUSD > 0 {
            cost = (current.costUSD - previous.costUSD) / previous.costUSD * 100
        } else {
            cost = nil
        }
        return .object([
            "tokens": delta(Double(current.totalTokens), Double(previous.totalTokens)).map(numberJSON) ?? .null,
            "costUSD": cost.map(decimalJSON) ?? .null,
            "requests": delta(Double(current.requestCount), Double(previous.requestCount)).map(numberJSON) ?? .null,
        ])
    }

    func sampleJSON(
        key: String,
        start: Date,
        totals: UsageTotals,
        byService: [UsageApp: UsageTotals],
        highlighted: Bool
    ) -> HostJSON {
        .object([
            "key": .string(key),
            "start": dateJSON(start),
            "totals": totalsJSON(totals),
            "byService": totalsByServiceJSON(byService),
            "highlighted": .bool(highlighted),
        ])
    }

    func modelFields(
        model: String,
        app: UsageApp,
        totals: UsageTotals,
        speed: UsageSpeedBreakdown
    ) -> [String: HostJSON] {
        [
            "model": .string(model),
            "service": .string(app.rawValue),
            "totals": totalsJSON(totals),
            "speed": speedJSON(speed),
        ]
    }

    func modelJSON(_ row: ModelRow, app: UsageApp) -> HostJSON {
        .object(modelFields(model: row.model, app: app, totals: row.totals, speed: row.speed))
    }

    func modelJSON(_ row: ProviderModelRow) -> HostJSON {
        .object(modelFields(model: row.model, app: row.app, totals: row.totals, speed: row.speed))
    }

    func compositionJSON(_ row: CompositionRow, model: StatsOverviewModel) -> HostJSON {
        let action: (type: String, value: String?)
        let id: String
        switch row.action {
        case .none:
            action = ("none", nil)
            id = row.id
        case .selectService(let app):
            action = ("selectService", app.rawValue)
            id = row.id
        case .expandProvider(let provider):
            action = ("expandProvider", provider.rawValue)
            id = row.id
        case .expandModel(let model):
            action = ("expandModel", model)
            id = row.id
        case .openProject(let key):
            let opaque = opaqueID(key, category: "project")
            action = ("openProject", opaque)
            id = "project:\(opaque)"
        case .openUnattributed:
            action = ("openUnattributed", nil)
            id = row.id
        }

        let title: String
        let subtitle: String
        switch row.kind {
        case .unattributed:
            title = tr("Unattributed", "未归属")
            subtitle = tr(
                "Cursor remote, backfilled and early history have no project info",
                "Cursor 远端用量、补录和早期历史，没有项目信息"
            )
        case .item:
            switch row.projectStatus {
            case .unassigned:
                title = tr("No project", "无明确项目")
                subtitle = tr("Started from home or a temporary folder", "从主目录或临时目录启动的对话")
            case .system:
                title = tr("CCBar system tasks", "CCBar 系统任务")
                subtitle = tr("Usage created by CCBar background tasks", "CCBar 后台任务产生的用量")
            case .available, .unavailable, .unverified:
                if case .openProject(let key) = row.action {
                    title = settings.privacyMode ? alias(key, category: "project") : row.title
                    subtitle = settings.privacyMode ? "" : row.subtitle
                } else {
                    title = row.title
                    subtitle = row.subtitle
                }
            case nil:
                title = row.title
                subtitle = row.subtitle
            }
        }

        let color: [String: HostJSON]
        switch row.color {
        case .service(let app): color = ["role": .string("service"), "service": .string(app.rawValue)]
        case .rank(let rank): color = ["role": .string("rank"), "rank": .number(Decimal(rank))]
        case .rest: color = ["role": .string("rest")]
        case .unattributed: color = ["role": .string("unattributed")]
        }
        var actionObject: [String: HostJSON] = ["type": .string(action.type)]
        if let value = action.value { actionObject["value"] = .string(value) }
        return .object([
            "id": .string(id),
            "kind": .string(row.kind == .item ? "item" : "unattributed"),
            "title": .string(title),
            "subtitle": .string(subtitle),
            "totals": totalsJSON(row.totals),
            "speed": row.speed.map { speedJSON($0) } ?? .null,
            "share": numberJSON(model.share(of: row.totals)),
            "color": .object(color),
            "action": .object(actionObject),
            "models": .array(row.providerModels.map { modelJSON($0) }),
            "sources": .array(row.modelSources.map { modelJSON($0) }),
            "services": .array(row.apps.map { .string($0.rawValue) }),
            "projectStatus": row.projectStatus.map { .string($0.rawValue) } ?? .null,
        ])
    }

    func projectJSON(_ project: StatsProjectIdentity) -> HostJSON {
        .object([
            "key": .string(opaqueID(project.key, category: "project")),
            "name": .string(projectName(project.name, key: project.key, status: project.status)),
            "path": .string(projectPath(project.path, status: project.status)),
            "status": .string(project.status.rawValue),
        ])
    }

    func conversationJSON(_ summary: ConversationSummary) -> HostJSON {
        let info = summary.info
        let id = opaqueID(info.key, category: "conversation")
        let project = state.usageService.conversationAggregator.statsProjectIdentity(for: info)
        return .object([
            "id": .string(id),
            "conversationID": .string(settings.privacyMode ? id : info.conversationID),
            "service": .string(info.app.rawValue),
            "title": settings.privacyMode
                ? .string(alias(info.key, category: "conversation"))
                : info.title.map(HostJSON.string) ?? .string(tr("Untitled", "（无标题）")),
            "project": projectJSON(project),
            "gitBranch": settings.privacyMode ? .null : info.gitBranch.map(HostJSON.string) ?? .null,
            "firstAt": dateJSON(info.firstAt),
            "lastAt": dateJSON(info.lastAt),
            "rangeLastAt": dateJSON(summary.rangeLastAt),
            "includesSubtasks": .bool(info.includesSubtasks),
            "cacheCreationAvailable": .bool(info.cacheCreationAvailable),
            "totals": totalsJSON(summary.totals),
            "costs": costsJSON(summary.costs),
            "speed": speedJSON(summary.speed),
            "models": .array(summary.models.map(HostJSON.string)),
        ])
    }

    func costsJSON(_ costs: ConversationCostTotals) -> HostJSON {
        .object([
            "input": decimalJSON(costs.input),
            "output": decimalJSON(costs.output),
            "cacheRead": decimalJSON(costs.cacheRead),
            "cacheCreation": decimalJSON(costs.cacheCreation),
            "total": decimalJSON(costs.total),
            "displayInput": .string(actions.formatCost(costs.input, .precise)),
            "displayOutput": .string(actions.formatCost(costs.output, .precise)),
            "displayCacheRead": .string(actions.formatCost(costs.cacheRead, .precise)),
            "displayCacheCreation": .string(actions.formatCost(costs.cacheCreation, .precise)),
            "displayTotal": .string(actions.formatCost(costs.total, .standard)),
            "hasUnpricedUsage": .bool(costs.hasUnpricedUsage),
        ])
    }

    func topConversationJSON(_ row: TopConversationRow, total: UsageTotals) -> HostJSON {
        .object([
            "summary": conversationJSON(row.summary),
            "project": projectJSON(row.project),
            "share": numberJSON(settings.statsRankMetric.share(of: row.summary.totals, in: total)),
        ])
    }

    func totalsByServiceJSON(_ totals: [UsageApp: UsageTotals]) -> HostJSON {
        .object(Dictionary(uniqueKeysWithValues: totals.map { ($0.key.rawValue, totalsJSON($0.value)) }))
    }

    func sharesByServiceJSON(_ values: [UsageApp: UsageTotals], total: UsageTotals, metric: StatsRankMetric) -> HostJSON {
        .object(Dictionary(uniqueKeysWithValues: values.map { ($0.key.rawValue, numberJSON(metric.share(of: $0.value, in: total))) }))
    }

    func unattributedJSON(_ breakdown: UnattributedBreakdown, granularity: StatsGranularity) -> HostJSON {
        .object([
            "total": totalsJSON(breakdown.total),
            "cursor": totalsJSON(breakdown.cursor),
            "local": totalsJSON(breakdown.local),
            "localServices": .array(breakdown.localApps.map { .string($0.rawValue) }),
            "localFirstDay": breakdown.localFirstDay.map { dateJSON($0) } ?? .null,
            "localLastDay": breakdown.localLastDay.map { dateJSON($0) } ?? .null,
            "dailyCursor": .array(residualPeriodSamples(
                daily: breakdown.dailyCursor,
                granularity: granularity,
                service: .cursor
            )),
            "dailyLocal": .array(residualPeriodSamples(
                daily: breakdown.dailyLocal,
                granularity: granularity,
                service: nil
            )),
            "overviewTotals": totalsJSON(breakdown.overviewTotals),
            "overviewShare": breakdown.overviewTotals.costUSD > 0 || breakdown.overviewTotals.totalTokens > 0
                ? numberJSON(StatsRankMetric.cost.share(of: breakdown.total, in: breakdown.overviewTotals)) : .null,
        ])
    }

    func projectDailyJSON(
        _ daily: [UsageDayAppKey: UsageTotals],
        granularity: StatsGranularity
    ) -> [HostJSON] {
        var grouped: [Date: [UsageApp: UsageTotals]] = [:]
        for (key, totals) in daily {
            grouped[granularity.bucketStart(for: key.day), default: [:]][key.app, default: .zero].add(totals)
        }
        return periodSamples(daily: grouped, granularity: granularity)
    }

    private func residualPeriodSamples(
        daily: [Date: UsageTotals],
        granularity: StatsGranularity,
        service: UsageApp?
    ) -> [HostJSON] {
        var grouped: [Date: UsageTotals] = [:]
        for (day, totals) in daily {
            grouped[granularity.bucketStart(for: day), default: .zero].add(totals)
        }
        return grouped.keys.sorted().map { day in
            let totals = grouped[day] ?? .zero
            return sampleJSON(
                key: StatsPeriodKey.key(for: day),
                start: day,
                totals: totals,
                byService: service.map { [$0: totals] } ?? [:],
                highlighted: false
            )
        }
    }

    private func periodSamples(
        daily: [Date: [UsageApp: UsageTotals]],
        granularity: StatsGranularity
    ) -> [HostJSON] {
        daily.keys.sorted().map { day in
            let byService = daily[day] ?? [:]
            let total = byService.values.reduce(into: UsageTotals.zero) { $0.add($1) }
            return sampleJSON(
                key: StatsPeriodKey.key(for: day),
                start: day,
                totals: total,
                byService: byService,
                highlighted: false
            )
        }
    }

    func cycleSummaryJSON(_ summary: CycleUsageSummary) -> HostJSON {
        let cycle = summary.cycle
        return .object([
            "cycle": .object([
                "id": .string(opaqueID(cycle.id, category: "quota-cycle")),
                "service": .string(cycle.app.rawValue),
                "limitID": .string(cycle.limitID),
                "kind": .string(cycle.limitKind.rawValue),
                "startAt": dateJSON(cycle.startAt),
                "endAt": dateJSON(cycle.endAt),
                "scheduledEndAt": dateJSON(cycle.scheduledEndAt),
                "firstSampleAt": cycle.firstSampleAt.map { dateJSON($0) } ?? .null,
                "lastSampleAt": cycle.lastSampleAt.map { dateJSON($0) } ?? .null,
                "latestUsedPercent": numberJSON(cycle.latestUsedPercent),
                "reportedUsedPercent": numberJSON(cycle.reportedUsedPercent),
                "boundaryQuality": .string(cycle.boundaryQuality.rawValue),
                "current": .bool(cycle.isCurrent(at: now())),
                "extraResetCount": .number(Decimal(cycle.extraResetCount)),
            ]),
            "totals": totalsJSON(summary.totals),
            "currentAllowanceTotals": totalsJSON(summary.currentAllowanceTotals),
            "quality": .string(summary.quality.rawValue),
            "estimatedFullAllowanceTokens": summary.estimatedFullAllowanceTokens.map { .number(Decimal($0)) } ?? .null,
            "estimatedFullAllowanceCostUSD": summary.estimatedFullAllowanceCostUSD.map(decimalJSON) ?? .null,
            "estimatedFullAllowanceCostDisplay": summary.estimatedFullAllowanceCostUSD.map { .string(actions.formatCost($0, .whole)) } ?? .null,
            "forecastConfidence": summary.forecastConfidence.map { .string($0.wireName) } ?? .null,
        ])
    }

    func dailyUsageJSON(_ daily: CycleDailyUsage) -> HostJSON {
        .object([
            "basis": .string("weekly-estimate"),
            "state": .string(daily.state.rawValue),
            "points": .array(daily.points.map { point in
                .object([
                    "day": dateJSON(point.day),
                    "tokens": point.tokens.map { .number(Decimal($0)) } ?? .null,
                    "estimatedUsedPercent": point.estimatedUsedPercent.map { .number(Decimal($0)) } ?? .null,
                    "partial": .bool(point.partial),
                ])
            }),
        ])
    }

    func quotaAccountJSON(_ account: QuotaAnalyticsAccount) -> HostJSON {
        .object([
            "id": .string(account.id),
            "kind": .string(account.kind),
            "service": .string(account.service),
            "name": .string(account.name),
            "subtitle": .string(account.subtitle),
            "plan": account.plan.map(HostJSON.string) ?? .null,
            "region": account.region.map(HostJSON.string) ?? .null,
            "detected": .bool(account.detected),
            "current": .bool(account.current),
            "personalAccessToken": .bool(account.personalAccessToken),
            "enabled": .bool(account.enabled),
            "showInMenuBar": .bool(account.showInMenuBar),
            "showInFloatingHUD": .bool(account.showInFloatingHUD),
            "supportsMenuBar": .bool(account.supportsMenuBar),
            "supportsFloatingHUD": .bool(account.supportsFloatingHUD),
            "keychainAccessBlocked": .bool(account.keychainAccessBlocked),
            "authorizationRequired": account.authorizationRequired.map(HostJSON.string) ?? .null,
            "sourceLines": .array(account.sourceLines.map(HostJSON.string)),
            "sourceOwned": .bool(account.kind == "primary"),
            "sourceApplication": account.kind == "primary" ? .string(account.service) : .null,
            "needsRefresh": .bool(account.detected && account.snapshot == nil),
            "snapshot": account.snapshot.map(quotaSnapshotJSON) ?? .null,
            "balance": .null,
            "refresh": quotaRefreshJSON(account.refresh, error: account.error),
        ])
    }

    func quotaTimelineWindowJSON(account: QuotaAnalyticsAccount, historyKey: String, kind: QuotaLimitKind) -> HostJSON {
        let sample = state.quotaHistory.lastSamples[QuotaHistoryStore.seriesKey(accountKey: historyKey, limitKind: kind)]
        let window = account.snapshot?.allLimits.first(where: { $0.kind == kind })?.window
        let hasEvents = state.quotaHistory.events.contains { $0.accountKey == historyKey && $0.limitKind == kind }
        guard sample != nil || window != nil || hasEvents else { return .null }
        let remaining = sample.map { Double($0.remainingPercent) }
            ?? window.map { max(0, min(100, $0.remainingPercent.rounded())) }
        return .object([
            "kind": .string(kind.rawValue),
            "remainingPercent": remaining.map(numberJSON) ?? .null,
            "latestSampleAt": sample.map { dateJSON($0.sampledAt) } ?? .null,
            "resetsAt": window?.resetsAt.map { dateJSON($0) } ?? .null,
        ])
    }

    private func quotaSnapshotJSON(_ snapshot: QuotaSnapshot) -> HostJSON {
        .object([
            "fetchedAt": dateJSON(snapshot.fetchedAt),
            "planType": snapshot.planType.map(HostJSON.string) ?? .null,
            "unlimited": snapshot.isUnlimited.map(HostJSON.bool) ?? .null,
            "limits": .array(snapshot.allLimits.map { limit in
                .object([
                    "id": .string(limit.id),
                    "kind": .string(limit.kind.rawValue),
                    "displayName": limit.displayName.map(HostJSON.string) ?? .null,
                    "usedPercent": numberJSON(limit.window.usedPercent),
                    "resetsAt": limit.window.resetsAt.map { dateJSON($0) } ?? .null,
                    "windowSeconds": limit.window.windowSeconds.map { .number(Decimal($0)) } ?? .null,
                    "active": limit.isActive.map(HostJSON.bool) ?? .null,
                ])
            }),
        ])
    }

    private func quotaRefreshJSON(_ refresh: QuotaRefreshState, error: String?) -> HostJSON {
        .object([
            "inFlight": .bool(refresh.inFlight),
            "backoffUntil": refresh.backoffUntil.map { dateJSON($0) } ?? .null,
            "lastSuccessAt": refresh.lastSuccessAt.map { dateJSON($0) } ?? .null,
            "lastAttemptAt": refresh.lastAttemptAt.map { dateJSON($0) } ?? .null,
            "failed": .bool(refresh.lastError != nil || error != nil),
            "source": refresh.source.map { .string($0.rawValue) } ?? .null,
            "error": privateText(refresh.lastError ?? error).map(HostJSON.string) ?? .null,
        ])
    }

    private func rebuildMessage(_ outcome: UsageRebuildOutcome?) -> String? {
        switch outcome {
        case .rejectedUsageChanged:
            return tr("Not applied: recalculated usage did not match existing data. Existing data kept.", "未生效：重算结果与已有数据不一致，原数据未改动")
        case .rejectedIncompleteSources:
            if let issue = state.usageService.logReadIssue {
                let cause = issue.localizedCause
                if let fix = issue.localizedFix {
                    return tr("Not applied: \(cause). Existing data kept; \(fix), then try again.", "未生效：\(cause)。原数据未改动，\(fix)后再试")
                }
                return tr("Not applied: \(cause). Existing data kept.", "未生效：\(cause)，原数据未改动")
            }
            return tr("Not applied: some logs could not be read. Existing data kept.", "未生效：部分日志读取失败，原数据未改动")
        case .commitFailed:
            return tr("Could not save the result. Existing data kept.", "结果保存失败，原数据未改动")
        case .partiallyCommitted:
            return tr("Partly applied: costs for models with newly fetched prices were not updated.", "部分生效：新获取价格的模型费用未更新")
        case .restrictedRecoveryRejected:
            return tr("Verification failed. Existing data kept; new usage is paused. Restore the logs or fix disk read/write errors, then retry.", "校验未通过：原数据保留，已暂停统计新用量。恢复日志或解决磁盘读写问题后再试")
        case .replaced, .recoveredFromRestrictedHistory, .none:
            return nil
        }
    }

    func statusJSON() -> HostJSON {
        let usage = state.usageService
        return .object([
            "scanning": .bool(usage.isScanning || refreshingUsage),
            "rebuildingHistory": .bool(usage.isRebuildingHistory),
            "rebuildingCycles": .bool(usage.isCycleRebuilding),
            "refreshingPricing": .bool(usage.isRefreshingPricingCatalog),
            "lastScanAt": usage.lastScanAt.map { dateJSON($0) } ?? .null,
            "error": privateText(usage.lastError).map(HostJSON.string) ?? .null,
            "progress": usage.scanProgress.map { progress in
                .object([
                    "service": .string(progress.app.rawValue),
                    "filesCompleted": .number(Decimal(progress.filesCompleted)),
                    "filesTotal": .number(Decimal(progress.filesTotal)),
                    "linesParsed": .number(Decimal(progress.linesParsed)),
                ])
            } ?? .null,
            "lastRebuildOutcome": usage.lastRebuildOutcome.map { .string($0.wireName) } ?? .null,
            // This message is composed from safe outcome/source-count enums. Keep
            // the recovery action visible in privacy mode; only diagnostics redact.
            "lastRebuildMessage": rebuildMessage(usage.lastRebuildOutcome).map(HostJSON.string) ?? .null,
            "lastRebuildDiagnostic": privateText(usage.lastRebuildDiagnostic).map(HostJSON.string) ?? .null,
            "historyNotice": historyNoticeJSON(notice: usage.historyRecoveryNotice, hasError: usage.lastError != nil, logReadIssue: usage.logReadIssue),
        ])
    }

    /// The same states and recovery actions as StatsUsageErrorBanner. The notice
    /// deliberately carries no source paths, log contents or raw error objects.
    func historyNoticeJSON(notice: UsageHistoryRecoveryNotice?, hasError: Bool, logReadIssue: UsageLogReadIssue? = nil) -> HostJSON {
        guard hasError || notice != nil else { return .null }
        let message: String
        if notice?.isUnavailable == true {
            message = tr("Local usage history could not be loaded, so new usage is paused. Files are untouched; restore a backup and restart CCBar.", "无法读取本机用量历史，已暂停统计新用量。原文件未改动，恢复备份后重启 CCBar。")
        } else if notice?.isReadOnly == true {
            message = tr("Usage history was saved by a newer CCBar. New usage is paused and only a compatible backup (if any) is shown. Update CCBar to continue.", "用量历史由更新版本的 CCBar 保存，已暂停统计新用量，仅显示兼容的备份（如有）。请更新 CCBar。")
        } else if notice?.isRestricted == true {
            message = notice?.verificationRejected == true
                ? tr("History verification failed. Existing data kept; new usage is paused. Restore the logs or fix disk read/write errors, then retry.", "历史校验未通过。现有数据保留，已暂停统计新用量。恢复日志或解决磁盘读写问题后再试。")
                : tr("Existing data kept. New usage is paused until history is verified.", "现有数据保留。历史校验通过前，暂停统计新用量。")
        } else if notice?.isDshFrozen == true {
            message = tr("DSH session details are unavailable, so DSH usage is paused. Existing data kept; other services are not affected.", "DSH 会话明细不可用，已暂停统计 DSH。现有数据保留，其他服务不受影响。")
        } else if hasError, let issue = logReadIssue {
            if let fix = issue.localizedFix {
                message = tr("Usage statistics are incomplete: \(issue.localizedCause). Existing data kept; \(fix), then recalculate in Settings.", "用量统计不完整：\(issue.localizedCause)。现有数据保留，\(fix)后到设置中重新计算。")
            } else {
                message = tr("Usage statistics are incomplete: \(issue.localizedCause). Existing data kept; retry later or recalculate in Settings.", "用量统计不完整：\(issue.localizedCause)。现有数据保留，可稍后重试或到设置中重新计算。")
            }
        } else {
            message = hasError
                ? tr("Usage statistics may be incomplete. Existing data kept; retry later or recalculate in Settings.", "用量统计可能不完整。现有数据保留，可稍后重试或到设置中重新计算。")
                : tr("Usage history was restored from the last complete save. Logs deleted after that cannot be recovered.", "用量历史已恢复到最近一次完整保存，之后被删除的日志无法找回。")
        }
        return .object([
            "message": .string(message),
            "restoredAt": notice?.restoredFromPreviousAt.map(dateJSON) ?? .null,
            "canOpenSettings": .bool(hasError && notice?.isReadOnly != true && notice?.isDshFrozen != true),
        ])
    }
}

extension CompositionDimension {
    var wireName: String {
        switch self {
        case .service: return "service"
        case .provider: return "provider"
        case .model: return "model"
        case .project: return "project"
        }
    }
}

private extension CycleForecastConfidence {
    var wireName: String {
        switch self {
        case .early: return "early"
        case .rough: return "rough"
        case .reference: return "reference"
        case .reliable: return "reliable"
        }
    }
}

private extension UsageRebuildOutcome {
    var wireName: String {
        switch self {
        case .replaced: return "replaced"
        case .rejectedUsageChanged: return "rejectedUsageChanged"
        case .rejectedIncompleteSources: return "rejectedIncompleteSources"
        case .commitFailed: return "commitFailed"
        case .partiallyCommitted: return "partiallyCommitted"
        case .recoveredFromRestrictedHistory: return "recoveredFromRestrictedHistory"
        case .restrictedRecoveryRejected: return "restrictedRecoveryRejected"
        }
    }
}
