import KeepoCore
import SwiftUI

/// One account in the Accounts list. Split out of `AccountsListView` so that
/// screen can stay focused on the drag/drop model.
///
/// The `Investment` badge sits beside the name, compacted to "Inv." — this
/// row is the tightest space it appears in, sharing the line with the name
/// and racing the balance on the trailing edge. Shared/mapped-card status
/// moves to its own row underneath instead, appearing only when applicable,
/// so a plain unshared account with no card contributes no second line at
/// all.
struct AccountRowView: View {
    let row: LocalAccountRow

    @Environment(\.isPrivacyMode) private var isPrivacyMode

    var body: some View {
        HStack(spacing: AppTheme.Spacing.m) {
            CategoryIconView(icon: row.icon, color: Color(hex: row.color))

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                HStack(spacing: AppTheme.Spacing.xs) {
                    Text(row.name)
                        .font(AppTheme.Typography.body)
                        .foregroundStyle(
                            row.archivedAt == nil ? AppTheme.Palette.textPrimary : AppTheme.Palette.textSecondary
                        )
                        .lineLimit(1)
                    if row.kind == .investment {
                        InvestmentBadge(compact: true)
                    }
                }
                if row.hasMappedCard || row.isShared {
                    HStack(spacing: AppTheme.Spacing.xs) {
                        if row.hasMappedCard {
                            MappedCardIcon()
                        }
                        if row.isShared {
                            SharedWithHouseholdIcon()
                        }
                    }
                }
            }

            Spacer(minLength: AppTheme.Spacing.s)

            VStack(alignment: .trailing, spacing: AppTheme.Spacing.xxs) {
                PrivateText(formattedBalance)
                    .font(AppTheme.Typography.bodyEmphasis)
                    .monospacedDigit()
                    .foregroundStyle(AppTheme.Palette.textPrimary)
                    .contentTransition(.numericText())
                if !isPrivacyMode {
                    CurrencyConversionLabel(
                        nativeCurrency: row.currency, amountBase: row.balanceBaseE4,
                        baseCurrency: row.baseCurrencyInfo?.code,
                        baseMinorUnit: row.baseCurrencyInfo.map { Int16($0.minorUnit) },
                        hasMissingRate: row.balanceE4 != nil && row.balanceBaseE4 == nil
                    )
                }
            }
        }
        .padding(.vertical, AppTheme.Spacing.xs)
    }

    private var formattedBalance: String {
        MoneyFormatter.format(row.balanceE4, currency: row.currencyInfo)
    }
}

/// The group header — "Everyday" / "Investments" plus that group's subtotal,
/// tappable to collapse. Also the boundary that makes a drag across groups
/// mean "convert this account's kind": an account landing anywhere below
/// this header belongs to it (see `AccountsListView+Reorder`). It draws no
/// background of its own — the accounts underneath are the cards, and a
/// header that also looked like one would blur exactly the distinction the
/// drag model depends on.
struct AccountGroupHeaderRow: View {
    let title: String
    let subtitle: String
    @Binding var isExpanded: Bool

    @Environment(\.isPrivacyMode) private var isPrivacyMode

    var body: some View {
        Button {
            withAnimation(AppTheme.Motion.standard) { isExpanded.toggle() }
        } label: {
            HStack {
                Text(title)
                    .font(AppTheme.Typography.rowTitle)
                Spacer()
                PrivateText(subtitle)
                    .font(AppTheme.Typography.label)
                    .monospacedDigit()
                    .foregroundStyle(AppTheme.Palette.textSecondary)
                Image(systemName: "chevron.down")
                    .font(AppTheme.Typography.microEmphasis)
                    .foregroundStyle(AppTheme.Palette.textSecondary)
                    .rotationEffect(.degrees(isExpanded ? 0 : -90))
            }
            .padding(.vertical, AppTheme.Spacing.xxs)
        }
        .buttonStyle(.pressableRow)
        .sensoryFeedback(AppTheme.Feedback.selection, trigger: isExpanded)
    }
}
