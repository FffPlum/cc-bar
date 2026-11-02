import Foundation
import CCBarConfiguration

/// Presentation and commands for applications. Credentials stay in the native owners;
/// adding a profile has the same save-only semantics as ApplicationProviderEditor.
@MainActor
final class HostWindowApplicationsService: HostWindowPresenter {
    static let methods: Set<String> = [
        "applications.list", "applications.detect", "applications.setVisibility", "applications.detail",
        "providers.catalog", "authorizations.saveAPIKey", "providers.add"
    ]
    private let detect: () -> Void

    init(state: AppState, settings: SettingsStore, detect: (() -> Void)? = nil) {
        self.detect = detect ?? { state.reloadApplications() }
        super.init(state: state, settings: settings)
    }

    func handle(_ method: String, params: [String: HostJSON]) throws -> HostJSON {
        switch method {
        case "applications.list":
            try HostWindowValidation.keys(params, allowed: [])
            return listJSON()
        case "applications.detect":
            try HostWindowValidation.keys(params, allowed: [])
            detect()
            return listJSON()
        case "applications.setVisibility":
            try HostWindowValidation.keys(params, allowed: ["application", "patch"])
            let application = try application(params)
            let patch = try HostWindowValidation.object(params, "patch")
            try HostWindowValidation.keys(patch, allowed: ["addedToSidebar", "usageVisible"])
            let sidebar = try HostWindowValidation.bool(patch, "addedToSidebar", required: false)
            let usage = try HostWindowValidation.bool(patch, "usageVisible", required: false)
            guard usage == nil || application.usageApp != nil else { throw HostWindowValidation.invalid() }
            if let sidebar { state.applications.setAdded(sidebar, application: application) }
            if let usage, let app = application.usageApp { settings.setUsageServiceVisible(usage, for: app) }
            if sidebar == false, state.mainTab == .application(application) { state.mainTab = .applications }
            return listJSON()
        case "applications.detail":
            try HostWindowValidation.keys(params, allowed: ["application"])
            return detailJSON(try application(params))
        case "providers.catalog":
            try HostWindowValidation.keys(params, allowed: ["application"])
            let application = try application(params)
            return .object([
                "application": .string(application.rawValue),
                "apiKeys": .array(state.apiKeyProviders.map(keyJSON)),
                "suppliers": .array(ModelSupplier.allCases.filter { $0 != .custom }.map {
                    .object(["id": .string($0.rawValue), "name": .string($0.name),
                             "endpoint": .string($0.defaultEndpoint), "website": .string($0.website)])
                }),
                "supportsCustom": .bool(true),
                "error": safeError(state.authorizations.error ?? state.applicationImportError)
            ])
        case "authorizations.saveAPIKey":
            try HostWindowValidation.keys(params, allowed: ["supplier", "name", "endpoint", "key"])
            guard let supplier = ModelSupplier(rawValue: try string(params, "supplier")) else { throw HostWindowValidation.invalid() }
            let name = try string(params, "name", max: 512)
            let endpoint = try string(params, "endpoint")
            let secret = try string(params, "key", max: 65536)
            do {
                let account = try state.authorizations.saveAccount(supplier: supplier, name: name, endpoint: endpoint, key: secret)
                return keyJSON(APIKeyProvider(id: account.id, name: account.name, supplier: account.supplier,
                                              endpoint: account.endpoint, sourceApplications: account.sourceApplications))
            } catch ConfigurationError.invalidProvider {
                throw HostError(code: "invalid_params", message: tr("API key wasn't saved. Check the name, API URL, and key.", "API Key 未保存，请检查名称、API 地址和 Key。"))
            } catch {
                throw HostError(code: "operation_failed", message: tr("API key wasn't saved. Check local file permissions.", "API Key 未保存，请检查本机文件权限。"))
            }
        case "providers.add":
            try HostWindowValidation.keys(params, allowed: ["application", "authorizationID", "name", "supplier", "endpoint", "model", "protocol", "contextWindow"])
            let application = try application(params)
            guard application.supportsProviderConfiguration,
                  let supplier = ModelSupplier(rawValue: try string(params, "supplier")),
                  let api = ProviderAPI(rawValue: try string(params, "protocol")), application.supportedAPIs.contains(api),
                  let context = try HostWindowValidation.int(params, "contextWindow", range: 1...Int.max) else {
                throw HostWindowValidation.invalid()
            }
            let provider = ApplicationProvider(application: application, name: try string(params, "name", max: 512),
                supplier: supplier, endpoint: try string(params, "endpoint"), model: try string(params, "model", max: 512), api: api,
                authorizationID: try string(params, "authorizationID", max: 512), contextWindow: context)
            do {
                let secret = try state.providerCredential(for: provider)
                try ConfigurationRepository.validate(provider, credential: secret)
                try state.authorizations.saveProvider(provider)
            } catch let error as ConfigurationError {
                throw HostError(code: "invalid_params", message: error.localizedDescription)
            } catch {
                throw HostError(code: "operation_failed", message: tr("Provider wasn't saved. Check local file permissions.", "供应商未保存，请检查本机文件权限。"))
            }
            return detailJSON(application)
        default: throw HostError(code: "unknown_method", message: "Unknown application method")
        }
    }

