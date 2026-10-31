import SwiftUI
import AppKit

struct AuthorizationServicesView: View {
    @Environment(AppState.self) private var appState
    @State private var showCodexResetCreditsSheet = false

    var body: some View {
        VStack(spacing: 24) { servicesSection(settings: SettingsStore.shared) }
            .sheet(isPresented: $showCodexResetCreditsSheet) {
                CodexResetCreditsSheet(accountTitle: appState.codexAccount?.email ?? "Codex",
                                       privacyAccountKey: "primary:codex",
                                       fetchCredits: { await appState.fetchCodexResetCredits() })
            }
    }

    // MARK: - Section 1: Services & Accounts

    /// 一层设置完：每个服务一行，右侧固定为 菜单栏 / 悬浮窗 / 数据来源 / 启用 四列。
    /// 检测到的服务在「正在使用」，其余在「未检测到」；其他 Codex 账号作为子行挂在 Codex 下面。
    @ViewBuilder
    private func servicesSection(settings: SettingsStore) -> some View {
        let entries = appState.quotaAccountProviders.map { quotaServiceEntry($0, settings: settings) }
        let inUse = entries.filter(\.isDetected)
        let others = entries.filter { !$0.isDetected }

        ServiceGroup(title: tr("Connected accounts", "已连接账号"), desc: nil) {
            if inUse.isEmpty {
                Text(tr("No services found on this Mac yet", "暂未在这台 Mac 上检测到服务"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            } else {
                serviceRows(inUse, floatingHUDGloballyEnabled: settings.floatingEnabled)
            }
        }

        ServiceGroup(title: "DeepSeek", desc: nil) {
            DeepSeekAccountsSettingsView()
        }

        if !others.isEmpty {
            ServiceGroup(
                title: tr("Connect subscriptions", "连接订阅账号"),
                desc: nil
            ) {
                serviceRows(others, floatingHUDGloballyEnabled: settings.floatingEnabled)
            }
        }
    }

    @ViewBuilder
    private func serviceRows(_ entries: [ServiceEntry], floatingHUDGloballyEnabled: Bool) -> some View {
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // 每个分组各自一个列表，只在组内重排。
        ReorderableStack(
            ids: entries.map(\.id),
            movableCount: entries.count,
            dividerLeading: ServiceRowMetrics.textLeading,
            onMove: commitServiceMove
        ) { id, reorder in
            if let entry = byID[id] {
                serviceBlock(entry, reorder: reorder, floatingHUDGloballyEnabled: floatingHUDGloballyEnabled)
            }
        }
    }

    private func orderItem(of id: ServiceEntry.ID) -> ServiceOrderItem {
        switch id {
        case .quota(let app): return .quota(app)
                }
    }

    /// 组内新顺序换算成全局顺序：插到组内新邻居的前面（落在组尾时插到前一个的后面）。
    private func commitServiceMove(_ moved: ServiceEntry.ID, _ newOrder: [ServiceEntry.ID]) {
        let items = newOrder.map(orderItem(of:))
        let source = orderItem(of: moved)
        guard let index = items.firstIndex(of: source) else { return }
        if index + 1 < items.count {
            SettingsStore.shared.moveService(source, before: items[index + 1])
        } else if index > 0 {
            SettingsStore.shared.moveService(source, after: items[index - 1])
        }
    }

    /// 每一行整行可拖（手柄只做提示）。
    /// 同一厂商的服务行、账户行与添加入口作为一块抬起和移动，视觉上仍同级对齐。
    @ViewBuilder
    private func serviceBlock(
        _ entry: ServiceEntry,
        reorder: ReorderRowState,
        floatingHUDGloballyEnabled: Bool
    ) -> some View {
        VStack(spacing: 0) {
            ServiceRow(
                entry: entry,
                floatingHUDGloballyEnabled: floatingHUDGloballyEnabled,
                isReorderLifted: reorder.isLifted
            )
            .reorderDragSource(reorder)

            if entry.id == .quota(.codex) {
                ImportedCodexAccountsView()
            }
            if entry.id == .quota(.kimi) {
                KimiManagedAccountsSettingsView()
            }
        }
    }

    /// 授权显示独立于应用的用量统计开关。
    private func serviceEnabledBinding(for app: QuotaApp, settings: SettingsStore) -> Binding<Bool> {
        Binding(
            get: { settings.isProviderEnabled(app) },
            set: { newValue in
                settings.setProviderEnabled(newValue, for: app)
                // Antigravity / Cursor / Command Code / OpenCode Go 开启后立即取一次额度，不等下一轮调度。
                guard newValue, [QuotaApp.antigravity, .cursor, .commandCode, .opencodeGo, .kimi].contains(app) else { return }
                Task { await appState.refreshQuotas(reason: .userInitiated) }
            }
        )
    }

    private func menuBarBinding(for app: QuotaApp, settings: SettingsStore) -> Binding<Bool> {
        Binding(
            get: { settings.isProviderShownInMenuBar(app) },
            set: { settings.setProviderShownInMenuBar($0, for: app) }
        )
    }

    private func floatingBinding(for app: QuotaApp, settings: SettingsStore) -> Binding<Bool> {
        Binding(
            get: { settings.isProviderShownInFloatingHUD(app) },
            set: { newValue in
                settings.setProviderShownInFloatingHUD(newValue, for: app)
                FloatingPanelController.shared.sync()
            }
        )
    }

    private func accountInfo(for app: QuotaApp) -> (email: String?, plan: String?, signedIn: Bool) {
        switch app {
        case .codex:
            return (
                email: appState.codexAccount?.email,
                plan: appState.codexPlanName,
                signedIn: appState.codexAccount != nil
            )
        case .claude:
            return (
                email: appState.claudeDisplayEmail,
                plan: appState.claudePlanName,
                signedIn: appState.claudeAccount != nil
            )
        case .antigravity:
            return (
                email: appState.antigravityAccount?.email,
                plan: (appState.antigravityAccount?.planType ?? appState.antigravityQuota?.planType)?.capitalized,
                signedIn: appState.antigravityAccount != nil
            )
        case .cursor:
            return (
                email: appState.cursorAccount?.email,
                plan: appState.cursorQuota?.planType,
                signedIn: appState.cursorAccount != nil
            )
        case .commandCode:
            return (
                email: appState.commandCodeAccount?.email ?? appState.commandCodeAccount?.login,
                plan: appState.commandCodeQuota?.planType ?? appState.commandCodeAccount?.planType,
                signedIn: appState.commandCodeAccount != nil
            )
        case .kimi:
            return (email: appState.kimiNickname, plan: appState.kimiPlanName, signedIn: appState.kimiAccount != nil)
        case .opencodeGo:
            // Go 没有可读的账号信息，检测到 key 即视为已登录，副标题显示「已登录」。
            return (email: nil, plan: nil, signedIn: appState.opencodeGoAccount != nil)
        }
    }

    private func quotaServiceEntry(_ provider: QuotaProviderDescriptor, settings: SettingsStore) -> ServiceEntry {
        let app = provider.app
        let info = accountInfo(for: app)
        // 每个服务只有一个主账号，隐私模式直接不显示邮箱，不必换成「账号 NN」。
        let email = PrivacyDisplay.isEnabled ? nil : info.email
        let plan = info.plan.flatMap { $0.isEmpty ? nil : $0 }

        var sourceLines = [quotaSourceHelp(for: app)]
        let claudeDesktopDenied = app == .claude && appState.claudeDesktopAccessDenied
        let authorizeClaudeDesktop = ServiceAction(title: tr("Authorize…", "授权…")) { appState.authorizeClaudeDesktopAccess() }
        let cursorKeychainRequired = app == .cursor && appState.cursorKeychainAccessRequired
        var isDetected = info.signedIn || cursorKeychainRequired || claudeDesktopDenied
            || (app == .codex && !appState.importedCodexAccounts.isEmpty)
            || (app == .kimi && appState.hasKimiSubscriptionAccount)
        if let offHint = offHint(for: app), !settings.isProviderEnabled(app) {
            sourceLines.append(offHint)
        }
        if claudeDesktopDenied {
            isDetected = true
            if info.signedIn {
                sourceLines.append(tr(
                    "Not allowed to read Claude Desktop's sign-in. When the Claude Code sign-in expires, quota can't fall back to Claude Desktop.",
                    "未授权读取 Claude 桌面版登录：Claude Code 登录过期后，无法改用桌面版的登录状态查询额度。"
                ))
            }
        }

        let subtitle: String
        if claudeDesktopDenied, !info.signedIn {
            subtitle = tr("Not allowed to read Claude Desktop's sign-in", "未授权读取 Claude 桌面版登录")
        } else if cursorKeychainRequired {
            subtitle = tr("Not allowed to read Cursor's sign-in", "未授权读取 Cursor 登录")
        } else if !isDetected {
            subtitle = connectHint(for: app)
        } else if !info.signedIn {
            subtitle = tr("Connect an account", "连接账号后查看额度")
        } else {
            switch (email, plan) {
            case (let email?, let plan?): subtitle = "\(email) · \(plan)"
            case (let email?, nil): subtitle = email
            case (nil, let plan?): subtitle = plan
            case (nil, nil): subtitle = tr("Signed in", "已登录")
            }
        }

        // 只对开着、已登录的服务报刷新失败；文案是 `QuotaError.userMessage`，原因放进数据来源弹窗。
        let error = settings.isProviderEnabled(app) && info.signedIn ? appState.quotaError(for: app) : nil

        var actions: [ServiceAction] = []
        if app == .codex, info.signedIn {
            actions.append(ServiceAction(title: tr("Reset Credits…", "额度重置次数…")) { showCodexResetCreditsSheet = true })
        }
        if claudeDesktopDenied, info.signedIn {
            actions.append(authorizeClaudeDesktop)
        }

        // 已登录时也放在行内：弹出面板的过期提示指引用户到这里授权，入口不能藏在数据来源弹窗里。
        let connectAction: ServiceAction?
        if claudeDesktopDenied {
            connectAction = authorizeClaudeDesktop
        } else if cursorKeychainRequired {
            connectAction = ServiceAction(title: tr("Authorize…", "授权…")) {
                appState.authorizeCursorAccess()
            }
        } else {
            connectAction = nil
        }

        return ServiceEntry(
            id: .quota(app),
            logoName: provider.logoName,
            fallback: provider.fallback,
            tint: app.tintColor,
            title: provider.title,
            subtitle: subtitle,
            errorDetail: error,
            isDetected: isDetected,
            connectAction: connectAction,
            sourceLines: sourceLines,
            actions: actions,
            isEnabled: serviceEnabledBinding(for: app, settings: settings),
            showInMenuBar: provider.supportsMenuBar ? menuBarBinding(for: app, settings: settings) : nil,
            showInFloatingHUD: provider.supportsFloatingHUD ? floatingBinding(for: app, settings: settings) : nil
        )
    }

    /// 额度的数据来源说明，放在行尾数据来源弹窗里。
    private func quotaSourceHelp(for app: QuotaApp) -> String {
        switch app {
        case .codex:
            tr("Quota: reads the sign-in in ~/.codex/auth.json and asks OpenAI for remaining quota. Read-only; your sign-in is not changed.",
               "额度：读取 ~/.codex/auth.json 的登录状态，向 OpenAI 查询剩余额度。只读取，不改动登录。")
        case .claude:
            tr("Quota: reads the sign-in from Claude Code CLI or Claude Desktop and asks Anthropic for remaining quota. Read-only; your sign-in is not changed.",
               "额度：读取 Claude Code CLI 或 Claude 桌面版的登录状态，向 Anthropic 查询剩余额度。只读取，不改动登录。")
        case .antigravity:
            tr("Quota: reads the sign-in in ~/.gemini (agy CLI / IDE plugin) and asks Google for remaining quota. Read-only; your sign-in is not changed.",
               "额度：读取 ~/.gemini 中的登录状态（agy CLI / IDE 插件登录），向 Google 查询剩余额度。只读取，不改动登录。")
        case .cursor:
            tr("Quota: reads the sign-in from the Cursor app (decrypted with the Cursor Safe Storage key in Keychain when Cursor encrypts it) and asks Cursor for remaining quota. Read-only; your sign-in is not changed.",
               "额度：读取 Cursor 应用的登录状态（Cursor 加密保存时，用钥匙串里的 Cursor Safe Storage 密钥解密），向 Cursor 查询剩余额度。只读取，不改动登录。")
        case .commandCode:
            tr("Quota: reads Command Code's local credentials or the ones you entered (stored in a private local file), and asks Command Code for remaining quota.",
               "额度：读取 Command Code 的本机凭据或手动填写的凭据（保存在本机私有文件中），向 Command Code 查询剩余额度。")
        case .kimi:
            tr("Quota: reads your existing Kimi Code CLI sign-in and asks Kimi for remaining quota. Expired access tokens are renewed automatically and saved back to the CLI credential file.",
               "额度：读取已有 Kimi Code CLI 登录，向 Kimi 查询剩余额度。访问令牌过期时自动续期，并同步更新 CLI 凭据文件。")
        case .opencodeGo:
            tr("Quota: reads the OpenCode Go API key from OpenCode, Pi, the OPENCODE_API_KEY environment variable, or the one you entered (stored in a private local file), and asks OpenCode for remaining quota.",
               "额度：读取 OpenCode、Pi 中的 OpenCode Go API Key、环境变量 OPENCODE_API_KEY 或手动填写的 Key（保存在本机私有文件中），向 OpenCode 查询剩余额度。")
        }
    }

    /// 「未检测到」行的接入提示。
    private func connectHint(for app: QuotaApp) -> String {
        switch app {
        case .codex:
            tr("Sign in with the Codex CLI to detect it", "用 Codex CLI 登录后自动识别")
        case .claude:
            tr("Sign in to Claude Code CLI or Claude Desktop to detect it", "登录 Claude Code CLI 或 Claude 桌面版后自动识别")
        case .antigravity:
            tr("Sign in to Antigravity (agy CLI or IDE plugin) to detect it", "登录 Antigravity（agy CLI 或 IDE 插件）后自动识别")
        case .cursor:
            tr("Sign in to the Cursor app to detect it", "登录 Cursor 应用后自动识别")
        case .commandCode:
            tr("Sign in with the Command Code CLI to detect it, or", "登录 Command Code CLI 后自动识别，或")
        case .kimi:
            tr("Sign in with /login in Kimi Code CLI to detect it", "在 Kimi Code CLI 中运行 /login 后自动识别")
        case .opencodeGo:
            tr("Connect OpenCode Go in OpenCode or Pi to detect it, or", "在 OpenCode 或 Pi 中连接 OpenCode Go 后自动识别，或")
        }
    }

    /// 默认关闭的服务，关闭态说明开启后会发生什么（两者开启后才联网请求）。
    private func offHint(for app: QuotaApp) -> String? {
        switch app {
        case .cursor:
            tr("Turning on reads Cursor's sign-in to fetch quota and usage online.",
               "开启后会读取 Cursor 的登录状态，联网查询额度和用量。")
        case .commandCode:
            tr("Turning on fetches Command Code quota online.", "开启后会联网查询 Command Code 额度。")
        case .kimi:
            tr("Turning on reads your Kimi Code sign-in to fetch quota online.", "开启后会读取 Kimi Code 登录状态，联网查询额度。")
        case .opencodeGo:
            tr("Turning on fetches OpenCode Go quota online.", "开启后会联网查询 OpenCode Go 额度。")
        default:
            nil
        }
    }

}

// MARK: - Service rows

/// 服务分组：标题行右侧写一次列名（菜单栏 / 悬浮窗 / 启用），与下面每行的控件对齐。
private struct ServiceGroup<Content: View>: View {
    let title: String
    let desc: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .kerning(-0.05)
                    if let desc {
                        Text(desc)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                columnTitle(tr("Menu Bar", "菜单栏"), width: ServiceRowMetrics.destination)
                columnTitle(tr("Floating HUD", "悬浮窗"), width: ServiceRowMetrics.destination)
                Color.clear
                    .frame(width: ServiceRowMetrics.info, height: 1)
                columnTitle(tr("Show quota", "额度显示"), width: ServiceRowMetrics.toggle)
            }
            .padding(.leading, 4)
            .padding(.trailing, ServiceRowMetrics.trailingPadding)
            .padding(.bottom, 8)

            VStack(spacing: 0) {
                content()
            }
            .ccPanel(cornerRadius: 10)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func columnTitle(_ text: String, width: CGFloat) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
            .frame(width: width)
    }
}

/// 额度管理中的订阅账号展示数据。
private struct ServiceEntry: Identifiable {
    enum ID: Hashable {
        case quota(QuotaApp)
    }

