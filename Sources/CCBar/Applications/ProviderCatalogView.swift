import SwiftUI
import CCBarConfiguration

struct ProviderCatalogView: View {
    @Environment(AppState.self) private var appState
    let application: AgentApplication
    let onBack: () -> Void
    @State private var search = ""
    @State private var category: Category = .all
    @State private var selectedKey: APIKeyProvider?
    @State private var keyEditor: ModelSupplier?

    private enum Category: String, CaseIterable, Identifiable {
        case all, keys, suppliers, custom
        var id: Self { self }
        var title: String {
            switch self {
            case .all: tr("All", "全部")
            case .keys: tr("Available API Keys", "可用 API Key")
            case .suppliers: tr("Model providers", "模型厂商")
            case .custom: tr("Custom", "自定义")
            }
        }
    }
    private var keys: [APIKeyProvider] {
        appState.apiKeyProviders.filter { matches($0.name + " " + $0.supplier.name + " " + $0.endpoint) }
    }
    private var suppliers: [ModelSupplier] {
        ModelSupplier.allCases.filter { $0 != .custom && matches($0.name + " " + $0.defaultEndpoint) }
    }
    private func matches(_ value: String) -> Bool {
        search.isEmpty || value.localizedCaseInsensitiveContains(search)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button(action: onBack) { Image(systemName: "chevron.left") }.buttonStyle(.plain)
                    .help(tr("Back to application", "返回应用"))
                Text(tr("Add provider", "添加供应商")).font(.title2.weight(.semibold))
                Text(application.name).foregroundStyle(.secondary)
                Spacer()
                Button { keyEditor = .custom } label: { Label(tr("Add API Key", "添加 API Key"), systemImage: "plus") }
            }.padding(24)
            Divider()
            VStack(spacing: 18) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(tr("Search name or endpoint", "搜索名称或 API 地址"), text: $search).textFieldStyle(.plain)
                }.padding(12).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                HStack(alignment: .top, spacing: 24) {
                    VStack(spacing: 5) {
                        ForEach(Category.allCases) { item in
                            Button { category = item } label: {
                                HStack {
                                    Text(item.title)
                                    Spacer()
                                    Text("\(count(item))").foregroundStyle(.secondary).monospacedDigit()
                                }.padding(10).background(category == item ? Color.primary.opacity(0.08) : .clear,
                                                          in: RoundedRectangle(cornerRadius: 7))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityAddTraits(category == item ? .isSelected : [])
                        }
                        Spacer()
                    }.frame(width: 165)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            if let error = appState.authorizations.error ?? appState.applicationImportError {
                                Text(error).font(.callout).foregroundStyle(.orange)
                            }
                            if category == .all || category == .keys {
                                catalogSection(tr("Available API Keys", "可用 API Key")) {
                                    ForEach(keys) { key in
                                        Button { selectedKey = key } label: {
                                            ProviderInfoCard(supplier: key.supplier, title: key.name, subtitle: key.endpoint,
                                                             detail: sourceLabel(key))
                                        }.buttonStyle(.plain).disabled(!application.supportsProviderConfiguration)
                                    }
                                }
                                if keys.isEmpty {
                                    Text(tr("No matching API Keys", "暂无匹配的 API Key")).font(.callout).foregroundStyle(.secondary)
                                }
                            }
                            if category == .all || category == .suppliers {
                                catalogSection(tr("Model providers", "模型厂商")) {
                                    ForEach(suppliers) { supplier in
                                        Button { keyEditor = supplier } label: {
                                            ProviderInfoCard(supplier: supplier, title: supplier.name,
                                                             subtitle: URL(string: supplier.defaultEndpoint)?.host ?? supplier.defaultEndpoint,
                                                             detail: tr("Add API Key", "添加 API Key"))
                                        }.buttonStyle(.plain)
                                    }
                                }
                            }
                            if (category == .all || category == .custom), matches("Custom 自定义 API Key") {
                                Button { keyEditor = .custom } label: {
                                    ProviderInfoCard(supplier: .custom, title: tr("Custom provider", "自定义供应商"),
                                                     subtitle: tr("Enter an endpoint and API Key", "填写 API 地址和 API Key"))
                                }.buttonStyle(.plain)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }.padding(24)
        }
        .sheet(item: $selectedKey) { ApplicationProviderEditor(application: application, authorization: $0) }
        .sheet(item: $keyEditor) { APIKeyEditor(supplier: $0) }
    }
    private func count(_ category: Category) -> Int {
        switch category {
        case .all: keys.count + suppliers.count + (matches("Custom 自定义 API Key") ? 1 : 0)
        case .keys: keys.count
        case .suppliers: suppliers.count
        case .custom: matches("Custom 自定义 API Key") ? 1 : 0
        }
    }
    private func sourceLabel(_ key: APIKeyProvider) -> String {
        let names = key.sourceApplications.sorted { $0.rawValue < $1.rawValue }.map(\.name).joined(separator: "、")
        return names.isEmpty ? tr("Saved API Key", "已保存的 API Key") : tr("Detected in \(names)", "识别自 \(names)")
    }
    private func catalogSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 14)], spacing: 14, content: content)
        }
    }
}

private struct ApplicationProviderEditor: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var provider: ApplicationProvider
    @State private var error: String?

    init(application: AgentApplication, authorization: APIKeyProvider) {
        let api = application.supportedAPIs.contains(.chatCompletions) ? ProviderAPI.chatCompletions : application.supportedAPIs[0]
        _provider = State(initialValue: ApplicationProvider(application: application, name: authorization.name,
                                                           supplier: authorization.supplier, endpoint: authorization.endpoint,
                                                           model: "", api: api, authorizationID: authorization.id))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(tr("Add provider", "添加供应商")).font(.title3.bold())
            TextField(tr("Name", "名称"), text: $provider.name)
            TextField(tr("API endpoint", "API 地址"), text: $provider.endpoint)
            Picker(tr("API protocol", "API 协议"), selection: $provider.api) {
                ForEach(provider.application.supportedAPIs, id: \.self) { Text($0.title).tag($0) }
            }
            TextField(tr("Model ID", "模型名称"), text: $provider.model)
            TextField(tr("Context window", "上下文长度"), value: $provider.contextWindow, format: .number.grouping(.never))
                .monospacedDigit()
            Text(tr("Adds this provider to CCBar. The application's current configuration is unchanged.",
                    "添加到 CCBar 的应用列表，原应用当前配置保持不变。"))
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button(tr("Cancel", "取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(tr("Add", "添加")) {
                    do {
                        let key = try appState.providerCredential(for: provider)
                        try ConfigurationRepository.validate(provider, credential: key)
                        try appState.authorizations.saveProvider(provider)
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 480)
    }
}
