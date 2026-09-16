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
    /// Only ever set for expense/income. A transfer's legs are each already
    /// in their own account's currency, so there is no third one to name —
    /// `needsReceivedAmount` below is that case, and it predates this.
    var foreign: ForeignAmount?
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
                excluding: nil,
                foreign: foreign
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

/// Everything the "paid in another currency" half of an amount block needs,
/// as one value — five parameters that are meaningless apart, and a single
/// `nil` for the ordinary case where the purchase was in the account's own
/// currency and none of this is drawn.
struct ForeignAmount {
    /// What the big figure is in. `nil` means the account's own currency,
    /// so the common entry carries no extra state at all — the chip simply
    /// shows the account's code and nothing below it appears.
    @Binding var paidCurrencyCode: String?
    /// The account-currency figure: prefilled from the rate, and **always
    /// editable**, which is the whole basis of money rule 6. Keepo's ECB
    /// reference rate is not what Visa or Revolut charged, and a balance is
    /// a running sum — so the user gets to replace an estimate with the
    /// real figure off their bank app.
    @Binding var chargedText: String
    let currencies: [CurrencyInfo]
    /// The day whose rate produced `chargedText`. `nil` means no rate could
    /// be resolved for that pair and date — money rule 5, so the field is
    /// left empty for the user to fill rather than guessed at.
    let rateDate: Date?
    let onPickCurrency: () -> Void
}

/// One account + its amount. The account row on top doubles as the picker,
/// keeping the exact visual format it has when it is merely displaying —
/// the row does not turn into a different-looking control when tapped,
/// which is what lets the same component serve "showing" and "choosing".
///
/// **The big figure is what was paid; the small one is what the account was
/// charged.** They are the same number for almost every transaction ever
/// entered, and then the block looks exactly as it always has. Pick another
/// currency from the chip and the second field appears underneath, so the
/// mental model is the same on all three surfaces this card serves —
/// capture review, edit, and manual entry.
struct TransactionDetailContainer: View {
    @Binding var accountId: UUID?
    @Binding var amountText: String
    let accounts: [LocalAccountRow]
    var excluding: UUID?
    var isAmountEditable = true
    /// Absent on a transfer, whose two legs are each already in their own
    /// account's currency — there is no third currency to name.
    var foreign: ForeignAmount?

    private var selected: LocalAccountRow? {
        accounts.first { $0.id == accountId }
    }

    /// What the big figure is in — the chosen currency when there is one,
    /// the account's otherwise.
    private var paidCurrency: CurrencyInfo? {
        guard let foreign, let code = foreign.paidCurrencyCode else { return selected?.currencyInfo }
        return foreign.currencies.first { $0.code == code } ?? selected?.currencyInfo
    }

    private var isForeign: Bool {
        guard let account = selected, let code = foreign?.paidCurrencyCode else { return false }
        return code != account.currency
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
            AccountPickerRow(selection: $accountId, accounts: accounts, excluding: excluding)

            AmountField(
                text: $amountText,
                currency: paidCurrency,
                isEnabled: isAmountEditable,
                onPickCurrency: foreign?.onPickCurrency,
                size: AppTheme.Typography.Number.balance
            )

            if isForeign, let foreign {
                chargedBlock(foreign)
            }
        }
        .padding(AppTheme.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Palette.bgSurfaceRaised, in: RoundedRectangle(cornerRadius: AppTheme.Radius.card))
    }

    /// Named after the account rather than the currency — "Charged to A
    /// Dollars" is the sentence the figure completes, and it is the account
    /// the user is reconciling against, not an abstract currency.
    private func chargedBlock(_ foreign: ForeignAmount) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
            Text("Charged to \(selected?.name ?? "this account")")
                .font(AppTheme.Typography.nano)
                .foregroundStyle(AppTheme.Palette.textSecondary)

            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.s) {
                AmountField(
                    text: foreign.$chargedText,
                    currency: selected?.currencyInfo,
                    size: AppTheme.Typography.Number.metricCompact
                )
                Spacer(minLength: 0)
                Text(rateNote(foreign))
                    .font(AppTheme.Typography.nano)
                    .foregroundStyle(AppTheme.Palette.textSecondary)
                    .multilineTextAlignment(.trailing)
            }
        }
        .padding(.top, AppTheme.Spacing.xs)
    }

    /// Says where the number came from, so replacing it is an obvious thing
    /// to do — and says plainly when there is no number at all rather than
    /// showing a zero (money rule 5).
    private func rateNote(_ foreign: ForeignAmount) -> String {
        guard let rateDate = foreign.rateDate else { return "No rate — enter what you were charged" }
        return "Rate \(PostgresDate.dateOnlyLabel(rateDate, calendar: .current))"
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
