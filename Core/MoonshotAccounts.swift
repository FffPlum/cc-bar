import Foundation

@MainActor
extension AppState {
    func loadMoonshotAccounts() {
        moonshotAccounts = MoonshotAccountStore.loadAll(from: accountStorageURL("moonshot_api_accounts.json"))
        var upgraded = false
        for index in moonshotAccounts.indices where moonshotAccounts[index].keyFingerprint == nil {
            let account = moonshotAccounts[index]
            if let key = moonshotAPIKeyStore.load(accountID: account.id) {
                moonshotAccounts[index].keyFingerprint = KimiManagedAccount.digest(account.region.rawValue + ":" + key)
                upgraded = true
            }
        }
        if upgraded { try? persistMoonshotMetadata(moonshotAccounts) }
        let byID = Dictionary(moonshotAccounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        moonshotBalances = MoonshotBalanceCache.load(from: accountStorageURL("moonshot_balance_cache.json")).filter { id, balance in
            guard let account = byID[id], let fingerprint = account.keyFingerprint else { return false }
            return balance.currencyCode == account.currencyCode && balance.keyFingerprint == fingerprint
        }
        moonshotErrors = moonshotErrors.filter { byID[$0.key] != nil }
        moonshotRefreshStates = [:]
        for (id, balance) in moonshotBalances {
            var state = QuotaRefreshState()
            state.lastSuccessAt = balance.fetchedAt
            state.source = .cache
            moonshotRefreshStates[id] = state
        }
    }

    func saveMoonshotAccount(
        id: String?, name: String, region: KimiRegion, apiKey: String?, refreshAfterSave: Bool = true
    ) async throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw MoonshotAccountEditError.emptyName }
        guard !isPreparingForTermination else { throw MoonshotAccountEditError.unavailable }
        var candidate = moonshotAccounts
        let existingIndex = id.flatMap { id in candidate.firstIndex(where: { $0.id == id }) }
        if id != nil && existingIndex == nil { throw MoonshotAccountEditError.unavailable }
        let previous = existingIndex.map { candidate[$0] }
        let accountID = previous?.id ?? UUID().uuidString
        let oldKey = moonshotAPIKeyStore.load(accountID: accountID)
        let entered = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if previous?.region != nil && previous?.region != region && entered.isEmpty {
            throw MoonshotAccountEditError.regionNeedsKey
        }
        let key = entered.isEmpty ? oldKey : KimiCredentials.sanitizeToken(entered)
        guard let key, KimiCredentials.sanitizeToken(key) != nil else { throw MoonshotAccountEditError.invalidKey }
        var account = previous ?? MoonshotAccount(id: accountID, name: name, region: region)
        account.name = name
        account.region = region
        account.keyFingerprint = KimiManagedAccount.digest(region.rawValue + ":" + key)
        let credentialChanged = previous == nil || previous?.region != region || previous?.keyFingerprint != account.keyFingerprint
        if let index = existingIndex { candidate[index] = account } else { candidate.append(account) }
        try moonshotAPIKeyStore.save(key, accountID: accountID)
        do { try persistMoonshotMetadata(candidate) }
        catch {
            if let oldKey { try? moonshotAPIKeyStore.save(oldKey, accountID: accountID) }
            else { moonshotAPIKeyStore.delete(accountID: accountID) }
            throw error
        }
        moonshotAccounts = candidate
        moonshotOperationError = nil
        if credentialChanged {
            moonshotRequestIDs[accountID] = nil
            moonshotBalances[accountID] = nil
            moonshotErrors[accountID] = nil
            moonshotRefreshStates[accountID] = nil
            saveMoonshotBalanceCache()
        }
        if refreshAfterSave { await loadMoonshotBalance(account: account, reason: .userInitiated) }
    }

    func updateMoonshotAccount(id: String, _ update: (inout MoonshotAccount) -> Void) {
        guard let index = moonshotAccounts.firstIndex(where: { $0.id == id }) else { return }
        var candidate = moonshotAccounts
        update(&candidate[index])
        do {
            try persistMoonshotMetadata(candidate)
            moonshotAccounts = candidate
            moonshotOperationError = nil
        } catch { moonshotOperationError = tr("Couldn't save account settings. Try again.", "账号设置未能保存，请重试") }
    }

    func removeMoonshotAccount(id: String) {
        let candidate = moonshotAccounts.filter { $0.id != id }
        do { try persistMoonshotMetadata(candidate) }
        catch {
            moonshotOperationError = tr("Couldn't remove the account. Try again.", "账号未能删除，请重试")
            return
        }
        moonshotRequestIDs[id] = nil
        moonshotAccounts = candidate
        moonshotAPIKeyStore.delete(accountID: id)
        moonshotBalances[id] = nil
        moonshotErrors[id] = nil
        moonshotRefreshStates[id] = nil
        moonshotOperationError = nil
        saveMoonshotBalanceCache()
    }

    private func persistMoonshotMetadata(_ accounts: [MoonshotAccount]) throws {
        try MoonshotAccountStore.saveAll(accounts, to: accountStorageURL("moonshot_api_accounts.json"))
    }

    func moonshotDisplayName(_ account: MoonshotAccount) -> String {
        PrivacyDisplay.isEnabled ? PrivacyDisplay.account(account.id) : account.name
    }

    func loadAllMoonshotBalances(reason: QuotaRefreshReason) async {
        for account in moonshotAccounts where account.visibleInPopover || account.showInMenuBar || account.showInFloatingHUD {
            await loadMoonshotBalance(account: account, reason: reason)
        }
    }

    func loadMoonshotBalance(
        account: MoonshotAccount, reason: QuotaRefreshReason,
        keyStore: (any MoonshotAPIKeyStore)? = nil,
        fetch: @Sendable (MoonshotAccount, String) async -> Result<MoonshotBalance, QuotaError> = {
            await MoonshotBalanceClient.fetch(account: $0, apiKey: $1)
        }
    ) async {
        let store = keyStore ?? moonshotAPIKeyStore
        let id = account.id
        var state = moonshotRefreshStates[id] ?? QuotaRefreshState()
        guard !isPreparingForTermination, !state.inFlight,
              moonshotAccounts.contains(where: { $0 == account }),
              account.visibleInPopover || account.showInMenuBar || account.showInFloatingHUD else { return }
        let now = Date()
        if let until = state.backoffUntil, until > now { moonshotErrors[id] = backoffMessage(until: until); return }
        if reason == .periodic, let last = state.lastSuccessAt, now.timeIntervalSince(last) < 60 { return }
        guard let key = store.load(accountID: id) else {
            let message = store.isAccessBlocked(accountID: id) ? ManagedKeychainError.pausedMessage
                : tr("Enter the Moonshot API key again", "请重新填写 Moonshot API Key")
            moonshotErrors[id] = message
            state.lastError = message
            moonshotRefreshStates[id] = state
            return
        }
        let fingerprint = KimiManagedAccount.digest(account.region.rawValue + ":" + key)
        guard account.keyFingerprint == nil || account.keyFingerprint == fingerprint else { return }
        let requestID = UUID()
        moonshotRequestIDs[id] = requestID
        state.inFlight = true
        state.lastAttemptAt = now
        moonshotRefreshStates[id] = state
        defer {
            if moonshotRequestIDs[id] == requestID {
                var current = moonshotRefreshStates[id] ?? state
                current.inFlight = false
                moonshotRefreshStates[id] = current
                moonshotRequestIDs[id] = nil
            }
        }
        let result = await fetch(account, key)
        guard !isPreparingForTermination, moonshotRequestIDs[id] == requestID,
              let currentAccount = moonshotAccounts.first(where: { $0.id == id }),
              currentAccount.region == account.region, currentAccount.keyFingerprint == account.keyFingerprint,
              currentAccount.visibleInPopover || currentAccount.showInMenuBar || currentAccount.showInFloatingHUD,
              store.load(accountID: id) == key else { return }
        switch result {
        case .success(var balance):
            guard balance.currencyCode == account.currencyCode else { return }
            balance.keyFingerprint = fingerprint
            moonshotBalances[id] = balance
            moonshotErrors[id] = nil
            state.lastSuccessAt = balance.fetchedAt
            state.lastError = nil
            state.lastErrorIsNetwork = false
            state.backoffUntil = nil
            state.source = .api
            moonshotRefreshStates[id] = state
            saveMoonshotBalanceCache()
        case .failure(let error):
            moonshotErrors[id] = error.userMessage
            state.lastError = error.userMessage
            state.lastErrorIsNetwork = error.isNetworkFailure
            if error.isRateLimited { state.backoffUntil = Date().addingTimeInterval(600) }
            moonshotRefreshStates[id] = state
        }
    }

    func retryMoonshotKeychainAccess(id: String) async {
        guard let account = moonshotAccounts.first(where: { $0.id == id }) else { return }
        moonshotAPIKeyStore.retryAccess(accountID: id)
        await loadMoonshotBalance(account: account, reason: .userInitiated)
    }

    private func saveMoonshotBalanceCache() {
        do { try MoonshotBalanceCache.save(moonshotBalances, to: accountStorageURL("moonshot_balance_cache.json")) }
        catch { AppLog.error(.quota, "Moonshot balance cache save failed: \(Redact.error(error))") }
    }
}

enum MoonshotAccountEditError: Error {
    case emptyName
    case invalidKey
    case regionNeedsKey
    case unavailable

    @MainActor var userMessage: String {
        switch self {
        case .emptyName: tr("Enter an account name", "请填写账户名称")
        case .invalidKey: tr("Enter a valid API key", "请输入有效的 API Key")
        case .regionNeedsKey: tr("Enter a key for the selected region", "请填写所选地区的 API Key")
        case .unavailable: tr("The account is no longer available", "此账号已不可用")
        }
    }
}
