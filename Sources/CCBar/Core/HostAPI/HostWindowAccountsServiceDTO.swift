import CCBarConfiguration
import Foundation

private enum QuotaManagementProvider: String {
    case claude, chatgpt, kimi, xai, deepseekHarness, antigravity
}

extension HostWindowAccountsService {
    func accountsJSON() -> HostJSON {
        var rows: [HostJSON] = []
        for provider in providers {
            rows.append(primaryJSON(provider))
            if provider.app == .codex { rows += state.importedCodexAccounts.map(importedJSON) }
            if provider.app == .kimi { rows += state.kimiManagedAccounts.map(kimiJSON) }
        }
        rows += state.deepSeekQuotaAccounts.map(deepSeekJSON)
        for app in [AgentApplication.gemini, .grok] {
            guard let login = state.applications.logins[app] else { continue }
            rows.append(row(id: Self.accountID(app.rawValue, raw: login.id), kind: "localLogin", service: app.rawValue,
                name: app.name, subtitle: settings.privacyMode ? privateName(login.id) : login.accountName ?? text("Local sign-in detected", "已识别本机登录"),
                detected: true, sourceOwned: true, sourceApplication: app.rawValue, needsRefresh: login.needsRefresh,
                management: app == .grok ? managementJSON(.xai, isDefault: true) : .null,
                sources: [login.needsRefresh ? text("Open the application to refresh its login.", "请打开原应用刷新登录。")
                    : text("Login managed by the application · Quota unavailable", "登录由原应用管理 · 暂未接入额度查询")]))
        }
        let operationFailed = state.kimiManagedOperationError != nil || state.deepSeekOperationError != nil
        return .object([
            "accounts": .array(rows), "serviceOrder": .array(providers.map { .string($0.app.rawValue) }),
            "floatingEnabled": .bool(settings.floatingEnabled),
            "kimiAuthorization": .object([
                "inProgress": .bool(state.kimiDeviceLoginInProgress), "awaitingBrowser": .bool(state.kimiDeviceLoginInProgress && state.kimiDeviceAuthorization != nil),
                "error": HostWindowJSON.string(state.kimiDeviceLoginError), "region": HostWindowJSON.string(kimiRegion?.rawValue),
                "replacingAccountID": HostWindowJSON.string(kimiReplacingID.map { Self.accountID("kimi", raw: $0) })
            ]),
            "deepSeekAuthorization": .object([
                "inProgress": .bool(deepSeekTask != nil), "awaitingBrowser": .bool(deepSeekTask != nil && state.deepSeekAuthorization?.isWaitingForBrowser == true),
                "error": HostWindowJSON.string(deepSeekError), "region": .null,
                "replacingAccountID": HostWindowJSON.string(deepSeekReplacingID.map { Self.accountID("deepSeek", raw: $0) })
            ]),
            "operationError": operationFailed ? .string(text("Account settings couldn't be saved. Try again.", "账号设置未能保存，请重试。")) : .null
        ])
    }

