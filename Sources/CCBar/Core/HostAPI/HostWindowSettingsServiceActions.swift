import Foundation

/// All operations which can touch the system, network, global stores or files are injected.
/// Tests provide these closures without constructing any live settings actions.
@MainActor
struct HostWindowSettingsActions {
    var system: HostWindowSystemActions
    var launchStatus: () -> (enabled: Bool, requiresApproval: Bool)
    var setLaunchAtLogin: (Bool) throws -> Void
    var currency: () -> (snapshot: ExchangeRateSnapshot?, refreshing: Bool, failedAt: Date?)
    var refreshCurrency: () async -> Void
    var notifications: () -> HostJSON
    var refreshPermission: () async -> Void
    var requestPermission: () async -> Void
    var notificationSettingsChanged: () -> Void
    var rebuildNotifications: () async -> Void
    var pricing: () -> (providers: [ModelsDevProviderPricing], fetchedAt: Date?, failed: Bool)
    var loadPricing: () async -> Void
    var recalculate: () async -> PricingRecalculationResult?
    var formatPrice: (Decimal) -> String
    var testProxy: () async -> Result<Void, QuotaError>
    var proxyResolution: () -> ProxyResolution
    var applyVerboseLogging: (Bool) -> Void
    var applyRefreshIntervals: () -> Void
    var piTimingGuide: () -> String

    static func live(state: AppState, settings: SettingsStore) -> Self {
        Self(
            system: .live(state: state),
            launchStatus: { (settings.launchAtLoginRegistered, settings.launchAtLoginRequiresApproval) },
            setLaunchAtLogin: { try settings.setLaunchAtLogin($0) },
            currency: {
                let store = CurrencyStore.shared
                return (store.snapshot, store.isRefreshing, store.lastRefreshFailedAt)
            },
            refreshCurrency: { _ = await CurrencyStore.shared.refresh() },
            notifications: { HostWindowSettingsService.notificationJSON(state.quotaNotifications) },
            refreshPermission: { _ = await state.quotaNotifications.refreshPermission() },
            requestPermission: { await state.quotaNotifications.requestPermissionIfNeeded() },
            notificationSettingsChanged: { state.quotaNotifications.settingsChanged() },
            rebuildNotifications: { await state.quotaNotifications.rebuild(entries: state.quotaAlertEntries) },
            pricing: {
                let store = PricingCatalogStore.shared
                return (store.providerCatalog, store.modelsDevFetchedAt, store.modelsDevRefreshFailed)
            },
            loadPricing: { await PricingCatalogStore.shared.loadProviderCatalogIfNeeded() },
            recalculate: { await state.usageService.refreshPricingCatalogAndRecalculateUsage() },
            formatPrice: { CurrencyFormatter.pricePerMillion($0) },
            testProxy: { await NetworkProxy.testConnection() },
            proxyResolution: { NetworkProxy.resolve() },
            applyVerboseLogging: { settings.verboseLogging = $0 },
            applyRefreshIntervals: { state.applySettingsChange() },
            piTimingGuide: { PiTimingPluginGuide.text }
        )
    }
}
