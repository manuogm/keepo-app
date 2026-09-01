import KeepoCore
import SwiftUI

/// The two "tap this row to change it" controls the transaction form is
/// built from. Both follow the same rule, which is the point of having them
/// as a pair: **the row that displays the value is the row that changes
/// it**, with identical layout in both states. A `Picker` with a label on
/// the left and a grey value on the right would have meant the account you
/// are looking at and the account you are choosing look nothing alike.

/// An account, shown exactly as the Accounts list shows one — icon, name,
/// shared marker, Investment badge underneath.
struct AccountPickerRow: View {
    @Binding var selection: UUID?
    let accounts: [LocalAccountRow]
    var excluding: UUID?

    private var selected: LocalAccountRow? {
        accounts.first { $0.id == selection }
    }

    private var options: [LocalAccountRow] {
        accounts.filter { $0.id != excluding && $0.archivedAt == nil }
    }

    var body: some View {
        Menu {
            ForEach(options) { account in
                Button {
                    selection = account.id
                } label: {
                    if selection == account.id {
                        Label(account.name, systemImage: "checkmark")
                    } else {
                        Text(account.name)
                    }
                }
            }
        } label: {
            HStack(spacing: AppTheme.Spacing.s) {
                if let selected {
                    CategoryIconView(icon: selected.icon, color: Color(hex: selected.color))
                } else {
                    CategoryIconView(icon: "questionmark", color: AppTheme.Palette.textSecondary)
                }

                VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                    HStack(spacing: AppTheme.Spacing.xs) {
                        Text(selected?.name ?? "Choose account")
                            .font(AppTheme.Typography.labelEmphasis)
                            .foregroundStyle(
                                selected == nil ? AppTheme.Palette.textSecondary : AppTheme.Palette.textPrimary
                            )
                            .lineLimit(1)
                        if selected?.isShared == true {
                            SharedWithHouseholdIcon()
                        }
                    }
                    if selected?.kind == .investment {
                        InvestmentBadge()
                    }
                }

                Spacer(minLength: AppTheme.Spacing.xs)

                Image(systemName: "chevron.up.chevron.down")
                    .font(AppTheme.Typography.nanoEmphasis)
                    .foregroundStyle(AppTheme.Palette.textSecondary)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.pressableRow)
        .sensoryFeedback(AppTheme.Feedback.selection, trigger: selection)
    }
}

/// A category, shown as its icon and name. Only ever handed the categories
/// valid for the current kind — an expense can never be filed under an
/// income category (`sign_matches_category_kind` enforces that server-side
/// anyway, but offering the choice and then rejecting it would be a trap).
struct CategoryPickerRow: View {
    @Binding var selection: UUID?
    let categories: [PublicSchema.CategoriesSelect]

    private var selected: PublicSchema.CategoriesSelect? {
        categories.first { $0.id == selection }
    }

    private var pillFill: Color {
        guard let selected else { return AppTheme.Palette.bgSurfaceRaised }
        return Color(hex: selected.color).opacity(AppTheme.Opacity.fillStrong)
    }

    var body: some View {
        Menu {
            ForEach(categories, id: \.id) { category in
                Button {
                    selection = category.id
                } label: {
                    if selection == category.id {
                        Label(category.name, systemImage: "checkmark")
                    } else {
                        Text(category.name)
                    }
                }
            }
        } label: {
            HStack(spacing: AppTheme.Spacing.s) {
                CategoryIconView(category: selected, diameter: AppTheme.Size.glyph)
                Text(selected?.name ?? "Category")
                    // Same weight and size as the account name above it —
                    // they are peers in the hierarchy, both answering "which
                    // one", and typographic parity is what says so.
                    .font(AppTheme.Typography.labelEmphasis)
                    .foregroundStyle(selected == nil ? AppTheme.Palette.textSecondary : AppTheme.Palette.textPrimary)
                    .lineLimit(1)
            }
            .padding(.horizontal, AppTheme.Spacing.m)
            .padding(.vertical, AppTheme.Spacing.s)
            // Tinted with the category's own colour rather than a neutral
            // fill, so the pill and the icon inside it are visibly the same
            // thing. Low opacity, not the solid colour: the label has to stay
            // readable in both appearances, and a saturated chip would also
            // outshout the amount directly above it.
            .background(pillFill, in: RoundedRectangle(cornerRadius: AppTheme.Radius.card))
            .contentShape(Rectangle())
            // Same reason the transactions filter pills and
            // `FxRateWidget.quotePicker` opt out — see
            // `TransactionsListView.pillLabel` for the traced explanation.
            .transaction { $0.animation = nil }
        }
        .menuStyle(.button)
        .buttonStyle(.pressableCard)
        .sensoryFeedback(AppTheme.Feedback.selection, trigger: selection)
    }
}
