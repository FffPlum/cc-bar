import SwiftUI
import AppKit

// MARK: - OnboardingView
//
// 见 docs/界面布局.md §5。
// 4 步:Welcome / Detect accounts / Configure / Ready。
// 首次启动时显示;完成后写入 SettingsStore.didCompleteOnboarding = true。

struct OnboardingView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    @State private var step: Int = 0
    @State private var installedClients: Set<QuotaApp>?

    var body: some View {
        ZStack {
            stepContent
                .transition(.opacity.combined(with: .move(edge: .trailing)))

            VStack {
                Spacer()
                progressDots.padding(.bottom, 16)
            }
        }
        .frame(width: 620, height: 520)
        .background(.regularMaterial)
        .animation(.easeInOut(duration: 0.25), value: step)
        .task {
            installedClients = await Task.detached(priority: .utility) {
                OnboardingClientDetection.installedClients()
            }.value
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case 0: WelcomeStep(onContinue: next)
        case 1: DetectAccountsStep(installedClients: installedClients, onBack: prev, onContinue: next)
        case 2: ConfigureStep(installedClients: installedClients, onBack: prev, onContinue: next)
        default: ReadyStep(onClose: finish, onOpenStats: openStats)
        }
    }

    private var progressDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<4, id: \.self) { i in
                Capsule()
                    .fill(i == step ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: i == step ? 12 : 6, height: 6)
                    .animation(.easeInOut(duration: 0.2), value: step)
            }
        }
    }

    private func next() { step = min(step + 1, 3) }
    private func prev() { step = max(step - 1, 0) }

    private func finish() {
        SettingsStore.shared.didCompleteOnboarding = true
        dismissWindow(id: "onboarding")
    }

    private func openStats() {
        SettingsStore.shared.didCompleteOnboarding = true
        appState.mainTab = .stats
        openWindow(id: "main")
        dismissWindow(id: "onboarding")
    }
}

// MARK: - Step 1: Welcome

private struct WelcomeStep: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            AppIconBlock()
                .padding(.bottom, 24)

            Text(tr("Welcome to CCBar", "欢迎使用 CCBar"))
                .font(.system(size: 22, weight: .bold))
                .kerning(-0.4)

            Text(tr(
                "Check your AI subscription quota and local usage from the menu bar.",
                "在菜单栏查看 AI 订阅额度和本机用量。"
            ))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .frame(maxWidth: 380)
                .padding(.top, 14)

            VStack(spacing: 8) {
                PrimaryButton(label: tr("Get started", "开始"), action: onContinue)
            }
            .padding(.top, 24)

            Spacer()
        }
        .padding(.horizontal, 32)
    }
}

/// 图标按 macOS 模板导出（1024 画布里圆角矩形主体 824，四周透明留边），
/// 框取 120 时可见主体约 96pt，与改模板前满铺图标的视觉大小一致。
private struct AppIconBlock: View {
    var body: some View {
        Group {
            if let icon = NSApplication.shared.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                // 回退方块没有透明留边，内缩到与真实图标主体同大。
                fallback
                    .padding(12)
            }
        }
        .frame(width: 120, height: 120)
        .shadow(color: .black.opacity(0.3), radius: 30, x: 0, y: 10)
    }

    private var fallback: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(LinearGradient(
                colors: [
                    Color(red: 0.29, green: 0.29, blue: 0.31),
                    Color.codexAccent,
                    Color.claudeAccent
                ],
                startPoint: UnitPoint(x: 0, y: 0),
                endPoint: UnitPoint(x: 1, y: 1)
            ))
            .overlay(
                Image(systemName: "gauge.medium")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
            )
    }
}

// MARK: - Step 2: Detect accounts

private struct DetectAccountsStep: View {
    @Environment(AppState.self) private var appState
    @State private var hasMoreAccountsBelow = false
    let installedClients: Set<QuotaApp>?
    let onBack: () -> Void
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(tr("Services and accounts", "服务与账号"))
                .font(.system(size: 18, weight: .bold))
                .kerning(-0.3)

