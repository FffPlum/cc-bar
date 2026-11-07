import SwiftUI
import CCBarConfiguration

struct ApplicationsManagementView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                WorkspaceHeader(title: tr("Applications", "应用")) {
                    Button { appState.reloadApplications() } label: {
                        Label(tr("Detect applications", "重新识别"), systemImage: "arrow.clockwise")
                    }
                }
                Text(tr("Detected applications and configurations", "已识别的应用与配置")).font(.headline)
                ForEach(AgentApplication.allCases.filter { appState.applications.detected.contains($0) }) { application in
                    HStack(spacing: 14) {
                        ApplicationIcon(application: application, size: 32)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(application.name).font(.headline)
                            if application.usageApp == nil {
                                Text(tr("Usage statistics unavailable", "暂未接入用量统计")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if let usage = application.usageApp {
                            Toggle(tr("Usage statistics", "用量统计"), isOn: Binding(
                                get: { SettingsStore.shared.isUsageServiceVisible(usage) },
                                set: { SettingsStore.shared.setUsageServiceVisible($0, for: usage) }
                            )).toggleStyle(.switch).controlSize(.small)
                                .help(tr("Controls statistics visibility; existing history is kept.", "控制统计展示，已记录的历史数据保留。"))
                        }
                        Toggle(tr("In sidebar", "添加到侧栏"), isOn: Binding(
                            get: { appState.applications.addedApplications.contains(application) },
                            set: { appState.applications.setAdded($0, application: application) }
                        )).toggleStyle(.switch).controlSize(.small)
                    }.padding(18).ccPanel()
                }
                if appState.applications.detected.isEmpty {
                    ContentUnavailableView(tr("No applications detected", "暂未识别到应用"), systemImage: "square.grid.2x2")
                }
            }.padding(28).frame(maxWidth: 1000).frame(maxWidth: .infinity, alignment: .top)
        }
    }
}

struct ApplicationIcon: View {
    let application: AgentApplication
    var size: CGFloat = 20
    var body: some View {
        ServiceTile(logoName: application.brand.logoName, fallback: String(application.name.prefix(1)),
                    tint: BrandColorResolver.color(for: application.brand, settings: SettingsStore.shared),
                    size: size, logoSize: size * 0.7)
    }
}
