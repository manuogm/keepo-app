import KeepoCore
import SwiftUI

/// One hero balance display — Home's net worth today, and available to
/// Accounts/Sync Ritual per app-architecture.md §2's shared-component
/// table whenever either screen wants a single aggregate figure of its
/// own; not retrofitted onto them yet since neither has asked for one.
struct BalanceHeaderView: View {
    let amount: Int64?
    let currency: CurrencyInfo?

    @Environment(\.isPrivacyMode) private var isPrivacyMode

    var body: some View {
        (isPrivacyMode ? Text("••••").font(.system(size: 44, weight: .bold)) : styledAmount)
            .monospacedDigit()
            .foregroundStyle(Color.primary)
            .contentTransition(.numericText())
            .animation(.easeInOut(duration: 0.2), value: isPrivacyMode)
    }

    /// The whole part carries the size — it's the number people actually
    /// scan for — with the fractional part rendered smaller so it reads as
    /// a detail rather than competing with it.
    private var styledAmount: Text {
        guard let currency else { return Text("—").font(.system(size: 44, weight: .bold)) }
        let split = MoneyFormatter.formatSplit(amount, currency: currency)
        return Text(split.whole).font(.system(size: 44, weight: .bold))
            + Text(split.fraction).font(.system(size: 24, weight: .bold))
    }
}
