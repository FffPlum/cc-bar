import SwiftUI

struct MoonshotAccountsSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var editingID: String?
    @State private var showEditor = false
    @State private var deleteTarget: MoonshotAccount?

    var body: some View {
        VStack(spacing: 0) {
            if let error = appState.moonshotOperationError {
                Text(error).font(.system(size: 11)).foregroundStyle(.orange).padding(8)
            }
            divider
            Text(tr("Moonshot API · Pay as you go", "Moonshot API · 按量计费"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, ServiceRowMetrics.textLeading)
                .padding(.vertical, 8)
            ForEach(appState.moonshotAccounts) { account in
                divider
                HStack(spacing: 0) {
                    Color.clear.frame(width: ServiceRowMetrics.textLeading - 30)
                    Image(systemName: "key.fill").font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(width: 20).padding(.trailing, 10)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(appState.moonshotDisplayName(account)).font(.system(size: 12.5)).lineLimit(1)
                        Text("\(account.region.displayName) · \(account.currencyCode)")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        if appState.moonshotErrors[account.id] != nil {
                            Text(tr("Refresh failed", "刷新失败")).font(.system(size: 11)).foregroundStyle(.orange)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    DisplayDestinationCheckbox(title: "Menu Bar", isOn: Binding(
                        get: { account.showInMenuBar },
                        set: { value in appState.updateMoonshotAccount(id: account.id) { $0.showInMenuBar = value } }
                    ))
                    .frame(width: ServiceRowMetrics.destination)
                    DisplayDestinationCheckbox(title: "Floating HUD", isOn: Binding(
                        get: { account.showInFloatingHUD },
                        set: { value in appState.updateMoonshotAccount(id: account.id) { $0.showInFloatingHUD = value } }
                    ))
                    .frame(width: ServiceRowMetrics.destination)
                    Menu {
                        if appState.moonshotAPIKeyStore.isAccessBlocked(accountID: account.id) {
                            Button(tr("Retry Keychain Access…", "重试钥匙串访问…")) {
                                Task { await appState.retryMoonshotKeychainAccess(id: account.id) }
                            }
                        }
                        Button(tr("Edit…", "编辑…")) {
                            editingID = account.id
                            showEditor = true
                        }
                        Button(tr("Remove…", "删除…"), role: .destructive) { deleteTarget = account }
                    } label: {
                        Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
                    }
                    .menuStyle(.button).buttonStyle(.borderless).menuIndicator(.hidden)
                    .frame(width: ServiceRowMetrics.info)
                    Toggle(account.id, isOn: Binding(
                        get: { account.visibleInPopover },
                        set: { value in appState.updateMoonshotAccount(id: account.id) { $0.visibleInPopover = value } }
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
            Button {
                editingID = nil
                showEditor = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                    Text(tr("Add Moonshot API Key…", "添加 Moonshot API Key…"))
                    Spacer()
                }
                .font(.system(size: 12.5)).foregroundStyle(Color.accentColor)
                .padding(.vertical, 9).padding(.leading, ServiceRowMetrics.textLeading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointingHandCursor()
        }
        .background(Color.primary.opacity(0.02))
        .sheet(isPresented: $showEditor) {
            MoonshotAccountEditor(account: appState.moonshotAccounts.first { $0.id == editingID })
        }
        .confirmationDialog(tr("Remove account?", "删除此账号？"), isPresented: Binding(
            get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }
        ), titleVisibility: .visible) {
            Button(tr("Remove", "删除"), role: .destructive) {
                if let target = deleteTarget { appState.removeMoonshotAccount(id: target.id) }
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

private struct MoonshotAccountEditor: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let account: MoonshotAccount?
    @State private var name: String
    @State private var region: KimiRegion
    @State private var apiKey = ""
    @State private var error: String?
    @State private var saving = false

    init(account: MoonshotAccount?) {
        self.account = account
        _name = State(initialValue: account?.name ?? "")
        _region = State(initialValue: account?.region ?? .china)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(account == nil
                 ? tr("Add Moonshot API account", "添加 Moonshot API 账户")
                 : tr("Edit Moonshot API account", "编辑 Moonshot API 账户"))
                .font(.system(size: 16, weight: .semibold))
            Text(tr("Tracks pay-as-you-go balance only. This is not a Kimi Code subscription sign-in.",
                    "仅追踪按量 API 余额，不是 Kimi Code 订阅登录入口。"))
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
            TextField(tr("Account name", "账户名称"), text: $name)
            Picker(tr("Region", "地区"), selection: $region) {
                ForEach(KimiRegion.allCases) { region in Text(region.displayName).tag(region) }
            }
            .pickerStyle(.segmented)
            SecureField(account == nil ? "API Key" : tr("New API Key (leave blank to keep current)", "新 API Key（留空则保留当前 Key）"), text: $apiKey)
            Text(tr("The key is stored in CCBar's Keychain and sent only to the selected region's official Moonshot balance endpoint.",
                    "Key 保存在 CCBar 钥匙串中，只发送到所选地区的 Moonshot 官方余额接口。"))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error {
                Text(error).font(.system(size: 11.5)).foregroundStyle(.red)
            }
            Spacer()
            HStack {
                Spacer()
                Button(tr("Cancel", "取消")) { dismiss() }
                Button(tr("Save", "保存")) { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460, height: 360)
    }

    private func save() {
        saving = true
        error = nil
        Task {
            do {
                try await appState.saveMoonshotAccount(id: account?.id, name: name, region: region, apiKey: apiKey)
                dismiss()
            } catch let editError as MoonshotAccountEditError {
                error = editError.userMessage
            } catch {
                self.error = QuotaError.from(transport: error).userMessage
            }
            saving = false
        }
    }
}
