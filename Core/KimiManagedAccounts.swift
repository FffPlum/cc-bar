import AppKit
import Foundation

@MainActor
extension AppState {
    func accountStorageURL(_ fileName: String) -> URL {
        (accountPersistenceDirectory ?? ImportedCodexStore.fileURL().deletingLastPathComponent())
            .appendingPathComponent(fileName)
    }

    var hasKimiSubscriptionAccount: Bool { kimiAccount != nil || !kimiManagedAccounts.isEmpty }

    var displayedKimiServiceStatus: ServiceStatus? {
        guard SettingsStore.shared.showServiceStatus, var status = kimiServiceStatus else { return nil }
        if kimiServiceStatusUnreachable {
            status.indicator = .unknown
            status.description = nil
            status.isStale = true
        }
        return status
    }

    func kimiManagedMirrorsCLI(_ account: KimiManagedAccount) -> Bool {
        kimiAccount?.userID == account.userID && kimiAccount?.baseURL == account.region.baseURL
    }

    func loadKimiManagedAccounts() {
        kimiManagedAccounts = KimiManagedAccount.deduplicated(KimiManagedAccountStore.loadAll(
            from: accountStorageURL("kimi_subscription_accounts.json")
        ))
        let loaded = KimiManagedQuotaCache.load(from: accountStorageURL("kimi_subscription_quota_cache.json"))
        let ids = Set(kimiManagedAccounts.map(\.id))
        kimiManagedQuotas = kimiManagedQuotas.filter { ids.contains($0.key) }
        kimiManagedSources = kimiManagedSources.filter { ids.contains($0.key) }
        kimiManagedErrors = kimiManagedErrors.filter { ids.contains($0.key) }
        kimiManagedRefreshStates = kimiManagedRefreshStates.filter { ids.contains($0.key) }
        kimiManagedQuotaCacheRecords = [:]
        for account in kimiManagedAccounts {
            guard let tokens = kimiTokenStore.load(accountID: account.id),
                  tokensMatchKimiAccount(tokens, account: account),
                  let record = loaded[account.id], record.snapshot.app == .kimi,
                  record.accountID == kimiManagedHistoryKey(account, tokens: tokens) else { continue }
            kimiManagedQuotaCacheRecords[account.id] = record
            kimiManagedQuotas[account.id] = record.snapshot
            kimiManagedSources[account.id] = .cache
            var state = QuotaRefreshState()
            state.lastSuccessAt = record.updatedAt
            state.source = .cache
            kimiManagedRefreshStates[account.id] = state
        }
    }

    func kimiManagedSubtitle(_ account: KimiManagedAccount) -> String {
        var parts: [String] = []
        if !SettingsStore.shared.privacyMode, let nickname = nonemptyAccountText(account.nickname) { parts.append(nickname) }
        if let plan = nonemptyAccountText(account.userLevelName ?? kimiManagedQuotas[account.id]?.planType) { parts.append(plan) }
        return parts.isEmpty ? tr("Signed in", "已登录") : parts.joined(separator: " · ")
    }

    func kimiManagedDisplayName(_ account: KimiManagedAccount) -> String {
        PrivacyDisplay.isEnabled ? PrivacyDisplay.account(account.id)
            : (nonemptyAccountText(account.nickname) ?? tr("Kimi account", "Kimi 账号"))
    }

    private func nonemptyAccountText(_ value: String?) -> String? {
        guard let result = value?.trimmingCharacters(in: .whitespacesAndNewlines), !result.isEmpty else { return nil }
        return result
    }

    func updateKimiManagedAccount(id: String, _ update: (inout KimiManagedAccount) -> Void) {
        guard let index = kimiManagedAccounts.firstIndex(where: { $0.id == id }) else { return }
        var candidate = kimiManagedAccounts
        update(&candidate[index])
        do {
            try persistKimiManagedMetadata(candidate)
            kimiManagedAccounts = candidate
            kimiManagedOperationError = nil
        } catch { kimiManagedOperationError = tr("Couldn't save account settings. Try again.", "账号设置未能保存，请重试") }
    }

