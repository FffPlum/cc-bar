import Foundation
import AppKit
import Observation
import CCBarConfiguration

/// The OS operations are injectable, so tests never open panels or change login items.
@MainActor
struct HostPlatformActions {
    var capabilities: Set<String>
    var pickDirectory: () throws -> String?
    var revealPath: (String) throws -> Void
    var setLaunchAtLogin: (Bool) throws -> (Bool, Bool)

    static func live(settings: SettingsStore) -> Self {
        Self(capabilities: ["platform.pickDirectory", "platform.revealPath", "platform.setLaunchAtLogin"], pickDirectory: {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            return panel.runModal() == .OK ? panel.url?.path : nil
        }, revealPath: { path in
            guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) else {
                throw HostError(code: "invalid_params", message: "Path must identify an existing absolute path")
            }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }, setLaunchAtLogin: { enabled in
            try settings.setLaunchAtLogin(enabled)
            return (settings.launchAtLoginRegistered, settings.launchAtLoginRequiresApproval)
        })
    }
}

@MainActor
final class MacOSHostService {
    private let state: AppState
    private let settings: SettingsStore
    private let platform: HostPlatformActions
    private let refreshQuota: () async -> Void
    private var listeners: [UUID: (HostEvent) -> Void] = [:]
    private var observationGeneration = 0
    private var revision: UInt64 = 0
    private var windowActive = false
    private var notificationTokens: [NSObjectProtocol] = []
    private var appearanceObservation: NSKeyValueObservation?
    private lazy var presenter = HostWindowPresenter(state: state, settings: settings)
    private lazy var applications = HostWindowApplicationsService(state: state, settings: settings)
    private lazy var accounts: HostWindowAccountsService = {
        let service = HostWindowAccountsService(state: state, settings: settings)
        service.didChange = { [weak self] in self?.emit(["quota", "applications", "authorizations"]) }
        return service
    }()
    private lazy var usage: HostWindowUsageService = {
        let service = HostWindowUsageService(state: state, settings: settings)
        service.didChange = { [weak self] in self?.emit(["usage"]) }
        return service
    }()
    private lazy var windowSettings = HostWindowSettingsService(state: state, settings: settings, usageStatus: { [weak self] in
        self?.usage.statusJSON() ?? .object([:])
    })
    private let baseCapabilities: Set<String> = ["host.describe", "usage.overview", "quota.snapshot", "quota.refresh", "settings.get", "settings.update"]
    private var capabilities: Set<String> {
        baseCapabilities.union(platform.capabilities).union(["window.bootstrap", "window.navigate"])
            .union(HostWindowApplicationsService.methods).union(HostWindowAccountsService.methods)
            .union(HostWindowUsageService.methods).union(HostWindowSettingsService.methods)
    }

    init(state: AppState, settings: SettingsStore, platform: HostPlatformActions? = nil,
         refreshQuota: (() async -> Void)? = nil) {
        self.state = state
        self.settings = settings
        self.platform = platform ?? .live(settings: settings)
        self.refreshQuota = refreshQuota ?? { await state.refreshQuotas(reason: .userInitiated) }
    }

    func subscribe(_ listener: @escaping (HostEvent) -> Void) -> UUID {
        let id = UUID()
        listeners[id] = listener
        if listeners.count == 1 { observationGeneration += 1; observe(generation: observationGeneration) }
        return id
    }

    func unsubscribe(_ id: UUID) {
        listeners.removeValue(forKey: id)
        if listeners.isEmpty { observationGeneration += 1 }
    }

    func invalidate() {
        if windowActive { accounts.invalidate(); usage.invalidate() }
        listeners.removeAll()
        observationGeneration += 1
        for token in notificationTokens { NotificationCenter.default.removeObserver(token) }
        notificationTokens.removeAll()
        appearanceObservation = nil
    }

