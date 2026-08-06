import KeepoCore
import SwiftUI

/// One hero balance display — Home's net worth today, and available to
/// Accounts/Sync Ritual per app-architecture.md §2's shared-component
/// table whenever either screen wants a single aggregate figure of its
/// own; not retrofitted onto them yet since neither has asked for one.
struct BalanceHeaderView: View {
    let amount: Decimal?
    let currency: CurrencyInfo?

    var body: some View {
        Text(formatted)
            .font(.system(size: 44, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(Color("TextPrimary"))
    }

    private var formatted: String {
        guard let currency else { return "—" }
        return MoneyFormatter.format(amount, currency: currency)
    }
}
