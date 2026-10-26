import AppKit
import SwiftUI

struct KimiManagedAccountsSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var loginAccountID: String?
    @State private var deleteTarget: KimiManagedAccount?

    var body: some View {
        VStack(spacing: 0) {
            if let error = appState.kimiManagedOperationError {
                Text(error).font(.system(size: 11)).foregroundStyle(.orange).padding(8)
            }
            ForEach(appState.kimiManagedAccounts) { account in
                divider
                HStack(spacing: 0) {
                    Color.clear.frame(width: ServiceRowMetrics.textLeading - 30)
                    ServiceTile(logoName: "kimi", fallback: "K", tint: .purple, size: 20, logoSize: 13, cornerRadius: 5.5)
                        .padding(.trailing, 10)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(appState.kimiManagedSubtitle(account)).font(.system(size: 12.5)).lineLimit(1)
                        Text(account.region.displayName)
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        if appState.kimiManagedErrors[account.id] != nil {
                            Text(tr("Refresh failed", "刷新失败")).font(.system(size: 11)).foregroundStyle(.orange)
                        } else if appState.kimiManagedQuotas[account.id]?.isEmptyKimiQuota == true {
                            Text(tr("No quota data available", "暂无额度数据")).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    DisplayDestinationCheckbox(title: tr("Show in menu bar", "在菜单栏显示"), isOn: Binding(
                        get: { account.showInMenuBar },
                        set: { value in appState.updateKimiManagedAccount(id: account.id) { $0.showInMenuBar = value } }
                    ))
                    .frame(width: ServiceRowMetrics.destination)
                    DisplayDestinationCheckbox(title: tr("Show in floating window", "在悬浮窗显示"), isOn: Binding(
                        get: { account.showInFloatingHUD },
                        set: { value in appState.updateKimiManagedAccount(id: account.id) { $0.showInFloatingHUD = value } }
                    ))
                    .frame(width: ServiceRowMetrics.destination)
                    Menu {
                        Button(tr("Sign in again…", "重新登录…")) { loginAccountID = account.id }
                        Button(tr("Remove…", "删除…"), role: .destructive) { deleteTarget = account }
                    } label: {
                        Image(systemName: "ellipsis.circle").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    .menuStyle(.button).buttonStyle(.borderless).menuIndicator(.hidden)
                    .frame(width: ServiceRowMetrics.info)
                    Toggle(account.id, isOn: Binding(
                        get: { account.visibleInPopover },
                        set: { value in appState.updateKimiManagedAccount(id: account.id) { $0.visibleInPopover = value } }
                    ))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(.green)
                    .help(tr("Show in popover", "在弹出面板中显示"))
                    .frame(width: ServiceRowMetrics.toggle)
                }
                .padding(.leading, 16)
                .padding(.trailing, ServiceRowMetrics.trailingPadding)
                .padding(.vertical, 8)
            }
            divider
            Button { loginAccountID = "" } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                    Text(tr("Add Kimi Account…", "添加 Kimi 账号…"))
                    Spacer()
                }
                .font(.system(size: 12.5))
                .foregroundStyle(Color.accentColor)
                .padding(.vertical, 9)
                .padding(.leading, ServiceRowMetrics.textLeading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointingHandCursor()
            .help(tr("Use official device authorization. Your Kimi Code CLI sign-in is not changed.",
                     "使用官方设备授权登录，不会更改 Kimi Code CLI 的登录账号"))
        }
        .background(Color.primary.opacity(0.02))
        .sheet(isPresented: Binding(get: { loginAccountID != nil }, set: { if !$0 { loginAccountID = nil } })) {
            KimiDeviceLoginView(account: appState.kimiManagedAccounts.first { $0.id == loginAccountID })
        }
        .confirmationDialog(tr("Remove account?", "删除此账号？"), isPresented: Binding(
            get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }
        ), titleVisibility: .visible) {
            Button(tr("Remove", "删除"), role: .destructive) {
                if let target = deleteTarget { appState.removeKimiManagedAccount(id: target.id) }
                deleteTarget = nil
            }
            Button(tr("Cancel", "取消"), role: .cancel) { deleteTarget = nil }
        }
    }

    private var divider: some View {
        Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 0.5)
            .padding(.leading, ServiceRowMetrics.textLeading)
    }
}

private struct KimiDeviceLoginView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let account: KimiManagedAccount?
    @State private var region: KimiRegion
    @State private var didStart = false

    init(account: KimiManagedAccount?) {
        self.account = account
        _region = State(initialValue: account?.region ?? .china)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(tr("Sign in to Kimi Code", "登录 Kimi Code"))
                .font(.system(size: 16, weight: .semibold))
            Picker(tr("Region", "地区"), selection: $region) {
                ForEach(KimiRegion.allCases) { region in
                    Text(region.displayName).tag(region)
                }
            }
            .pickerStyle(.segmented)
            .disabled(appState.kimiDeviceLoginInProgress || account != nil)

            if appState.kimiDeviceLoginInProgress {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(appState.kimiDeviceAuthorization == nil
                         ? tr("Requesting official authorization…", "正在申请官方授权…")
                         : tr("Complete authorization in your browser. Sign-in continues automatically.", "请在浏览器中完成授权，登录会自动继续。"))
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if !didStart {
                Text(tr("After you start, CCBar will open the official Kimi authorization page in your browser.",
                        "点击开始登录后，CCBar 会自动在浏览器中打开 Kimi 官方授权页。"))
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = appState.kimiDeviceLoginError {
                Text(error).font(.system(size: 11.5)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if didStart && !appState.kimiDeviceLoginInProgress && appState.kimiDeviceLoginError == nil && appState.kimiDeviceAuthorization != nil {
                Label(tr("Signed in", "已登录"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }

            Divider()
            HStack {
                Spacer()
                Button(appState.kimiDeviceLoginInProgress ? tr("Cancel authorization", "取消授权") : tr("Cancel", "取消")) {
                    if appState.kimiDeviceLoginInProgress {
                        appState.cancelKimiDeviceLogin(showCancellation: true)
                    } else {
                        appState.cancelKimiDeviceLogin()
                        dismiss()
                    }
                }
                .keyboardShortcut(.escape, modifiers: [])
                if !appState.kimiDeviceLoginInProgress {
                    Button(appState.kimiDeviceLoginError != nil ? tr("Try again", "重试") : (didStart ? tr("Done", "完成") : tr("Start official sign-in", "开始官方登录"))) {
                        if didStart && appState.kimiDeviceLoginError == nil {
                            dismiss()
                        } else {
                            didStart = true
                            appState.startKimiDeviceLogin(region: region, replacing: account?.id)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(didStart && appState.kimiDeviceLoginError == nil && appState.kimiDeviceAuthorization == nil)
                }
            }
        }
        .padding(20)
        .frame(width: 440).fixedSize(horizontal: false, vertical: true)
        .onDisappear { appState.cancelKimiDeviceLogin() }
    }
}
