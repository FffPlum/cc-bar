import AppKit
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    private var menuController: MenuBarController?
    private var mainWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var openStatisticsWindow: (() -> Void)?
    private var shouldOpenStatisticsWhenReady = false
    private var terminationHandler: (@MainActor () async throws -> Void)?
    private var terminationFailureHandler: (@MainActor (Error) -> Bool)?
    private var terminationTask: Task<Void, Never>?
    private var quotaNotificationDelegate: QuotaNotificationDelegate?

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard !AppRuntime.isRunningUnitTests else { return }
        let delegate = QuotaNotificationDelegate { [weak self] in self?.requestOpenStatisticsWindow() }
        quotaNotificationDelegate = delegate
        UNUserNotificationCenter.current().delegate = delegate
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        menuController = MenuBarController(appDelegate: self, appState: appState)
        // 冷启动（含开机自启、Dock/应用程序/Launchpad/Raycast 手动启动）一律静默，
        // 只驻留菜单栏；主窗口只在用户点 Dock 图标触发 reopen 时才打开。
        let info = Bundle.main.infoDictionary
        AppLog.info(.app, """
            launched version=\(info?["CFBundleShortVersionString"] as? String ?? "—") \
            build=\(info?["CFBundleVersion"] as? String ?? "—") \
            macOS=\(ProcessInfo.processInfo.operatingSystemVersionString)
            """)
    }

    func openMainWindow() {
        menuController?.closeMenu()
        // 等原生菜单退出 tracking，再激活主窗口，避免切换应用时菜单仍在处理点击。
        DispatchQueue.main.async { [weak self] in self?.showMainWindow() }
    }

    private func showMainWindow() {
        if mainWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "CCBar"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: MainWindowRootView().environment(appState))
            window.center()
            mainWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    func openOnboardingWindow() {
        if onboardingWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = tr("Welcome", "欢迎")
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: OnboardingView(
                closeWindow: { [weak self] in self?.onboardingWindow?.close() },
                openStatistics: { [weak self] in
                    self?.appState.mainTab = .stats
                    self?.openMainWindow()
                }
            ).environment(appState))
            window.center()
            onboardingWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow?.makeKeyAndOrderFront(nil)
    }

    /// 退出前把缓冲里剩下的日志写完——崩溃前最后那几行往往正是要查的东西。
    func applicationWillTerminate(_ notification: Notification) {
        AppLog.info(.app, "terminating")
        AppLog.shared.flushNow()
    }

    /// 普通退出和更新重启都等业务数据保存成功后再退出。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let terminationHandler else { return .terminateNow }
        guard terminationTask == nil else { return .terminateLater }
        terminationTask = Task {
            do {
                try await terminationHandler()
                sender.reply(toApplicationShouldTerminate: true)
            } catch {
                AppLog.error(.persistence, "termination cancelled: \(Redact.error(error))")
                sender.reply(toApplicationShouldTerminate: false)
                terminationTask = nil
                if terminationFailureHandler?(error) == true { return }
                let alert = NSAlert()
                alert.messageText = tr("CCBar could not quit", "CCBar 未能退出")
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.addButton(withTitle: tr("OK", "好"))
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
        return .terminateLater
    }

    func installTerminationHandler(_ handler: @escaping @MainActor () async throws -> Void) {
        terminationHandler = handler
    }

    func installTerminationFailureHandler(_ handler: @escaping @MainActor (Error) -> Bool) {
        terminationFailureHandler = handler
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        requestOpenStatisticsWindow()
        return false
    }

    func installOpenStatisticsHandler(_ handler: @escaping () -> Void) {
        openStatisticsWindow = handler
        guard shouldOpenStatisticsWhenReady else { return }
        shouldOpenStatisticsWhenReady = false
        handler()
    }

    private func requestOpenStatisticsWindow() {
        guard let openStatisticsWindow else {
            shouldOpenStatisticsWhenReady = true
            return
        }
        openStatisticsWindow()
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === mainWindow {
            window.contentView = nil
            mainWindow = nil
        } else if window === onboardingWindow {
            window.contentView = nil
            onboardingWindow = nil
        }
    }
}

/// 原生状态栏菜单负责 tracking，在全屏 / 自动隐藏模式下保持系统菜单栏展开。
@MainActor
private final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var labelView: StatusLabelHostingView?
    private var contentView: NSHostingView<AnyView>?
    private var keyMonitor: Any?
    private let appState: AppState
    private weak var appDelegate: AppDelegate?

    init(appDelegate: AppDelegate, appState: AppState) {
        self.appState = appState
        self.appDelegate = appDelegate
        super.init()
        guard let button = statusItem.button else { return }
        let label = MenuBarLabelRoot(
            appDelegate: appDelegate,
            openMain: { [weak appDelegate] in appDelegate?.openMainWindow() },
            openOnboarding: { [weak appDelegate] in appDelegate?.openOnboardingWindow() },
            updateStatusImage: { [weak button] image, label in
                button?.image = image
                button?.setAccessibilityLabel(label)
            }
        ).environment(appState)
        // 保留 SwiftUI 的启动任务和状态观察，尺寸交给 NSStatusBarButton 原生图像布局。
        let view = StatusLabelHostingView(rootView: AnyView(label))
        view.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
        button.addSubview(view)
        labelView = view

        let content = NSHostingView(rootView: AnyView(PopoverRootView(
            openMain: { [weak appDelegate] tab in
                appDelegate?.appState.mainTab = tab
                appDelegate?.openMainWindow()
            }
        ).environment(appState)))
        content.setFrameSize(content.fittingSize)
        contentView = content
        let item = NSMenuItem()
        item.view = content
        menu.autoenablesItems = false
        menu.showsStateColumn = false
        menu.delegate = self
        menu.addItem(item)
        // 交给 NSStatusItem 开启系统菜单 tracking，不激活 App，也不手动弹出浮窗。
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        // 自定义菜单视图在打开前测量；tracking 期间不修改菜单尺寸。
        if let contentView { contentView.setFrameSize(contentView.fittingSize) }
    }

    func menuWillOpen(_ menu: NSMenu) {
        // 自定义菜单视图不接收键盘事件；保留面板原有的快捷键入口。
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else { return event }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "r":
                Task { await self.appState.refreshNow() }
            case ",":
                self.appState.mainTab = .settings
                self.appDelegate?.openMainWindow()
            case "1":
                self.appState.mainTab = .stats
                self.appDelegate?.openMainWindow()
            default:
                return event
            }
            return nil
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
    }

    func closeMenu() {
        menu.cancelTrackingWithoutAnimation()
    }
}

private final class StatusLabelHostingView: NSHostingView<AnyView> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
