import SwiftUI

struct DeepSeekAccountsSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var editor: EditorRequest<DeepSeekAccount>?
    @State private var deleteTarget: DeepSeekAccount?

    var body: some View {
        VStack(spacing: 0) {
            if let error = appState.deepSeekOperationError {
                Text(error).font(.system(size: 11)).foregroundStyle(.orange).padding(8)
            }
            ForEach(appState.deepSeekQuotaAccounts) { account in
                HStack(spacing: 0) {
                    Color.clear.frame(width: ServiceRowMetrics.handleWidth + ServiceRowMetrics.handleGap)
                    ServiceTile(logoName: "deepseek", fallback: "D", tint: .blue)
                        .frame(width: ServiceRowMetrics.tileSize, height: ServiceRowMetrics.tileSize)
                        .padding(.trailing, ServiceRowMetrics.tileGap)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(appState.deepSeekDisplayName(account)).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Text(account.kind.displayName + (account.sourceApplication.map { tr(" · Detected in ", " · 自动识别于 ") + $0 } ?? ""))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        Text(appState.deepSeekBalanceText(for: account)).font(.system(size: 12)).monospacedDigit()
                        if appState.deepSeekErrors[account.id] != nil {
                            Text(tr("Refresh failed", "刷新失败")).font(.system(size: 11)).foregroundStyle(.orange)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    DisplayDestinationCheckbox(title: "Menu Bar", isOn: Binding(
                        get: { account.showInMenuBar },
                        set: { value in appState.updateDeepSeekAccount(id: account.id) { $0.showInMenuBar = value } }
                    )).frame(width: ServiceRowMetrics.destination)
                    DisplayDestinationCheckbox(title: "Floating HUD", isOn: Binding(
                        get: { account.showsInFloatingSurfaces },
                        set: { value in appState.updateDeepSeekAccount(id: account.id) { $0.visibleInPopover = value; $0.showInFloatingHUD = value } }
                    )).frame(width: ServiceRowMetrics.destination)
                    Menu {
                        Button(tr("Refresh", "刷新")) {
                            Task { await appState.loadDeepSeekBalance(account: account, reason: .userInitiated) }
                        }
                        Button(tr("Edit / Reconnect…", "编辑／重新连接…")) { editor = EditorRequest(value: account) }
                        Button(tr("Remove…", "删除…"), role: .destructive) { deleteTarget = account }
                    } label: { Image(systemName: "ellipsis.circle").foregroundStyle(.secondary) }
                    .menuStyle(.button).buttonStyle(.borderless).menuIndicator(.hidden)
                    .frame(width: ServiceRowMetrics.info)
                    Toggle(account.id, isOn: Binding(
                        get: { account.showsInFloatingSurfaces },
                        set: { value in appState.updateDeepSeekAccount(id: account.id) { $0.visibleInPopover = value; $0.showInFloatingHUD = value } }
                    ))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(.green)
                    .help(tr("Show in popover", "在弹出面板中显示"))
                    .frame(width: ServiceRowMetrics.toggle)
                }
                .padding(.leading, 16).padding(.trailing, ServiceRowMetrics.trailingPadding).padding(.vertical, 9)
                Divider().padding(.leading, ServiceRowMetrics.textLeading)
            }
            Button { editor = EditorRequest(value: nil) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                    Text(tr("Add DeepSeek account…", "添加 DeepSeek 账号…"))
                    Spacer()
                }
                .font(.system(size: 12.5)).foregroundStyle(Color.accentColor)
                .padding(.vertical, 12).padding(.leading, ServiceRowMetrics.textLeading).contentShape(Rectangle())
            }.buttonStyle(.plain).pointingHandCursor()
        }
        .sheet(item: $editor) { DeepSeekAccountEditor(account: $0.value) }
        .confirmationDialog(tr("Remove account?", "删除此账号？"), isPresented: Binding(
            get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }
        ), titleVisibility: .visible) {
            Button(tr("Remove", "删除"), role: .destructive) {
                if let target = deleteTarget { appState.removeDeepSeekAccount(id: target.id) }
                deleteTarget = nil
            }
            Button(tr("Cancel", "取消"), role: .cancel) { deleteTarget = nil }
        } message: {
            Text(deleteTarget?.sourceApplication != nil
                 ? tr("Removes only the CCBar copy. The original application remains signed in.", "只删除 CCBar 的凭据副本，原应用保持登录。")
                 : tr("Removes credentials saved by CCBar. CCBar also requests sign-out from DeepSeek for browser authorizations.", "删除 CCBar 保存的凭据；浏览器授权账号还会向 DeepSeek 请求退出登录。"))
        }
    }
}