    private func application(_ params: [String: HostJSON]) throws -> AgentApplication {
        try HostWindowValidation.application(string(params, "application"))
    }
    private func string(_ params: [String: HostJSON], _ key: String, max: Int = 4096) throws -> String {
        guard let value = try HostWindowValidation.string(params, key, max: max) else { throw HostWindowValidation.invalid() }
        return value
    }
    private func safeError(_ error: String?) -> HostJSON {
        HostWindowJSON.string(error.map { settings.privacyMode ? tr("Operation failed. Check the local configuration.", "操作失败，请检查本机配置。") : Redact.scrub($0) })
    }
    private func listJSON() -> HostJSON {
        .object(["applications": .array(AgentApplication.allCases.map(applicationJSON)),
                 "error": safeError(state.applicationImportError ?? state.authorizations.error)])
    }
    private func keyJSON(_ key: APIKeyProvider) -> HostJSON {
        .object(["id": .string(key.id), "name": .string(settings.privacyMode ? tr("Saved account", "已保存账号") : key.name),
                 "supplier": .string(key.supplier.rawValue), "endpoint": .string(key.endpoint),
                 "sourceApplications": .array(key.sourceApplications.map(\.rawValue).sorted().map(HostJSON.string))])
    }
    private func detailJSON(_ application: AgentApplication) -> HostJSON {
        guard case .object(var result) = applicationJSON(application) else { return HostWindowJSON.empty }
        let summary = state.applicationLoginSummary(application)
        result["loginSummary"] = HostWindowJSON.string(summary.map { settings.privacyMode ? tr("Signed in", "已登录") : $0 })
        result["error"] = safeError(state.applications.errors[application])
        result["connections"] = .array(ProviderConnection.list(application: application,
            native: state.applications.snapshots[application]?.providers ?? [], saved: state.authorizations.providers).map { connection in
            let provider = connection.provider
            return .object([
                "id": .string(opaqueID(connection.id)), "name": .string(settings.privacyMode && !provider.isOfficial ? tr("Saved provider", "已保存供应商") : provider.name),
                "supplier": .string(provider.supplier.rawValue), "endpoint": .string(provider.endpoint),
                "models": .array(connection.models.map(HostJSON.string)), "protocol": .string(provider.api.rawValue),
                "contextWindow": .number(Decimal(provider.contextWindow)), "official": .bool(provider.isOfficial),
                "active": .bool(connection.isActive), "authorizationID": HostWindowJSON.string(provider.authorizationID)
            ])
        })
        return .object(result)
    }
}
