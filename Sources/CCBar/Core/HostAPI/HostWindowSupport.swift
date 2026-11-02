import AppKit
import CCBarConfiguration
import CryptoKit
import Foundation

@MainActor
enum HostWindowValidation {
    static func keys(_ params: [String: HostJSON], allowed: Set<String>) throws {
        guard Set(params.keys).isSubset(of: allowed) else { throw invalid() }
    }
    static func invalid() -> HostError { HostError(code: "invalid_params", message: "Invalid parameters") }
    static func notFound() -> HostError { HostError(code: "not_found", message: "Item not found") }
    static func unavailable() -> HostError { HostError(code: "unavailable", message: "Operation is unavailable") }
    static func string(_ params: [String: HostJSON], _ key: String, required: Bool = true, max: Int = 4096) throws -> String? {
        guard let value = params[key] else {
            if required { throw invalid() }
            return nil
        }
        guard case .string(let text) = value, text.count <= max, required == false || !text.isEmpty else { throw invalid() }
        return text
    }
    static func bool(_ params: [String: HostJSON], _ key: String, required: Bool = true) throws -> Bool? {
        guard let value = params[key] else {
            if required { throw invalid() }
            return nil
        }
        guard case .bool(let result) = value else { throw invalid() }
        return result
    }
    static func int(_ params: [String: HostJSON], _ key: String, required: Bool = true, range: ClosedRange<Int> = 0...Int.max) throws -> Int? {
        guard let value = params[key] else {
            if required { throw invalid() }
            return nil
        }
        guard case .number(let decimal) = value, let result = Int(exactly: decimal as NSNumber), range.contains(result) else { throw invalid() }
        return result
    }
    static func object(_ params: [String: HostJSON], _ key: String) throws -> [String: HostJSON] {
        guard case .object(let value) = params[key] else { throw invalid() }
        return value
    }
    static func stringArray(_ params: [String: HostJSON], _ key: String, required: Bool = true, max: Int = 100) throws -> [String]? {
        guard let value = params[key] else {
            if required { throw invalid() }
            return nil
        }
        guard case .array(let values) = value, values.count <= max else { throw invalid() }
        return try values.map {
            guard case .string(let text) = $0, !text.isEmpty, text.count <= 512 else { throw invalid() }
            return text
        }
    }
    static func application(_ raw: String) throws -> AgentApplication {
        guard let value = AgentApplication(rawValue: raw) else { throw invalid() }
        return value
    }
    static func quotaApp(_ raw: String) throws -> QuotaApp {
        guard let value = QuotaApp(rawValue: raw) else { throw invalid() }
        return value
    }
}

@MainActor
enum HostWindowJSON {
    static let empty = HostJSON.object([:])
    static let ok = HostJSON.object(["ok": .bool(true)])
    static func date(_ value: Date?) -> HostJSON { value.map { .string(HostWindowDateFormatter.string($0)) } ?? .null }
    static func decimal(_ value: Decimal?) -> HostJSON { value.map { .string(NSDecimalNumber(decimal: $0).stringValue) } ?? .null }
    static func string(_ value: String?) -> HostJSON { value.map(HostJSON.string) ?? .null }
    static func bool(_ value: Bool?) -> HostJSON { value.map(HostJSON.bool) ?? .null }
}

@MainActor
enum HostWindowDateFormatter {
    static func string(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

@MainActor
struct HostWindowSystemActions {
    var appearance: () -> String
    var syncFloating: () -> Void
    var copyText: (String) throws -> Void
    var openExternal: (URL) -> Bool
    var openNotificationSettings: () -> Void
    var revealLogs: () -> Void
    var exportDiagnostics: () async throws -> String
    var updates: () -> HostJSON
    var checkUpdates: () -> Void
    var setAutomaticUpdates: (Bool) -> Void

    static func live(state: AppState) -> Self {
        Self(
            appearance: {
                NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? "dark" : "light"
            },
            syncFloating: { FloatingPanelController.shared.sync() },
            copyText: { text in
                NSPasteboard.general.clearContents()
                guard NSPasteboard.general.setString(text, forType: .string) else {
                    throw HostError(code: "operation_failed", message: "Could not copy text")
                }
            },
            openExternal: { NSWorkspace.shared.open($0) },
            openNotificationSettings: {
                let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
                if !NSWorkspace.shared.open(url) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
                }
            },
            revealLogs: { DiagnosticsBundle.revealLogDirectory() },
            exportDiagnostics: {
                let url = try await DiagnosticsBundle.export(appState: state)
                DiagnosticsBundle.revealInFinder(url)
                return url.path
            },
            updates: { HostWindowSettingsService.updateJSON(AppUpdater.shared) },
            checkUpdates: { AppUpdater.shared.checkForUpdates() },
            setAutomaticUpdates: { AppUpdater.shared.setAutomaticChecks($0) }
        )
    }
}

@MainActor
class HostWindowPresenter {
    let state: AppState
    let settings: SettingsStore

    init(state: AppState, settings: SettingsStore) {
        self.state = state
        self.settings = settings
    }