    private func primaryJSON(_ provider: QuotaProviderDescriptor) -> HostJSON {
        let app = provider.app
        let identity: (name: String?, plan: String?, signedIn: Bool)
        switch app {
        case .codex: identity = (state.codexAccount?.email, state.codexPlanName, state.codexAccount != nil)
        case .claude: identity = (state.claudeDisplayEmail, state.claudePlanName, state.claudeAccount != nil)
        case .antigravity: identity = (nonemptyAccountText(state.antigravityAccount?.email) ?? state.antigravityAccount?.displayName, state.antigravityAccount?.planType ?? state.antigravityQuota?.planType, state.antigravityAccount != nil)
        case .cursor: identity = (state.cursorAccount?.email, state.cursorQuota?.planType, state.cursorAccount != nil)
        case .kimi: identity = (nonemptyAccountText(state.kimiNickname) ?? state.kimiEmail, state.kimiPlanName, state.kimiAccount != nil)
        case .commandCode: identity = (state.commandCodeAccount?.email, state.commandCodeQuota?.planType, state.commandCodeAccount != nil)
        case .opencodeGo: identity = (nil, nil, state.opencodeGoAccount != nil)
        }
        let authorization = app == .claude && state.claudeDesktopAccessDenied ? "claudeDesktop"
            : app == .cursor && state.cursorKeychainAccessRequired ? "cursor" : nil
        let detected = identity.signedIn || authorization != nil || (app == .codex && !state.importedCodexAccounts.isEmpty)
            || (app == .kimi && !state.kimiManagedAccounts.isEmpty)
        let name = if identity.signedIn {
            settings.privacyMode ? privateName("primary:" + app.rawValue) : nonemptyAccountText(identity.name) ?? provider.title
        } else { provider.title }
        let subtitle: String
        if authorization != nil && !identity.signedIn {
            subtitle = text("Authorize access to the application's sign-in.", "请授权读取应用的登录状态。")
        } else if identity.signedIn {
            subtitle = nonemptyAccountText(identity.plan) ?? text("Signed in", "已登录")
        } else { subtitle = connectHint(app) }
        return row(id: Self.accountID(app.rawValue), kind: "primary", service: app.rawValue,
            name: name, subtitle: subtitle,
            plan: identity.plan, region: app == .kimi ? state.kimiCLIRegion?.rawValue : nil,
            detected: detected, current: identity.signedIn, pat: app == .codex && state.codexAccount?.isPersonalAccessToken == true,
            enabled: settings.isProviderEnabled(app), menuBar: settings.isProviderShownInMenuBar(app),
            floating: settings.isProviderShownInFloatingHUD(app), supportsMenuBar: provider.supportsMenuBar,
            supportsFloating: provider.supportsFloatingHUD, authorization: authorization, sourceOwned: true,
            sourceApplication: AgentApplication(rawValue: app.rawValue)?.rawValue,
            management: primaryManagementProvider(app).map { managementJSON($0, isDefault: true) } ?? .null,
            sources: [sourceHelp(app)],
            snapshot: state.quotaSnapshot(for: app), refresh: state.refreshState(for: app), error: state.quotaError(for: app))
    }

