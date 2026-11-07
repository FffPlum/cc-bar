import Foundation
import CCBarConfiguration

/// Presentation and commands for applications. Credentials stay in the native owners;
/// adding a profile has the same save-only semantics as ApplicationProviderEditor.
@MainActor
final class HostWindowApplicationsService: HostWindowPresenter {
    static let methods: Set<String> = [
        "applications.list", "applications.detect", "applications.setVisibility", "applications.detail",
        "applications.inventory", "applications.checkVersions", "applications.planOperation", "applications.executeOperation",
        "providers.catalog", "authorizations.saveAPIKey", "providers.add"
    ]
    private let detect: () -> Void

    init(state: AppState, settings: SettingsStore, detect: (() -> Void)? = nil) {
        self.detect = detect ?? { state.reloadApplications() }
        super.init(state: state, settings: settings)
    }

    func handle(_ method: String, params: [String: HostJSON]) throws -> HostJSON {
        switch method {
        case "applications.inventory":
            try HostWindowValidation.keys(params, allowed: ["refresh"])
            let refresh = try HostWindowValidation.bool(params, "refresh", required: false) ?? false
            state.applications.management.ensureScan(refresh: refresh)
            return inventoryJSON()
        case "applications.checkVersions":
            try HostWindowValidation.keys(params, allowed: ["catalogID"])
            let id = try HostWindowValidation.string(params, "catalogID", required: false, max: 100)
            try state.applications.management.checkVersions(catalogID: id)
            return inventoryJSON()
        case "applications.planOperation":
            try HostWindowValidation.keys(params, allowed: ["catalogID", "action", "installationID"])
            guard let action = ApplicationLifecycleAction(rawValue: try string(params, "action", max: 30)) else { throw HostWindowValidation.invalid() }
            let installation = try HostWindowValidation.string(params, "installationID", required: false, max: 100)
            let (id, plan, expires) = try state.applications.management.prepare(catalogID: string(params, "catalogID", max: 100), action: action, installationID: installation)
            let name = state.applications.management.definitions.first { $0.id == plan.catalogID }?.name ?? plan.catalogID
            return .object(["id": .string(id), "catalogID": .string(plan.catalogID),
                "installationID": HostWindowJSON.string(plan.installation?.id), "action": .string(plan.action.rawValue),
                "name": .string(name), "sourceLabel": .string(plan.sourceLabel),
                "steps": .array(plan.steps.map { .string(displayPath($0.description)) }),
                "preservesData": .bool(true), "expiresAt": HostWindowJSON.date(expires)])
        case "applications.executeOperation":
            try HostWindowValidation.keys(params, allowed: ["planID"])
            try state.applications.management.execute(planID: string(params, "planID", max: 100))
            return inventoryJSON()
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

    func trackManagementChanges() {
        let manager = state.applications.management
        _ = (manager.inventory, manager.versions, manager.scanning, manager.checkingVersions,
             manager.lastScannedAt, manager.operation, manager.error)
    }

    private func displayPath(_ path: String) -> String {
        settings.privacyMode ? path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~") : path
    }

    private func inventoryJSON() -> HostJSON {
        let manager = state.applications.management
        let planner = manager.planner
        let rows = manager.definitions.map { definition -> HostJSON in
            let discovery = manager.inventory[definition.id] ?? ApplicationDiscoveryResult()
            let install = Result { try planner.plan(definition, action: .install) }
            let installReason: String? = if case .failure(let error) = install { error.localizedDescription } else { nil }
            let brand: ServiceBrand? = definition.configurationApplication?.brand
                ?? (definition.id == "claude-desktop" ? .claude : definition.id == "codex-desktop" ? .codex : nil)
            let installations = discovery.installations.map { installation -> HostJSON in
                func unavailableReason(_ action: ApplicationLifecycleAction) -> String? {
                    // Discovery already validated this managed installer. Enumerating every
                    // release file belongs to the requested plan, not every list refresh.
                    if definition.id == "mcode", installation.source == .native, installation.ownershipRoot != nil { return nil }
                    do { _ = try planner.plan(definition, action: action, installation: installation); return nil }
                    catch { return error.localizedDescription }
                }
                let upgradeReason = unavailableReason(.upgrade)
                let uninstallReason = unavailableReason(.uninstall)
                var version = manager.versions[installation.id] ?? ApplicationVersionState(error: installation.versionError)
                if ["current", "updateAvailable"].contains(version.status) {
                    if ApplicationVersionClient.source(for: definition, installation: installation) != nil,
                       let installed = installation.version, let latest = version.latestVersion,
                       let order = ApplicationVersionClient.compare(installed: installed, latest: latest) {
                        version.status = order == .orderedAscending ? "updateAvailable" : "current"
                    } else {
                        version.status = "unknown"
                        version.error = installation.versionError
                    }
                }
                return .object([
                    "id": .string(installation.id), "path": .string(displayPath(installation.path)),
                    "resolvedPath": .string(displayPath(installation.resolvedPath)), "version": HostWindowJSON.string(installation.version),
                    "source": .string(installation.source.rawValue), "sourceLabel": .string(installation.source.label), "active": .bool(installation.active),
                    "versionCheck": .object(["status": .string(version.status), "latestVersion": HostWindowJSON.string(version.latestVersion),
                        "checkedAt": HostWindowJSON.date(version.checkedAt), "error": HostWindowJSON.string(version.error)]),
                    "canUpgrade": .bool(upgradeReason == nil), "canUninstall": .bool(uninstallReason == nil),
                    "unavailableReason": HostWindowJSON.string(upgradeReason ?? uninstallReason)
                ])
            }
            return .object([
                "id": .string(definition.id), "name": .string(definition.name), "kind": .string(definition.kind.rawValue),
                "configurationApplication": HostWindowJSON.string(definition.configurationApplication?.rawValue),
                "website": .string(definition.website), "icon": brand.map(iconJSON) ?? .null,
                "installed": .bool(!discovery.installations.isEmpty), "configurationFound": .bool(discovery.configurationFound),
                "installations": .array(installations), "canInstall": .bool(installReason == nil && discovery.installations.isEmpty),
                "installUnavailableReason": HostWindowJSON.string(installReason)
            ])
        }
        let operation: HostJSON = manager.operation.map { operation in
            .object(["id": .string(operation.id), "catalogID": .string(operation.plan.catalogID),
                "installationID": HostWindowJSON.string(operation.plan.installation?.id), "action": .string(operation.plan.action.rawValue),
                "status": .string(operation.status), "startedAt": HostWindowJSON.date(operation.startedAt),
                "finishedAt": HostWindowJSON.date(operation.finishedAt), "error": safeError(operation.error),
                "output": .string(settings.privacyMode ? "" : Redact.scrub(operation.output))])
        } ?? .null
        let detectionErrors = manager.definitions.compactMap { definition -> String? in
            manager.inventory[definition.id]?.error.map { definition.name + ": " + $0 }
        }
        return .object(["applications": .array(rows), "scanning": .bool(manager.scanning),
            "checkingVersions": .bool(manager.checkingVersions), "lastScannedAt": HostWindowJSON.date(manager.lastScannedAt),
            "operation": operation, "error": safeError(manager.error ?? (detectionErrors.isEmpty ? nil : detectionErrors.joined(separator: "\n")))])
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
