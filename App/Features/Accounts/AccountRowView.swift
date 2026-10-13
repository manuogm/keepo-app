import KeepoCore
import SwiftUI

/// One account in the Accounts list. Split out of `AccountsListView` so that
/// screen can stay focused on the drag/drop model.
///
/// The household marker and the `Investment` badge follow the name on one
/// line — the badge compacted to "Inv." because this row is the tightest
/// space they appear in, racing the balance on the trailing edge. They are
/// small fixed-size views, so the name is what truncates, never them. Whether
/// a card is mapped is not shown here; the account form carries it.
struct AccountRowView: View {
    let row: LocalAccountRow
    /// Requested changes to draw over this row, set only by the Sync Conflict
    /// sheet's "Your change" card — see `TransactionRow.edits`. For `.kind`
    /// the value is the requested type's badge text, `nil` for none.
    var edits: [Part: String?] = [:]
    /// The balance in full rather than its short form — the Sync Conflict
    /// sheet, where two versions of one figure sit side by side.
    var showsExactBalance = false

    /// What `edits` can change.
    enum Part: Hashable {
        case name, kind, balance
    }

    @Environment(\.isPrivacyMode) private var isPrivacyMode

    private var nameColor: Color {
        row.archivedAt == nil ? AppTheme.Palette.textPrimary : AppTheme.Palette.textSecondary
    }

    var body: some View {
        HStack(spacing: AppTheme.Spacing.m) {
            CategoryIconView(icon: row.icon, color: Color(hex: row.color))

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                HStack(spacing: AppTheme.Spacing.xs) {
                    name
                        .font(AppTheme.Typography.body)
                        .lineLimit(1)
                    if row.isShared {
                        // Added to the name's own `xs`, so the marker stands
                        // apart from the name rather than reading as part of it.
                        SharedWithHouseholdIcon()
                            .padding(.leading, AppTheme.Spacing.xs)
                    }
                    kindBadge
                }
            }

            Spacer(minLength: AppTheme.Spacing.s)

            VStack(alignment: .trailing, spacing: AppTheme.Spacing.xxs) {
                if let edit = edits[.balance] {
                    balanceEdit(edit)
                } else {
                    PrivateText(formattedBalance(exact: showsExactBalance), spoken: formattedBalance(exact: true))
                        .font(AppTheme.Typography.bodyEmphasis)
                        .monospacedDigit()
                        .foregroundStyle(AppTheme.Palette.textPrimary)
                        .contentTransition(.numericText())
                }
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

    /// The name as saved, or struck through in red with the requested one
    /// after it — the same treatment `TransactionRow` gives its parts.
    private var name: Text {
        guard let edit = edits[.name] else { return Text(row.name).foregroundStyle(nameColor) }
        let negative = AppTheme.Palette.statusNegative
        let struck = Text(row.name).strikethrough(color: negative).foregroundStyle(negative)
        guard let requested = edit else { return struck }
        return struck + Text(" ")
            + Text(requested).foregroundStyle(AppTheme.Palette.brandPrimary).fontWeight(.semibold)
    }

    /// The Investment badge: struck through when a change takes it away,
    /// drawn in the brand colour when a change adds it.
    @ViewBuilder
    private var kindBadge: some View {
        if let edit = edits[.kind] {
            if row.kind == .investment {
                InvestmentBadge(compact: true).strikethrough(color: AppTheme.Palette.statusNegative)
            }
            if edit != nil {
                InvestmentBadge(compact: true, isHighlighted: true)
            }
        } else if row.kind == .investment {
            InvestmentBadge(compact: true)
        }
    }

    private func balanceEdit(_ requested: String?) -> some View {
        // Stacked rather than side by side: two exact figures in a row take
        // the width the name and account need.
        VStack(alignment: .trailing, spacing: AppTheme.Spacing.xxs) {
            if let requested {
                PrivateText(requested)
                    .font(AppTheme.Typography.bodyEmphasis)
                    .foregroundStyle(AppTheme.Palette.brandPrimary)
            }
            PrivateText(formattedBalance(exact: true))
                .font(requested == nil ? AppTheme.Typography.bodyEmphasis : AppTheme.Typography.micro)
                .strikethrough(color: AppTheme.Palette.statusNegative)
                .foregroundStyle(AppTheme.Palette.statusNegative)
        }
        .monospacedDigit()
    }

    /// `exact` is the VoiceOver reading.
    private func formattedBalance(exact: Bool = false) -> String {
        MoneyFormatter.format(row.balanceE4, currency: row.currencyInfo, exact: exact)
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
    /// The exact subtotal behind a short one, for VoiceOver.
    var spokenSubtitle: String?
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
                PrivateText(subtitle, spoken: spokenSubtitle)
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
