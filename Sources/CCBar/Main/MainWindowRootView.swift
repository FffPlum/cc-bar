import SwiftUI
import CCBarConfiguration

enum MainTab: Hashable {
    case application(AgentApplication)
    case applications
    case quotaManagement
    case stats
    case settings
}

enum MainWindowLayout {
    static let sidebarWidth: CGFloat = 200
}

struct MainWindowRootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 0) {
            navigation
            Divider().ignoresSafeArea(.container, edges: .top)
            Group {
                switch appState.mainTab {
                case .application(let application): ApplicationDetailView(application: application).id(application)
                case .applications: ApplicationsManagementView()
                case .quotaManagement: QuotaManagementView()
                case .stats: StatsView()
                case .settings: SettingsRootView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 1040, minHeight: 520)
        // 显式隐藏窗口工具栏背景，让全局侧栏材质铺进标题栏。
        // 不写时由 SwiftUI 按内容推断，首次打开窗口推断不生效，标题栏会画成整条不透明白底。
        .toolbarBackground(.hidden, for: .windowToolbar)
        .background(InitialFirstResponderClearer())
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        .onDisappear {
            NSApp.setActivationPolicy(.accessory)
        }
    }
    private var navigation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CCBar").font(.system(size: 19, weight: .semibold)).padding(.horizontal, 12).padding(.bottom, 16)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(appState.applications.sidebarApplications) { app in
                        navigationItem(.application(app), title: app.name) {
                            ApplicationIcon(application: app)
                        }
                    }
                    if appState.applications.sidebarApplications.isEmpty {
                        Text(tr("Add applications below", "在下方「应用」中添加")).font(.caption).foregroundStyle(.secondary).padding(12)
                    }
                }
            }
            Divider().padding(.vertical, 8)
            navigationItem(.quotaManagement, title: tr("Quota Management", "额度管理")) {
                Image(systemName: "person.crop.rectangle").frame(width: 20)
            }
            navigationItem(.stats, title: tr("Usage Statistics", "用量统计")) {
                Image(systemName: "chart.bar").frame(width: 20)
            }
            Divider().padding(.vertical, 8)
            HStack(spacing: 2) {
                navigationItem(.applications, title: tr("Apps", "应用")) {
                    Image(systemName: "square.grid.2x2").frame(width: 18)
                }
                navigationItem(.settings, title: tr("Settings", "设置")) {
                    Image(systemName: "gearshape").frame(width: 18)
                }
            }
        }
        .padding(12).padding(.top, 12).padding(.bottom, 10)
        .frame(width: MainWindowLayout.sidebarWidth, alignment: .leading)
        .background(.regularMaterial)
        .onAppear { appState.reloadApplications() }
        .onChange(of: appState.applications.sidebarApplications) { _, applications in
            if case .application(let selected) = appState.mainTab, !applications.contains(selected) {
                appState.mainTab = .applications
            }
        }
    }

    private func navigationItem<Icon: View>(_ tab: MainTab, title: String,
                                            @ViewBuilder icon: () -> Icon) -> some View {
        Button { appState.mainTab = tab } label: {
            HStack(spacing: 8) {
                icon()
                Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 9)
            .background(appState.mainTab == tab ? Color.accentColor.opacity(0.15) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(appState.mainTab == tab ? .isSelected : [])
    }

}

/// 主窗口打开时，系统会把第一个可聚焦控件设为第一响应者，
/// 开启「键盘导航」时 控件外会多一圈蓝色焦点环。窗口首次成为 key 后清掉这个初始焦点；
/// 之后按 Tab 键导航、点击输入框时焦点环照常出现。
private struct InitialFirstResponderClearer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ClearerView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ClearerView: NSView {
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeObserver()
            guard let window else { return }
            if window.isKeyWindow {
                clear(window)
            } else {
                observer = NotificationCenter.default.addObserver(
                    forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
                ) { [weak self, weak window] _ in
                    MainActor.assumeIsolated {
                        self?.removeObserver()
                        if let window { self?.clear(window) }
                    }
                }
            }
        }

        /// 推迟一拍，等 AppKit / SwiftUI 设完初始焦点再清。
        private func clear(_ window: NSWindow) {
            DispatchQueue.main.async { [weak window] in
                window?.makeFirstResponder(nil)
            }
        }

        private func removeObserver() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }
    }
}