            // 账号列表可滚动，固定高度窗口中仍保留凭据说明和底部操作。
            VStack(spacing: 6) {
                accountList

                ScrollDownHint(isVisible: hasMoreAccountsBelow)
            }
            .padding(.top, 18)

            CredentialInfoCard()
                .padding(.top, 18)

            HStack(spacing: 8) {
                SecondaryButton(label: tr("Back", "上一步"), action: onBack)
                Spacer()
                PrimaryButton(label: tr("Continue", "继续"), action: onContinue)
            }
            .padding(.top, 18)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 28)
    }

    @ViewBuilder
    private var accountList: some View {
        if #available(macOS 15.0, *) {
            ScrollView {
                accountListContent
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height > geometry.visibleRect.maxY + 1
            } action: { _, hasMore in
                hasMoreAccountsBelow = hasMore
            }
        } else {
            GeometryReader { viewport in
                let viewportHeight = viewport.size.height
                ScrollView {
                    accountListContent
                        .onGeometryChange(for: Bool.self) { content in
                            content.frame(in: .named("onboardingAccounts")).maxY > viewportHeight + 1
                        } action: { hasMore in
                            hasMoreAccountsBelow = hasMore
                        }
                }
                .coordinateSpace(name: "onboardingAccounts")
            }
        }
    }

    private var accountListContent: some View {
        VStack(spacing: 8) {
            ForEach(orderedAccountRows, id: \.app) { row in
                row
            }
        }
    }

    private var accountRows: [DetectedAccountRow] {
        [
            DetectedAccountRow(
                app: .codex,
                title: "Codex",
                subtitle: "OpenAI",
                plan: appState.codexPlanName,
                email: appState.codexAccount?.email,
                source: codexSource,
                tint: .codexAccent,
                logoName: "codex",
                fallback: "C",
                status: status(for: .codex, signedIn: appState.codexAccount != nil)
            ),
            DetectedAccountRow(
                app: .claude,
                title: "Claude Code",
                subtitle: "Anthropic",
                plan: appState.claudePlanName,
                email: appState.claudeDisplayEmail,
                source: claudeSource,
                tint: .claudeAccent,
                logoName: "claude",
                fallback: "K",
                status: status(for: .claude, signedIn: appState.claudeAccount != nil,
                               needsAuthorization: appState.claudeDesktopAccessDenied)
            ),
            DetectedAccountRow(
                app: .antigravity,
                title: "Antigravity",
                subtitle: "Google",
                plan: appState.antigravityQuota?.planType ?? appState.antigravityAccount?.planType,
                email: appState.antigravityAccount?.email,
                source: "~/.gemini/jetski-standalone-oauth-token",
                tint: .antigravityAccent,
                logoName: "antigravity",
                fallback: "A",
                status: status(for: .antigravity, signedIn: appState.antigravityAccount != nil)
            ),
            DetectedAccountRow(
                app: .cursor,
                title: "Cursor",
                subtitle: "Cursor",
                plan: appState.cursorQuota?.planType,
                email: appState.cursorAccount?.email,
                source: "~/Library/Application Support/Cursor/User/globalStorage/state.vscdb",
                tint: .cursorAccent,
                logoName: "cursor",
                fallback: "C",
                status: status(for: .cursor, signedIn: appState.cursorAccount != nil,
                               needsAuthorization: appState.cursorKeychainAccessRequired)
            ),
            DetectedAccountRow(
                app: .commandCode,
                title: "Command Code",
                subtitle: "Command Code",
                plan: appState.commandCodeQuota?.planType ?? appState.commandCodeAccount?.planType,
                email: appState.commandCodeAccount?.login ?? appState.commandCodeAccount?.email,
                source: commandCodeSource,
                tint: QuotaApp.commandCode.tintColor,
                logoName: "commandcode",
                fallback: "⌘",
                status: status(for: .commandCode, signedIn: appState.commandCodeAccount != nil)
            ),
            DetectedAccountRow(
                app: .kimi,
                title: "Kimi Code",
                subtitle: "Moonshot AI",
                plan: kimiPlan,
                email: kimiIdentity,
                source: kimiSource,
                tint: QuotaApp.kimi.tintColor,
                logoName: "kimi",
                fallback: "K",
                status: status(for: .kimi, signedIn: appState.hasKimiSubscriptionAccount)
            )
        ]
    }

    private var orderedAccountRows: [DetectedAccountRow] {
        let rows = accountRows
        return AccountDetectionStatus.allCases.flatMap { status in rows.filter { $0.status == status } }
    }

    private func status(for app: QuotaApp, signedIn: Bool, needsAuthorization: Bool = false) -> AccountDetectionStatus {
        if signedIn { return .signedIn }
        if needsAuthorization { return .needsAuthorization }
        guard let installedClients else { return .checking }
        return installedClients.contains(app) ? .installed : .notFound
    }

    private var codexSource: String {
        "~/.codex/auth.json"
    }

    private var claudeSource: String {
        switch appState.claudeAccount?.source {
        case .file: return "~/.claude/.credentials.json"
        case .keychain: return "Keychain · claude-code"
        case .desktop: return "Claude Desktop"
        case .none: return "—"
        }
    }

    private var commandCodeSource: String {
        switch appState.commandCodeAccount?.source {
        case .commandCodeCLI: return "~/.commandcode/auth.json"
        case .pi: return "~/.pi/agent/auth.json"
        case .opencode: return "~/.local/share/opencode/auth.json"
        case .environment: return "ENV · COMMAND_CODE_API_KEY"
        case .manualKeychain: return "Keychain · command-code"
        case .none: return "—"
        }
    }

    private var kimiPlan: String? {
        if appState.kimiAccount != nil {
            return appState.kimiPlanName ?? appState.kimiQuota?.planType
        }
        return appState.kimiManagedAccounts.first?.userLevelName
    }

    private var kimiIdentity: String? {
        if appState.kimiAccount != nil {
            return appState.kimiNickname ?? appState.kimiEmail
        }
        let account = appState.kimiManagedAccounts.first
        return account?.nickname ?? account?.email
    }

    private var kimiSource: String {
        if let account = appState.kimiAccount {
            if let url = account.credentialURL {
                return (url.path as NSString).abbreviatingWithTildeInPath
            }
            return account.source.displayName
        }
        return appState.hasKimiSubscriptionAccount ? "CCBar" : "—"
    }

}

