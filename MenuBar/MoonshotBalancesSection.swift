import SwiftUI

struct MoonshotBalancesSection: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let accounts = appState.moonshotAccounts.filter(\.visibleInPopover)
        VStack(alignment: .leading, spacing: 10) {
            Text(tr("Moonshot API · Pay as you go", "Moonshot API · 按量计费"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                if index > 0 { Divider() }
                row(account)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func row(_ account: MoonshotAccount) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(appState.moonshotDisplayName(account))
                    .font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                Spacer()
                if let balance = appState.moonshotBalances[account.id] {
                    Text(MoonshotBalanceFormatter.amount(balance.available, currencyCode: balance.currencyCode))
                        .font(.system(size: 18, weight: .semibold)).monospacedDigit()
                } else if appState.moonshotRefreshStates[account.id]?.inFlight == true {
                    ProgressView().controlSize(.small)
                } else {
                    Text("—").font(.system(size: 18)).foregroundStyle(.secondary)
                }
            }
            if let balance = appState.moonshotBalances[account.id] {
                HStack {
                    Text(tr("Cash", "现金"))
                    Spacer()
                    Text(MoonshotBalanceFormatter.amount(balance.cash, currencyCode: balance.currencyCode))
                    Text(tr("Voucher", "代金券"))
                    Spacer()
                    Text(MoonshotBalanceFormatter.amount(balance.voucher, currencyCode: balance.currencyCode))
                }
                .font(.system(size: 10.5)).foregroundStyle(.secondary).monospacedDigit()
                Text(tr("Fetched \(PopoverRootView.relativeAge(from: balance.fetchedAt)) ago · \(balance.currencyCode)",
                        "\(PopoverRootView.relativeAge(from: balance.fetchedAt)) 前获取 · \(balance.currencyCode)"))
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            if let error = appState.moonshotErrors[account.id] {
                Text(PrivacyDisplay.error(error))
                    .font(.system(size: 10.5)).foregroundStyle(.orange).lineLimit(2)
            }
        }
    }
}