    let id: ID
    let logoName: String
    let fallback: String
    let tint: Color
    let title: String
    /// 账号 · 套餐、本机记录状态，或未检测到时的接入提示。
    let subtitle: String
    /// 最近一次刷新失败的原因（`QuotaError.userMessage`）；行内只写「刷新失败」，原因放进数据来源弹窗。
    let errorDetail: String?
    /// 这台 Mac 上检测到了（登录态或本机记录），决定放在「正在使用」还是「未检测到」。
    let isDetected: Bool
    /// 副标题后的按钮：未检测到时 Command Code 手动填写凭据；Claude 未授权读取桌面版登录时重新授权（已登录、未登录都显示）。
    let connectAction: ServiceAction?
    let sourceLines: [String]
    /// 数据来源弹窗底部的操作（Codex 额度重置次数、Command Code 凭据、Claude 桌面版重新授权）。
    let actions: [ServiceAction]
    let isEnabled: Binding<Bool>
    /// 菜单栏 / 悬浮窗只跟额度有关；仅有用量的服务为 nil，单元格留空。
    let showInMenuBar: Binding<Bool>?
    let showInFloatingHUD: Binding<Bool>?
}

private struct ServiceAction {
    let title: String
    let action: () -> Void
}

private struct ServiceRow: View {
    @Environment(AppState.self) private var appState
    let entry: ServiceEntry
    let floatingHUDGloballyEnabled: Bool
    /// 左侧重排抓手的抬起态；拖动手势由列表挂在整行上。
    var isReorderLifted = false

