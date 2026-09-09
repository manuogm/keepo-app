import KeepoCore
import SwiftUI

/// Report screen one: what the household is worth, and what it is held in.
///
/// The two facts that are only true *because* there is a household. Every
/// other screen in the report is a list of things you already had; this is
/// the first time the two ledgers are one number.
struct HouseholdReportOverview: View {
    let snapshot: HouseholdSnapshot

    var body: some View {
        VStack(spacing: AppTheme.Spacing.l) {
            netWorthCard
            currencyCard
        }
    }

    private var netWorthCard: some View {
        HouseholdCard(
            title: "Household net worth",
            subtitle: "Everything the two of you share, in your base currency."
        ) {
            // `BalanceHeaderView` rather than a formatted string: it is where
            // the currency-symbol-first layout, the smaller fraction digits
            // and privacy mode all live, and money rule 5's `—` for an
            // uncomputable total comes with it.
            BalanceHeaderView(
                amount: snapshot.netWorthE4,
                currency: snapshot.baseCurrency,
                size: AppTheme.Typography.Number.balance
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var currencyCard: some View {
        HouseholdCard(
            title: "Currencies",
            subtitle: "What the household's money is actually held in."
        ) {
            if let slices = snapshot.currencySlices, !slices.isEmpty {
                VStack(spacing: AppTheme.Spacing.m) {
                    ForEach(slices) { slice in
                        row(slice)
                    }
                }
            } else {
                // Money rule 5, at list scale. One unresolvable rate makes
                // every share wrong, not one share missing — a percentage
                // taken against an incomplete total is a wrong number wearing
                // a percent sign.
                Text(
                    snapshot.currencySlices == nil
                        ? "—  Some balances can't be converted yet, so the split can't be worked out."
                        : "Nothing shared yet."
                )
                .font(AppTheme.Typography.caption)
                .foregroundStyle(AppTheme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row(_ slice: CurrencyExposureLocal) -> some View {
        HStack(spacing: AppTheme.Spacing.m) {
            CurrencyBadge(code: slice.currencyInfo.code)
            Spacer(minLength: AppTheme.Spacing.s)

            if let share = snapshot.share(of: slice) {
                Text(share.formatted(.percent.precision(.fractionLength(0))))
                    .font(AppTheme.Typography.Number.inline)
                    .foregroundStyle(AppTheme.Palette.textPrimary)
            } else {
                Text("—")
                    .font(AppTheme.Typography.Number.inline)
                    .foregroundStyle(AppTheme.Palette.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