/// Local executable or app presence is separate from account credential detection.
enum OnboardingClientDetection {
    nonisolated static func installedClients(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        standardDirectories: [URL]? = nil,
        applicationDirectories: [URL]? = nil
    ) -> Set<QuotaApp> {
        let fm = FileManager.default
        let path = environment["PATH"] ?? ""
        let nvmPath = environment["NVM_DIR"].flatMap { $0.hasPrefix("/") ? $0 : nil }
            ?? home.appendingPathComponent(".nvm").path
        let nodeVersions = URL(fileURLWithPath: nvmPath).appendingPathComponent("versions/node")
        let nodeDirectories = (try? fm.contentsOfDirectory(at: nodeVersions, includingPropertiesForKeys: nil,
                                                           options: [.skipsHiddenFiles])) ?? []
        var directories = path.split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
        let standard = standardDirectories ?? [home.appendingPathComponent(".local/bin"),
                                                URL(fileURLWithPath: "/opt/homebrew/bin"),
                                                URL(fileURLWithPath: "/usr/local/bin"),
                                                URL(fileURLWithPath: "/usr/bin")]
        directories.append(contentsOf: standard.map(\.path))
        directories.append(contentsOf: nodeDirectories.map { $0.appendingPathComponent("bin").path })
        func hasCommand(_ name: String) -> Bool {
            directories.contains { fm.isExecutableFile(atPath: URL(fileURLWithPath: $0).appendingPathComponent(name).path) }
        }
        func hasApp(_ name: String) -> Bool {
            (applicationDirectories ?? [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")])
                .contains { fm.fileExists(atPath: $0.appendingPathComponent(name).path) }
        }
        var found: Set<QuotaApp> = []
        if hasCommand("codex") || hasApp("Codex.app") { found.insert(.codex) }
        if hasCommand("claude") { found.insert(.claude) }
        if hasCommand("agy") || fm.isExecutableFile(atPath: home.appendingPathComponent(".gemini/bin/agy").path)
            || hasApp("Antigravity.app") { found.insert(.antigravity) }
        if hasApp("Cursor.app") || hasCommand("cursor") { found.insert(.cursor) }
        if hasCommand("commandcode") { found.insert(.commandCode) }
        if hasCommand("kimi") || hasCommand("kimi-code") { found.insert(.kimi) }
        return found
    }
}

private enum AccountDetectionStatus: CaseIterable {
    case signedIn, needsAuthorization, installed, checking, notFound
}

private struct ScrollDownHint: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lowered = false
    let isVisible: Bool

    var body: some View {
        hintContent
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .offset(y: lowered ? 4 : 0)
            .frame(maxWidth: .infinity)
            .frame(height: 20)
            .opacity(isVisible ? 1 : 0)
            .animation(.easeOut(duration: 0.2), value: isVisible)
            .accessibilityElement(children: .combine)
            .accessibilityHidden(!isVisible)
            .task(id: isVisible && !reduceMotion) {
                guard isVisible && !reduceMotion else {
                    if reduceMotion {
                        lowered = false
                    } else {
                        withAnimation(.smooth(duration: 0.2, extraBounce: 0)) { lowered = false }
                    }
                    return
                }
                for _ in 0..<3 {
                    do { try await Task.sleep(for: .milliseconds(600)) }
                    catch { return }
                    guard !Task.isCancelled else { return }
                    withAnimation(.smooth(duration: 0.35, extraBounce: 0)) { lowered = true }
                    do { try await Task.sleep(for: .milliseconds(500)) }
                    catch { return }
                    guard !Task.isCancelled else { return }
                    withAnimation(.smooth(duration: 0.3, extraBounce: 0)) { lowered = false }
                    do { try await Task.sleep(for: .milliseconds(300)) }
                    catch { return }
                }
            }
    }

    private var hintContent: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.down")
                .accessibilityHidden(true)
            Text(tr("Scroll down to see more", "向下滚动查看更多"))
        }
    }
}

