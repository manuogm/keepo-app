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
    /// Up to three, most-used first, for the account and kind on screen —
    /// `LocalCategoryRanking`. Empty is fine and simply means the row
    /// draws nothing but "More": a ledger with no history has no habits to
    /// read off it yet.
    let suggestedCategories: [PublicSchema.CategoriesSelect]
    let isTransfer: Bool
    /// What the transfer's DESTINATION picker may offer, when that is
    /// narrower than `accounts`. `nil` — the transaction form's case — means
    /// the same list on both ends. The recurring form passes a filtered one,
    /// because a rule's two accounts must share an owner and a currency
    /// (migration 20260927100000).
    var destinationAccounts: [LocalAccountRow]?
    /// Only ever set for expense/income. A transfer's legs are each already
    /// in their own account's currency, so there is no third one to name —
    /// `needsReceivedAmount` below is that case, and it predates this.
    var foreign: ForeignAmount?
    /// Off for a captured transaction — see `TransactionDetailContainer
    /// .showsAmountCalculator`. Transfers never carry it: a transfer is
    /// always hand-entered.
    var showsAmountCalculator = true
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
                showsAmountCalculator: showsAmountCalculator,
                foreign: foreign
            )

            CategorySuggestionRow(
                selection: $categoryId, suggestions: suggestedCategories, categories: categories
            )

            tagRow
        }
    }

    // MARK: - Transfer

    private var transferBody: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.m) {
            TransferLegsView(
                fromAccountId: $fromAccountId,
                toAccountId: $toAccountId,
                amountText: $amountText,
                receivedAmountText: $receivedAmountText,
                accounts: accounts,
                destinationAccounts: destinationAccounts,
                needsReceivedAmount: needsReceivedAmount,
                showsAmountCalculator: showsAmountCalculator
            )
            tagRow
        }
    }
}

/// Two account+amount blocks with the direction of travel drawn down their
/// left — what a transfer literally is, and the shape both forms that can
/// create one are built from.
///
/// Extracted from `TransactionDetailCard` when recurring transfers landed:
/// the rule form asks the same question (out of which account, into which,
/// how much) and had no business answering it with its own layout. What the
/// two forms do NOT share is the card around this — a transaction carries
/// tags and a note, a rule carries a frequency — so the legs are the
/// component and the card is not.
///
/// The arrow rail runs down the left of both containers rather than sitting
/// between them: a glyph in the gap reads as a divider, while a line that
/// starts at one block and ends at the other reads as flow.
struct TransferLegsView: View {
    @Binding var fromAccountId: UUID?
    @Binding var toAccountId: UUID?
    @Binding var amountText: String
    @Binding var receivedAmountText: String

    let accounts: [LocalAccountRow]
    /// What the DESTINATION picker may offer, when that is narrower than
    /// `accounts`. `nil` — the transaction form's case — means the same list
    /// on both ends.
    ///
    /// A recurring transfer is the case this exists for: the server restricts
    /// one to two accounts of the same owner in the same currency (migration
    /// 20260927100000), so the rule form hands a filtered list rather than
    /// offering a destination the save would then refuse.
    var destinationAccounts: [LocalAccountRow]?
    /// Only meaningful when the two accounts hold different currencies —
    /// otherwise the received amount is the sent amount and asking for it
    /// twice is asking the user to agree with themselves.
    let needsReceivedAmount: Bool
    /// Off for a recurring transfer, whose amount comes from the rule rather
    /// than from a purchase that needs working out.
    var showsAmountCalculator = true

