import Foundation

@MainActor
extension AppState {
    /// Only browser sign-ins participate in quota management. Legacy API keys remain
    /// available to the provider catalog without changing their credential references.
    var deepSeekQuotaAccounts: [DeepSeekAccount] { deepSeekAccounts.filter { $0.kind == .account } }

    func loadDeepSeekAccounts() {
        deepSeekAccounts = DeepSeekAccountStore.load(from: accountStorageURL("deepseek_accounts.json"))
        if let data = try? Data(contentsOf: accountStorageURL("deepseek_balances.json")),
           let cached = try? JSONDecoder().decode([String: DeepSeekBalance].self, from: data) {
            deepSeekBalances = cached.filter { id, balance in
                deepSeekAccounts.contains { $0.id == id && $0.credentialFingerprint == balance.credentialFingerprint }
            }
        }
        for (id, balance) in deepSeekBalances {
            var state = QuotaRefreshState()
            state.lastSuccessAt = balance.fetchedAt
            state.source = .cache
            deepSeekRefreshStates[id] = state
        }
    }

    func saveDeepSeekAccount(id: String?, name: String, kind: DeepSeekAuthKind, secret: String?) throws -> DeepSeekAccount {
        guard !isPreparingForTermination else { throw QuotaError.transport("App is closing") }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw QuotaError.decode("Account name is required") }
        var accounts = deepSeekAccounts
        let previous = id.flatMap { id in accounts.first { $0.id == id } }
        guard id == nil || previous != nil else { throw QuotaError.decode("Account no longer exists") }
        let accountID = previous?.id ?? UUID().uuidString
        let oldSecret = deepSeekCredentialStore.load(id: accountID)
        let entered = secret?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let value = entered.isEmpty ? oldSecret : entered, DeepSeekAccount.validSecret(value),
              previous == nil || previous?.kind == kind else { throw QuotaError.decode("Invalid DeepSeek credential") }
        let fingerprint = DeepSeekAccount.fingerprint(value, kind: kind)
        var account = previous ?? DeepSeekAccount(id: accountID, name: name, kind: kind, credentialFingerprint: fingerprint)
        account.name = name
        account.credentialFingerprint = fingerprint
        if let index = accounts.firstIndex(where: { $0.id == accountID }) { accounts[index] = account }
        else { accounts.append(account) }
        try deepSeekCredentialStore.save(value, id: accountID)
        do { try DeepSeekAccountStore.save(accounts, to: accountStorageURL("deepseek_accounts.json")) }
        catch {
            if let oldSecret { try? deepSeekCredentialStore.save(oldSecret, id: accountID) }
            else { _ = deepSeekCredentialStore.delete(id: accountID) }
            throw error
        }
        deepSeekAccounts = accounts
        deepSeekOperationError = nil
        if previous?.credentialFingerprint != fingerprint {
            deepSeekRequestIDs[accountID] = nil
            deepSeekBalances[accountID] = nil
            deepSeekRefreshStates[accountID] = nil
            deepSeekErrors[accountID] = nil
            saveDeepSeekBalanceCache()
        }
        return account
    }

    func updateDeepSeekAccount(id: String, update: (inout DeepSeekAccount) -> Void) {
        guard let index = deepSeekAccounts.firstIndex(where: { $0.id == id }) else { return }
        var accounts = deepSeekAccounts
        update(&accounts[index])
        if accounts[index].showInFloatingHUD != deepSeekAccounts[index].showInFloatingHUD {
            accounts[index].visibleInPopover = accounts[index].showInFloatingHUD
        } else if accounts[index].visibleInPopover != deepSeekAccounts[index].visibleInPopover {
            accounts[index].showInFloatingHUD = accounts[index].visibleInPopover
        }
        do {
            try DeepSeekAccountStore.save(accounts, to: accountStorageURL("deepseek_accounts.json"))
            deepSeekAccounts = accounts
            deepSeekOperationError = nil
        } catch { deepSeekOperationError = tr("Couldn't save account settings. Try again.", "账号设置未能保存，请重试") }
    }

    func removeDeepSeekAccount(id: String) {
        guard let account = deepSeekAccounts.first(where: { $0.id == id }) else { return }
        let secret = deepSeekCredentialStore.load(id: id)
        if account.sourceApplication != nil {
            do {
                try authorizations.ignoreImport(account.credentialFingerprint)
                if let source = account.sourceConfigurationID { try authorizations.ignoreImport(source) }
            }
            catch { deepSeekOperationError = tr("Couldn't save account settings.", "账号设置未能保存。"); return }
        }
        guard deepSeekCredentialStore.delete(id: id) else {
            deepSeekOperationError = tr("Couldn't remove credentials. Try again.", "凭据未能删除，请重试")
            return
        }
        let accounts = deepSeekAccounts.filter { $0.id != id }
        do { try DeepSeekAccountStore.save(accounts, to: accountStorageURL("deepseek_accounts.json")) }
        catch {
            if let secret { try? deepSeekCredentialStore.save(secret, id: id) }
            deepSeekOperationError = tr("Couldn't remove the account. Try again.", "账号未能删除，请重试")
            return
        }
        deepSeekAccounts = accounts
        deepSeekRequestIDs[id] = nil
        deepSeekBalances[id] = nil
        deepSeekRefreshStates[id] = nil
        deepSeekErrors[id] = nil
        deepSeekOperationError = nil
        saveDeepSeekBalanceCache()
        if account.kind == .account, account.sourceApplication == nil, let secret,
           !accounts.contains(where: { $0.credentialFingerprint == account.credentialFingerprint }) {
            let metadata = DeepSeekClient.ClientMetadata.current
            Task {
                _ = try? await DeepSeekClient.request(path: "/auth-api/v0/users/logout", body: [:],
                                                      token: secret, metadata: metadata)
            }
        }
    }

    func deepSeekDisplayName(_ account: DeepSeekAccount) -> String {
        PrivacyDisplay.isEnabled ? PrivacyDisplay.account(account.id) : account.name
    }

    func loadAllDeepSeekBalances(reason: QuotaRefreshReason) async {
        for account in deepSeekAccounts where account.isVisible {
            await loadDeepSeekBalance(account: account, reason: reason)
        }
    }

    func loadDeepSeekBalance(account: DeepSeekAccount, reason: QuotaRefreshReason,
                             fetch: @Sendable (DeepSeekAccount, String, DeepSeekClient.ClientMetadata) async -> Result<DeepSeekBalance, QuotaError> = {
                                 await DeepSeekClient.fetch(account: $0, secret: $1, metadata: $2)
                             }) async {
        let id = account.id
        var state = deepSeekRefreshStates[id] ?? QuotaRefreshState()
        guard !isPreparingForTermination, !state.inFlight,
              deepSeekAccounts.contains(where: { $0.id == id && $0.credentialFingerprint == account.credentialFingerprint }) else { return }
        if let until = state.backoffUntil, until > Date() { deepSeekErrors[id] = backoffMessage(until: until); return }
        if reason == .periodic, let last = state.lastAttemptAt, Date().timeIntervalSince(last) < 60 { return }
        guard let secret = deepSeekCredentialStore.load(id: id),
              DeepSeekAccount.fingerprint(secret, kind: account.kind) == account.credentialFingerprint else {
            let message = tr("Credentials unavailable. Reconnect the account.", "凭据不可用，请重新连接账号")
            deepSeekErrors[id] = message
            state.lastError = message
            state.lastErrorIsNetwork = false
            deepSeekRefreshStates[id] = state
            return
        }
        let requestID = UUID()
        deepSeekRequestIDs[id] = requestID
        state.inFlight = true
        state.lastAttemptAt = Date()
        deepSeekRefreshStates[id] = state
        defer {
            if deepSeekRequestIDs[id] == requestID {
                deepSeekRefreshStates[id]?.inFlight = false
                deepSeekRequestIDs[id] = nil
            }
        }
        let result = await fetch(account, secret, .current)
        guard !isPreparingForTermination, deepSeekRequestIDs[id] == requestID,
              deepSeekAccounts.contains(where: { $0.id == id && $0.credentialFingerprint == account.credentialFingerprint }),
              deepSeekCredentialStore.load(id: id) == secret else { return }
        switch result {
        case .success(var balance):
            balance.credentialFingerprint = account.credentialFingerprint
            deepSeekBalances[id] = balance
            deepSeekErrors[id] = nil
            state.lastSuccessAt = balance.fetchedAt
            state.lastError = nil
            state.lastErrorIsNetwork = false
            state.backoffUntil = nil
            state.source = .api
            saveDeepSeekBalanceCache()
        case .failure(let error):
            let message: String
            if case .http(401, _) = error {
                message = tr("Authorization expired. Reconnect the account.", "授权已失效，请重新连接账号")
            } else { message = error.userMessage }
            deepSeekErrors[id] = message
            state.lastError = message
            state.lastErrorIsNetwork = error.isNetworkFailure
            if error.isRateLimited { state.backoffUntil = Date().addingTimeInterval(600) }
        }
        deepSeekRefreshStates[id] = state
    }

    private func saveDeepSeekBalanceCache() {
        do { try JSONEncoder().encode(deepSeekBalances).write(to: accountStorageURL("deepseek_balances.json"), options: .atomic) }
        catch { AppLog.error(.quota, "DeepSeek balance cache save failed") }
    }
}