private struct DetectedAccountRow: View {
    @Environment(AppState.self) private var appState
    let app: QuotaApp
    let title: String
    let subtitle: String
    let plan: String?
    let email: String?
    let source: String
    let tint: Color
    let logoName: String
    let fallback: String
    let status: AccountDetectionStatus

    var body: some View {
        HStack(spacing: 12) {
            CheckmarkBox(checked: status == .signedIn, unavailable: (status == .installed || status == .notFound) && !isLoading)
            ServiceTile(logoName: logoName, fallback: fallback, tint: tint, size: 28, logoSize: 15, cornerRadius: 7)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    Text("· \(subtitleText)")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                // 邮箱优先完整显示；凭据来源（Cursor 的路径很长）只占一行，放不下从中间截断。
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.75)
                            .frame(width: 14, height: 14)
                            .accessibilityHidden(true)
                            .padding(.trailing, 4)
                        Text(tr("Loading account information…", "账户信息加载中…"))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text(status == .signedIn
                             ? (email.map { PrivacyDisplay.isEnabled ? PrivacyDisplay.account("primary:\(app.rawValue)") : $0 } ?? statusText)
                             : statusText)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .layoutPriority(1)
                        if status == .signedIn && source != "—" {
                            PrivacySensitiveText(text: " · \(source)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .ccPanel(cornerRadius: 12)
        .opacity(status == .notFound && !isLoading ? 0.6 : 1)
    }

    private var isLoading: Bool {
        appState.startupAccountLoading.contains(app)
            || appState.accountProfileLoading.contains(app)
            || status == .checking
    }

    private var statusText: String {
        switch status {
        case .signedIn: tr("Detected", "已检测到")
        case .needsAuthorization: tr("Authorization required", "需要授权")
        case .installed: tr("Installed · No sign-in detected", "已安装 · 未检测到登录")
        case .checking: tr("Checking…", "正在检测…")
        case .notFound: tr("Client not found", "未发现客户端")
        }
    }

    private var subtitleText: String {
        if status == .signedIn, let plan, !plan.isEmpty { return "\(subtitle) · \(plan)" }
        return subtitle
    }
}

private struct CheckmarkBox: View {
    let checked: Bool
    let unavailable: Bool

    var body: some View {
        Image(systemName: checked ? "checkmark.circle.fill" : (unavailable ? "minus.circle.fill" : "circle"))
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(checked ? Color.accentColor : Color.secondary.opacity(0.35))
    }
}

private struct CredentialInfoCard: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle")
                .font(.system(size: 14))
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(tr("Your credentials", "关于凭据"))
                    .font(.system(size: 11.5, weight: .medium))
                Text(tr(
                    "CCBar connects directly to each service's official API to check quota, with no third-party servers in between. For some services, expired logins are renewed automatically and the local credential file is updated.",
                    "CCBar 直接连接各服务的官方接口查询额度，不经过任何第三方服务器。部分服务登录过期时会自动续期，并更新本机的凭据文件。"
                ))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 0.5)
        )
    }
}

