import KeepoCore
import SwiftUI

/// Which account the ledger is showing — "All accounts" over every live one,
/// each drawn exactly as the Accounts list draws it.
///
/// **A sheet rather than a `Menu`.** An account is recognised by its icon in
/// its own colour before its name is read, and a menu can only draw a
/// monochrome symbol — the old account menu listed plain text, which made
/// choosing between two similarly-named accounts a reading exercise. The rows
/// are `AccountRowView`, the same component the Accounts tab uses, so an
/// account looks like itself wherever it is offered and the balance beside it
/// is computed by the same code rather than a second copy.
///
/// One tap selects and dismisses, for the reason `CategoryPickerSheet` states:
/// the tap *is* the answer, and a Done button behind it asks the user to
/// confirm something they have already said.
struct AccountFilterSheet: View {
    @Binding var selection: UUID?
    let accounts: [LocalAccountRow]
    /// The figure the "All accounts" row carries, computed by the caller —
    /// the same net worth its chip shows, so the row the user is choosing
    /// between cannot disagree with the chip they chose it from.
    let allAccountsBalance: AccountFilterBalance?

    @Environment(\.dismiss) private var dismiss

    /// Archived accounts are left out for the reason every other picker
    /// leaves them out (`AccountPickerRow.options`): they are not somewhere
    /// money is moving any more. Their transactions are already out of the
    /// ledger too — `LocalTransactionRow`'s join drops them — so offering one
    /// here could only ever produce an empty list.
    private var options: [LocalAccountRow] {
        accounts.filter { $0.archivedAt == nil }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.Palette.bgCanvas.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: AppTheme.Spacing.s) {
                        allAccountsRow
                        ForEach(options) { account in
                            row(isSelected: selection == account.id) {
                                choose(account.id)
                            } content: {
                                AccountRowView(row: account)
                            }
                        }
                    }
                    .padding(AppTheme.Spacing.l)
                }
            }
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// First, not last: it is the answer the list is narrowed *from*, and the
    /// one someone comes back to this sheet to get back to.
    private var allAccountsRow: some View {
        row(isSelected: selection == nil) {
            choose(nil)
        } content: {
            AllAccountsRowView(balance: allAccountsBalance)
        }
    }

    private func row<Content: View>(
        isSelected: Bool, action: @escaping () -> Void, @ViewBuilder content: () -> Content
    ) -> some View {
        Button(action: action) {
            HStack(spacing: AppTheme.Spacing.s) {
                content()
                // Reserved whatever the state, so picking a different account
                // does not shuffle every name a checkmark's width sideways.
                Image(systemName: "checkmark")
                    .font(AppTheme.Typography.captionEmphasis)
                    .foregroundStyle(AppTheme.Palette.brandPrimary)
                    .opacity(isSelected ? 1 : 0)
                    .frame(width: AppTheme.Size.glyphSmall)
            }
            .padding(.horizontal, AppTheme.Spacing.l)
            .padding(.vertical, AppTheme.Spacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressableCard)
        .background(AppTheme.Palette.bgSurface, in: RoundedRectangle(cornerRadius: AppTheme.Radius.card))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func choose(_ accountId: UUID?) {
        selection = accountId
        dismiss()
    }
}

/// "All accounts", drawn to `AccountRowView`'s anatomy — leading disc, name,
/// balance on the trailing edge.
///
/// Shared by the two places that offer the answer "all of them": the ledger's
/// pinned account row and the picker sheet it opens. They sit one tap apart,
/// so a difference between them would be seen immediately — and the figure on
/// both is the same `AccountFilterBalance`, computed once by the screen.
struct AllAccountsRowView: View {
    let balance: AccountFilterBalance?

    var body: some View {
        HStack(spacing: AppTheme.Spacing.m) {
            // Not an account's own icon, because this is not an account: a
            // neutral disc holding a stack, in the same seat every account's
            // icon takes so the rows line up.
            CategoryIconView(icon: "rectangle.stack.fill", color: AppTheme.Palette.textSecondary)
            Text("All accounts")
                .font(AppTheme.Typography.body)
                .foregroundStyle(AppTheme.Palette.textPrimary)
                .lineLimit(1)
            Spacer(minLength: AppTheme.Spacing.s)
            // `—` for a figure that cannot be computed, never 0 (money rule
            // 5): one unresolvable rate is not a zero net worth.
            PrivateText(
                balance.map { MoneyFormatter.format($0.amountE4, currency: $0.currency) } ?? "—"
            )
            .font(AppTheme.Typography.bodyEmphasis)
            .foregroundStyle(AppTheme.Palette.textPrimary)
        }
        .padding(.vertical, AppTheme.Spacing.xs)
    }
}
