import SwiftUI

/// Imported accounts share the Codex vendor header and the primary account's quota layout.
struct OtherCodexAccountsSection: View {
    @Environment(AppState.self) private var appState
    /// Hide an imported account when the CLI account already displays the same identity.
    var dedupPrimary = false
    var showsVendorHeader = true

    private var visible: [ImportedCodexAccount] {
        appState.importedCodexAccounts.filter {
            $0.visibleInPopover && !(dedupPrimary && appState.importedCodexAccountMirrorsPrimary($0))
        }
    }

    var body: some View {
        let accounts = visible
        if !accounts.isEmpty {
            VStack(spacing: 0) {
                if showsVendorHeader {
                    AccountVendorHeader(title: "Codex", logoName: "codex", fallback: "C", tint: .codexAccent)
                }
                ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                    if index > 0 { Divider().padding(.leading, 28).padding(.trailing, 16) }
                    ServiceBlockView(
                        app: .codex,
                        subtitle: accountSubtitle(account),
                        tint: .codexAccent,
                        snapshot: appState.importedCodexQuota(for: account),
                        error: appState.importedCodexError(for: account),
                        periodSpend: nil,
                        periodIsBillingCycle: false,
                        todayCost: nil,
                        showsCost: false,
                        isLoading: appState.importedCodexRefreshState(for: account).inFlight,
                        followsVendorHeader: index == 0 && showsVendorHeader
                    )
                }
            }
        }
    }

    private func accountSubtitle(_ account: ImportedCodexAccount) -> String {
        var parts: [String] = []
        if PrivacyDisplay.isEnabled {
            parts.append(PrivacyDisplay.account(account.id))
        } else {
            if !account.alias.isEmpty { parts.append(account.alias) }
            if let email = account.email, !email.isEmpty { parts.append(email) }
            if parts.isEmpty { parts.append(account.id) }
        }
        if let plan = CodexAccount.planName(account.planType) { parts.append(plan) }
        return parts.joined(separator: " · ")
    }
}