    var capabilities: Set<String> { [] }

    func bootstrapJSON() -> HostJSON {
        .object([
            "route": routeJSON(),
            "language": .string(settings.appLanguage.rawValue),
            "resolvedLanguage": .string(settings.resolvedLanguage == .zh ? "zh" : "en"),
            "platform": .string("macos"),
            "timeZone": .string(TimeZone.current.identifier),
            "appearance": .string(NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? "dark" : "light"),
            "version": .string(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"),
            "sidebarApplications": .array(state.applications.sidebarApplications.map { applicationJSON($0) }),
            "visibleUsageServices": .array(settings.visibleUsageApps.map { .string($0.rawValue) }),
            "capabilities": .array(capabilities.sorted().map(HostJSON.string)),
        ])
    }

    func routeJSON() -> HostJSON {
        switch state.mainTab {
        case .application(let application):
            return .object(["page": .string("application"), "application": .string(application.rawValue)])
        case .applications: return .object(["page": .string("applications")])
        case .quotaManagement: return .object(["page": .string("quotaManagement")])
        case .stats: return .object(["page": .string("stats")])
        case .settings: return .object(["page": .string("settings")])
        }
    }

    func applicationJSON(_ application: AgentApplication) -> HostJSON {
        .object([
            "id": .string(application.rawValue),
            "name": .string(application.name),
            "detected": .bool(state.applications.detected.contains(application)),
            "addedToSidebar": .bool(state.applications.addedApplications.contains(application)),
            "usageService": application.usageApp.map { .string($0.rawValue) } ?? .null,
            "usageVisible": .bool(application.usageApp.map { settings.isUsageServiceVisible($0) } ?? false),
            "supportsProviderConfiguration": .bool(application.supportsProviderConfiguration),
            "supportedAPIs": .array(application.supportedAPIs.map { .string($0.rawValue) }),
            "defaultSupplier": .string(application.defaultSupplier.rawValue),
            "icon": iconJSON(application.brand),
        ])
    }

    func iconJSON(_ brand: ServiceBrand) -> HostJSON {
        let resolved = ServiceIconResolver.resolve(brand: brand, useInstalledAppIcons: settings.useInstalledAppIcons)
        var dataURI: String?
        if let image = resolved?.image,
           let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
           let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) {
            dataURI = "data:image/png;base64," + data.base64EncodedString()
        }
        let kind = switch resolved?.kind {
        case .installedApp: "installedApp"
        case .favicon: "favicon"
        case .brand: "brand"
        case nil: "fallback"
        }
        let custom = settings.colorMode(for: brand) == .custom ? settings.customColorHex(for: brand) : nil
        return .object([
            "brand": .string(brand.rawValue),
            "kind": .string(kind),
            "dataURI": HostWindowJSON.string(dataURI),
            "fillsTile": .bool(resolved?.fillsTile ?? brand.faviconFillsTile),
            "lightHex": .string(custom ?? brand.defaultLightHex),
            "darkHex": .string(custom ?? brand.defaultDarkHex),
        ])
    }

    func opaqueID(_ raw: String) -> String {
        let digest = SHA256.hash(data: Data(raw.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return "acct_" + digest
    }

    func quotaSnapshotJSON(_ snapshot: QuotaSnapshot?) -> HostJSON {
        guard let snapshot else { return .null }
        let limits = [snapshot.primaryLimit, snapshot.secondaryLimit].compactMap { $0 } + snapshot.auxiliaryLimits + snapshot.modelLimits
        return .object([
            "fetchedAt": HostWindowJSON.date(snapshot.fetchedAt),
            "planType": HostWindowJSON.string(snapshot.planType),
            "unlimited": HostWindowJSON.bool(snapshot.isUnlimited),
            "limits": .array(limits.map { limit in
                .object([
                    "id": .string(limit.id),
                    "kind": .string(limit.kind.rawValue),
                    "displayName": HostWindowJSON.string(limit.displayName),
                    "usedPercent": .number(Decimal(limit.window.usedPercent)),
                    "resetsAt": HostWindowJSON.date(limit.window.resetsAt),
                    "windowSeconds": limit.window.windowSeconds.map { .number(Decimal($0)) } ?? .null,
                    "active": HostWindowJSON.bool(limit.isActive),
                ])
            }),
        ])
    }

    func refreshJSON(_ refresh: QuotaRefreshState, error: String?) -> HostJSON {
        .object([
            "inFlight": .bool(refresh.inFlight),
            "backoffUntil": HostWindowJSON.date(refresh.backoffUntil),
            "lastSuccessAt": HostWindowJSON.date(refresh.lastSuccessAt),
            "lastAttemptAt": HostWindowJSON.date(refresh.lastAttemptAt),
            "failed": .bool(refresh.lastError != nil || error != nil),
            "source": HostWindowJSON.string(refresh.source?.rawValue),
            "error": HostWindowJSON.string(error.map { PrivacyDisplay.error($0) }),
        ])
    }

    func emptyRefreshJSON() -> HostJSON { refreshJSON(QuotaRefreshState(), error: nil) }
}