// MARK: - Step 3: Configure menu bar + HUD

private struct ConfigureStep: View {
    @Environment(AppState.self) private var appState
    let installedClients: Set<QuotaApp>?
    let onBack: () -> Void
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(tr("Choose your view", "选择你想看到的方式"))
                .font(.system(size: 18, weight: .bold))
                .kerning(-0.3)

            VStack(spacing: 14) {
                ConfigureRow(title: "Show in menu bar",
                             chineseTitle: "菜单栏",
                             subtitle: "Show enabled providers next to the menu bar icon.",
                             chineseSubtitle: "在菜单栏图标旁显示百分比") {
                    menuBarOptions
                }

                ConfigureRow(title: "Floating HUD",
                             chineseTitle: "桌面悬浮窗",
                             subtitle: "Pin a small percentage HUD to your desktop.",
                             chineseSubtitle: "在桌面置顶显示剩余百分比") {
                    Toggle(tr("On", "开启"), isOn: Binding(
                        get: { SettingsStore.shared.floatingEnabled },
                        set: { v in
                            SettingsStore.shared.floatingEnabled = v
                            FloatingPanelController.shared.sync()
                        }
                    ))
                    .toggleStyle(.switch)
                    .tint(.green)
                }
            }
            .padding(.top, 18)

            Spacer()