    func removeKimiManagedAccount(id: String) {
        let candidate = kimiManagedAccounts.filter { $0.id != id }
        do { try persistKimiManagedMetadata(candidate) }
        catch {
            kimiManagedOperationError = tr("Couldn't remove the account. Try again.", "账号未能删除，请重试")
            return
        }
        cancelKimiDeviceLogin()
        kimiManagedRequestIDs[id] = nil
        kimiManagedAccounts = candidate
        kimiTokenStore.delete(accountID: id)
        kimiManagedQuotas[id] = nil
        kimiManagedSources[id] = nil
        kimiManagedErrors[id] = nil
        kimiManagedRefreshStates[id] = nil
        kimiManagedProfileAttempts[id] = nil
        kimiManagedQuotaCacheRecords[id] = nil
        kimiManagedOperationError = nil
        saveKimiManagedQuotaCache()
    }

    private func persistKimiManagedMetadata(_ accounts: [KimiManagedAccount]) throws {
        try KimiManagedAccountStore.saveAll(accounts, to: accountStorageURL("kimi_subscription_accounts.json"))
    }

    private func saveKimiManagedQuotaCache() {
        // These small account snapshots are committed in MainActor order. A
        // detached write could restore a removed account or an older credential.
        do { try KimiManagedQuotaCache.save(kimiManagedQuotaCacheRecords, to: accountStorageURL("kimi_subscription_quota_cache.json")) }
        catch { AppLog.error(.quota, "Kimi account cache save failed: \(Redact.error(error))") }
    }

