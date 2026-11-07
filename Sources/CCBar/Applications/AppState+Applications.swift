import Foundation
import CCBarConfiguration

struct APIKeyProvider: Identifiable {
    let id: String
    let name: String
    let supplier: ModelSupplier
    let endpoint: String
    var sourceApplications: Set<AgentApplication> = []
}

extension AppState {
    var quotaAccountProviders: [QuotaProviderDescriptor] {
        SettingsStore.shared.orderedProviders.filter {
            !$0.app.usesAPIKey
        }
    }
    func reloadApplications() {
        guard !isPreparingForTermination else { return }
        authorizations.load()
        applications.scan()
        applicationImportError = nil
        for snapshot in applications.snapshots.values where applications.errors[snapshot.application] == nil {
            for native in snapshot.providers where !native.provider.isOfficial {
                do {
                    if native.provider.supplier == .deepseek,
                       let key = native.credential, APISecret.isValid(key),
                       URL(string: native.provider.endpoint)?.scheme == "https" {
                        let sourceID = native.provider.application.rawValue + ":" + (native.provider.nativeID ?? native.id)
                        if let account = try importDeepSeek(secret: key, kind: .apiKey, name: native.provider.name,
                                                           application: native.provider.application.rawValue, sourceID: sourceID) {
                            var profile = native.provider
                            profile.authorizationID = "deepseek:" + account.id
                            if authorizations.providers.first(where: { $0.id == profile.id }) != profile {
                                try authorizations.saveProvider(profile)
                            }
                        }
                    } else { try authorizations.importNative(native) }
                } catch {
                    applicationImportError = tr("Some application authorizations couldn't be imported.", "部分应用授权未能导入，请检查配置和凭据文件。")
                }
            }
        }
        // The DSH grant is a source-owned authorization: removing the CCBar copy never
        // signs the user out of DSH. It is still queried only at the official platform.
        do {
            if let grant = try applications.repository.deepSeekAccountGrant(), DeepSeekAccount.validSecret(grant) {
                _ = try importDeepSeek(secret: grant, kind: .account, name: "DeepSeek Harness",
                                       application: "dsh", sourceID: "dsh:platform")
            }
        } catch { deepSeekOperationError = tr("Couldn't read the DeepSeek Harness authorization.", "未能读取 DeepSeek Harness 授权。") }
    }

    private func importDeepSeek(secret: String, kind: DeepSeekAuthKind, name: String,
                                application: String, sourceID: String) throws -> DeepSeekAccount? {
        let fingerprint = DeepSeekAccount.fingerprint(secret, kind: kind)
        guard !authorizations.isImportIgnored(fingerprint), !authorizations.isImportIgnored(sourceID) else { return nil }
        if let existing = deepSeekAccounts.first(where: { $0.credentialFingerprint == fingerprint }) { return existing }
        let previous = deepSeekAccounts.first { $0.sourceConfigurationID == sourceID && $0.kind == kind }
        let account = try saveDeepSeekAccount(id: previous?.id, name: previous?.name ?? name, kind: kind, secret: secret)
        updateDeepSeekAccount(id: account.id) { $0.sourceApplication = application; $0.sourceConfigurationID = sourceID }
        return account
    }

    var apiKeyProviders: [APIKeyProvider] {
        var providers: [APIKeyProvider] = authorizations.accounts.map {
            APIKeyProvider(id: $0.id, name: PrivacyDisplay.isEnabled ? PrivacyDisplay.account($0.id) : $0.name,
                                         supplier: $0.supplier, endpoint: $0.endpoint, sourceApplications: $0.sourceApplications)
        }
        for account in deepSeekAccounts where account.kind == .apiKey {
            let application = account.sourceApplication.flatMap { AgentApplication(rawValue: $0) }
            let sources: Set<AgentApplication> = application.map { [$0] } ?? []
            providers.append(APIKeyProvider(id: "deepseek:" + account.id, name: deepSeekDisplayName(account),
                                         supplier: .deepseek, endpoint: ModelSupplier.deepseek.defaultEndpoint,
                                         sourceApplications: sources))
        }
        providers += moonshotAccounts.map {
            APIKeyProvider(id: "moonshot:" + $0.id, name: PrivacyDisplay.isEnabled ? PrivacyDisplay.account($0.id) : $0.name,
                                         supplier: .kimi, endpoint: $0.region == .china ? "https://api.moonshot.cn/v1" : "https://api.moonshot.ai/v1")
        }
        if let account = opencodeGoAccount {
            let sources: Set<AgentApplication> = account.source == .pi ? [.pi] : account.source == .opencode ? [.opencode] : []
            providers.append(APIKeyProvider(id: "opencode-go", name: "OpenCode Go", supplier: .custom,
                                         endpoint: "https://opencode.ai/zen/go/v1",
                                         sourceApplications: sources))
        }
        if let account = commandCodeAccount {
            let sources: Set<AgentApplication> = account.source == .pi ? [.pi] : account.source == .opencode ? [.opencode] : account.source == .commandCodeCLI ? [.commandCode] : []
            providers.append(APIKeyProvider(id: "command-code-key", name: "Command Code", supplier: .custom,
                                                endpoint: "https://api.commandcode.ai",
                                                sourceApplications: sources))
        }
        return providers
    }
    func providerCredential(for provider: ApplicationProvider) throws -> String {
        guard let id = provider.authorizationID,
              let choice = apiKeyProviders.first(where: { $0.id == id }),
              let destination = try? APIEndpoint(provider.endpoint), let issuer = try? APIEndpoint(choice.endpoint),
              destination.acceptsCredential(issuedFor: issuer) else {
            throw ConfigurationError.missingCredential
        }
        let key: String?
        if id.hasPrefix("deepseek:") { key = deepSeekCredentialStore.load(id: String(id.dropFirst("deepseek:".count))) }
        else if id.hasPrefix("moonshot:") { key = moonshotAPIKeyStore.load(accountID: String(id.dropFirst("moonshot:".count))) }
        else if id == "opencode-go" { key = opencodeGoAccount?.apiKey }
        else if id == "command-code-key" { key = commandCodeAccount?.accessToken }
        else { key = authorizations.key(for: id) }
        guard let key else { throw ConfigurationError.missingCredential }
        return key
    }
    func activateProvider(_ provider: ApplicationProvider) throws {
        try applications.activate(provider, key: providerCredential(for: provider))
        reloadApplications()
    }
    func selectProvider(_ provider: NativeProvider) throws {
        try applications.select(provider)
        reloadApplications()
    }
}
