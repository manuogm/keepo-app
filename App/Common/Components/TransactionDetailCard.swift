import KeepoCore
import SwiftUI

/// The bulk of a transaction, as one component with three shapes.
///
/// Expense and Income are structurally identical — an account + amount
/// block, then a category row and a wrapping row of tag chips; only which
/// categories are offered differs. A transfer gets the tag row too, under
/// its two legs: a transfer carries no category, so only an all-categories
/// tag can reach it, but that is the picker's rule to state rather than a
/// control to hide here. A transfer is two of the same account+amount blocks with the
/// direction of travel drawn down the left, because that is literally what
/// a transfer is: the same money leaving one container and arriving in
/// another. Building it out of the same subcomponent rather than a separate
/// transfer layout is what keeps the two legs looking like peers.
struct TransactionDetailCard: View {
    @Binding var fromAccountId: UUID?
    @Binding var toAccountId: UUID?
    @Binding var categoryId: UUID?
    @Binding var amountText: String
    @Binding var receivedAmountText: String

    /// The tags currently on this transaction, and the way into the picker.
    /// Held by the form (it is what Save writes), rendered here.
    @Binding var selectedTagIds: Set<UUID>
    let tagsById: [UUID: PublicSchema.TagsSelect]
    let onEditTags: () -> Void

    let accounts: [LocalAccountRow]
    let categories: [PublicSchema.CategoriesSelect]
    let isTransfer: Bool
    /// Only meaningful for a transfer, and only when the two accounts hold
    /// different currencies — otherwise the received amount is the sent
    /// amount and asking for it twice is asking the user to agree with
    /// themselves.
    let needsReceivedAmount: Bool

    var body: some View {
        if isTransfer {
            transferBody
        } else {
            ledgerBody
        }
    }

    /// One row of chips plus the add button, wrapping onto as many lines as
    /// it needs. Shown for **every** kind, transfers included — a transfer
    /// can carry an all-categories tag, and the picker is where that rule
    /// gets expressed rather than by hiding the control here.
    private var tagRow: some View {
        TagFlowLayout(spacing: AppTheme.Spacing.s) {
            ForEach(orderedSelectedTags, id: \.id) { tag in
                Button(action: onEditTags) { TagChip(name: tag.name) }
                    .buttonStyle(.pressableCard)
            }
            Button(action: onEditTags) { AddTagButton() }
                .buttonStyle(.pressableCard)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Resolved through `tagsById` and sorted by name, so the chips keep a
    /// stable order — a `Set` has none, and rendering it directly made the
    /// chips jump around every time one was toggled.
    private var orderedSelectedTags: [PublicSchema.TagsSelect] {
        selectedTagIds
            .compactMap { tagsById[$0] }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Expense / Income

    private var ledgerBody: some View {
        VStack(spacing: AppTheme.Spacing.m) {
            TransactionDetailContainer(
                accountId: $fromAccountId,
                amountText: $amountText,
                accounts: accounts,
                excluding: nil
            )

            HStack(spacing: AppTheme.Spacing.s) {
                CategoryPickerRow(selection: $categoryId, categories: categories)
                Spacer(minLength: 0)
            }

            tagRow
        }
    }

    // MARK: - Transfer

    /// The arrow rail runs down the left of both containers rather than
    /// sitting between them: a glyph in the gap reads as a divider, while a
    /// line that starts at one block and ends at the other reads as flow.
    private var transferBody: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.m) {
            transferLegs
            tagRow
        }
    }

    private var transferLegs: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.s) {
            FlowRail()
            VStack(spacing: AppTheme.Spacing.m) {
                TransactionDetailContainer(
                    accountId: $fromAccountId,
                    amountText: $amountText,
                    accounts: accounts,
                    excluding: toAccountId
                )
                TransactionDetailContainer(
                    accountId: $toAccountId,
                    // Same-currency transfers mirror the sent amount rather
                    // than offering a second field that can only ever hold
                    // the same number.
                    amountText: needsReceivedAmount ? $receivedAmountText : $amountText,
                    accounts: accounts,
                    excluding: fromAccountId,
                    isAmountEditable: needsReceivedAmount
                )
            }
        }
    }
}

/// One account + its amount. The account row on top doubles as the picker,
/// keeping the exact visual format it has when it is merely displaying —
/// the row does not turn into a different-looking control when tapped,
/// which is what lets the same component serve "showing" and "choosing".
struct TransactionDetailContainer: View {
    @Binding var accountId: UUID?
    @Binding var amountText: String
    let accounts: [LocalAccountRow]
    var excluding: UUID?
    var isAmountEditable = true

    private var selected: LocalAccountRow? {
        accounts.first { $0.id == accountId }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
            AccountPickerRow(selection: $accountId, accounts: accounts, excluding: excluding)

            AmountField(
                text: $amountText,
                currency: selected?.currencyInfo,
                isEnabled: isAmountEditable,
                size: AppTheme.Typography.Number.balance
            )
        }
        .padding(AppTheme.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Palette.bgSurfaceRaised, in: RoundedRectangle(cornerRadius: AppTheme.Radius.card))
    }
}

/// Money leaving the top block and arriving in the bottom one.
private struct FlowRail: View {
    var body: some View {
        VStack(spacing: 0) {
            Circle()
                .fill(AppTheme.Palette.fillStrong)
                .frame(width: AppTheme.Size.dot, height: AppTheme.Size.dot)
            Rectangle()
                .fill(AppTheme.Palette.fillStrong)
                .frame(width: 1.5)
                .frame(maxHeight: .infinity)
            Image(systemName: "arrowtriangle.down.fill")
                .font(AppTheme.Typography.nano)
                .foregroundStyle(AppTheme.Palette.fillStrong)
        }
        .padding(.vertical, AppTheme.Spacing.l)
        .accessibilityLabel("Money moves from the first account to the second")
    }
}
