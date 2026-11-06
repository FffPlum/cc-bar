import CCBarConfiguration
import Foundation

@MainActor
final class HostWindowAccountsService: HostWindowPresenter {
    static let methods: Set<String> = ["quota.accounts", "quota.updateAccount", "quota.reorder", "quota.resetCredits", "window.quota.refresh",
        "codex.preview", "codex.import", "codex.delete", "codex.retryAccess", "kimi.startAuthorization", "kimi.cancelAuthorization",
        "kimi.retryAccess", "kimi.delete", "deepseek.startAuthorization", "deepseek.cancelAuthorization", "deepseek.rename",
        "deepseek.delete", "deepseek.refresh", "authorizations.grantAccess"]
    var didChange: (() -> Void)?
    let actions: HostWindowAccountsActions
    var kimiRegion: KimiRegion?
    var kimiReplacingID: String?
    var ownsKimi = false
    var kimiLoginID: UUID?
    var kimiWatcher: Task<Void, Never>?
    var deepSeekTask: Task<Void, Never>?
    var deepSeekError: String?
    var deepSeekReplacingID: String?
    var generation = 0
    var deepSeekGeneration = 0
    var importing = false

    override convenience init(state: AppState, settings: SettingsStore) {
        self.init(state: state, settings: settings, actions: .live(state: state, settings: settings))
    }
    init(state: AppState, settings: SettingsStore, actions: HostWindowAccountsActions) {
        self.actions = actions
        super.init(state: state, settings: settings)
    }

    func invalidate() {
        generation += 1
        deepSeekGeneration += 1
        kimiWatcher?.cancel(); kimiWatcher = nil
        if ownsKimi, let kimiLoginID, state.kimiDeviceLoginID == kimiLoginID { actions.cancelKimi() }
        ownsKimi = false; kimiLoginID = nil
        if deepSeekTask != nil { deepSeekTask?.cancel(); deepSeekTask = nil; actions.cancelDeepSeek() }
    }
    func trackChanges() {
        _ = (state.codexAccount, state.claudeAccount, state.antigravityAccount, state.cursorAccount, state.kimiAccount,
             state.claudeDisplayEmail, state.claudePlanName, state.kimiNickname, state.kimiPlanName,
             state.primaryQuotaStates, state.importedCodexAccounts, state.importedCodexQuotas, state.importedCodexRefreshStates,
             state.importedCodexErrors, state.kimiManagedAccounts, state.kimiManagedQuotas, state.kimiManagedRefreshStates,
             state.kimiManagedErrors, state.kimiDeviceLoginInProgress, state.kimiDeviceLoginError, state.kimiDeviceAuthorization,
             state.deepSeekAccounts, state.deepSeekBalances, state.deepSeekRefreshStates, state.deepSeekErrors,
             state.deepSeekOperationError, state.kimiManagedOperationError, state.claudeDesktopAccessDenied,
             state.cursorKeychainAccessRequired, state.applications.logins, settings.serviceOrder,
             settings.providerDisplaySettings, settings.privacyMode, settings.floatingEnabled)
    }

