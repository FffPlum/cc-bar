import Foundation

@MainActor
final class HostWindowSettingsService {
    static let methods: Set<String> = [
        "window.settings.get", "window.settings.update", "window.settings.setLaunchAtLogin",
        "settings.resetBrandColors", "settings.copyPiTimingGuide", "settings.testProxy", "settings.refreshCurrency",
        "pricing.catalog", "pricing.refreshAndRecalculate", "notifications.requestPermission",
        "notifications.rebuild", "notifications.openSettings", "diagnostics.export", "diagnostics.revealLogs",
        "updates.status", "updates.check", "updates.setAutomatic", "platform.openExternal"
    ]
    private let settings: SettingsStore
    private let usageStatus: () -> HostJSON
    private let actions: HostWindowSettingsActions
    private var hasReadPermission = false
    private var recalculating = false
    private var exporting = false

    convenience init(state: AppState, settings: SettingsStore, usageStatus: @escaping () -> HostJSON) {
        self.init(settings: settings, usageStatus: usageStatus, actions: .live(state: state, settings: settings))
    }

    init(settings: SettingsStore, usageStatus: @escaping () -> HostJSON, actions: HostWindowSettingsActions) {
        self.settings = settings
        self.usageStatus = usageStatus
        self.actions = actions
    }

    func trackChanges() {
        _ = (settings.menuBarWindow, settings.useInstalledAppIcons, settings.floatingEnabled, settings.resetTimeDisplay,
             settings.showServiceStatus, settings.privacyMode, settings.statsRankMetric, settings.cycleIncludesOtherAgents,
             settings.piEstimatedOutputSpeed, settings.brandColorPreferences, settings.recentBrandColors,
             settings.quotaInterval, settings.usageInterval, settings.proxyMode, settings.proxyType, settings.proxyHost,
             settings.proxyPort, settings.displayCurrency, settings.appLanguage, settings.quotaAlertsEnabled,
             settings.quotaAlertThresholdPercent, settings.quotaAlertFiveHourEnabled, settings.quotaAlertWeeklyEnabled,
             settings.quotaAlertBillingCycleEnabled, settings.quotaAlertSoundEnabled, settings.verboseLogging)
        _ = actions.notifications()
        _ = actions.system.updates()
        _ = actions.currency()
        _ = usageStatus()
    }

