import KeepoCore
import SwiftUI

/// One hero balance display — Home's net worth today, and available to
/// Accounts/Sync Ritual per app-architecture.md §2's shared-component
/// table whenever either screen wants a single aggregate figure of its
/// own; not retrofitted onto them yet since neither has asked for one.
struct BalanceHeaderView: View {
    let amount: Int64?
    let currency: CurrencyInfo?
    /// Point size of the whole part. Defaults to the hero size Home led
    /// with before the dashboard existed; a widget tile passes something
    /// smaller. Parameterised rather than copied into a second view so the
    /// big-whole/small-fraction weighting can only ever be defined once.
    var size: CGFloat = 44
    /// How the sign is *drawn*, never how it is stored (money rule 1). A
    /// balance keeps `.standard`, where a minus means "overdrawn" and is real
    /// information; a figure whose direction its own label already states —
    /// Upcoming Bills' "due" — passes `.ledger` and drops the minus.
    var signStyle: MoneySignStyle = .standard

    @Environment(\.isPrivacyMode) private var isPrivacyMode

    var body: some View {
        (isPrivacyMode ? Text("••••").font(.system(size: size, weight: .bold)) : styledAmount)
            .monospacedDigit()
            .foregroundStyle(Color.primary)
            .contentTransition(.numericText())
            .animation(.easeInOut(duration: 0.2), value: isPrivacyMode)
    }

    /// The whole part carries the size — it's the number people actually
    /// scan for — with the fractional part rendered smaller so it reads as
    /// a detail rather than competing with it.
    private var styledAmount: Text {
        guard let currency else { return Text("—").font(.system(size: size, weight: .bold)) }
        let split = MoneyFormatter.formatSplit(amount, currency: currency, signStyle: signStyle)
        return Text(split.whole).font(.system(size: size, weight: .bold))
            + Text(split.fraction).font(.system(size: size * 0.55, weight: .bold))
    }
}