    func handle(_ method: String, params: [String: HostJSON]) async throws -> HostJSON {
        switch method {
        case "quota.accounts": try keys(params, []); return accountsJSON()
        case "quota.updateAccount":
            try keys(params, ["id", "patch"])
            let account = try target(try string(params, "id"))
            let raw = try HostWindowValidation.object(params, "patch")
            try keys(raw, ["enabled", "showInMenuBar", "showInFloatingHUD"])
            let patch = HostWindowAccountPatch(enabled: try HostWindowValidation.bool(raw, "enabled", required: false),
                menuBar: try HostWindowValidation.bool(raw, "showInMenuBar", required: false),
                floating: try HostWindowValidation.bool(raw, "showInFloatingHUD", required: false))
            if case .primary(let app) = account,
               let provider = providers.first(where: { $0.app == app }) {
                guard patch.menuBar == nil || provider.supportsMenuBar,
                      patch.floating == nil || provider.supportsFloatingHUD else { throw HostWindowValidation.invalid() }
            }
            try actions.update(account, patch)
            actions.syncFloating(); didChange?()
            if patch.enabled == true || patch.menuBar == true || patch.floating == true {
                await actions.refresh(account); didChange?()
            }
            return accountsJSON()
        case "quota.reorder": return try reorder(params)
        case "window.quota.refresh":
            try keys(params, ["id"])
            let raw = try HostWindowValidation.string(params, "id", required: false)
            let account = try raw.map { try target($0) }
            if raw == nil { await actions.discoverAccounts() }
            await actions.refresh(account); didChange?(); return accountsJSON()
        case "quota.resetCredits":
            try keys(params, ["id"])
            let id = try string(params, "id"), account = try target(id)
            switch account { case .primary(.codex), .imported: break; default: throw HostWindowValidation.invalid() }
            switch await actions.resetCredits(account) {
            case .success(let result):
                return .object(["accountID": .string(id), "availableCount": .number(Decimal(result.availableCount)),
                    "credits": .array(result.credits.map { credit in .object([
                        "id": .string(credit.id), "title": .string(credit.title), "status": .string(credit.status),
                        "grantedAt": HostWindowJSON.date(credit.grantedAt), "expiresAt": HostWindowJSON.date(credit.expiresAt)
                    ]) }), "error": .null])
            case .failure:
                return .object(["accountID": .string(id), "availableCount": .number(0), "credits": .array([]),
                                "error": .string(text("Couldn't load reset credits. Try again.", "重置次数未能加载，请重试。"))])
            }
        case "codex.preview":
            try keys(params, ["payload"])
            let payload = try string(params, "payload", max: 1_048_576)
            if ImportedCodexPaste.personalAccessToken(in: payload) != nil { return .object(["kind": .string("personalAccessToken"), "accounts": .array([])]) }
            let parsed = try parseCodex(payload)
            return .object(["kind": .string("oauth"), "accounts": .array(parsed.map { account in .object([
                "id": .string(Self.accountID("codex", raw: account.id)),
                "email": HostWindowJSON.string(settings.privacyMode ? privateName(account.id) : account.email),
                "plan": HostWindowJSON.string(CodexAccount.planName(account.planType)),
                "chatgptAccountID": .string(settings.privacyMode ? "••••" : account.chatgptAccountId)
            ]) })])
        case "codex.import": return try await importCodex(params)
        case "codex.delete", "kimi.delete", "deepseek.delete":
            try keys(params, ["id"])
            let account = try typedTarget(try string(params, "id"), prefix: String(method.split(separator: ".")[0]))
            try actions.delete(account); actions.syncFloating(); didChange?(); return accountsJSON()
        case "codex.retryAccess", "kimi.retryAccess":
            try keys(params, ["id"])
            let account = try typedTarget(try string(params, "id"), prefix: String(method.split(separator: ".")[0]))
            await actions.retry(account); didChange?(); return accountsJSON()
        case "kimi.startAuthorization":
            try keys(params, ["region", "replacingAccountID"])
            guard let region = KimiRegion(rawValue: try string(params, "region")) else { throw HostWindowValidation.invalid() }
            var replacing: String?
            if let id = try HostWindowValidation.string(params, "replacingAccountID", required: false) {
                guard case .kimi(let account) = try target(id), account.region == region else { throw HostWindowValidation.invalid() }
                replacing = account.id
            }
            guard !state.kimiDeviceLoginInProgress else { return .object(["started": .bool(false)]) }
            generation += 1
            kimiRegion = region; kimiReplacingID = replacing
            actions.startKimi(region, replacing)
            ownsKimi = state.kimiDeviceLoginInProgress
            kimiLoginID = ownsKimi ? state.kimiDeviceLoginID : nil
            if let task = state.kimiDeviceLoginTask {
                let epoch = generation
                kimiWatcher = Task { [weak self] in
                    await task.value
                    guard let self, self.generation == epoch, !Task.isCancelled else { return }
                    self.ownsKimi = false; self.kimiLoginID = nil
                    self.didChange?()
                }
            }
            didChange?(); return .object(["started": .bool(state.kimiDeviceLoginInProgress)])
        case "kimi.cancelAuthorization":
            try keys(params, []); generation += 1
            kimiWatcher?.cancel(); kimiWatcher = nil
            actions.cancelKimi(); ownsKimi = false; kimiLoginID = nil
            didChange?(); return accountsJSON()
        case "deepseek.startAuthorization": return try startDeepSeek(params)
        case "deepseek.cancelAuthorization":
            try keys(params, []); cancelDeepSeek(); didChange?(); return accountsJSON()
        case "deepseek.rename":
            try keys(params, ["id", "name"])
            guard case .deepSeek(let account) = try target(try string(params, "id")) else { throw HostWindowValidation.invalid() }
            let name = try nonemptyName(params)
            do { try actions.renameDeepSeek(account.id, name) }
            catch { throw HostError(code: "operation_failed", message: text("Account name wasn't saved. Try again.", "账号名称未保存，请重试。")) }
            didChange?(); return accountsJSON()
        case "deepseek.refresh":
            try keys(params, ["id"])
            let account = try typedTarget(try string(params, "id"), prefix: "deepseek")
            await actions.refresh(account); didChange?(); return accountsJSON()
        case "authorizations.grantAccess":
            try keys(params, ["kind"])
            let kind = try string(params, "kind")
            guard ["claudeDesktop", "cursor"].contains(kind) else { throw HostWindowValidation.invalid() }
            actions.grantAccess(kind); didChange?(); return accountsJSON()
        default: throw HostError(code: "unknown_method", message: "Unknown account method")
        }
    }

