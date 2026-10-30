import SwiftUI
import Combine
import AppKit

// MARK: - PopoverRootView
//
// 见 docs/界面布局.md §1。
// 结构:Header(标题 + 副标题 + 状态点 + 刷新 / 统计 / 退出) /
//      每个已启用 Provider 一个 ServiceBlockView(tile + 服务名/plan + 主额度大字 +
//      进度条 + reset + today/week cost + 次要额度行),block 间 0.5pt Divider。
// Footer 左侧为当前版本与发布页入口，右侧为设置。

struct PopoverRootView: View {
    let openMain: (MainTab) -> Void
    @Environment(AppState.self) private var appState
    @State private var refreshRotation: Double = 0
    @State private var hoveredPopoverTooltip: PopoverTooltip?

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            content

            Divider()

            HStack(alignment: .center, spacing: 8) {
                Button {
                    clearPopoverTooltip()
                    AppUpdater.shared.openReleasePage(activates: false)
                } label: {
                    HStack(alignment: .center, spacing: 6) {
                        Text("v\(AppUpdater.shared.currentVersion)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        PopoverButtonIcon(systemName: "arrow.up.forward.square")
                    }
                    .padding(.horizontal, 6)
                }
                .buttonStyle(PopoverIconButtonStyle(width: nil))
                .accessibilityLabel("v\(AppUpdater.shared.currentVersion) · \(popoverTooltipText(.releasePage))")
                .anchorPreference(key: PopoverTooltipAnchorKey.self, value: .bounds) { [.releasePage: $0] }
                .onHover { hoverPopoverTooltip(.releasePage, inside: $0) }

                Spacer()

                popoverButton(.settings, symbol: "gearshape") {
                    activateAndOpenMain(tab: .settings)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 340)
        .modifier(PopoverTooltipOverlay(hovered: $hoveredPopoverTooltip, text: popoverTooltipText))
        // 转圈由 appState.isRefreshing 统一驱动:无论刷新从哪个入口发起
        // (点击刷新按钮、⌘R 全局快捷键),只要整体刷新真正开始,按钮就转一圈。
        .onChange(of: appState.isRefreshing) { _, refreshing in
            if refreshing { refreshRotation += 360 }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: 1) {
                Text(tr("Quota", "额度"))
                    .font(.system(size: 13, weight: .semibold))

                // 用 TimelineView 每秒重新渲染一次,让 "Xs 前已刷新" 实时滚动。
                // Popover 不可见时 TimelineView 不会被调度,几乎零 CPU 成本。
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(headerSubtitle(now: context.date))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }

            Spacer()

            if let state = headerState {
                Circle()
                    .fill(state.color)
                    .frame(width: 7, height: 7)
                    .accessibilityLabel(headerStateTooltip(state))
                    .anchorPreference(key: PopoverTooltipAnchorKey.self, value: .bounds) { [.status: $0] }
                    .onHover { hoverPopoverTooltip(.status, inside: $0) }
                    .padding(.trailing, 4)
            }

            // 不加 disabled:按钮永远可点;AppState.refreshNow() 内部已经做了
            // in-flight 去重,不会重复发请求。刷新真正开始时由 isRefreshing 驱动转圈。
            popoverButton(.refresh, symbol: "arrow.clockwise", action: refresh)

            popoverButton(.statistics, symbol: "chart.bar.xaxis") {
                activateAndOpenMain(tab: .stats)
            }

            popoverButton(.quit, symbol: "power") {
                NSApp.terminate(nil)
            }
        }
        .padding(.top, 14)
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    private func popoverButton(_ item: PopoverTooltip, symbol: String, action: @escaping () -> Void) -> some View {
        Button {
            clearPopoverTooltip()
            action()
        } label: {
            PopoverButtonIcon(systemName: symbol)
                .rotationEffect(.degrees(item == .refresh ? refreshRotation : 0))
                .animation(.easeInOut(duration: 0.7), value: refreshRotation)
        }
        .buttonStyle(PopoverIconButtonStyle())
        .accessibilityLabel(popoverTooltipText(item))
        .anchorPreference(key: PopoverTooltipAnchorKey.self, value: .bounds) { [item: $0] }
        .onHover { hoverPopoverTooltip(item, inside: $0) }
    }

    private func popoverTooltipText(_ item: PopoverTooltip) -> String {
        switch item {
        case .status: headerState.map { headerStateTooltip($0) } ?? ""
        case .refresh: tr("Refresh now", "立即刷新")
        case .statistics: tr("Open Statistics", "查看统计")
        case .settings: tr("Settings", "设置")
        case .quit: tr("Quit", "退出")
        case .releasePage: tr("Open release page", "打开发布页")
        case .statusRefresh: tr("Refresh official status", "刷新官方状态")
        case .statusPage: tr("Open status page", "打开状态页")
        case .currencyRefresh: tr("Refresh exchange rates", "刷新汇率")
        }
    }

    private func hoverPopoverTooltip(_ item: PopoverTooltip, inside: Bool) {
        if inside {
            guard hoveredPopoverTooltip != item else { return }
            hoveredPopoverTooltip = item
        } else if hoveredPopoverTooltip == item {
            clearPopoverTooltip()
        }
    }

    private func clearPopoverTooltip() {
        hoveredPopoverTooltip = nil
    }

    /// `now` 由 header 的 TimelineView 提供,让"Xs 前已刷新"实时滚动。
    ///
    /// 刷新失败时必须说出来。旧实现只要有过一次成功就报"X 前已刷新",于是断网时
    /// header 说"刚刷新过"、下面每个服务却挂着报错,自相矛盾;而 `lastSuccessAt`
    /// 冷启动是从缓存的 `updatedAt` 恢复的,完全离线启动也会显示"X 前已刷新"。
    private func headerSubtitle(now: Date) -> String {
        let states = displayedRefreshStates
        let latest = states.compactMap(\.lastSuccessAt).max()
        let failing = states.contains { $0.lastError != nil }
        let networkDown = Self.allFailuresAreNetwork(states)

        if let latest {
            let age = Self.relativeAge(from: latest, now: now)
            if failing {
                return networkDown
                    ? tr("network unavailable · data from \(age) ago", "网络不可用 · \(age) 前的数据")
                    : tr("refresh failed · data from \(age) ago", "刷新失败 · \(age) 前的数据")
            }
            return tr("refreshed \(age) ago", "\(age) 前已刷新")
        }
        if failing {
            return networkDown ? tr("network unavailable", "网络不可用") : tr("refresh failed", "刷新失败")
        }
        return tr("waiting…", "等待数据")
    }

    /// 正在失败的服务是否**全部**败在网络上。
    ///
    /// 网络不可用是全局事实,归 header 表达;凭据过期一类是单个服务的事实,留在各自的
    /// block 里。这样断网时 header 说"网络不可用"、Claude 块说"凭据已过期",两条各自
    /// 成立,合起来用户就知道根因——不必把网络状态耦合进每个 Provider 的错误文案。
    ///
    /// 判定要求"全部":只要有一个服务败在别的原因上(比如 401),就说明网络是通的。
    private static func allFailuresAreNetwork(_ states: [QuotaRefreshState]) -> Bool {
        let failing = states.filter { $0.lastError != nil }
        return !failing.isEmpty && failing.allSatisfy(\.lastErrorIsNetwork)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        let providers = SettingsStore.shared.orderedProviders.filter {
            SettingsStore.shared.isProviderEnabled($0.app)
        }
        let hasImported = appState.importedCodexAccounts.contains(where: \.visibleInPopover)
        let includesCodex = providers.contains(where: { $0.app == .codex })
        // 主 Codex 卡片会展示时,「其他账号」区去掉与主账号同身份的镜像项后是否还有内容。
        let hasOtherCodexAfterDedup = appState.importedCodexAccounts.contains {
            $0.visibleInPopover && !appState.importedCodexAccountMirrorsPrimary($0)
        }

        if providers.isEmpty && !hasImported && !appState.moonshotAccounts.contains(where: \.visibleInPopover) {
            VStack(spacing: 6) {
                Text(tr("No services turned on", "未开启任何服务"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(tr("Turn one on in Settings → Services & Accounts", "到「设置 → 服务与账号」开启"))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        } else {
            VStack(spacing: 0) {
                if hasImported && !includesCodex {
                    OtherCodexAccountsSection()
                    if !providers.isEmpty {
                        Divider().padding(.horizontal, 16)
                    }
                }

                ForEach(Array(providers.enumerated()), id: \.element.app) { index, provider in
                    if index > 0 {
                        Divider().padding(.horizontal, 16)
                    }
                    if provider.app != .kimi || appState.kimiAccount != nil || appState.kimiManagedAccounts.isEmpty
                        || appState.kimiManagedAccounts.contains(where: \.visibleInPopover) {
                        AccountVendorHeader(title: provider.title, logoName: provider.logoName,
                                            fallback: provider.fallback, tint: provider.app.tintColor,
                                            status: provider.app == .kimi ? appState.displayedKimiServiceStatus : serviceStatus(for: provider.app),
                                            statusPageURL: ServiceStatusClient.pageURL(for: provider.app))
                    }
                    if provider.app != .kimi || appState.kimiAccount != nil || appState.kimiManagedAccounts.isEmpty {
                        primaryServiceBlock(provider)
                    }

                    if provider.app == .codex && hasOtherCodexAfterDedup {
                        Divider().padding(.leading, 28).padding(.trailing, 16)
                        OtherCodexAccountsSection(dedupPrimary: true, showsVendorHeader: false)
                    }
                    if provider.app == .kimi && appState.kimiManagedAccounts.contains(where: { $0.visibleInPopover && !appState.kimiManagedMirrorsCLI($0) }) {
                        if appState.kimiAccount != nil { Divider().padding(.leading, 28).padding(.trailing, 16) }
                        KimiManagedAccountsSection()
                    }
                }
                if appState.moonshotAccounts.contains(where: \.visibleInPopover) {
                    if !providers.isEmpty || hasImported { Divider().padding(.horizontal, 16) }
                    MoonshotBalancesSection()
                }
            }
        }
    }

    private func providerSubtitle(for app: QuotaApp) -> String {
        let privacy = SettingsStore.shared.privacyMode
        var parts: [String] = []
        let email: String?
        let plan: String?
        switch app {
        case .codex:
            email = appState.codexAccount?.email
            plan = appState.codexPlanName
        case .claude:
            email = appState.claudeDisplayEmail
            plan = appState.claudePlanName
        case .antigravity:
            email = appState.antigravityAccount?.email
            plan = appState.quotaSnapshot(for: .antigravity)?.planType ?? appState.antigravityAccount?.planType
        case .cursor:
            email = appState.cursorAccount?.email
            plan = appState.quotaSnapshot(for: .cursor)?.planType
        case .commandCode:
            email = appState.commandCodeAccount?.email ?? appState.commandCodeAccount?.login
            plan = appState.commandCodeAccount?.planType ?? appState.quotaSnapshot(for: .commandCode)?.planType
        case .kimi:
            return appState.kimiDisplaySubtitle
        case .opencodeGo:
            // Go 没有可读的账号信息，无需重复服务名称。
            email = nil
            plan = nil
        }
        // 每个服务只有一个主账号，隐私模式直接不显示邮箱，不必换成「账号 NN」。
        if !privacy, let email, !email.isEmpty { parts.append(email) }
        if let plan, !plan.isEmpty { parts.append(plan) }
        return parts.joined(separator: " · ")
    }

    private func primaryServiceBlock(
        _ provider: QuotaProviderDescriptor
    ) -> some View {
        let snap = appState.quotaSnapshot(for: provider.app)
        return ServiceBlockView(
            app: provider.app,
            subtitle: providerSubtitle(for: provider.app),
            tint: provider.app.tintColor,
            snapshot: snap,
            error: providerDisplayError(for: provider.app),
            periodSpend: periodSpend(for: provider.app),
            periodIsBillingCycle: cursorCycleBounds(for: provider.app) != nil,
            todayCost: todayCost(for: provider.app),
            showsCost: provider.showsCost,
            accountEdition: provider.app == .kimi ? appState.kimiCLIRegion?.displayName : nil,
            isKimiCurrentAccount: provider.app == .kimi && appState.kimiAccount != nil,
            followsVendorHeader: true
        )
    }

    /// 存进 `AppState` 的已经是 `QuotaError.userMessage`——一句人话、双语、不含技术串,
    /// 所以这里不再需要把 Cursor / Command Code 抹成通用的"刷新失败"
    /// (那样断网时它们只会说"刷新失败",看不出是网络问题还是账号问题)。
    private func providerDisplayError(for app: QuotaApp) -> String? {
        appState.quotaError(for: app)
    }

    /// Cursor 额度按计费周期重置，拿得到周期时费用跟周期对齐（本期）；
    /// 其余服务及拿不到周期的 Cursor 仍按自然周（本周）。
    private func periodSpend(for app: QuotaApp) -> Decimal? {
        if let cycle = cursorCycleBounds(for: app) { return cursorCost(from: cycle.0, to: cycle.1) }
        let (from, to) = Self.weekBounds()
        if app == .cursor { return cursorCost(from: from, to: to) }
        guard let usageApp = app.usageApp else { return nil }
        return appState.usageService.aggregator.subscriptionCost(for: usageApp, from: from, to: to)
            + otherAgentSubscriptionCost(for: app, from: from, to: to)
    }

    /// 开关打开时 Codex 花费按订阅口径算：同时计入 Pi / OpenCode / DSH 里的 Codex 订阅用量。
    private func includesOtherAgentSubscription(_ app: QuotaApp) -> Bool {
        app == .codex && SettingsStore.shared.cycleIncludesOtherAgents
    }

    private func otherAgentSubscriptionCost(for app: QuotaApp, from: Date, to: Date) -> Decimal {
        guard includesOtherAgentSubscription(app), let usageApp = app.usageApp else { return 0 }
        return appState.usageService.aggregator.otherAgentSubscriptionCost(for: usageApp, from: from, to: to)
    }

    /// 远端计量按自然日分桶，起点取周期开始那天的 0 点，与补拉范围一致。
    private func cursorCycleBounds(for app: QuotaApp) -> (Date, Date)? {
        guard app == .cursor,
              let cycle = appState.quotaSnapshot(for: .cursor)?.billingCycleWindow
        else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let startOfToday = cal.startOfDay(for: Date())
        let startOfTomorrow = cal.date(byAdding: .day, value: 1, to: startOfToday) ?? startOfToday
        let cycleStart = cal.startOfDay(for: cycle.lowerBound)
        guard cycleStart < startOfTomorrow else { return nil }
        return (cycleStart, startOfTomorrow)
    }

    /// Cursor 没有本地日志费用。只要远端缓存已有相交日桶，就展示已知 `chargedCents`
    /// 汇总；完整覆盖由刷新链路在后台补齐，不能让一个缺口抹掉已有金额。
    private func cursorCost(from: Date, to: Date) -> Decimal? {
        guard appState.usageService.hasCursorRemoteUsage(in: from..<to) else { return nil }
        return appState.usageService.aggregator.totals(app: .cursor, from: from, to: to).costUSD
    }

    private func todayCost(for app: QuotaApp) -> Decimal? {
        switch app {
        case .codex: appState.codexTodayCost.map { (cost: Decimal) -> Decimal in
            let (from, to) = Self.todayBounds()
            return cost + otherAgentSubscriptionCost(for: .codex, from: from, to: to)
        }
        case .claude: appState.claudeTodayCost
        case .antigravity: nil
        case .cursor: cursorTodayCost
        case .commandCode: nil
        case .opencodeGo: nil
        case .kimi: nil
        }
    }

    private var cursorTodayCost: Decimal? {
        let (from, to) = Self.todayBounds()
        return cursorCost(from: from, to: to)
    }

    private func serviceStatus(for app: QuotaApp) -> ServiceStatus? {
        guard SettingsStore.shared.showServiceStatus else { return nil }
        let status: ServiceStatus? = switch app {
        case .codex: appState.codexServiceStatus
        case .claude: appState.claudeServiceStatus
        case .cursor: appState.cursorServiceStatus
        case .kimi: appState.kimiServiceStatus
        case .antigravity, .commandCode, .opencodeGo: nil
        }
        guard let status else { return nil }
        let unreachable = app == .kimi
            ? appState.kimiServiceStatusUnreachable
            : appState.serviceStatusUnreachable
        // 获取失败时旧快照仍被保留(刻意的,别的信息还能用),
        // 但它已经不代表"现在"的服务状态了,不能继续拿一个陈旧的绿点说"服务正常"。
        guard !unreachable else {
            return ServiceStatus(
                indicator: .unknown,
                description: nil,
                updatedAt: status.updatedAt,
                fetchedAt: status.fetchedAt,
                components: status.components,
                isStale: true
            )
        }
        return status
    }

    // MARK: Header state (live / stale / offline)

    /// 状态点。判定同时看**数据新鲜度**和**当前是否在失败**。
    ///
    /// 旧实现只要有 `lastSuccessAt` 就纯按 age 判定,完全忽略 `lastError`:默认 2 分钟
    /// 间隔下断网后仍有 3 分钟显示绿色"在线",6 分钟后才变红。`lastError` 在每次成功时
    /// 由 `storeXxx` 清空,所以它非空就等于"最近一次尝试没成功"。
    private var headerState: CCRefreshState? {
        let settings = SettingsStore.shared
        let states = displayedRefreshStates
        guard !states.isEmpty else { return nil }
        let latest = states.compactMap(\.lastSuccessAt).max()
        let failing = states.contains { $0.lastError != nil }

        guard let latest else {
            return failing ? .offline : nil
        }

        let interval = settings.quotaInterval.seconds ?? 300
        let age = Date().timeIntervalSince(latest)
        // 正在失败就不给绿灯:数据还新是"停止更新"(橙),已经旧了就是离线(红)。
        if failing {
            return age <= interval * 3 ? .stale : .offline
        }
        if age <= interval * 1.5 { return .live }
        if age <= interval * 3 { return .stale }
        return .offline
    }

    /// 状态点 tooltip。失败态用专门文案,而不是只说"数据陈旧"——用户需要知道
    /// 看到的数字是上一次成功留下的,不是现在的。
    private func headerStateTooltip(_ state: CCRefreshState) -> String {
        let states = displayedRefreshStates
        guard states.contains(where: { $0.lastError != nil }) else { return state.tooltip }
        if Self.allFailuresAreNetwork(states) {
            return tr(
                "Network unavailable — showing the last data that came through",
                "网络不可用,显示的是上次成功取到的数据"
            )
        }
        return tr(
            "Refresh failing — showing the last data that came through",
            "刷新失败,显示的是上次成功取到的数据"
        )
    }

    private var displayedRefreshStates: [QuotaRefreshState] {
        var states = enabledPrimaryApps.compactMap { app -> QuotaRefreshState? in
            if app == .kimi, appState.kimiAccount == nil, !appState.kimiManagedAccounts.isEmpty { return nil }
            return appState.refreshState(for: app)
        }
        if SettingsStore.shared.isProviderEnabled(.kimi) {
            states += appState.kimiManagedAccounts.filter {
                $0.visibleInPopover || $0.showInMenuBar || $0.showInFloatingHUD
            }.map { appState.kimiManagedRefreshStates[$0.id] ?? QuotaRefreshState() }
        }
        states += appState.moonshotAccounts.filter {
            $0.visibleInPopover || $0.showInMenuBar || $0.showInFloatingHUD
        }.map { appState.moonshotRefreshStates[$0.id] ?? QuotaRefreshState() }
        return states
    }

    private var enabledPrimaryApps: [QuotaApp] {
        SettingsStore.shared.orderedProviders.compactMap {
            SettingsStore.shared.isProviderEnabled($0.app) ? $0.app : nil
        }
    }

    // MARK: Open main window

    private func activateAndOpenMain(tab: MainTab) {
        openMain(tab)
    }

    // MARK: Refresh

    /// 用户点刷新按钮的处理:
    /// - 只负责启动一个非阻塞 Task 去做真正的刷新工作;UI 不等
    /// - 真正的去重 / 协调放在 `AppState.refreshNow()` 内部
    /// - 转圈动画不在这里手动触发,而由 body 上监听 `appState.isRefreshing` 统一驱动,
    ///   让点击和 ⌘R 两个入口的视觉反馈完全一致(刷新真正开始才转,in-flight 去重时不转)
    /// - 数据更新通过 @Observable 自动驱动 UI 刷新,不需要在这里 await 结果
    private func refresh() {
        Task { await appState.refreshNow() }
    }

    // MARK: Helpers

    private static func todayBounds(now: Date = Date()) -> (Date, Date) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let start = cal.startOfDay(for: now)
        return (start, cal.date(byAdding: .day, value: 1, to: start) ?? start)
    }

    private static func weekBounds(now: Date = Date()) -> (Date, Date) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        cal.firstWeekday = 2
        let startOfToday = cal.startOfDay(for: now)
        let startOfTomorrow = cal.date(byAdding: .day, value: 1, to: startOfToday) ?? startOfToday
        let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
        let weekStart = cal.date(from: comps) ?? startOfToday
        return (weekStart, startOfTomorrow)
    }

    /// 计算相对时间字符串。`now` 默认是当前时间;header 用 `TimelineView` 驱动时
    /// 把 timeline 提供的 `context.date` 传进来,避免和 `Date()` 真实时间细微偏差。
    static func relativeAge(from date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        return "\(hours / 24)d"
    }
}

// MARK: - ServiceBlockView

/// One vendor title and status, followed by account rows with the same inset.
struct AccountVendorHeader: View {
    let title: String
    var logoName: String? = nil
    var fallback = "K"
    var tint: Color = .purple
    var status: ServiceStatus? = nil
    var statusPageURL: URL? = nil

    var body: some View {
        HStack(spacing: 9) {
            if let logoName {
                ServiceTile(logoName: logoName, fallback: fallback, tint: tint)
            } else {
                Image(systemName: "key.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
            }
            Text(title).font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 0)
            if let status {
                ServiceStatusDot(status: status, title: title, statusPageURL: statusPageURL)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }
}

struct ServiceBlockView: View {
    let app: QuotaApp
    let subtitle: String
    let tint: Color
    let snapshot: QuotaSnapshot?
    let error: String?
    let periodSpend: Decimal?
    /// true 时第二项费用是本计费周期（本期），否则是自然周（本周）。
    let periodIsBillingCycle: Bool
    let todayCost: Decimal?
    let showsCost: Bool
    var accountEdition: String? = nil
    var isKimiCurrentAccount = false
    var isLoading = false
    var followsVendorHeader = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !subtitle.isEmpty || accountEdition != nil || isKimiCurrentAccount {
                accountHeader
            }
            if isLoading && snapshot == nil {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.small)
                    Text(tr("Loading…", "加载中…"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            } else if snapshot?.isEmptyKimiQuota == true {
                Text(tr("No quota data available", "暂无额度数据"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                bodyRow
            }
            ForEach(compactLimits) { limit in
                compactLimitRow(limit)
            }
            if let message = shortError(error) {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                    Text(PrivacyDisplay.error(message))
                        .font(.system(size: 11))
                        .lineLimit(2)
                }
                .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, followsVendorHeader ? 4 : 14)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var accountHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            if isKimiCurrentAccount { KimiCurrentAccountBadge(usesQuickHover: true) }
            if let accountEdition {
                Text(accountEdition)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            Spacer(minLength: 0)
        }
    }

    private var bodyRow: some View {
        HStack(alignment: .center, spacing: 10) {
            // 左:主要额度大百分比 + 动态窗口标签
            VStack(alignment: .center, spacing: 4) {
                // 与 Codex / Claude 的「数值 + 窗口标签」同构：这里放值，下面的
                // UNLIMITED 才是标签，不把同一个词写两遍。∞ 与菜单栏、悬浮窗一致。
                if isUnlimited {
                    Text("∞")
                        .font(.system(size: 32, weight: .semibold))
                        .kerning(-0.8)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text(primaryValueText)
                            .font(.system(size: 32, weight: .semibold))
                            .monospacedDigit()
                            .kerning(-0.8)
                            .foregroundStyle(primaryColor)
                            .lineLimit(1)
                        if hasPrimaryLimit {
                            Text("%")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(primaryColor.opacity(0.75))
                        }
                    }
                    .fixedSize()
                }

                Text(primaryLimitTitle)
                    .font(.system(size: 9, weight: .semibold))
                    .kerning(0.5)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(app == .antigravity ? 0.75 : 1)
            }
            .frame(width: 72, alignment: .center)

            // 右:主要额度进度条 + 两行(数值 / label)
            VStack(alignment: .leading, spacing: 8) {
                // Unlimited 没有可填充的比例，进度条会被读成「已用满」；左栏已经写了
                // 「不限额度」，这里不再重复第二遍，只保留计费周期重置时间。
                if !isUnlimited {
                    ProgressBar(value: primaryRemaining / 100, tint: primaryColor, height: 7)
                }

                VStack(spacing: 1) {
                    HStack(spacing: 0) {
                        ResetTimeText(resetsAt: snapshot?.primaryLimit?.window.resetsAt)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Spacer(minLength: 8)

                        if showsCost {
                            HStack(spacing: 10) {
                                statInline(value: formatCostInt(todayCost), english: "today", chinese: "今日")
                                statInline(
                                    value: formatCostInt(periodSpend),
                                    english: periodIsBillingCycle ? "this cycle" : "this week",
                                    chinese: periodIsBillingCycle ? "本期" : "本周"
                                )
                            }
                        }
                    }

                    HStack(spacing: 0) {
                        BilingualInline(english: "reset", chinese: "重置")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)

                        // Spacer 必须在 showsCost 之外：showsCost 为 false 时这行只剩
                        // 一个子视图，HStack 会把它居中，"重置"会跑到行中间。
                        Spacer(minLength: 0)

                        if showsCost {
                            BilingualInline(english: "cost", chinese: "费用")
                                .font(.system(size: 9.5))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func compactLimitRow(_ limit: QuotaLimit) -> some View {
        let remaining = limit.window.remainingPercent
        let color = statusColor(remainingPercent: remaining, tint: tint)
        return HStack(spacing: 10) {
            Text(compactLimitLabel(limit))
                .font(.system(size: 9, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .frame(width: 72, alignment: .leading)

            ProgressBar(value: remaining / 100, tint: color, height: 2.5)

            Text("\(Int(remaining.rounded()))%")
                .font(.system(size: 10.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(color)
                .frame(width: 32, alignment: .trailing)

            compactLimitStatus(limit)
                // 68pt 放得下悬浮 /「绝对时间」下的跨天格式 `MM-dd HH:mm`（10.5pt 约 61pt）。
                .frame(width: 68, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func compactLimitStatus(_ limit: QuotaLimit) -> some View {
        if limit.kind == .modelWeekly,
           limit.window.usedPercent == 0,
           limit.window.resetsAt == nil
        {
            Text(tr("Unused", "尚未使用"))
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        } else if let resetsAt = limit.window.resetsAt {
            ResetTimeText(resetsAt: resetsAt)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        } else {
            Text(tr("Unknown", "未知"))
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    private func compactLimitLabel(_ limit: QuotaLimit) -> String {
        // Antigravity 的共享窗口及 Argon 独立额度带官方组名，
        // 用 displayName 显示；其余服务仍按窗口类型回落。
        if app == .antigravity, let name = normalizedModelLabel(limit.displayName) {
            return name.uppercased()
        }
        if app == .cursor, let name = normalizedModelLabel(limit.displayName) {
            return name.uppercased()
        }
        switch limit.kind {
        case .fiveHour:
            return "5HOUR"
        case .weekly:
            return app == .claude ? "ALL" : "WEEKLY"
        case .modelWeekly:
            return normalizedModelLabel(limit.displayName) ?? "MODEL"
        case .unknown:
            return normalizedModelLabel(limit.displayName) ?? "CURRENT"
        }
    }

    private func normalizedModelLabel(_ name: String?) -> String? {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty
        else { return nil }
        return name.caseInsensitiveCompare("Fable") == .orderedSame ? "Fable" : name
    }

    private func statInline(value: String, english: String, chinese: String) -> some View {
        HStack(spacing: 4) {
            BilingualInline(english: english, chinese: chinese)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
    }

    // MARK: Derived data

    private var primaryRemaining: Double {
        snapshot?.primaryWindow?.remainingPercent ?? 0
    }

    private var primaryColor: Color {
        guard hasPrimaryLimit, !isUnlimited else { return .secondary }
        return statusColor(remainingPercent: primaryRemaining, tint: tint)
    }

    private var visibleSecondaryLimit: QuotaLimit? {
        guard let secondary = snapshot?.secondaryLimit,
              secondary.id != snapshot?.primaryLimit?.id
        else { return nil }
        return secondary
    }

    private var compactLimits: [QuotaLimit] {
        let candidates = [visibleSecondaryLimit].compactMap { $0 }
            + (snapshot?.auxiliaryLimits ?? [])
            + (snapshot?.modelLimits ?? [])
        return candidates.reduce(into: [QuotaLimit]()) { result, limit in
            if !result.contains(where: { $0.id == limit.id }) {
                result.append(limit)
            }
        }
    }

    private var hasPrimaryLimit: Bool {
        snapshot?.primaryLimit != nil
    }

    private var isUnlimited: Bool {
        snapshot?.isUnlimited == true
    }

    private var primaryValueText: String {
        guard let window = snapshot?.primaryWindow else { return "--" }
        return "\(Int(window.remainingPercent.rounded()))"
    }

    private var primaryLimitTitle: String {
        if isUnlimited { return "UNLIMITED" }
        guard let limit = snapshot?.primaryLimit else { return "CURRENT" }
        // Antigravity 优先以 Argon 周额度为主条，标签使用实际 displayName。
        if app == .antigravity, let name = normalizedModelLabel(limit.displayName) {
            return name.uppercased()
        }
        switch limit.kind {
        case .fiveHour: return "5HOUR"
        case .weekly: return app == .claude ? "ALL" : "WEEKLY"
        case .modelWeekly: return normalizedModelLabel(limit.displayName) ?? "MODEL"
        case .unknown:
            if app == .cursor, let name = normalizedModelLabel(limit.displayName) {
                return name.uppercased()
            }
            return normalizedModelLabel(limit.displayName) ?? "CURRENT"
        }
    }

    private func formatCostInt(_ value: Decimal?) -> String {
        CurrencyFormatter.compactWhole(value)
    }

    private func shortError(_ error: String?) -> String? {
        guard let error, !error.isEmpty else { return nil }
        let oneLine = error.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if oneLine.count <= 110 { return oneLine }
        return String(oneLine.prefix(107)) + "..."
    }
}

enum PopoverTooltip: Hashable {
    case status, refresh, statistics, settings, quit, releasePage, statusRefresh, statusPage, currencyRefresh

    var appearsAbove: Bool {
        switch self {
        case .settings, .releasePage, .statusRefresh, .statusPage: true
        default: false
        }
    }
}

struct PopoverTooltipOverlay: ViewModifier {
    @Binding var hovered: PopoverTooltip?
    let text: (PopoverTooltip) -> String
    @State private var visible: PopoverTooltip?

    func body(content: Content) -> some View {
        content
            .overlayPreferenceValue(PopoverTooltipAnchorKey.self) { anchors in
                GeometryReader { geometry in
                    if let item = visible, item == hovered, let anchor = anchors[item] {
                        PopoverTooltipLayout(anchor: geometry[anchor], appearsAbove: item.appearsAbove) {
                            Text(text(item))
                                .font(.system(size: 11.5))
                                .foregroundStyle(Color.black.opacity(0.85))
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(.white, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                        }
                        .frame(width: geometry.size.width, height: geometry.size.height)
                    }
                }
                // 说明只负责绘制，不建立额外 popover、不抢焦点或吞掉点击。
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .task(id: hovered) {
                visible = nil
                guard let item = hovered else { return }
                do { try await Task.sleep(nanoseconds: 100_000_000) }
                catch { return }
                guard !Task.isCancelled, hovered == item else { return }
                visible = item
            }
            .onDisappear { hovered = nil; visible = nil }
    }
}

struct PopoverTooltipAnchorKey: PreferenceKey {
    static var defaultValue: [PopoverTooltip: Anchor<CGRect>] = [:]

    static func reduce(value: inout [PopoverTooltip: Anchor<CGRect>], nextValue: () -> [PopoverTooltip: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// 在根视图内按实际文字尺寸放置说明，避开按钮并收进左右边缘。
private struct PopoverTooltipLayout: Layout {
    let anchor: CGRect
    let appearsAbove: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let tooltip = subviews.first else { return }
        let margin: CGFloat = 12
        let size = tooltip.sizeThatFits(ProposedViewSize(width: min(220, max(0, bounds.width - margin * 2)), height: nil))
        let x = min(max(margin, anchor.midX - size.width / 2), bounds.width - margin - size.width)
        let y = appearsAbove ? anchor.minY - size.height - 6 : anchor.maxY + 6
        tooltip.place(
            at: CGPoint(x: bounds.minX + x, y: bounds.minY + max(0, min(y, bounds.height - size.height))),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: size.width, height: size.height)
        )
    }
}

@MainActor
private final class QuickHoverPresentation: ObservableObject {
    @Published var isPresented = false
    private var anchorHovered = false
    private var contentHovered = false
    private var pinned = false
    private var pending: Task<Void, Never>?

    func hover(_ inside: Bool, content: Bool = false, delayNanoseconds: UInt64 = 150_000_000) {
        if content { contentHovered = inside } else { anchorHovered = inside }
        pending?.cancel()
        pending = nil
        if anchorHovered || contentHovered {
            guard !isPresented else { return }
            pending = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: delayNanoseconds)
                guard !Task.isCancelled, let self, self.anchorHovered || self.contentHovered else { return }
                self.isPresented = true
            }
        } else if !pinned {
            pending = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard !Task.isCancelled, let self, !self.anchorHovered, !self.contentHovered else { return }
                self.isPresented = false
            }
        }
    }

    func toggle() {
        pending?.cancel()
        isPresented.toggle()
        pinned = isPresented
    }

    func reset() {
        pending?.cancel()
        pending = nil
        pinned = false
        anchorHovered = false
        contentHovered = false
        isPresented = false
    }
}

struct ServiceStatusDot: View {
    let status: ServiceStatus
    let title: String
    let statusPageURL: URL?
    @StateObject private var presentation = QuickHoverPresentation()

    var body: some View {
        Button { presentation.toggle() } label: {
            HStack(spacing: 5) {
                Circle().fill(status.indicator.dotColor).frame(width: 6, height: 6)
                Text(tr("Official status", "官方状态"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            .padding(5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(title): \(tr("Official status", "官方状态")) · \(status.isStale ? tr("Status unknown", "状态未知") : status.indicator.componentLabel)"))
        .onHover { presentation.hover($0, delayNanoseconds: 100_000_000) }
        .onDisappear { presentation.reset() }
        .popover(isPresented: $presentation.isPresented, arrowEdge: .bottom) {
            ServiceStatusDetailView(status: status, title: title, statusPageURL: statusPageURL)
                .onHover { presentation.hover($0, content: true) }
                .onDisappear { presentation.reset() }
        }
    }
}

private struct ServiceStatusDetailView: View {
    @Environment(AppState.self) private var appState
    let status: ServiceStatus
    let title: String
    let statusPageURL: URL?
    @State private var isRefreshing = false
    @State private var hoveredTooltip: PopoverTooltip?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(status.isStale
                 ? tr("Official status unavailable · showing older data", "官方状态获取失败 · 显示旧数据")
                 : tr("Official status", "官方状态"))
                .font(.system(size: 12.5, weight: .semibold))
            if status.components.isEmpty {
                statusRow(name: title, indicator: status.indicator)
                if !status.isStale, let description = status.description, !description.isEmpty {
                    Text(description).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            } else {
                ForEach(status.components, id: \.id) { component in
                    statusRow(name: component.name, indicator: component.indicator)
                }
            }
            Divider()
            Text(status.isStale
                 ? tr("Last fetched \(PopoverRootView.relativeAge(from: status.fetchedAt)) ago; statuses below are not current",
                      "\(PopoverRootView.relativeAge(from: status.fetchedAt)) 前获取；以上状态不是当前状态")
                 : tr("Fetched \(PopoverRootView.relativeAge(from: status.fetchedAt)) ago",
                      "\(PopoverRootView.relativeAge(from: status.fetchedAt)) 前获取"))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack(alignment: .center) {
                Button {
                    hoveredTooltip = nil
                    isRefreshing = true
                    Task {
                        await appState.refreshServiceStatus()
                        isRefreshing = false
                    }
                } label: {
                    if isRefreshing {
                        ProgressView().controlSize(.small).frame(width: 16, height: 16)
                    } else {
                        PopoverButtonIcon(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(PopoverIconButtonStyle())
                .foregroundStyle(.secondary)
                .disabled(isRefreshing)
                .accessibilityLabel(tr("Refresh official status", "刷新官方状态"))
                .anchorPreference(key: PopoverTooltipAnchorKey.self, value: .bounds) { [.statusRefresh: $0] }
                .onHover { hoverTooltip(.statusRefresh, inside: $0 && !isRefreshing) }

                Spacer()

                if let statusPageURL {
                    Button {
                        hoveredTooltip = nil
                        let configuration = NSWorkspace.OpenConfiguration()
                        configuration.activates = false
                        NSWorkspace.shared.open(statusPageURL, configuration: configuration)
                    } label: {
                        PopoverButtonIcon(systemName: "arrow.up.forward.square")
                    }
                    .buttonStyle(PopoverIconButtonStyle())
                    .accessibilityLabel(tr("Open status page", "打开状态页"))
                    .anchorPreference(key: PopoverTooltipAnchorKey.self, value: .bounds) { [.statusPage: $0] }
                    .onHover { hoverTooltip(.statusPage, inside: $0) }
                }
            }
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
        .modifier(PopoverTooltipOverlay(hovered: $hoveredTooltip) { item in
            item == .statusRefresh
                ? tr("Refresh official status", "刷新官方状态")
                : tr("Open status page", "打开状态页")
        })
    }

    private func hoverTooltip(_ item: PopoverTooltip, inside: Bool) {
        if inside { hoveredTooltip = item }
        else if hoveredTooltip == item { hoveredTooltip = nil }
    }

    private func statusRow(name: String, indicator: ServiceStatusIndicator) -> some View {
        HStack(spacing: 8) {
            Circle().fill(indicator.dotColor).frame(width: 6, height: 6)
            Text(name).font(.system(size: 11.5)).lineLimit(2)
            Spacer(minLength: 8)
            Text(indicator.componentLabel)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}

private struct NativeHoverPopover: ViewModifier {
    let text: String
    let delayNanoseconds: UInt64
    @StateObject private var presentation = QuickHoverPresentation()

    func body(content: Content) -> some View {
        content
            .onHover { if !text.isEmpty { presentation.hover($0, delayNanoseconds: delayNanoseconds) } }
            .onChange(of: text) { _, newValue in
                if newValue.isEmpty { presentation.reset() }
            }
            .onDisappear { presentation.reset() }
            .popover(isPresented: $presentation.isPresented, arrowEdge: .bottom) {
                Text(text).font(.system(size: 11.5)).padding(12)
                    .frame(maxWidth: 420).fixedSize(horizontal: false, vertical: true)
                    .onHover { presentation.hover($0, content: true) }
                    .onDisappear { presentation.reset() }
            }
    }
}

extension View {
    func nativeHover(_ text: String, delayNanoseconds: UInt64 = 150_000_000) -> some View {
        modifier(NativeHoverPopover(text: text, delayNanoseconds: delayNanoseconds))
    }
}