    private var isEnabled: Bool { entry.isEnabled.wrappedValue }

    var body: some View {
        HStack(spacing: 0) {
            reorderHandle
                .frame(width: ServiceRowMetrics.handleWidth)
                .padding(.trailing, ServiceRowMetrics.handleGap)

            ServiceTile(
                logoName: entry.logoName,
                fallback: entry.fallback,
                tint: entry.tint,
                size: ServiceRowMetrics.tileSize,
                logoSize: 18,
                cornerRadius: 7.5
            )
            .opacity(entry.isDetected ? 1 : 0.45)
            .padding(.trailing, ServiceRowMetrics.tileGap)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(entry.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(entry.isDetected ? Color.primary : Color.secondary)
                        .lineLimit(1)
                    if entry.id == .quota(.kimi), appState.kimiAccount != nil {
                        KimiCurrentAccountBadge()
                    }
                }
                subtitleLine
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 8)

            // 服务关闭时两列置灰且不可点，不隐藏，保持列对齐。
            HStack(spacing: 0) {
                destinationCell(entry.showInMenuBar, title: tr("Menu Bar", "菜单栏"), unavailable: false, help: nil)
                destinationCell(
                    entry.showInFloatingHUD,
                    title: tr("Floating HUD", "悬浮窗"),
                    unavailable: !floatingHUDGloballyEnabled,
                    help: floatingDisabledHelp
                )
            }
            .opacity(isEnabled ? 1 : 0.4)

            ServiceInfoButton(entry: entry)
                .frame(width: ServiceRowMetrics.info)

            Toggle(entry.title, isOn: entry.isEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(.green)
                .help(tr(
                    "Turning off hides this account's quota. Application usage settings are unchanged.",
                    "关闭后不再显示此账号的额度，应用用量统计设置保留。"
                ))
                .frame(width: ServiceRowMetrics.toggle)
        }
        .padding(.leading, ServiceRowMetrics.leadingPadding)
        .padding(.trailing, ServiceRowMetrics.trailingPadding)
        .padding(.vertical, 9)
        .frame(minHeight: 50)
    }