    var providers: [QuotaProviderDescriptor] { settings.orderedProviders.filter { !$0.app.usesAPIKey } }
    static func accountID(_ service: String, raw: String? = nil) -> String {
        HostWindowUsageService.quotaAccountID(service: service, kind: raw == nil ? "primary" : "imported", rawID: raw)
    }
    func target(_ id: String) throws -> HostWindowAccountTarget {
        if let provider = providers.first(where: { Self.accountID($0.app.rawValue) == id }) { return .primary(provider.app) }
        if let account = state.importedCodexAccounts.first(where: { Self.accountID("codex", raw: $0.id) == id }) { return .imported(account) }
        if let account = state.kimiManagedAccounts.first(where: { Self.accountID("kimi", raw: $0.id) == id }) { return .kimi(account) }
        if let account = state.deepSeekQuotaAccounts.first(where: { Self.accountID("deepSeek", raw: $0.id) == id }) { return .deepSeek(account) }
        throw HostWindowValidation.notFound()
    }
    private func typedTarget(_ id: String, prefix: String) throws -> HostWindowAccountTarget {
        let account = try target(id)
        switch (prefix, account) { case ("codex", .imported), ("kimi", .kimi), ("deepseek", .deepSeek): return account; default: throw HostWindowValidation.invalid() }
    }
    private func reorder(_ params: [String: HostJSON]) throws -> HostJSON {
        try keys(params, ["serviceOrder", "importedCodexOrder"])
        guard let order = try HostWindowValidation.stringArray(params, "serviceOrder"), Set(order).count == order.count,
              Set(order) == Set(providers.map { $0.app.rawValue }) else { throw HostWindowValidation.invalid() }
        let imported = try HostWindowValidation.stringArray(params, "importedCodexOrder", required: false, max: 1000)
        let rawImported = try imported.map { ids -> [String] in
            guard Set(ids).count == ids.count, Set(ids) == Set(state.importedCodexAccounts.map { Self.accountID("codex", raw: $0.id) }) else { throw HostWindowValidation.invalid() }
            return try ids.map { id in guard case .imported(let account) = try target(id) else { throw HostWindowValidation.invalid() }; return account.id }
        }
        if let rawImported { try actions.reorderImported(rawImported) }
        var remaining = order.makeIterator()
        let allowed = Set(order)
        let next = settings.orderedServices.map { item -> ServiceOrderItem in
            if case .quota(let app) = item, allowed.contains(app.rawValue), let next = remaining.next(), let replacement = QuotaApp(rawValue: next) { return .quota(replacement) }
            return item
        }
        settings.reorderServices(next); didChange?(); return accountsJSON()
    }
    private func parseCodex(_ payload: String) throws -> [ImportedCodexPaste.Parsed] {
        switch ImportedCodexPaste.parseAny(payload) {
        case .success(let parsed): return parsed
        case .failure: throw HostError(code: "invalid_params", message: text("Credentials couldn't be read. Paste Codex auth.json or a personal access token JSON.", "凭据无法读取，请粘贴 Codex auth.json 或个人访问令牌 JSON。"))
        }
    }
    private func importCodex(_ params: [String: HostJSON]) async throws -> HostJSON {
        try keys(params, ["payload", "visibleInPopover", "alias"])
        let payload = try string(params, "payload", max: 1_048_576)
        guard let visible = try HostWindowValidation.bool(params, "visibleInPopover") else { throw HostWindowValidation.invalid() }
        let alias = try HostWindowValidation.string(params, "alias", required: false, max: 200) ?? ""
        let pat = ImportedCodexPaste.personalAccessToken(in: payload)
        let parsed = pat == nil ? try parseCodex(payload) : []
        guard pat == nil || alias.isEmpty else { throw HostWindowValidation.invalid() }
        guard !importing else { throw HostError(code: "busy", message: text("An import is already running.", "正在导入，请稍候。")) }
        importing = true; defer { importing = false }
        var imported = 0, failed = 0
        if let pat {
            do { try await actions.importPAT(pat, visible); imported = 1 } catch { failed = 1 }
        } else {
            for account in parsed {
                do { try actions.importOAuth(account, alias, visible); imported += 1 } catch { failed += 1 }
            }
        }
        didChange?()
        return .object(["imported": .number(Decimal(imported)), "failed": .number(Decimal(failed)),
                        "error": failed > 0 ? .string(text("Some accounts weren't imported. Check the credentials and retry.", "部分账号未导入，请检查凭据后重试。")) : .null])
    }
    private func startDeepSeek(_ params: [String: HostJSON]) throws -> HostJSON {
        try keys(params, ["name", "accountID"])
        let name = try nonemptyName(params)
        var rawID: String?
        if let id = try HostWindowValidation.string(params, "accountID", required: false) {
            guard case .deepSeek(let account) = try target(id) else { throw HostWindowValidation.invalid() }
            rawID = account.id
        }
        guard deepSeekTask == nil else { return .object(["started": .bool(false)]) }
        deepSeekError = nil; deepSeekReplacingID = rawID
        let epoch = deepSeekGeneration
        deepSeekTask = Task { [weak self] in
            guard let self, self.deepSeekGeneration == epoch, !Task.isCancelled else { return }
            do {
                try await self.actions.authorizeDeepSeek(name, rawID) { [weak self] in
                    guard let self, self.deepSeekGeneration == epoch else { return }
                    self.didChange?()
                }
            }
            catch {
                guard self.deepSeekGeneration == epoch, !Task.isCancelled else { return }
                self.deepSeekError = self.text("Authorization wasn't completed. Try signing in again.", "授权未完成，请重新登录。")
            }
            guard self.deepSeekGeneration == epoch, !Task.isCancelled else { return }
            self.deepSeekTask = nil; self.didChange?()
        }
        didChange?(); return .object(["started": .bool(true)])
    }
    private func cancelDeepSeek() {
        deepSeekGeneration += 1
        if deepSeekTask != nil { deepSeekTask?.cancel(); deepSeekTask = nil; actions.cancelDeepSeek() }
        deepSeekError = nil; deepSeekReplacingID = nil
    }
    private func nonemptyName(_ params: [String: HostJSON]) throws -> String {
        let name = try string(params, "name", max: 200).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw HostWindowValidation.invalid() }
        return name
    }
    func keys(_ params: [String: HostJSON], _ allowed: Set<String>) throws { try HostWindowValidation.keys(params, allowed: allowed) }
    func string(_ params: [String: HostJSON], _ key: String, max: Int = 4096) throws -> String {
        guard let value = try HostWindowValidation.string(params, key, max: max) else { throw HostWindowValidation.invalid() }; return value
    }
    func text(_ english: String, _ chinese: String) -> String { settings.resolvedLanguage == .zh ? chinese : english }
    func privateName(_ key: String) -> String { text("Account", "账号") + " · " + String(Self.accountID("private", raw: key).suffix(6)) }
}
