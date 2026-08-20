import KeepoCore
import SwiftUI

/// The bulk of a transaction, as one component with three shapes.
///
/// Expense and Income are structurally identical — an account + amount
/// block, then a category and tag row; only which categories are offered
/// differs. A transfer is two of the same account+amount blocks with the
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

    // MARK: - Expense / Income

    private var ledgerBody: some View {
        VStack(spacing: 12) {
            TransactionDetailContainer(
                accountId: $fromAccountId,
                amountText: $amountText,
                accounts: accounts,
                excluding: nil
            )

            HStack(spacing: 10) {
                CategoryPickerRow(selection: $categoryId, categories: categories)
                AddTagPlaceholder()
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Transfer

    /// The arrow rail runs down the left of both containers rather than
    /// sitting between them: a glyph in the gap reads as a divider, while a
    /// line that starts at one block and ends at the other reads as flow.
    private var transferBody: some View {
        HStack(alignment: .top, spacing: 10) {
            FlowRail()
            VStack(spacing: 12) {
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
        VStack(alignment: .leading, spacing: 10) {
            AccountPickerRow(selection: $accountId, accounts: accounts, excluding: excluding)

            AmountField(
                text: $amountText,
                currency: selected?.currencyInfo,
                isEnabled: isAmountEditable,
                size: 40
            )
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}

/// Money leaving the top block and arriving in the bottom one.
private struct FlowRail: View {
    var body: some View {
        VStack(spacing: 0) {
            Circle()
                .fill(Color.secondary.opacity(0.35))
                .frame(width: 7, height: 7)
            Rectangle()
                .fill(Color.secondary.opacity(0.25))
                .frame(width: 1.5)
                .frame(maxHeight: .infinity)
            Image(systemName: "arrowtriangle.down.fill")
                .font(.system(size: 9))
                .foregroundStyle(Color.secondary.opacity(0.45))
        }
        .padding(.vertical, 20)
        .accessibilityLabel("Money moves from the first account to the second")
    }
}

/// Tags do not exist in the schema yet — this is the placeholder the design
/// calls for, rendered as a genuinely inert chip rather than a button that
/// does nothing. A tappable control that silently no-ops is worse than an
/// obviously-not-ready one.
struct AddTagPlaceholder: View {
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "plus")
                .font(.caption.weight(.semibold))
            Text("Add Tag")
                .font(.subheadline)
        }
        .foregroundStyle(Color.secondary.opacity(0.6))
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
        .accessibilityHidden(true)
    }
}