extension DeepSeekAuthKind {
    @MainActor var displayName: String {
        self == .apiKey ? "API Key" : tr("Account authorization", "账号授权")
    }
}

private struct DeepSeekAccountEditor: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let account: DeepSeekAccount?
    @State private var name: String
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @State private var busy = false

    init(account: DeepSeekAccount?) {
        self.account = account
        _name = State(initialValue: account?.name ?? "DeepSeek")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(account == nil ? tr("Add DeepSeek account", "添加 DeepSeek 账号") : tr("Edit DeepSeek account", "编辑 DeepSeek 账号"))
                .font(.system(size: 16, weight: .semibold))
            TextField(tr("Account name", "账号名称"), text: $name).disabled(busy)
            Text(tr("Continue in your browser to authorize your DeepSeek account.", "在系统浏览器中完成 DeepSeek 账号授权。"))
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Text(tr("Credentials are saved in a private file on this Mac. CCBar connects directly to DeepSeek to read your balance.",
                    "凭据保存在本机私有文件中，CCBar 直接连接 DeepSeek 官方接口查询余额。"))
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if busy {
                HStack { ProgressView().controlSize(.small); Text(tr("Waiting for authorization…", "等待授权…")) }
                    .font(.system(size: 12))
            }
            if let error { Text(error).font(.system(size: 11.5)).foregroundStyle(.orange) }
            Spacer(minLength: 0)
            HStack {
                Button(tr("Cancel", "取消")) { cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if account != nil {
                    Button(tr("Save name", "保存名称")) { save(secret: nil) }.disabled(busy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Button(tr("Authorize in browser", "在浏览器中授权")) { signIn() }.buttonStyle(.borderedProminent)
                    .disabled(busy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20).frame(width: 460, height: 350)
        .onDisappear { cancel() }
    }
    private func save(secret: String?) {
        do {
            let saved = try appState.saveDeepSeekAccount(id: account?.id, name: name, kind: .account, secret: secret)
            Task { await appState.loadDeepSeekBalance(account: saved, reason: .userInitiated) }
            dismiss()
        } catch {
            self.error = tr("Couldn't save the account. Check the name and credentials, then retry.", "账号未能保存，请检查名称和凭据后重试")
        }
    }
    private func signIn() {
        error = nil
        busy = true
        let authorization = DeepSeekAuthorization()
        appState.deepSeekAuthorization?.cancel()
        appState.deepSeekAuthorization = authorization
        task = Task {
            do {
                let grant = try await authorization.authorize()
                try Task.checkCancellation()
                try authorization.validateForCommit()
                let saved = try appState.saveDeepSeekAccount(id: account?.id, name: name, kind: .account, secret: grant.token)
                authorization.finish(completionURL: grant.completionURL)
                appState.deepSeekAuthorization = nil
                Task { await appState.loadDeepSeekBalance(account: saved, reason: .userInitiated) }
                dismiss()
            } catch {
                authorization.cancel()
                if !Task.isCancelled {
                    self.error = tr("Authorization wasn't completed. Try signing in again.", "授权未完成，请重新登录")
                }
            }
            busy = false
        }
    }
    private func cancel() {
        task?.cancel(); task = nil
        appState.deepSeekAuthorization?.cancel()
        appState.deepSeekAuthorization = nil
    }
}
