import SwiftUI

struct PricingCatalogView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var expandedProviders: Set<String> = []
    @State private var collapsedSearchProviders: Set<String> = []
    @State private var updateMessage: String?
    @State private var updateMessageIsError = false
    @State private var providers: [ModelsDevProviderPricing] = []
    @State private var fetchedAt: Date?
    @State private var isLoading = true
    @State private var loadFailed = false
    @State private var isSourceHovered = false

    private let priceColumnWidth: CGFloat = 104

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if providers.isEmpty && isLoading {
                ProgressView(tr("Loading prices…", "正在加载价格…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visibleProviders.isEmpty {
                ContentUnavailableView(
                    tr("No prices found", "未找到价格"),
                    systemImage: "magnifyingglass",
                    description: Text(query.isEmpty
                        ? (loadFailed
                            ? tr("Could not load prices. Check your connection and try updating again.", "价格加载失败，请检查网络后重新更新。")
                            : tr("Update the catalog to fetch official prices from models.dev.", "更新目录，从 models.dev 获取官方价格。"))
                        : tr("Try a different provider or model name.", "试试其他提供商或模型名称。"))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(visibleProviders) { provider in
                            providerGroup(provider)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(minWidth: 820, idealWidth: 920, minHeight: 520, idealHeight: 660)
        .task {
            reloadCatalogSnapshot()
            await PricingCatalogStore.shared.loadProviderCatalogIfNeeded()
            guard !Task.isCancelled else { return }
            reloadCatalogSnapshot()
            isLoading = false
        }
        .onReceive(NotificationCenter.default.publisher(for: PricingCatalogStore.didChangeNotification)) { _ in
            reloadCatalogSnapshot()
        }
        .onChange(of: isSearching) { _, _ in
            collapsedSearchProviders.removeAll()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(tr("Price Catalog", "价格目录"))
                    .font(.system(size: 17, weight: .bold))
                    .kerning(-0.4)
                Text(tr("Per 1M tokens · \(SettingsStore.shared.displayCurrency.code)", "每百万 Token · \(SettingsStore.shared.displayCurrency.code)"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tr("Close", "关闭"))
                .keyboardShortcut(.cancelAction)
            }

            HStack(spacing: 10) {
                TextField(tr("Search providers or models", "搜索提供商或模型"), text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                Spacer()
                if let updateMessage {
                    Text(updateMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(updateMessageIsError ? Color.orange : Color.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
                Button {
                    updateMessage = nil
                    Task {
                        let succeeded = await appState.usageService.refreshPricingCatalogAndRecalculateUsage()
                        reloadCatalogSnapshot()
                        updateMessageIsError = !succeeded || loadFailed
                        updateMessage = !updateMessageIsError
                            ? tr("Prices updated and usage recalculated", "价格已更新，用量已重算")
                            : tr("Price update failed; usage recalculated with cached prices", "价格更新失败，已用缓存价格重算用量")
                    }
                } label: {
                    if appState.usageService.isRefreshingPricingCatalog {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(tr("Update & Recalculate", "更新并重算"))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(appState.usageService.isRefreshingPricingCatalog)
            }

            HStack(spacing: 3) {
                Link(destination: URL(string: "https://models.dev")!) {
                    HStack(spacing: 3) {
                        Text("models.dev").underline(isSourceHovered)
                        Image(systemName: "arrow.up.forward.square")
                            .font(.system(size: 9, weight: .medium))
                    }
                    .foregroundStyle(isSourceHovered ? Color.primary : Color.secondary)
                }
                .buttonStyle(.plain)
                .onHover { isSourceHovered = $0 }
                .pointingHandCursor()
                if let fetchedAt {
                    Text(tr("prices fetched \(PopoverRootView.relativeAge(from: fetchedAt)) ago", "价格于 \(PopoverRootView.relativeAge(from: fetchedAt)) 前获取"))
                } else {
                    Text(tr("· price source", "· 价格来源"))
                }
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.tertiary)
        }
        .padding(16)
    }

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var visibleProviders: [ModelsDevProviderPricing] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return providers }
        return providers.compactMap { provider in
            if provider.name.localizedCaseInsensitiveContains(query)
                || provider.id.localizedCaseInsensitiveContains(query) {
                return provider
            }
            let models = provider.models.filter {
                $0.name.localizedCaseInsensitiveContains(query)
                    || $0.id.localizedCaseInsensitiveContains(query)
            }
            guard !models.isEmpty else { return nil }
            return ModelsDevProviderPricing(id: provider.id, name: provider.name, models: models)
        }
    }

    private func reloadCatalogSnapshot() {
        let catalog = PricingCatalogStore.shared
        providers = catalog.providerCatalog
        fetchedAt = catalog.modelsDevFetchedAt
        loadFailed = catalog.modelsDevRefreshFailed
    }

    private func providerGroup(_ provider: ModelsDevProviderPricing) -> some View {
        return GroupBox {
            DisclosureGroup(isExpanded: Binding(
                get: {
                    isSearching ? !collapsedSearchProviders.contains(provider.id) : expandedProviders.contains(provider.id)
                },
                set: { isExpanded in
                    if isSearching {
                        if isExpanded {
                            collapsedSearchProviders.remove(provider.id)
                        } else {
                            collapsedSearchProviders.insert(provider.id)
                        }
                    } else if isExpanded {
                        expandedProviders.insert(provider.id)
                    } else {
                        expandedProviders.remove(provider.id)
                    }
                }
            )) {
                VStack(spacing: 0) {
                    priceHeader
                    Divider().padding(.vertical, 6)
                    ForEach(Array(provider.models.enumerated()), id: \.element.id) { index, model in
                        if index > 0 { Divider().padding(.vertical, 4) }
                        priceRow(model)
                    }
                }
                .padding(.top, 8)
            } label: {
                HStack {
                    Text(provider.name)
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text(tr("\(provider.models.count) models", "\(provider.models.count) 个模型"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }

    private var priceHeader: some View {
        HStack(spacing: 8) {
            Text(tr("Model", "模型"))
                .frame(maxWidth: .infinity, alignment: .leading)
            headerLabel("Input", chinese: "输入")
            headerLabel("Output", chinese: "输出")
            headerLabel("Cache read", chinese: "缓存读取")
            headerLabel("Cache write", chinese: "缓存写入")
        }
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(.tertiary)
    }

    private func headerLabel(_ english: String, chinese: String) -> some View {
        Text(tr(english, chinese))
            .frame(width: priceColumnWidth, alignment: .trailing)
    }

    private func priceRow(_ model: ModelsDevModelPricing) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.name)
                    .font(.system(size: 11.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if model.name != model.id {
                    Text(model.id)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            priceText(model.price.input)
            priceText(model.price.output)
            priceText(model.price.cacheRead)
            priceText(model.price.cacheCreation)
        }
    }

    private func priceText(_ value: Decimal) -> some View {
        Text(CurrencyFormatter.pricePerMillion(value))
            .font(.system(size: 11))
            .monospacedDigit()
            .frame(width: priceColumnWidth, alignment: .trailing)
    }
}
