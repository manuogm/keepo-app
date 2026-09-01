import KeepoCore
import SwiftUI

/// One hero balance display — Home's net worth today, and available to
/// Accounts/Sync Ritual per app-architecture.md §2's shared-component
/// table whenever either screen wants a single aggregate figure of its
/// own; not retrofitted onto them yet since neither has asked for one.
struct BalanceHeaderView: View {
    let amount: Int64?
    let currency: CurrencyInfo?
    /// Point size of the whole part, from `AppTheme.Typography.Number`.
    /// Defaults to the hero size Home led with before the dashboard existed;
    /// a widget tile passes something smaller. Parameterised rather than
    /// copied into a second view so the big-whole/small-fraction weighting
    /// can only ever be defined once.
    var size: CGFloat = AppTheme.Typography.Number.balance
    /// How the sign is *drawn*, never how it is stored (money rule 1). A
    /// balance keeps `.standard`, where a minus means "overdrawn" and is real
    /// information; a figure whose direction its own label already states —
    /// Upcoming Bills' "due" — passes `.ledger` and drops the minus.
    var signStyle: MoneySignStyle = .standard

    @Environment(\.isPrivacyMode) private var isPrivacyMode
    /// **The whole app's money figures scale from here.** Every balance,
    /// every widget headline and every metric goes through this view, so
    /// one `@ScaledMetric` is all it takes for the largest numbers in the
    /// app to honour Dynamic Type — which a bare `.system(size:)` never did,
    /// and `keepo-brand-identity.md` §3 requires. Relative to `.largeTitle`
    /// because that is the role these figures play.
    @ScaledMetric(relativeTo: .largeTitle) private var typeScale: CGFloat = 1

    private func font(_ points: CGFloat) -> Font {
        AppTheme.Typography.Number.display(points, weight: .bold, scale: typeScale)
    }

    var body: some View {
        (isPrivacyMode ? Text(PrivacyMask.hidden).font(font(size)) : styledAmount)
            .foregroundStyle(AppTheme.Palette.textPrimary)
            .contentTransition(.numericText())
            .animation(AppTheme.Motion.colorSafe, value: isPrivacyMode)
    }

    /// The whole part carries the size — it's the number people actually
    /// scan for — with the fractional part rendered smaller so it reads as
    /// a detail rather than competing with it.
    private var styledAmount: Text {
        guard let currency else { return Text("—").font(font(size)) }
        let split = MoneyFormatter.formatSplit(amount, currency: currency, signStyle: signStyle)
        return Text(split.whole).font(font(size))
            + Text(split.fraction).font(font(size * 0.55))
    }
}
