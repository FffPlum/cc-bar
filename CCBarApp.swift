import SwiftUI

@main
struct CCBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            AppCommands(appState: appDelegate.appState, openMain: { appDelegate.openMainWindow() })
        }
    }
}

/// 菜单栏标签同时承载启动任务及系统通知处理。
struct MenuBarLabelRoot: View {
    let appDelegate: AppDelegate
    @Environment(AppState.self) private var appState
    let openMain: () -> Void
    let openOnboarding: () -> Void
    let updateStatusImage: (NSImage, String) -> Void

    var body: some View {
        MenuBarLabel(updateImage: updateStatusImage)
            .onChange(of: appState.kimiManagedAccounts) { _, _ in
                guard !AppRuntime.isRunningUnitTests else { return }
                FloatingPanelController.shared.sync()
            }
            .onChange(of: appState.moonshotAccounts) { _, _ in
                guard !AppRuntime.isRunningUnitTests else { return }
                FloatingPanelController.shared.sync()
            }
            .onChange(of: appState.moonshotBalances) { _, _ in
                guard !AppRuntime.isRunningUnitTests else { return }
                FloatingPanelController.shared.sync()
            }
            .onChange(of: SettingsStore.shared.privacyMode) { _, enabled in
                appState.quotaNotifications.settingsChanged(clearNotifications: enabled)
            }
            .onChange(of: SettingsStore.shared.quotaAlertsEnabled) { _, _ in
                appState.quotaNotifications.settingsChanged()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                guard !AppRuntime.isRunningUnitTests else { return }
                Task { await appState.quotaNotifications.refreshPermission() }
            }
            .onAppear {
                appDelegate.installTerminationHandler {
                    try await appState.prepareForTermination()
                }
                appDelegate.installTerminationFailureHandler { error in
                    AppUpdater.shared.terminationPreparationFailed(error)
                }
                appDelegate.installOpenStatisticsHandler {
                    // 首次启动仍由 Onboarding 接管，不同时打开主窗口。
                    guard SettingsStore.shared.didCompleteOnboarding else { return }
                    appState.mainTab = .stats
                    openMain()
                }
            }
            .task {
                // 单元测试宿主也会启动 App；此时绝不能触发真实 bootstrap，
                // 它会读真实日志、写真实 rollup / 缓存。测试自己注入临时目录驱动 UsageService。
                guard !AppRuntime.isRunningUnitTests else { return }
                CurrencyStore.shared.refreshIfNeeded()
                appState.quotaNotifications.settingsChanged(
                    clearNotifications: SettingsStore.shared.privacyMode || !SettingsStore.shared.quotaAlertsEnabled
                )
                await appState.bootstrap()
                AppUpdater.shared.start()
                FloatingPanelController.shared.attach(appState: appState)
                FloatingPanelController.shared.openSettingsHandler = {
                    appState.mainTab = .settings
                    openMain()
                }
                FloatingPanelController.shared.sync()
            }
            .onChange(of: appState.shouldShowOnboarding) { _, show in
                guard show else { return }
                appState.shouldShowOnboarding = false
                openOnboarding()
            }
    }
}

/// 运行环境判定。测试宿主同样是 CCBar.app，必须显式区分，否则单元测试会启动真实采集。
nonisolated enum AppRuntime {
    /// 测试宿主进程里必须为 true。判定取多重信号：不同 Xcode 版本注入的环境变量与
    /// 加载进来的 xctest bundle 名称并不一致，任一命中即认定处于测试环境。
    static var isRunningUnitTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        if environment["XCTestConfigurationFilePath"] != nil { return true }
        if environment["XCTestBundlePath"] != nil { return true }
        if environment["XCTestSessionIdentifier"] != nil { return true }
        if environment["XCTestSessionIdentifierKey"] != nil { return true }
        if NSClassFromString("XCTestCase") != nil { return true }
        if Bundle.allBundles.contains(where: { $0.bundlePath.hasSuffix(".xctest") }) { return true }
        if Bundle.allFrameworks.contains(where: { $0.bundlePath.contains("XCTest.framework") }) { return true }
        return false
    }
}

/// 主窗口 / 刷新 / 设置 的全局快捷键。
/// ⌘Q 由 SwiftUI 默认提供。
private struct AppCommands: Commands {
    let appState: AppState
    let openMain: () -> Void

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button(tr("Check for Updates…", "检查更新…")) {
                AppUpdater.shared.checkForUpdates()
            }
        }
        CommandGroup(replacing: .appSettings) {
            Button(tr("Preferences…", "设置")) {
                appState.mainTab = .settings
                openMain()
            }
            .keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(after: .windowList) {
            Button(tr("Statistics", "统计")) {
                appState.mainTab = .stats
                openMain()
            }
            .keyboardShortcut("1", modifiers: .command)

            Button(tr("Refresh now", "立即刷新")) {
                Task { await appState.refreshNow() }
            }
            .keyboardShortcut("r", modifiers: .command)
        }
    }
}
