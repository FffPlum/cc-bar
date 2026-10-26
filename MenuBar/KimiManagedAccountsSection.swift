import SwiftUI

struct KimiManagedAccountsSection: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let accounts = appState.kimiManagedAccounts.filter { $0.visibleInPopover && !appState.kimiManagedMirrorsCLI($0) }
        VStack(spacing: 0) {
            HStack {
                Text(tr("KIMI CODE ACCOUNTS", "Kimi Code 账号"))
                    .font(.system(size: 9.5, weight: .semibold))
                    .kerning(0.3)
                    .foregroundStyle(.tertiary)
                Spacer()
                if appState.kimiAccount == nil, let status = appState.displayedKimiServiceStatus {
                    ServiceStatusDot(status: status, title: "Kimi Code")
                }
                Text("\(accounts.count)")
                    .font(.system(size: 9.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.quaternary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 6)
            ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                if index > 0 { Divider().padding(.horizontal, 16) }
                row(account)
            }
        }
    }

    private func row(_ account: KimiManagedAccount) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(appState.kimiManagedSubtitle(account))
                    .font(.system(size: 12))
                    .lineLimit(1)
                Text(account.region.displayName)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 104, alignment: .leading)
            VStack(alignment: .leading, spacing: 5) {
                if let snapshot = appState.kimiManagedQuotas[account.id] {
                    if snapshot.isEmptyKimiQuota {
                        Text(tr("No quota data available", "暂无额度数据"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    ForEach([snapshot.primaryLimit, snapshot.secondaryLimit].compactMap { $0 } + snapshot.auxiliaryLimits) { limit in
                        quotaRow(limit)
                    }
                } else if appState.kimiManagedRefreshStates[account.id]?.inFlight == true {
                    ProgressView().controlSize(.small)
                } else {
                    Text("—").foregroundStyle(.quaternary)
                }
                if let error = appState.kimiManagedErrors[account.id] {
                    Text(PrivacyDisplay.error(error))
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    private func quotaRow(_ limit: QuotaLimit) -> some View {
        HStack(spacing: 6) {
            Text(limit.kind == .fiveHour ? "5H" : (limit.kind == .weekly ? "WK" : (limit.id == "kimi-monthly-code" ? "CODE" : "MON")))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 28, alignment: .leading)
            ProgressBar(
                value: limit.window.remainingPercent / 100,
                tint: statusColor(remainingPercent: limit.window.remainingPercent, tint: .purple),
                height: 2.5
            )
            Text("\(Int(limit.window.remainingPercent.rounded()))%")
                .font(.system(size: 10.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(statusColor(remainingPercent: limit.window.remainingPercent, tint: .purple))
                .frame(width: 30, alignment: .trailing)
            ResetTimeText(resetsAt: limit.window.resetsAt)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .frame(width: 70, alignment: .trailing)
        }
    }
}
