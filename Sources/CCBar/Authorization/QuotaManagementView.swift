import SwiftUI
import CCBarConfiguration

struct QuotaManagementView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                WorkspaceHeader(title: tr("Quota Management", "额度管理")) {
                    Button { appState.reloadApplications(); Task { await appState.refreshQuotas(reason: .userInitiated) } } label: {
                        Label(tr("Refresh", "刷新"), systemImage: "arrow.clockwise")
                    }
                }
                AuthorizationServicesView()
                VStack(alignment: .leading, spacing: 12) {

                    ForEach([AgentApplication.gemini, .grok].filter { appState.applications.logins[$0] != nil }) { application in
                        let login = appState.applications.logins[application]
                        HStack(spacing: 12) {
                            SupplierIcon(supplier: application.defaultSupplier, size: 30)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(application.name).font(.headline)
                                if let login {
                                    Text(PrivacyDisplay.isEnabled ? PrivacyDisplay.account(login.id)
                                         : login.accountName ?? tr("Local sign-in detected", "已识别本机登录"))
                                        .font(.callout)
                                    Text(login.needsRefresh
                                         ? tr("Open the application to refresh its login.", "请打开原应用刷新登录。")
                                         : tr("Login managed by the application · Quota unavailable", "登录由原应用管理 · 暂未接入额度查询"))
                                        .font(.caption).foregroundStyle(.secondary)
                                } else {
                                    Text(application == .grok
                                         ? tr("Sign in with grok login, then refresh.", "使用 grok login 登录后刷新。")
                                         : tr("Sign in within Gemini CLI, then refresh.", "在 Gemini CLI 中登录后刷新。"))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if appState.applications.detected.contains(application) {
                                Button(tr("Open application settings", "应用配置")) { appState.mainTab = .application(application) }
                            }
                        }.padding(16).ccPanel()
                    }
                }
            }.padding(28).frame(maxWidth: 1100).frame(maxWidth: .infinity, alignment: .top)
        }
    }
}
