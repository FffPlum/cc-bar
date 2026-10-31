import SwiftUI

struct DeepSeekBalancesSection: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            AccountVendorHeader(title: "DeepSeek", logoName: "deepseek", fallback: "D", tint: .blue)
            ForEach(appState.deepSeekQuotaAccounts.filter(\.visibleInPopover)) { account in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(appState.deepSeekDisplayName(account)).lineLimit(1)
                        Spacer()
                        Text(account.kind.displayName)
                    }.font(.system(size: 11)).foregroundStyle(.secondary)
                    if let balance = appState.deepSeekBalances[account.id] {
                        ForEach(balance.wallets) { wallet in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(CurrencyFormatter.balance(wallet.total, from: wallet.currency))
                                        .font(.system(size: 18, weight: .semibold))
                                    Text(tr("Source: \(wallet.currency)", "原币：\(wallet.currency)"))
                                        .font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                                HStack {
                                    Text(tr("Top-up", "充值"))
                                    Text(CurrencyFormatter.balance(wallet.toppedUp, from: wallet.currency))
                                    Spacer()
                                    Text(tr("Bonus", "赠金"))
                                    Text(CurrencyFormatter.balance(wallet.granted, from: wallet.currency))
                                }.font(.system(size: 10.5)).foregroundStyle(.secondary)
                            }.monospacedDigit()
                        }
                        if balance.wallets.isEmpty {
                            Text(tr("No balance data", "暂无余额数据")).font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        if balance.isAvailable == false {
                            Text(tr("Balance unavailable for API calls", "当前余额不可用于 API 调用"))
                                .font(.system(size: 11)).foregroundStyle(.orange)
                        }
                        Text(tr("Fetched \(PopoverRootView.relativeAge(from: balance.fetchedAt)) ago",
                                "\(PopoverRootView.relativeAge(from: balance.fetchedAt)) 前获取"))
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                    } else if appState.deepSeekRefreshStates[account.id]?.inFlight == true {
                        ProgressView().controlSize(.small)
                    } else { Text("—").foregroundStyle(.secondary) }
                    if let error = appState.deepSeekErrors[account.id] {
                        Label(PrivacyDisplay.error(error), systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 10.5)).foregroundStyle(.orange).lineLimit(2)
                    }
                }.padding(.horizontal, 16).padding(.vertical, 10)
            }
        }
    }
}

extension AppState {
    func deepSeekBalanceText(for account: DeepSeekAccount) -> String {
        guard let balance = deepSeekBalances[account.id], !balance.wallets.isEmpty else { return "—" }
        return balance.wallets.map { CurrencyFormatter.balance($0.total, from: $0.currency) }.joined(separator: " / ")
    }
}