    func handle(_ method: String, params: [String: HostJSON]) async throws -> HostJSON {
        switch method {
        case "window.settings.get":
            try HostWindowValidation.keys(params, allowed: [])
            if !hasReadPermission {
                hasReadPermission = true
                await actions.refreshPermission()
            }
            return settingsJSON()
        case "window.settings.update":
            try HostWindowValidation.keys(params, allowed: ["patch"])
            let patch = try HostWindowValidation.object(params, "patch")
            let changes = try validatedChanges(patch)
            for change in changes { change() }
            if patch["quotaInterval"] != nil || patch["usageInterval"] != nil { actions.applyRefreshIntervals() }
            if patch["floatingEnabled"] != nil { actions.system.syncFloating() }
            if patch.keys.contains(where: { $0.hasPrefix("quotaAlert") }) { actions.notificationSettingsChanged() }
            // Saving the preference and requesting permission are distinct operations. The frontend
            // calls notifications.requestPermission after enabling alerts; denial preserves preferences.
            return settingsJSON()
        case "window.settings.setLaunchAtLogin":
            try HostWindowValidation.keys(params, allowed: ["enabled"])
            let enabled = try requiredBool(params, "enabled")
            do { try actions.setLaunchAtLogin(enabled) }
            catch {
                throw HostError(code: "operation_failed", message: text(
                    "Login item wasn't changed. Check CCBar in System Settings > General > Login Items & Extensions.",
                    "开机启动未更改，请在「系统设置 > 通用 > 登录项与扩展」中检查 CCBar。"))
            }
            return settingsJSON()
        case "settings.resetBrandColors":
            try noParams(params); settings.resetBrandColors(); return settingsJSON()
        case "settings.copyPiTimingGuide":
            try noParams(params); try actions.system.copyText(actions.piTimingGuide()); return HostWindowJSON.ok
        case "settings.testProxy":
            try noParams(params)
            switch await actions.testProxy() {
            case .success: return .object(["ok": .bool(true), "message": .string(text("Connected", "可连接"))])
            case .failure(let error): return .object(["ok": .bool(false), "message": .string(proxyFailure(error))])
            }
        case "settings.refreshCurrency":
            try noParams(params); await actions.refreshCurrency(); return settingsJSON()
        case "pricing.catalog":
            try noParams(params); await actions.loadPricing(); return pricingJSON()
        case "pricing.refreshAndRecalculate":
            try noParams(params)
            guard !recalculating else { return recalculationJSON(nil) }
            recalculating = true
            defer { recalculating = false }
            return recalculationJSON(await actions.recalculate())
        case "notifications.requestPermission":
            try noParams(params)
            await actions.requestPermission()
            hasReadPermission = true
            return settingsJSON()
        case "notifications.rebuild":
            try noParams(params); await actions.rebuildNotifications(); return settingsJSON()
        case "notifications.openSettings":
            try noParams(params); actions.system.openNotificationSettings(); hasReadPermission = false
            return HostWindowJSON.ok
        case "diagnostics.export":
            try noParams(params)
            guard !exporting else { throw HostError(code: "busy", message: text("Diagnostics are already being exported.", "诊断日志正在导出。")) }
            exporting = true
            defer { exporting = false }
            do { return .object(["path": .string(try await actions.system.exportDiagnostics())]) }
            catch { throw HostError(code: "operation_failed", message: text("Export failed. Try again.", "导出失败，请重试。")) }
        case "diagnostics.revealLogs":
            try noParams(params); actions.system.revealLogs(); return HostWindowJSON.ok
        case "updates.status":
            try noParams(params); return actions.system.updates()
        case "updates.check":
            try noParams(params); actions.system.checkUpdates(); return actions.system.updates()
        case "updates.setAutomatic":
            try HostWindowValidation.keys(params, allowed: ["enabled"])
            actions.system.setAutomaticUpdates(try requiredBool(params, "enabled")); return actions.system.updates()
        case "platform.openExternal":
            try HostWindowValidation.keys(params, allowed: ["url"])
            guard let raw = try HostWindowValidation.string(params, "url", max: 8192),
                  let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
                  ["https", "http"].contains(scheme), let host = url.host, !host.isEmpty,
                  url.user == nil, url.password == nil,
                  !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw HostWindowValidation.invalid()
            }
            guard actions.system.openExternal(url) else { throw HostWindowValidation.unavailable() }
            return HostWindowJSON.ok
        default: throw HostError(code: "unknown_method", message: "Unknown settings method")
        }
    }

    private func noParams(_ params: [String: HostJSON]) throws { try HostWindowValidation.keys(params, allowed: []) }
    private func requiredBool(_ params: [String: HostJSON], _ key: String) throws -> Bool {
        guard let value = try HostWindowValidation.bool(params, key) else { throw HostWindowValidation.invalid() }
        return value
    }
    private func text(_ english: String, _ chinese: String) -> String { settings.resolvedLanguage == .zh ? chinese : english }

    /// Capture validated values in closures, then run them only after every field and cross-field
    /// invariant has passed. No setting or system action is touched while validating a patch.
    private func validatedChanges(_ patch: [String: HostJSON]) throws -> [() -> Void] {
        let booleanFields: [String: ReferenceWritableKeyPath<SettingsStore, Bool>] = [
            "useInstalledAppIcons": \.useInstalledAppIcons, "floatingEnabled": \.floatingEnabled,
            "showServiceStatus": \.showServiceStatus, "privacyMode": \.privacyMode,
            "cycleIncludesOtherAgents": \.cycleIncludesOtherAgents, "piEstimatedOutputSpeed": \.piEstimatedOutputSpeed,
            "quotaAlertsEnabled": \.quotaAlertsEnabled, "quotaAlertFiveHourEnabled": \.quotaAlertFiveHourEnabled,
            "quotaAlertWeeklyEnabled": \.quotaAlertWeeklyEnabled, "quotaAlertBillingCycleEnabled": \.quotaAlertBillingCycleEnabled,
            "quotaAlertSoundEnabled": \.quotaAlertSoundEnabled
        ]
        let otherFields: Set<String> = ["menuBarWindow", "resetTimeDisplay", "statsRankMetric", "brandColor", "quotaInterval",
            "usageInterval", "proxyMode", "proxyType", "proxyHost", "proxyPort", "currency", "language", "quotaAlertThresholdPercent", "verboseLogging"]
        try HostWindowValidation.keys(patch, allowed: Set(booleanFields.keys).union(otherFields))
        var changes: [() -> Void] = []
        for (key, path) in booleanFields {
            if let value = try HostWindowValidation.bool(patch, key, required: false) {
                changes.append { [settings] in settings[keyPath: path] = value }
            }
        }
        func enumeration<Value: RawRepresentable>(_ key: String, _ path: ReferenceWritableKeyPath<SettingsStore, Value>) throws where Value.RawValue == String {
            if let raw = try HostWindowValidation.string(patch, key, required: false) {
                guard let value = Value(rawValue: raw) else { throw HostWindowValidation.invalid() }
                changes.append { [settings] in settings[keyPath: path] = value }
            }
        }
        try enumeration("menuBarWindow", \.menuBarWindow)
        try enumeration("resetTimeDisplay", \.resetTimeDisplay)
        try enumeration("statsRankMetric", \.statsRankMetric)
        try enumeration("quotaInterval", \.quotaInterval)
        try enumeration("usageInterval", \.usageInterval)
        try enumeration("proxyMode", \.proxyMode)
        try enumeration("proxyType", \.proxyType)
        try enumeration("currency", \.displayCurrency)
        try enumeration("language", \.appLanguage)
        if let host = try HostWindowValidation.string(patch, "proxyHost", required: false, max: 1024) {
            guard !host.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw HostWindowValidation.invalid() }
            // Preserve draft host input just as the native form does; the connection test reports invalid addresses.
            changes.append { [settings] in settings.proxyHost = host }
        }
        if let port = try HostWindowValidation.int(patch, "proxyPort", required: false, range: 0...99999) {
            changes.append { [settings] in settings.proxyPort = port }
        }
        if let threshold = try HostWindowValidation.int(patch, "quotaAlertThresholdPercent", required: false, range: 5...50) {
            guard threshold.isMultiple(of: 5) else { throw HostWindowValidation.invalid() }
            changes.append { [settings] in settings.quotaAlertThresholdPercent = threshold }
        }
        if let verbose = try HostWindowValidation.bool(patch, "verboseLogging", required: false) {
            changes.append { [actions] in actions.applyVerboseLogging(verbose) }
        }
        let fiveHour = try HostWindowValidation.bool(patch, "quotaAlertFiveHourEnabled", required: false) ?? settings.quotaAlertFiveHourEnabled
        let weekly = try HostWindowValidation.bool(patch, "quotaAlertWeeklyEnabled", required: false) ?? settings.quotaAlertWeeklyEnabled
        let billing = try HostWindowValidation.bool(patch, "quotaAlertBillingCycleEnabled", required: false) ?? settings.quotaAlertBillingCycleEnabled
        guard fiveHour || weekly || billing else { throw HostWindowValidation.invalid() }
        if patch["brandColor"] != nil {
            let color = try HostWindowValidation.object(patch, "brandColor")
            try HostWindowValidation.keys(color, allowed: ["brand", "mode", "customHex"])
            guard let brandRaw = try HostWindowValidation.string(color, "brand"), let brand = ServiceBrand(rawValue: brandRaw),
                  let modeRaw = try HostWindowValidation.string(color, "mode"), let mode = BrandColorMode(rawValue: modeRaw) else { throw HostWindowValidation.invalid() }
            let hex = try HostWindowValidation.string(color, "customHex", required: false, max: 9)
            if let hex {
                guard (hex.count == 7 || hex.count == 9), hex.hasPrefix("#"),
                      hex.dropFirst().allSatisfy({ "0123456789abcdefABCDEF".contains($0) }) else { throw HostWindowValidation.invalid() }
            }
            guard mode != .custom || hex != nil else { throw HostWindowValidation.invalid() }
            changes.append { [settings] in
                if mode == .custom, let hex {
                    settings.applyCustomBrandColor(hex.uppercased(), for: brand)
                    settings.recordRecentBrandColor(hex)
                } else { settings.setColorMode(mode, for: brand) }
            }
        }
        return changes
    }

    private func settingsJSON() -> HostJSON {
        let launch = actions.launchStatus()
        let appearance: [String: HostJSON] = [
            "menuBarWindow": .string(settings.menuBarWindow.rawValue),
            "useInstalledAppIcons": .bool(settings.useInstalledAppIcons), "floatingEnabled": .bool(settings.floatingEnabled),
            "resetTimeDisplay": .string(settings.resetTimeDisplay.rawValue), "showServiceStatus": .bool(settings.showServiceStatus),
            "privacyMode": .bool(settings.privacyMode), "statsRankMetric": .string(settings.statsRankMetric.rawValue),
            "cycleIncludesOtherAgents": .bool(settings.cycleIncludesOtherAgents), "piEstimatedOutputSpeed": .bool(settings.piEstimatedOutputSpeed),
            "brandColors": .array(ServiceBrand.allCases.map { brand in .object([
                "brand": .string(brand.rawValue), "mode": .string(settings.colorMode(for: brand).rawValue),
                "customHex": HostWindowJSON.string(settings.customColorHex(for: brand)),
                "defaultLightHex": .string(brand.defaultLightHex), "defaultDarkHex": .string(brand.defaultDarkHex)
            ]) }),
            "recentBrandColors": .array(settings.recentBrandColors.map(HostJSON.string))
        ]
        let data: [String: HostJSON] = [
            "quotaInterval": .string(settings.quotaInterval.rawValue), "usageInterval": .string(settings.usageInterval.rawValue),
            "proxyMode": .string(settings.proxyMode.rawValue), "proxyType": .string(settings.proxyType.rawValue),
            "proxyHost": .string(settings.proxyHost), "proxyPort": .number(Decimal(settings.proxyPort)),
            "currency": currencyJSON(), "usage": usageStatus(),
            "piTimingGuide": .object([
                "title": .string(text("Pi timing plugin", "Pi 计时插件")),
                "instructions": .string(text("Give these instructions to an AI to write a Pi timing plugin. Once installed, first token latency and output speed use actual generation time.",
                    "把下面的说明交给 AI，为 Pi 写一个计时插件。装好后，Pi 的首字和输出速度按实际生成时间计算。")),
                "copyText": .string(actions.piTimingGuide())
            ])
        ]
        let general: [String: HostJSON] = [
            "language": .string(settings.appLanguage.rawValue), "launchAtLogin": .bool(launch.enabled),
            "launchAtLoginRequiresApproval": .bool(launch.requiresApproval),
            "quotaAlertsEnabled": .bool(settings.quotaAlertsEnabled), "quotaAlertThresholdPercent": .number(Decimal(settings.quotaAlertThresholdPercent)),
            "quotaAlertFiveHourEnabled": .bool(settings.quotaAlertFiveHourEnabled), "quotaAlertWeeklyEnabled": .bool(settings.quotaAlertWeeklyEnabled),
            "quotaAlertBillingCycleEnabled": .bool(settings.quotaAlertBillingCycleEnabled), "quotaAlertSoundEnabled": .bool(settings.quotaAlertSoundEnabled),
            "notifications": actions.notifications(), "verboseLogging": .bool(settings.verboseLogging), "updates": actions.system.updates()
        ]
        return .object(["appearance": .object(appearance), "data": .object(data), "general": .object(general)])
    }

    private func currencyJSON() -> HostJSON {
        let state = actions.currency()
        var rates: [String: HostJSON] = ["USD": .string("1")]
        for currency in DisplayCurrency.allCases where currency != .usd {
            if let value = state.snapshot?.rates[currency.rawValue], value > 0 {
                rates[currency.rawValue] = HostWindowJSON.decimal(value)
            }
        }
        return .object([
            "selected": .string(settings.displayCurrency.rawValue), "rates": .object(rates),
            "fetchedAt": HostWindowJSON.date(state.snapshot?.fetchedAt), "sourceUpdatedAt": HostWindowJSON.date(state.snapshot?.sourceUpdatedAt),
            "refreshing": .bool(state.refreshing), "lastRefreshFailedAt": HostWindowJSON.date(state.failedAt)
        ])
    }

    private func pricingJSON() -> HostJSON {
        let catalog = actions.pricing()
        let providers: [HostJSON] = catalog.providers.map { provider in
            let models: [HostJSON] = provider.models.map { model in
                let amounts = ["input": model.price.input, "output": model.price.output,
                               "cacheRead": model.price.cacheRead, "cacheCreation": model.price.cacheCreation]
                return .object([
                    "id": .string(model.id), "name": .string(model.name),
                    "price": .object(amounts.mapValues { HostWindowJSON.decimal($0) }),
                    "displayPrice": .object(amounts.mapValues { .string(actions.formatPrice($0)) })
                ])
            }
            return .object(["id": .string(provider.id), "name": .string(provider.name), "models": .array(models)])
        }
        return .object(["providers": .array(providers), "fetchedAt": HostWindowJSON.date(catalog.fetchedAt),
                        "refreshFailed": .bool(catalog.failed), "usage": usageStatus()])
    }

    private func recalculationJSON(_ result: PricingRecalculationResult?) -> HostJSON {
        .object(["started": .bool(result != nil), "ok": .bool(result.map { !$0.isError } ?? false),
                 "message": .string(result?.message ?? text("Update and recalculation did not start", "更新和重算未执行")),
                 "usage": usageStatus()])
    }

    private func proxyFailure(_ error: QuotaError) -> String {
        if case .network(.tls) = error {
            return text("Secure connection failed — the proxy's certificate may not be trusted by the system", "安全连接失败，代理的证书可能未被系统信任")
        }
        guard case .network(.proxyUnavailable) = error else { return error.userMessage }
        switch actions.proxyResolution() {
        case .unavailable(.manualIncomplete): return text("Enter the address and port", "请填写地址和端口")
        case .unavailable(.invalidPort): return text("Port must be between 1 and 65535", "端口需在 1–65535 之间")
        case .unavailable(.invalidHost): return text("Enter only a hostname or IP, without http:// or a port", "地址只填主机名或 IP，不带 http:// 和端口")
        case .system, .proxy: return text("Proxy unavailable", "代理不可用")
        }
    }

    static func notificationJSON(_ service: QuotaNotificationService) -> HostJSON {
        let authorization: String
        switch service.permissionState?.authorization {
        case .notDetermined: authorization = "notDetermined"
        case .denied: authorization = "denied"
        case .allowed: authorization = "authorized"
        case nil: authorization = "unknown"
        }
        return .object([
            "authorization": .string(authorization), "canSubmit": .bool(service.permissionState?.canSubmit ?? false),
            "alertsAllowed": HostWindowJSON.bool(service.permissionState?.alerts), "soundAllowed": HostWindowJSON.bool(service.permissionState?.sound),
            "statusText": HostWindowJSON.string(service.statusText), "requesting": .bool(service.isRequestingAuthorization),
            "authorizationFailed": .bool(service.authorizationFailed), "permissionReadFailed": .bool(service.permissionReadFailed),
            "storagePaused": .bool(service.storagePaused), "rebuilding": .bool(service.isRebuilding)
        ])
    }

    static func updateJSON(_ updater: AppUpdater) -> HostJSON {
        .object([
            "version": .string(updater.currentVersion), "automaticChecks": .bool(updater.automaticChecks),
            // The native command always opens the update window, including an existing task or configuration error.
            "canCheck": .bool(true), "hasUpdate": .bool(updater.hasUpdate), "isWorking": .bool(updater.isWorking),
            "lastCheckedAt": HostWindowJSON.date(updater.lastCheckedAt)
        ])
    }
}
