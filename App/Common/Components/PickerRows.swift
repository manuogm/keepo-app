import KeepoCore
import SwiftUI

/// The "tap this row to change it" control the transaction form is built
/// from. It follows one rule: **the row that displays the value is the row
/// that changes it**, with identical layout in both states. A `Picker` with
/// a label on the left and a grey value on the right would have meant the
/// account you are looking at and the account you are choosing look nothing
/// alike.
///
/// Its category counterpart used to live here and was a second copy of the
/// same idea. It is now `CategorySuggestionRow` — three ranked chips rather
/// than a menu — because the two questions turned out not to be the same
/// one: an account is picked from a handful the user can see at a glance,
/// a category from dozens where three of them cover most days.

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
