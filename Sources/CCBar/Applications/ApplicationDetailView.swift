import SwiftUI
import CCBarConfiguration

struct ApplicationDetailView: View {
    @Environment(AppState.self) private var appState
    let application: AgentApplication
    @State private var showsCatalog = false

    private var connections: [ProviderConnection] {
        ProviderConnection.list(application: application,
                                native: appState.applications.snapshots[application]?.providers ?? [],
                                saved: appState.authorizations.providers)
    }
    private var connectionCount: Int {
        connections.isEmpty && appState.applicationLoginSummary(application) != nil ? 1 : connections.count
    }
    var body: some View {
        if showsCatalog {
            ProviderCatalogView(application: application) { showsCatalog = false }
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    ApplicationIcon(application: application, size: 28)
                    WorkspaceHeader(title: application.name) {
                        Button { showsCatalog = true } label: {
                            Label(tr("Add provider", "添加供应商"), systemImage: "plus")
                        }.buttonStyle(.borderedProminent)
                    }
                }.padding(24)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let error = appState.applications.errors[application] {
                            Label(PrivacyDisplay.error(error), systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                        }
                        Text(tr("Added · \(connectionCount)", "已添加 · \(connectionCount)"))
                            .font(.callout).foregroundStyle(.secondary)
                        ForEach(connections) { connection in
                            connectionCard(connection)
                        }
                        if connections.isEmpty {
                            if let login = appState.applicationLoginSummary(application) {
                                ProviderInfoCard(supplier: application.defaultSupplier, title: application.name,
                                                 subtitle: login, detail: tr("Account sign-in", "账号登录"), active: true)
                            } else {
                                ContentUnavailableView(tr("No authorizations detected", "暂未识别到授权"), systemImage: "key",
                                                       description: Text(tr("Add a provider or sign in within the application.", "添加供应商，或在原应用中登录账号。")))
                            }
                        }
                    }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func connectionCard(_ connection: ProviderConnection) -> some View {
        let provider = connection.provider
        let subtitle = provider.isOfficial
            ? appState.applicationLoginSummary(application) ?? tr("Sign-in managed by the application", "登录由原应用管理")
            : provider.endpoint
        let detail = provider.isOfficial ? tr("Account sign-in", "账号登录")
            : "API Key" + (connection.models.isEmpty ? "" : " · " + connection.models.joined(separator: " / "))
        return ProviderInfoCard(supplier: provider.supplier, title: provider.name, subtitle: subtitle,
                                detail: detail, active: connection.isActive, official: provider.isOfficial)
    }
}

struct ProviderInfoCard: View {
    let supplier: ModelSupplier
    let title: String
    let subtitle: String
    var detail: String? = nil
    var active = false
    var official = false

    var body: some View {
        HStack(spacing: 16) {
            SupplierIcon(supplier: supplier, size: 38)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    if official {
                        Text(tr("Official", "官方")).font(.caption).foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 2).background(.quaternary, in: Capsule())
                    }
                }
                Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            }
            Spacer(minLength: 12)
            if active {
                Label(tr("In use", "使用中"), systemImage: "circle.fill")
                    .font(.caption).foregroundStyle(Color.accentColor)
            }
        }
        .padding(18).frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
        .background(active ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(active ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.1), lineWidth: 1) }
    }
}

extension AppState {
    func applicationLoginSummary(_ application: AgentApplication) -> String? {
        let identity: String?
        switch application {
        case .codex: identity = codexAccount.map { [$0.email, codexPlanName].compactMap { $0 }.joined(separator: " · ") }
        case .claude: identity = claudeAccount.map { _ in [claudeDisplayEmail, claudePlanName].compactMap { $0 }.joined(separator: " · ") }
        case .kimi: identity = kimiAccount.map { _ in [kimiNickname, kimiPlanName].compactMap { $0 }.joined(separator: " · ") }
        case .dsh: identity = deepSeekQuotaAccounts.first.map { deepSeekDisplayName($0) }
        case .cursor: identity = cursorAccount.map { _ in tr("Signed in", "已登录") }
        case .antigravity: identity = antigravityAccount?.email
        case .commandCode: identity = nil
        case .gemini, .grok: identity = applications.logins[application].map { $0.accountName ?? tr("Signed in", "已登录") }
        default: identity = nil
        }
        guard let identity else { return nil }
        return PrivacyDisplay.isEnabled ? PrivacyDisplay.account("application:" + application.rawValue) : identity
    }
}