    func startKimiDeviceLogin(
        region: KimiRegion,
        replacing accountID: String? = nil,
        requestAuthorization: @escaping @MainActor (KimiRegion) async throws -> KimiDeviceAuthorization = {
            try await KimiDeviceAuthorizationClient.request(region: $0)
        },
        openAuthorization: @escaping @MainActor (URL) -> Void = { _ = NSWorkspace.shared.open($0) }
    ) {
        guard !isPreparingForTermination, !kimiDeviceLoginInProgress else { return }
        if let until = kimiDeviceLoginBackoffUntil, until > Date() {
            kimiDeviceLoginError = tr("Too many sign-in attempts. Try again later.", "登录请求过于频繁，请稍后再试")
            return
        }
        cancelKimiDeviceLogin()
        let loginID = UUID()
        kimiDeviceLoginID = loginID
        kimiDeviceLoginInProgress = true
        kimiDeviceLoginTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.kimiDeviceLoginID == loginID {
                    self.kimiDeviceLoginInProgress = false
                    self.kimiDeviceLoginTask = nil
                }
            }
            do {
                let authorization = try await requestAuthorization(region)
                guard self.ownsKimiLogin(loginID) else { return }
                self.kimiDeviceAuthorization = authorization
                openAuthorization(authorization.verificationURL)
                guard self.ownsKimiLogin(loginID) else { return }
                let tokens = try await KimiDeviceLoginRunner.run(authorization: authorization)
                guard self.ownsKimiLogin(loginID) else { return }
                try await self.completeKimiDeviceLogin(region: region, tokens: tokens, loginID: loginID, replacing: accountID)
            } catch is CancellationError {
                // A cancelled flow must not change a subsequently opened flow.
            } catch let error as KimiDeviceAuthorizationError {
                guard self.kimiDeviceLoginID == loginID else { return }
                if error != .cancelled { self.kimiDeviceLoginError = error.userMessage }
                if error == .rateLimited { self.kimiDeviceLoginBackoffUntil = Date().addingTimeInterval(600) }
            } catch {
                guard self.kimiDeviceLoginID == loginID else { return }
                self.kimiDeviceLoginError = tr("Couldn't save the signed-in account. Try again.", "登录账号未能保存，请重试")
            }
        }
    }

    func cancelKimiDeviceLogin(showCancellation: Bool = false) {
        kimiDeviceLoginID = nil
        kimiDeviceLoginTask?.cancel()
        kimiDeviceLoginTask = nil
        kimiDeviceLoginInProgress = false
        kimiDeviceAuthorization = nil
        kimiDeviceLoginError = showCancellation ? KimiDeviceAuthorizationError.cancelled.userMessage : nil
    }

    private func ownsKimiLogin(_ id: UUID) -> Bool {
        kimiDeviceLoginID == id && !Task.isCancelled && !isPreparingForTermination
    }

    func completeKimiDeviceLogin(
        region: KimiRegion, tokens: KimiManagedTokens, loginID: UUID, replacing accountID: String? = nil,
        profile fetchProfile: @Sendable (KimiAuthSession) async -> KimiUserInfo? = { await KimiQuotaClient.fetchUserInfo(auth: $0) },
        refreshAfterSave: Bool = true
    ) async throws {
        guard ownsKimiLogin(loginID) else { throw KimiDeviceAuthorizationError.cancelled }
        let tokenUserID = KimiCredentials.jwtUserID(tokens.accessToken) ?? KimiCredentials.jwtUserID(tokens.refreshToken)
        var account = KimiManagedAccount(id: UUID().uuidString, region: region, userID: tokenUserID ?? "")
        let profile = await fetchProfile(account.auth(tokens: tokens, homeDirectory: FileManager.default.homeDirectoryForCurrentUser))
        guard ownsKimiLogin(loginID) else { throw KimiDeviceAuthorizationError.cancelled }
        if let profileID = nonemptyAccountText(profile?.userID) {
            guard tokenUserID == nil || tokenUserID == profileID else { throw KimiDeviceAuthorizationError.invalidResponse }
            account.userID = profileID
        }
        guard !account.userID.isEmpty else { throw KimiDeviceAuthorizationError.invalidResponse }
        if let accountID {
            guard let original = kimiManagedAccounts.first(where: { $0.id == accountID }), original.identity == account.identity else {
                throw KimiDeviceAuthorizationError.differentAccount
            }
        }
        account.nickname = nonemptyAccountText(profile?.nickname)
        account.email = profile?.email
        account.userLevelName = nonemptyAccountText(profile?.userLevelName)
        var candidate = kimiManagedAccounts
        if let index = candidate.firstIndex(where: { $0.identity == account.identity }) {
            let previous = candidate[index]
            account.id = previous.id
            account.visibleInPopover = previous.visibleInPopover
            account.showInMenuBar = previous.showInMenuBar
            account.showInFloatingHUD = previous.showInFloatingHUD
            candidate[index] = account
        } else { candidate.append(account) }
        let priorTokens = kimiTokenStore.load(accountID: account.id)
        try kimiTokenStore.save(tokens, accountID: account.id)
        do { try persistKimiManagedMetadata(candidate) }
        catch {
            if let priorTokens { try? kimiTokenStore.save(priorTokens, accountID: account.id) }
            else { kimiTokenStore.delete(accountID: account.id) }
            throw error
        }
        kimiManagedRequestIDs[account.id] = nil
        kimiManagedAccounts = candidate
        var state = kimiManagedRefreshStates[account.id] ?? QuotaRefreshState()
        state.inFlight = false
        kimiManagedRefreshStates[account.id] = state
        kimiManagedErrors[account.id] = nil
        kimiManagedProfileAttempts[account.id] = nil
        SettingsStore.shared.setServiceEnabled(true, for: .kimi)
        if refreshAfterSave { await loadKimiManagedQuota(account: account, reason: .userInitiated) }
    }

    func loadAllKimiManagedQuotas(reason: QuotaRefreshReason) async {
        guard SettingsStore.shared.isProviderEnabled(.kimi) else { return }
        for account in kimiManagedAccounts where account.visibleInPopover || account.showInMenuBar || account.showInFloatingHUD {
            await loadKimiManagedQuota(account: account, reason: reason)
        }
    }

    func retryKimiKeychainAccess(id: String) async {
        guard let account = kimiManagedAccounts.first(where: { $0.id == id }) else { return }
        kimiTokenStore.retryAccess(accountID: id)
        await loadKimiManagedQuota(account: account, reason: .userInitiated)
    }

    func loadKimiManagedQuota(
        account: KimiManagedAccount, reason: QuotaRefreshReason, tokenStore: (any KimiTokenStore)? = nil,
        fetch: @Sendable (KimiAuthSession) async -> Result<QuotaSnapshot, QuotaError> = { await KimiQuotaClient.fetch(auth: $0) },
        profile: @Sendable (KimiAuthSession) async -> KimiUserInfo? = { await KimiQuotaClient.fetchUserInfo(auth: $0) }
    ) async {
        let store = tokenStore ?? kimiTokenStore
        let id = account.id
        var state = kimiManagedRefreshStates[id] ?? QuotaRefreshState()
        guard !isPreparingForTermination, SettingsStore.shared.isProviderEnabled(.kimi), !state.inFlight,
              kimiManagedAccounts.contains(where: { $0.id == id && $0.identity == account.identity }) else { return }
        let now = Date()
        if let until = state.backoffUntil, until > now { kimiManagedErrors[id] = backoffMessage(until: until); return }
        if reason == .periodic, let last = state.lastSuccessAt, now.timeIntervalSince(last) < 60 { return }
        let requestID = UUID()
        kimiManagedRequestIDs[id] = requestID
        state.inFlight = true
        state.lastAttemptAt = now
        kimiManagedRefreshStates[id] = state
        defer {
            if kimiManagedRequestIDs[id] == requestID {
                var current = kimiManagedRefreshStates[id] ?? state
                current.inFlight = false
                kimiManagedRefreshStates[id] = current
                kimiManagedRequestIDs[id] = nil
            }
        }
        let isCurrent: @MainActor @Sendable () -> Bool = { self.ownsKimiManagedRequest(requestID, account: account) }
        var tokens: KimiManagedTokens
        switch await KimiManagedTokenRefresher.ensureFresh(account: account, tokenStore: store, isCurrent: isCurrent) {
        case .success(let value): tokens = value
        case .failure(let error):
            if isCurrent() { markKimiManagedFailure(account: account, error: error, keychainBlocked: store.isAccessBlocked(accountID: id)) }
            return
        }
        guard isCurrent(), tokensMatchKimiAccount(tokens, account: account) else { return }
        var result = await fetch(account.auth(tokens: tokens, homeDirectory: FileManager.default.homeDirectoryForCurrentUser))
        guard isCurrent(), store.load(accountID: id) == tokens else { return }
        if case .failure(let error) = result, error.httpStatusCode == 401, !error.looksLikeInterceptedResponse {
            switch await KimiManagedTokenRefresher.ensureFresh(account: account, force: true, tokenStore: store, isCurrent: isCurrent) {
            case .success(let renewed):
                tokens = renewed
                guard isCurrent(), tokensMatchKimiAccount(tokens, account: account) else { return }
                result = await fetch(account.auth(tokens: tokens, homeDirectory: FileManager.default.homeDirectoryForCurrentUser))
            case .failure(let error):
                if isCurrent() { markKimiManagedFailure(account: account, error: error, keychainBlocked: store.isAccessBlocked(accountID: id)) }
                return
            }
        }
        guard isCurrent(), store.load(accountID: id) == tokens else { return }
        switch result {
        case .success(let snapshot):
            guard snapshot.app == .kimi else { markKimiManagedFailure(account: account, error: .decode("unexpected provider")); return }
            storeKimiManagedQuota(snapshot, account: account, tokens: tokens)
            if let last = kimiManagedProfileAttempts[id], Date().timeIntervalSince(last) < 3600 { return }
            kimiManagedProfileAttempts[id] = Date()
            let info = await profile(account.auth(tokens: tokens, homeDirectory: FileManager.default.homeDirectoryForCurrentUser))
            guard isCurrent(), store.load(accountID: id) == tokens, let info,
                  info.userID == nil || info.userID == account.userID,
                  let index = kimiManagedAccounts.firstIndex(where: { $0.id == id }) else { return }
            var candidate = kimiManagedAccounts
            candidate[index].nickname = nonemptyAccountText(info.nickname)
            candidate[index].email = info.email
            candidate[index].userLevelName = nonemptyAccountText(info.userLevelName)
            do { try persistKimiManagedMetadata(candidate); kimiManagedAccounts = candidate }
            catch { AppLog.error(.app, "Kimi profile save failed: \(Redact.error(error))") }
            if let plan = candidate[index].userLevelName {
                kimiManagedQuotas[id]?.planType = plan
                kimiManagedQuotaCacheRecords[id]?.snapshot.planType = plan
                saveKimiManagedQuotaCache()
            }
        case .failure(let error): markKimiManagedFailure(account: account, error: error)
        }
    }

    private func ownsKimiManagedRequest(_ id: UUID, account: KimiManagedAccount) -> Bool {
        !isPreparingForTermination && SettingsStore.shared.isProviderEnabled(.kimi)
            && kimiManagedRequestIDs[account.id] == id
            && kimiManagedAccounts.contains(where: { $0.id == account.id && $0.identity == account.identity })
    }

    private func tokensMatchKimiAccount(_ tokens: KimiManagedTokens, account: KimiManagedAccount) -> Bool {
        let identity = KimiCredentials.jwtUserID(tokens.accessToken) ?? KimiCredentials.jwtUserID(tokens.refreshToken)
        return identity == nil || identity == account.userID
    }

    private func kimiManagedHistoryKey(_ account: KimiManagedAccount, tokens: KimiManagedTokens) -> String {
        QuotaHistoryAccountKey.kimiPrimary(accountKey: account.auth(tokens: tokens, homeDirectory: FileManager.default.homeDirectoryForCurrentUser).accountKey)
    }

    private func storeKimiManagedQuota(_ snapshot: QuotaSnapshot, account: KimiManagedAccount, tokens: KimiManagedTokens) {
        let now = Date()
        var snapshot = snapshot
        snapshot.planType = kimiManagedAccounts.first(where: { $0.id == account.id })?.userLevelName ?? snapshot.planType
        let merged = snapshot.preservingFutureResetDates(from: kimiManagedQuotas[account.id], now: now)
        kimiManagedQuotas[account.id] = merged
        kimiManagedSources[account.id] = .api
        kimiManagedErrors[account.id] = nil
        var state = kimiManagedRefreshStates[account.id] ?? QuotaRefreshState()
        state.lastSuccessAt = now
        state.lastError = nil
        state.lastErrorIsNetwork = false
        state.backoffUntil = nil
        state.source = .api
        kimiManagedRefreshStates[account.id] = state
        kimiManagedQuotaCacheRecords[account.id] = QuotaCacheRecord(snapshot: merged, source: .api, updatedAt: now, accountID: kimiManagedHistoryKey(account, tokens: tokens))
        saveKimiManagedQuotaCache()
        recordKimiQuotaHistory(snapshot: merged, sampledAt: now, managedAccountKey: account.auth(tokens: tokens, homeDirectory: FileManager.default.homeDirectoryForCurrentUser).accountKey)
    }

    private func markKimiManagedFailure(account: KimiManagedAccount, error: QuotaError, keychainBlocked: Bool = false) {
        let message = keychainBlocked ? ManagedKeychainError.pausedMessage : error.userMessage
        kimiManagedErrors[account.id] = message
        var state = kimiManagedRefreshStates[account.id] ?? QuotaRefreshState()
        state.lastError = message
        state.lastErrorIsNetwork = error.isNetworkFailure
        if error.isRateLimited { state.backoffUntil = Date().addingTimeInterval(600) }
        kimiManagedRefreshStates[account.id] = state
    }
}