    private func activateWindow() {
        guard !windowActive else { return }
        windowActive = true
        notificationTokens.append(NotificationCenter.default.addObserver(forName: PricingCatalogStore.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.emit(["pricing", "usage", "settings"]) }
        })
        appearanceObservation = NSApp?.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.emit(["settings"]) }
        }
        observationGeneration += 1
        observe(generation: observationGeneration)
    }

    private func emit(_ domains: [String]) {
        guard !listeners.isEmpty else { return }
        revision &+= 1
        let event = HostEvent(revision: String(revision), domains: domains)
        for listener in Array(listeners.values) { listener(event) }
    }

    private func observe(generation: Int) {
        guard generation == observationGeneration, !listeners.isEmpty else { return }
        // Observation tracks writes from native UI and background scans as well as host calls.
        withObservationTracking {
            _ = state.usageService.aggregator.revision
            _ = state.primaryQuotaStates
            _ = settings.privacyMode
            _ = settings.useInstalledAppIcons
            _ = settings.usageServiceVisibility
            _ = settings.serviceOrder
            _ = settings.cursorAccountDetected
            _ = settings.commandCodeAccountDetected
            if windowActive {
                _ = state.mainTab
                _ = state.usageService.requestIndexRevision
                _ = state.usageService.conversationAggregator.revision
                _ = state.usageService.cycleAggregator.snapshot()
                _ = state.quotaCycles
                _ = state.quotaHistory
                _ = state.applications.snapshots
                _ = state.applications.detected
                _ = state.applications.logins
                _ = state.applications.errors
                _ = state.applications.addedApplications
                applications.trackManagementChanges()
                _ = state.authorizations.accounts
                _ = state.authorizations.providers
                _ = state.authorizations.error
                _ = state.applicationImportError
                _ = usage.statusJSON()
                accounts.trackChanges()
                windowSettings.trackChanges()
            }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.observationGeneration == generation, !self.listeners.isEmpty else { return }
                self.emit(self.windowActive ? ["usage", "quota", "settings", "navigation", "applications", "authorizations", "notifications", "updates"] : ["usage", "quota", "settings"])
                self.observe(generation: generation)
            }
        }
    }

    func handle(_ request: HostRequest) async -> HostResponse {
        guard request.version == 1 else { return .init(id: request.id, error: .init(code: "unsupported_version", message: "Unsupported protocol version")) }
        guard !request.id.isEmpty else { return .init(id: request.id, error: .init(code: "invalid_request", message: "Request id is required")) }
        do { return .init(id: request.id, result: try await execute(request.method, request.params)) }
        catch let error as HostError { return .init(id: request.id, error: error) }
        catch { return .init(id: request.id, error: .init(code: "operation_failed", message: "Native operation failed")) }
    }

    private func execute(_ method: String, _ params: [String: HostJSON]) async throws -> HostJSON {
        let capabilities = self.capabilities
        guard capabilities.contains(method) else {
            if method.hasPrefix("platform.") { throw HostError(code: "unavailable", message: "Capability is unavailable") }
            throw HostError(code: "unknown_method", message: "Unknown method")
        }
        if !baseCapabilities.contains(method), !platform.capabilities.contains(method) {
            activateWindow()
            if HostWindowApplicationsService.methods.contains(method) { return try applications.handle(method, params: params) }
            if HostWindowAccountsService.methods.contains(method) { return try await accounts.handle(method, params: params) }
            if HostWindowUsageService.methods.contains(method) { return try await usage.handle(method, params: params) }
            if HostWindowSettingsService.methods.contains(method) { return try await windowSettings.handle(method, params: params) }
        }
        switch method {
        case "window.bootstrap":
            try keys(params, allowed: [])
            return bootstrapJSON()
        case "window.navigate":
            try keys(params, allowed: ["route"])
            let route = try HostWindowValidation.object(params, "route")
            let page = try HostWindowValidation.string(route, "page")
            switch page {
            case "application":
                try keys(route, allowed: ["page", "application"])
                guard let id = try HostWindowValidation.string(route, "application"),
                      let app = AgentApplication(rawValue: id), state.applications.sidebarApplications.contains(app) else { throw invalid() }
                state.mainTab = .application(app)
            case "applications", "quotaManagement", "stats", "settings":
                try keys(route, allowed: ["page"])
                switch page {
                case "applications": state.mainTab = .applications
                case "quotaManagement": state.mainTab = .quotaManagement
                case "stats": state.mainTab = .stats
                default: state.mainTab = .settings
                }
            default: throw invalid()
            }
            return bootstrapJSON()
        case "host.describe":
            try keys(params, allowed: [])
            return .object(["platform": .string("macos"), "timeZone": .string(TimeZone.current.identifier), "capabilities": .array(capabilities.sorted().map(HostJSON.string))])
        case "usage.overview": return try overview(params)
        case "settings.get": try keys(params, allowed: []); return settingsJSON()
        case "settings.update":
            try keys(params, allowed: ["patch"])
            guard case .object(let patch) = params["patch"] else { throw invalid() }
            try keys(patch, allowed: ["privacyMode", "useInstalledAppIcons"])
            for value in patch.values { guard case .bool = value else { throw invalid() } }
            if case .bool(let value) = patch["privacyMode"] { settings.privacyMode = value }
            if case .bool(let value) = patch["useInstalledAppIcons"] { settings.useInstalledAppIcons = value }
            return settingsJSON()
        case "quota.snapshot": try keys(params, allowed: []); return quotaJSON()
        case "quota.refresh":
            try keys(params, allowed: [])
            await refreshQuota()
            return quotaJSON()
        case "platform.pickDirectory":
            try keys(params, allowed: [])
            return .object(["path": try platform.pickDirectory().map(HostJSON.string) ?? .null])
        case "platform.revealPath":
            try keys(params, allowed: ["path"])
            guard case .string(let path) = params["path"], !path.isEmpty else { throw invalid() }
            try platform.revealPath(path)
            return .object([:])
        case "platform.setLaunchAtLogin":
            try keys(params, allowed: ["enabled"])
            guard case .bool(let enabled) = params["enabled"] else { throw invalid() }
            let result = try platform.setLaunchAtLogin(enabled)
            return .object(["enabled": .bool(result.0), "requiresApproval": .bool(result.1)])
        default: throw HostError(code: "unknown_method", message: "Unknown method")
        }
    }

    private func bootstrapJSON() -> HostJSON {
        guard case .object(var value) = presenter.bootstrapJSON() else { return .object([:]) }
        value["capabilities"] = .array(capabilities.sorted().map(HostJSON.string))
        return .object(value)
    }

    private func keys(_ params: [String: HostJSON], allowed: Set<String>) throws {
        guard Set(params.keys).isSubset(of: allowed) else { throw invalid() }
    }
    private func invalid() -> HostError { .init(code: "invalid_params", message: "Invalid parameters") }
    private func settingsJSON() -> HostJSON {
        .object(["privacyMode": .bool(settings.privacyMode), "useInstalledAppIcons": .bool(settings.useInstalledAppIcons)])
    }
    private func overview(_ params: [String: HostJSON]) throws -> HostJSON {
        try keys(params, allowed: ["from", "to", "service"])
        guard case .string(let fromString) = params["from"], case .string(let toString) = params["to"],
              let from = Self.parseDate(fromString), let to = Self.parseDate(toString), from < to,
              Calendar.current.startOfDay(for: from) == from, Calendar.current.startOfDay(for: to) == to else { throw invalid() }
        var app: UsageApp?
        if let value = params["service"] {
            guard case .string(let raw) = value, let parsed = UsageApp(rawValue: raw) else { throw invalid() }
            app = parsed
        }
        let range = StatsDateInterval(from: from, to: to)
        let aggregator = state.usageService.aggregator
        let model = StatsOverviewModel.build(buckets: aggregator.snapshot(), input: StatsOverviewInput(
            revision: aggregator.revision, current: range, previous: nil, chart: range, granularity: .day,
            serviceApp: app, visibleApps: settings.visibleUsageApps, highlightedPeriodStart: nil))
        return .object(["totals": totalsJSON(model.totalsAll), "samples": .array(model.samples.map {
            .object(["date": .string(Self.dateString($0.day)), "totals": totalsJSON($0.totalUsage)])
        })])
    }
    private func totalsJSON(_ t: UsageTotals) -> HostJSON {
        .object(["inputTokens": .number(Decimal(t.inputTokens)), "outputTokens": .number(Decimal(t.outputTokens)),
                 "cacheReadTokens": .number(Decimal(t.cacheReadTokens)), "cacheCreationTokens": .number(Decimal(t.cacheCreationTokens)),
                 "totalTokens": .number(Decimal(t.totalTokens)), "costUSD": .string(NSDecimalNumber(decimal: t.costUSD).stringValue),
                 "requestCount": .number(Decimal(t.requestCount)), "hasUnpricedUsage": .bool(t.hasUnpricedUsage), "costIncomplete": .bool(t.costIncomplete)])
    }
    private func quotaJSON() -> HostJSON {
        .object(["services": .array(QuotaApp.allCases.map { app in
            let refresh = state.refreshState(for: app)
            return .object(["service": .string(app.rawValue), "snapshot": state.quotaSnapshot(for: app).map(snapshotJSON) ?? .null,
                "refresh": .object(["inFlight": .bool(refresh.inFlight), "backoffUntil": refresh.backoffUntil.map { .string(Self.dateString($0)) } ?? .null,
                    "lastSuccessAt": refresh.lastSuccessAt.map { .string(Self.dateString($0)) } ?? .null,
                    "lastAttemptAt": refresh.lastAttemptAt.map { .string(Self.dateString($0)) } ?? .null,
                    "failed": .bool(refresh.lastError != nil || state.quotaError(for: app) != nil),
                    "source": refresh.source.map { .string($0.rawValue) } ?? .null])])
        })])
    }
    private func snapshotJSON(_ snapshot: QuotaSnapshot) -> HostJSON {
        let limits = [snapshot.primaryLimit, snapshot.secondaryLimit].compactMap { $0 } + snapshot.auxiliaryLimits + snapshot.modelLimits
        return .object(["fetchedAt": .string(Self.dateString(snapshot.fetchedAt)), "planType": snapshot.planType.map(HostJSON.string) ?? .null,
                        "isUnlimited": snapshot.isUnlimited.map(HostJSON.bool) ?? .null,
                        "limits": .array(limits.map { limit in
            .object(["id": .string(limit.id), "kind": .string(limit.kind.rawValue), "displayName": limit.displayName.map(HostJSON.string) ?? .null,
                     "usedPercent": .number(Decimal(limit.window.usedPercent)), "resetsAt": limit.window.resetsAt.map { .string(Self.dateString($0)) } ?? .null,
                     "windowSeconds": limit.window.windowSeconds.map { .number(Decimal($0)) } ?? .null, "isActive": limit.isActive.map(HostJSON.bool) ?? .null])
        })])
    }
    private static func dateString(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    private static func parseDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: string)
    }
}