    private func importedJSON(_ account: ImportedCodexAccount) -> HostJSON {
        let display = account.alias.isEmpty ? account.email ?? text("Codex account", "Codex 账号") : account.alias
        return row(id: Self.accountID("codex", raw: account.id), kind: "importedCodex", service: "codex",
            name: settings.privacyMode ? privateName(account.id) : display,
            subtitle: CodexAccount.planName(account.planType) ?? text("Signed in", "已登录"), plan: CodexAccount.planName(account.planType),
            detected: true, current: state.importedCodexAccountMirrorsPrimary(account), pat: account.isPersonalAccessToken == true,
            enabled: account.isVisible, menuBar: account.showInMenuBar == true, floating: account.showsInFloatingSurfaces,
            supportsMenuBar: true, supportsFloating: true, blocked: actions.keychainBlocked(.imported(account)),
            management: account.isPersonalAccessToken == true ? .null : managementJSON(.chatgpt, isDefault: false),
            sources: [text("Credentials imported into CCBar's private local storage. Your Codex CLI sign-in is not changed.", "凭据导入 CCBar 的本机私有存储，不会更改 Codex CLI 登录。")],
            snapshot: state.importedCodexQuota(for: account), refresh: state.importedCodexRefreshState(for: account), error: state.importedCodexError(for: account))
    }
    private func kimiJSON(_ account: KimiManagedAccount) -> HostJSON {
        row(id: Self.accountID("kimi", raw: account.id), kind: "managedKimi", service: "kimi",
            name: settings.privacyMode ? privateName(account.id) : nonemptyAccountText(account.nickname) ?? nonemptyAccountText(account.email) ?? text("Kimi account", "Kimi 账号"),
            subtitle: account.region.displayName, plan: account.userLevelName ?? state.kimiManagedQuotas[account.id]?.planType,
            region: account.region.rawValue, detected: true, current: state.kimiManagedMirrorsCLI(account),
            enabled: account.isVisible, menuBar: account.showInMenuBar, floating: account.showsInFloatingSurfaces,
            supportsMenuBar: true, supportsFloating: true, blocked: actions.keychainBlocked(.kimi(account)),
            management: managementJSON(.kimi, isDefault: false),
            sources: [text("Official device authorization managed by CCBar. Your Kimi CLI sign-in is not changed.", "由 CCBar 管理官方设备授权，不会更改 Kimi CLI 登录。")],
            snapshot: state.kimiManagedQuotas[account.id], refresh: state.kimiManagedRefreshStates[account.id] ?? QuotaRefreshState(),
            error: state.kimiManagedErrors[account.id])
    }
    private func deepSeekJSON(_ account: DeepSeekAccount) -> HostJSON {
        let balance: HostJSON
        if let snapshot = state.deepSeekBalances[account.id] {
            balance = .object(["wallets": .array(snapshot.wallets.map { wallet in .object([
                "currency": .string(wallet.currency), "total": HostWindowJSON.decimal(wallet.total),
                "toppedUp": HostWindowJSON.decimal(wallet.toppedUp), "granted": HostWindowJSON.decimal(wallet.granted),
                "displayTotal": .string(CurrencyFormatter.balance(wallet.total, from: wallet.currency))
            ]) }), "available": HostWindowJSON.bool(snapshot.isAvailable), "fetchedAt": HostWindowJSON.date(snapshot.fetchedAt)])
        } else { balance = .null }
        return row(id: Self.accountID("deepSeek", raw: account.id), kind: "deepSeek", service: "deepSeek",
            name: settings.privacyMode ? privateName(account.id) : account.name,
            subtitle: text("Account authorization", "账号授权"), detected: true,
            enabled: account.isVisible, menuBar: account.showInMenuBar, floating: account.showsInFloatingSurfaces,
            supportsMenuBar: true, supportsFloating: true, sourceOwned: account.sourceApplication != nil,
            sourceApplication: account.sourceApplication.flatMap { AgentApplication(rawValue: $0)?.rawValue },
            management: managementJSON(.deepseekHarness, isDefault: account.sourceApplication != nil),
            sources: [account.sourceApplication != nil
                ? text("Detected in an application. Removing the CCBar copy leaves the original application signed in.", "从应用自动识别。删除 CCBar 副本后，原应用保持登录。")
                : text("Credentials saved by CCBar. Removing a browser authorization also requests sign-out from DeepSeek.", "凭据由 CCBar 保存。删除浏览器授权账号时也会向 DeepSeek 请求退出登录。")],
            refresh: state.deepSeekRefreshStates[account.id] ?? QuotaRefreshState(), error: state.deepSeekErrors[account.id], balance: balance)
    }

    private func row(id: String, kind: String, service: String, name: String, subtitle: String,
                     plan: String? = nil, region: String? = nil, detected: Bool = false, current: Bool = false,
                     pat: Bool = false, enabled: Bool = false, menuBar: Bool = false, floating: Bool = false,
                     supportsMenuBar: Bool = false, supportsFloating: Bool = false, blocked: Bool = false,
                     authorization: String? = nil, sourceOwned: Bool = false, sourceApplication: String? = nil,
                     needsRefresh: Bool = false, management: HostJSON = .null, sources: [String] = [], snapshot: QuotaSnapshot? = nil,
                     refresh: QuotaRefreshState = QuotaRefreshState(), error: String? = nil, balance: HostJSON = .null) -> HostJSON {
        .object([
            "id": .string(id), "kind": .string(kind), "service": .string(service), "name": .string(name), "subtitle": .string(subtitle),
            "plan": HostWindowJSON.string(plan), "region": HostWindowJSON.string(region), "detected": .bool(detected), "current": .bool(current),
            "personalAccessToken": .bool(pat), "enabled": .bool(enabled), "showInMenuBar": .bool(menuBar), "showInFloatingHUD": .bool(floating),
            "supportsMenuBar": .bool(supportsMenuBar), "supportsFloatingHUD": .bool(supportsFloating), "keychainAccessBlocked": .bool(blocked),
            "authorizationRequired": HostWindowJSON.string(authorization), "sourceLines": .array(sources.map(HostJSON.string)),
            "sourceOwned": .bool(sourceOwned), "sourceApplication": HostWindowJSON.string(sourceApplication), "needsRefresh": .bool(needsRefresh),
            "quotaManagement": management,
            "snapshot": quotaSnapshotJSON(snapshot), "balance": balance,
            "refresh": refreshJSON(refresh, error: error == nil ? nil : text("Refresh failed. Try again after the retry period.", "刷新失败，请等待重试间隔后再试。"))
        ])
    }