    var body: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.s) {
            FlowRail()
            VStack(spacing: AppTheme.Spacing.m) {
                TransactionDetailContainer(
                    accountId: $fromAccountId,
                    amountText: $amountText,
                    accounts: accounts,
                    excluding: toAccountId,
                    showsAmountCalculator: showsAmountCalculator
                )
                TransactionDetailContainer(
                    accountId: $toAccountId,
                    // Same-currency transfers mirror the sent amount rather
                    // than offering a second field that can only ever hold
                    // the same number.
                    amountText: needsReceivedAmount ? $receivedAmountText : $amountText,
                    accounts: destinationAccounts ?? accounts,
                    excluding: fromAccountId,
                    isAmountEditable: needsReceivedAmount,
                    showsAmountCalculator: showsAmountCalculator
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
    /// Fetches fresh rates and re-derives the charge. Offered only in the
    /// no-rate case, and only while the user has not already typed the
    /// figure themselves — see `chargedBlock`.
    let onRefreshRates: () async -> Void
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
    /// Off for a captured transaction. The paid figure came out of the
    /// Wallet automation's `Amount` string, so there is nothing to work
    /// out — and the charged field below keeps its own calculator either
    /// way, because that one IS typed, off a bank statement.
    var showsAmountCalculator = true
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

    @State private var isRefreshingRates = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
            AccountPickerRow(selection: $accountId, accounts: accounts, excluding: excluding)

            AmountField(
                text: $amountText,
                currency: paidCurrency,
                isEnabled: isAmountEditable,
                onPickCurrency: foreign?.onPickCurrency,
                showsCalculator: showsAmountCalculator,
                size: AppTheme.Typography.Number.balance
            )

            // Both codes are non-nil whenever `isForeign` is — unwrapping
            // them here rather than inside the block is what lets the
            // no-rate caption name the actual pair instead of a fallback.
            if isForeign, let foreign, let paid = foreign.paidCurrencyCode, let account = selected?.currency {
                chargedBlock(foreign, paidCode: paid, accountCode: account)
            }
        }
        .padding(AppTheme.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Palette.bgSurfaceRaised, in: RoundedRectangle(cornerRadius: AppTheme.Radius.card))
    }

    /// **The caption carries the provenance, not a note off the right
    /// edge.** Which rate produced this figure — or that none could be
    /// found — is what decides whether the user accepts the number or
    /// replaces it with what their bank actually charged (money rule 6), so
    /// it belongs in the line that introduces the figure rather than
    /// trailing it. The account's name comes out with it: the picker row
    /// naming the account sits directly above, and repeating it here spent
    /// the caption on something already on screen.
    private func chargedBlock(_ foreign: ForeignAmount, paidCode: String, accountCode: String) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.s) {
                Text(chargedCaption(foreign, paidCode: paidCode, accountCode: accountCode))
                    .font(AppTheme.Typography.nano)
                    .foregroundStyle(AppTheme.Palette.textSecondary)
                if foreign.rateDate == nil && foreign.chargedText.isEmpty {
                    Spacer(minLength: 0)
                    refreshRatesButton(foreign)
                }
            }

            AmountField(
                text: foreign.$chargedText,
                currency: selected?.currencyInfo,
                size: AppTheme.Typography.Number.metricCompact
            )
        }
        .padding(.top, AppTheme.Spacing.xs)
    }

    /// Says where the number came from, and says plainly when there is no
    /// number at all rather than showing a zero (money rule 5). The no-rate
    /// wording names the actual pair, because "no rate" on its own reads as
    /// a fault in the app rather than a gap in the ECB's table for the two
    /// currencies this particular purchase happens to span.
    private func chargedCaption(_ foreign: ForeignAmount, paidCode: String, accountCode: String) -> String {
        guard let rateDate = foreign.rateDate else { return "\(paidCode)/\(accountCode) rate not available" }
        return "Charged to account based on \(PostgresDate.dateOnlyLabel(rateDate, calendar: .current)) Rate"
    }

    /// Only ever drawn when there is no rate **and** the field is still
    /// empty. A rate that resolved needs no refreshing, and once the user
    /// has typed what their bank charged, that figure is theirs — a fresh
    /// rate would not be allowed to replace it (money rule 6), so offering
    /// to fetch one would be offering a button that changes nothing.
    private func refreshRatesButton(_ foreign: ForeignAmount) -> some View {
        Button {
            Task {
                isRefreshingRates = true
                await foreign.onRefreshRates()
                isRefreshingRates = false
            }
        } label: {
            if isRefreshingRates {
                ProgressView()
            } else {
                Text("Refresh FX rates")
                    .font(AppTheme.Typography.nanoEmphasis)
                    .foregroundStyle(AppTheme.Palette.brandPrimary)
            }
        }
        .buttonStyle(.plain)
        .disabled(isRefreshingRates)
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