            HStack(spacing: 8) {
                SecondaryButton(label: tr("Back", "上一步"), action: onBack)
                Spacer()
                PrimaryButton(label: tr("Continue", "继续"), action: onContinue)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 28)
    }

    private var signedInProviders: [QuotaProviderDescriptor] {
        guard let installedClients else { return [] }
        return SettingsStore.shared.orderedMenuBarProviders.filter { provider in
            installedClients.contains(provider.app) && hasAccount(for: provider.app)
        }
    }

    private func hasAccount(for app: QuotaApp) -> Bool {
        switch app {
        case .codex: appState.codexAccount != nil
        case .claude: appState.claudeAccount != nil
        case .antigravity: appState.antigravityAccount != nil
        case .cursor: appState.cursorAccount != nil
        case .commandCode: appState.commandCodeAccount != nil
        case .kimi: appState.hasKimiSubscriptionAccount
        case .opencodeGo: false // 引导页不检测该客户端。
        }
    }

    @ViewBuilder
    private var menuBarOptions: some View {
        if signedInProviders.isEmpty {
            if installedClients == nil || !appState.startupAccountLoading.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small).accessibilityHidden(true)
                    Text(tr("Checking services…", "正在检测服务…"))
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                Text(tr("No signed-in apps found", "未发现已登录的应用"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        } else {
            let columns = signedInProviders.count == 1
                ? [GridItem(.fixed(152))]
                : [GridItem(.fixed(152), spacing: 12), GridItem(.fixed(152))]
            LazyVGrid(columns: columns,
                      alignment: .trailing, spacing: 8) {
                ForEach(signedInProviders, id: \.app) { provider in
                    HStack(spacing: 8) {
                        Text(provider.title)
                            .font(.system(size: 13))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(width: 90, alignment: .trailing)
                        Toggle(provider.title, isOn: menuBarBinding(for: provider.app))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .tint(.green)
                            .fixedSize()
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
    }

    private func menuBarBinding(for app: QuotaApp) -> Binding<Bool> {
        Binding {
            let settings = SettingsStore.shared
            guard settings.isProviderEnabled(app) else { return false }
            if app == .kimi {
                let cliVisible = appState.kimiAccount != nil && settings.isProviderShownInMenuBar(.kimi)
                return cliVisible || appState.kimiManagedAccounts.contains(where: \.showInMenuBar)
            }
            return settings.isProviderShownInMenuBar(app)
        } set: { shown in
            let settings = SettingsStore.shared
            settings.setProviderShownInMenuBar(shown, for: app)
            if app == .kimi {
                for account in appState.kimiManagedAccounts where account.showInMenuBar != shown {
                    appState.updateKimiManagedAccount(id: account.id) { $0.showInMenuBar = shown }
                }
            }
            let needsRefresh = shown && (!settings.isProviderEnabled(app) || app == .kimi)
            if shown && !settings.isProviderEnabled(app) {
                settings.setServiceEnabled(true, for: app)
            }
            if needsRefresh {
                Task { await appState.refreshQuotas(reason: .userInitiated) }
            }
        }
    }
}

private struct ConfigureRow<Trailing: View>: View {
    let title: String
    let chineseTitle: String
    let subtitle: String
    let chineseSubtitle: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tr(title, chineseTitle))
                    .font(.system(size: 13, weight: .semibold))
                Text(tr(subtitle, chineseSubtitle))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            trailing()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .ccPanel(cornerRadius: 12)
    }
}

// MARK: - Step 4: Ready

private struct ReadyStep: View {
    let onClose: () -> Void
    let onOpenStats: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            ZStack {
                AppIconBlock()
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 32, height: 32)
                    .overlay(
                        Image(systemName: "checkmark")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                    )
                    .offset(x: 36, y: 36)
            }
            .padding(.bottom, 24)

            Text(tr("You're all set", "一切就绪"))
                .font(.system(size: 22, weight: .bold))
                .kerning(-0.4)

            Text(tr(
                "Click the menu bar icon any time to check your quota.",
                "随时点击菜单栏图标查看额度。"
            ))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .padding(.top, 14)

            HStack(spacing: 8) {
                SecondaryButton(label: tr("Close", "关闭"), action: onClose)
                PrimaryButton(label: tr("Open Statistics", "打开统计"), action: onOpenStats)
            }
            .padding(.top, 24)

            Spacer()
        }
        .padding(.horizontal, 32)
    }
}

// MARK: - Buttons

private struct PrimaryButton: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .frame(height: 26)
                .background(
                    Capsule().fill(Color.accentColor)
                )
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }
}

private struct SecondaryButton: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12.5, weight: .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(height: 26)
                .background(
                    Capsule().fill(Color.secondary.opacity(0.15))
                )
                .overlay(
                    Capsule().strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }
}
