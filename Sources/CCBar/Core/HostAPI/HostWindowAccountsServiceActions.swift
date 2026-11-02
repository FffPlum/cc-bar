import Foundation

enum HostWindowAccountTarget {
    case primary(QuotaApp), imported(ImportedCodexAccount), kimi(KimiManagedAccount), deepSeek(DeepSeekAccount)
}
struct HostWindowAccountPatch {
    var enabled: Bool?
    var menuBar: Bool?
    var floating: Bool?
}

@MainActor
struct HostWindowAccountsActions {
    var refresh: (HostWindowAccountTarget?) async -> Void
    var update: (HostWindowAccountTarget, HostWindowAccountPatch) throws -> Void
    var delete: (HostWindowAccountTarget) throws -> Void
    var retry: (HostWindowAccountTarget) async -> Void
    var resetCredits: (HostWindowAccountTarget) async -> Result<CodexResetCreditsClient.Fetched, QuotaError>
    var reorderImported: ([String]) throws -> Void
    var importOAuth: (ImportedCodexPaste.Parsed, String, Bool) throws -> Void
    var importPAT: (String, Bool) async throws -> Void
    var keychainBlocked: (HostWindowAccountTarget) -> Bool
    var startKimi: (KimiRegion, String?) -> Void
    var cancelKimi: () -> Void
    var authorizeDeepSeek: (String, String?, @escaping () -> Void) async throws -> Void
    var cancelDeepSeek: () -> Void
    var renameDeepSeek: (String, String) throws -> Void
    var grantAccess: (String) -> Void
    var syncFloating: () -> Void

    static func live(state: AppState, settings: SettingsStore) -> Self {
        let failed = HostError(code: "operation_failed", message: tr("Account settings weren't saved. Try again.", "账号设置未保存，请重试。"))
        return Self(
            refresh: { target in
                switch target {
                case .kimi(let account): await state.loadKimiManagedQuota(account: account, reason: .userInitiated)
                case .deepSeek(let account): await state.loadDeepSeekBalance(account: account, reason: .userInitiated)
                default: await state.refreshQuotas(reason: .userInitiated)
                }
            },
            update: { target, patch in
                switch target {
                case .primary(let app):
                    if let value = patch.enabled { settings.setProviderEnabled(value, for: app) }
                    if let value = patch.menuBar { settings.setProviderShownInMenuBar(value, for: app) }
                    if let value = patch.floating { settings.setProviderShownInFloatingHUD(value, for: app) }
                case .imported(let account):
                    state.updateImportedCodexMetadata(id: account.id) {
                        if let value = patch.enabled { $0.visibleInPopover = value }
                        if let value = patch.menuBar { $0.showInMenuBar = value }
                        if let value = patch.floating { $0.showInFloatingHUD = value }
                    }
                    guard let next = state.importedCodexAccounts.first(where: { $0.id == account.id }),
                          patch.enabled.map({ next.visibleInPopover == $0 }) ?? true,
                          patch.menuBar.map({ next.showInMenuBar == $0 }) ?? true,
                          patch.floating.map({ next.showInFloatingHUD == $0 }) ?? true else { throw failed }
                case .kimi(let account):
                    state.updateKimiManagedAccount(id: account.id) {
                        if let value = patch.enabled { $0.visibleInPopover = value }
                        if let value = patch.menuBar { $0.showInMenuBar = value }
                        if let value = patch.floating { $0.showInFloatingHUD = value }
                    }
                    if state.kimiManagedOperationError != nil { throw failed }
                case .deepSeek(let account):
                    state.updateDeepSeekAccount(id: account.id) {
                        if let value = patch.enabled { $0.visibleInPopover = value }
                        if let value = patch.menuBar { $0.showInMenuBar = value }
                        if let value = patch.floating { $0.showInFloatingHUD = value }
                    }
                    if state.deepSeekOperationError != nil { throw failed }
                }
            },
            delete: { target in
                switch target {
                case .imported(let account):
                    state.removeImportedCodexAccount(id: account.id)
                    if state.importedCodexAccounts.contains(where: { $0.id == account.id }) { throw failed }
                case .kimi(let account):
                    state.removeKimiManagedAccount(id: account.id)
                    if state.kimiManagedOperationError != nil { throw failed }
                case .deepSeek(let account):
                    state.removeDeepSeekAccount(id: account.id)
                    if state.deepSeekOperationError != nil { throw failed }
                case .primary: throw HostWindowValidation.invalid()
                }
            },
            retry: { target in
                switch target {
                case .imported(let account):
                    ImportedCodexStore.retryLegacyAccess(accountId: account.id)
                    await state.refreshQuotas(reason: .userInitiated)
                case .kimi(let account): await state.retryKimiKeychainAccess(id: account.id)
                default: break
                }
            },
            resetCredits: { target in
                switch target {
                case .primary(.codex): return await state.fetchCodexResetCredits()
                case .imported(let account): return await state.fetchImportedCodexResetCredits(account: account)
                default: return .failure(.decode("Reset credits unavailable"))
                }
            },
            reorderImported: { ids in
                state.reorderImportedCodexAccounts(orderedIds: ids)
                guard state.importedCodexAccounts.map(\.id) == ids else { throw failed }
            },
            importOAuth: { try state.upsertImportedCodexAccount(from: $0, alias: $1, visibleInPopover: $2) },
            importPAT: { try await state.importCodexPersonalAccessToken(token: $0, visibleInPopover: $1) },
            keychainBlocked: {
                switch $0 {
                case .imported(let account): ImportedCodexStore.isLegacyAccessBlocked(accountId: account.id)
                case .kimi(let account): state.kimiTokenStore.isAccessBlocked(accountID: account.id)
                default: false
                }
            },
            startKimi: { state.startKimiDeviceLogin(region: $0, replacing: $1) },
            cancelKimi: { state.cancelKimiDeviceLogin() },
            authorizeDeepSeek: { name, id, onStateChange in
                try Task.checkCancellation()
                let authorization = DeepSeekAuthorization()
                authorization.onStateChange = onStateChange
                state.deepSeekAuthorization?.cancel()
                state.deepSeekAuthorization = authorization
                defer {
                    authorization.onStateChange = nil
                    if state.deepSeekAuthorization === authorization { state.deepSeekAuthorization = nil }
                }
                do {
                    let grant = try await authorization.authorize()
                    try Task.checkCancellation()
                    try authorization.validateForCommit()
                    let saved = try state.saveDeepSeekAccount(id: id, name: name, kind: .account, secret: grant.token)
                    authorization.finish(completionURL: grant.completionURL)
                    await state.loadDeepSeekBalance(account: saved, reason: .userInitiated)
                } catch { authorization.cancel(); throw error }
            },
            cancelDeepSeek: { state.deepSeekAuthorization?.cancel(); state.deepSeekAuthorization = nil },
            renameDeepSeek: { id, name in
                _ = try state.saveDeepSeekAccount(id: id, name: name, kind: .account, secret: nil)
            },
            grantAccess: { kind in
                if kind == "claudeDesktop" { state.authorizeClaudeDesktopAccess() }
                else { state.authorizeCursorAccess() }
            },
            syncFloating: { FloatingPanelController.shared.sync() }
        )
    }
}