    // The shared account list also feeds statistics. Keep those accounts intact,
    // and describe eligibility for the narrower account-management view separately.
    private func primaryManagementProvider(_ app: QuotaApp) -> QuotaManagementProvider? {
        switch app {
        case .codex:
            guard let account = state.codexAccount, !account.isPersonalAccessToken else { return nil }
            return .chatgpt
        case .claude:
            return state.claudeAccount != nil || state.claudeDesktopAccessDenied ? .claude : nil
        case .kimi:
            guard let account = state.kimiAccount, account.source != .apiKey else { return nil }
            return .kimi
        case .antigravity:
            return state.antigravityAccount != nil ? .antigravity : nil
        case .cursor, .commandCode, .opencodeGo:
            return nil
        }
    }

    private func managementJSON(_ provider: QuotaManagementProvider, isDefault: Bool) -> HostJSON {
        .object(["provider": .string(provider.rawValue), "isDefault": .bool(isDefault)])
    }

    private func nonemptyAccountText(_ value: String?) -> String? {
        guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    private func connectHint(_ app: QuotaApp) -> String {
        switch app {
        case .codex: text("Sign in with the Codex CLI to detect it", "用 Codex CLI 登录后自动识别")
        case .claude: text("Sign in to Claude Code CLI or Claude Desktop to detect it", "登录 Claude Code CLI 或 Claude 桌面版后自动识别")
        case .antigravity: text("Sign in to Antigravity (agy CLI or IDE plugin) to detect it", "登录 Antigravity（agy CLI 或 IDE 插件）后自动识别")
        case .cursor: text("Sign in to the Cursor app to detect it", "登录 Cursor 应用后自动识别")
        case .kimi: text("Sign in with /login in Kimi Code CLI to detect it", "在 Kimi Code CLI 中运行 /login 后自动识别")
        case .commandCode: text("Sign in with the Command Code CLI", "登录 Command Code CLI")
        case .opencodeGo: text("Connect OpenCode Go in OpenCode or Pi", "在 OpenCode 或 Pi 中连接 OpenCode Go")
        }
    }
    private func sourceHelp(_ app: QuotaApp) -> String {
        switch app {
        case .codex: text("Reads ~/.codex/auth.json and asks OpenAI for quota. Read-only; your sign-in is not changed.", "读取 ~/.codex/auth.json，向 OpenAI 查询额度。只读取，不改动登录。")
        case .claude: text("Reads Claude Code CLI or Claude Desktop sign-in and asks Anthropic for quota. Your sign-in is not changed.", "读取 Claude Code CLI 或 Claude 桌面版登录，向 Anthropic 查询额度，不改动登录。")
        case .antigravity: text("Reads ~/.gemini (agy CLI / IDE plugin) and asks Google for quota. Your sign-in is not changed.", "读取 ~/.gemini（agy CLI / IDE 插件）登录，向 Google 查询额度，不改动登录。")
        case .cursor: text("Reads Cursor sign-in, using Cursor Safe Storage in Keychain when encrypted, and queries Cursor quota.", "读取 Cursor 登录，加密时使用钥匙串中的 Cursor Safe Storage 解密，向 Cursor 查询额度。")
        case .kimi: text("Reads Kimi CLI sign-in. Expired access tokens are renewed and saved back to the CLI credential file.", "读取 Kimi CLI 登录。访问令牌过期后自动续期，并同步更新 CLI 凭据文件。")
        case .commandCode: text("Reads local or manually supplied Command Code credentials.", "读取本机或手动填写的 Command Code 凭据。")
        case .opencodeGo: text("Reads the OpenCode Go key from OpenCode, Pi or local configuration.", "读取 OpenCode、Pi 或本机配置中的 OpenCode Go Key。")
        }
    }
}