    private var reorderHandle: some View {
        ReorderGrip(isLifted: isReorderLifted)
    }

    private var subtitleLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(entry.subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(entry.subtitle)
            if entry.id == .quota(.kimi), let region = appState.kimiCLIRegion {
                Text("· \(region.displayName)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            if let errorDetail = entry.errorDetail {
                Text("· \(tr("Refresh failed", "刷新失败"))")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .fixedSize()
                    .help(errorDetail)
            }
            if let connectAction = entry.connectAction {
                Button(connectAction.title, action: connectAction.action)
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .focusEffectDisabled()
                    .fixedSize()
            }
        }
    }

    /// 悬浮窗列不可勾选的原因：服务关闭时不提示；其余是全局悬浮窗未开启。
    private var floatingDisabledHelp: String? {
        guard isEnabled, !floatingHUDGloballyEnabled else { return nil }
        return tr("Enable Floating HUD in Appearance & Display first", "需先在「外观与显示」中开启桌面悬浮窗")
    }

    @ViewBuilder
    private func destinationCell(
        _ binding: Binding<Bool>?,
        title: String,
        unavailable: Bool,
        help: String?
    ) -> some View {
        Group {
            if let binding {
                DisplayDestinationCheckbox(
                    title: "\(entry.title) \(title)",
                    isOn: binding,
                    disabled: !isEnabled || unavailable,
                    disabledHelp: help
                )
            } else {
                Color.clear
                    .frame(height: 22)
            }
        }
        .frame(width: ServiceRowMetrics.destination)
    }
}

/// 行尾数据来源按钮：悬停提示，点击弹出说明（读哪里、向谁查询、最近一次失败原因）和专属操作。
/// 刷新失败时图标换成橙色感叹号。
private struct ServiceInfoButton: View {
    let entry: ServiceEntry
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: entry.errorDetail == nil ? "info.circle" : "exclamationmark.circle")
                .font(.system(size: 13))
                .foregroundStyle(entry.errorDetail == nil ? Color.secondary : Color.orange)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .pointingHandCursor()
        .help(tr("Data sources", "数据来源"))
        .accessibilityLabel(tr("\(entry.title) data sources", "\(entry.title) 数据来源"))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text(entry.title)
                    .font(.system(size: 13, weight: .semibold))
                ForEach(entry.sourceLines, id: \.self) { line in
                    Text(line)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let errorDetail = entry.errorDetail {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(errorDetail)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(.orange)
                }
                if !entry.actions.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(entry.actions, id: \.title) { item in
                            Button(item.title) {
                                isPresented = false
                                item.action()
                            }
                            .controlSize(.small)
                        }
                    }
                    .padding(.top, 2)
                }
            }
            .padding(14)
            .frame(width: 300, alignment: .leading)
        }
    }
}
