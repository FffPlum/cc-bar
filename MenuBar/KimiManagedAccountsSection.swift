import SwiftUI

/// Account content under the shared Kimi vendor header, without extra inset.
struct KimiManagedAccountsSection: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let accounts = appState.kimiManagedAccounts.filter { $0.visibleInPopover && !appState.kimiManagedMirrorsCLI($0) }
        VStack(spacing: 0) {
            ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                if index > 0 { Divider().padding(.horizontal, 16) }
                ServiceBlockView(
                    app: .kimi,
                    title: "Kimi Code",
                    subtitle: appState.kimiManagedSubtitle(account),
                    tint: .purple,
                    logoName: "kimi",
                    fallback: "K",
                    snapshot: appState.kimiManagedQuotas[account.id],
                    error: appState.kimiManagedErrors[account.id],
                    periodSpend: nil,
                    periodIsBillingCycle: false,
                    todayCost: nil,
                    serviceStatus: appState.displayedKimiServiceStatus,
                    showsCost: false,
                    accountEdition: account.region.displayName,
                    isKimiCurrentAccount: appState.kimiManagedMirrorsCLI(account),
                    showsProviderHeader: false
                )
            }
        }
    }
}
