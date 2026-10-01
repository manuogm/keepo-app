import KeepoCore
import SwiftUI

// One account + its amount, the block `TransactionDetailCard` and
// `TransferLegsView` are built from — split out of TransactionDetailCard.swift
// for the file-length lint.

/// Everything the "paid in another currency" half of an amount block needs,
/// as one value — parameters that are meaningless apart, and a single `nil`
/// for the ordinary case where the purchase was in the account's own
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
    /// The day whose rate produced `chargedText`. `nil` when no rate
    /// produced it — none resolved, or the figure is the user's own.
    let rateDate: Date?
    /// The lookup finished and found no rate for the pair and date. Kept
    /// apart from `rateDate == nil`, which is also true while a lookup is
    /// still running and would flash the warning on every keystroke.
    let isRateMissing: Bool
    let onPickCurrency: () -> Void
    /// Fetches fresh rates and re-derives the charge. Offered only while
    /// the rate is missing and the user has not typed the figure themselves.
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
    /// out — the charge below is still typed off a bank statement, so the
    /// calculator stays for that.
    var showsAmountCalculator = true
    /// Absent on a transfer, whose two legs are each already in their own
    /// account's currency — there is no third currency to name.
    var foreign: ForeignAmount?
    /// What is wrong with a figure in this block, if anything — the paid
    /// amount, or the charge beneath it, which the user reads as the same
    /// block. Drawn as a red wash over the block and one line under it,
    /// **there** rather than at the foot of the form: the mistake is in
    /// this block, so this is where the eye already is.
    var amountIssue: AmountIssue?
    /// Bumped by the form when Save is tapped at an amount already flagged.
    /// This block shakes on it only while it holds an issue — a transfer
    /// passes the same counter to both legs. A NEW issue needs no bump; the
    /// block shakes on its arrival by itself, and sways on the arrival of a
    /// missing rate (Save stays disabled while the charge is empty, so that
    /// one is never tapped at).
    var amountRejections = 0

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

    /// No rate, and nothing typed in its place. The moment the user enters
    /// the charge themselves there is nothing missing any more: their
    /// figure is what is stored, rate or no rate (money rule 6).
    private var showsRateWarning: Bool {
        guard isForeign, let foreign else { return false }
        return foreign.isRateMissing && foreign.chargedText.isEmpty
    }

    @State private var isRefreshingRates = false
    /// This block's own count of shakes, so a rejection meant for the other
    /// leg of a transfer leaves this one still.
    @State private var shakes = 0
    @State private var nudges = 0
    @State private var isCalculatorPresented = false
    /// Which of the two figures the one calculator fills by default: the
    /// one the user last typed into. See `calculatorTargets`.
    @State private var lastEdited: Figure = .paid

    private enum Figure {
        case paid, charged
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            block
                .modifier(ShakeEffect(rejections: shakes))
                .modifier(ShakeEffect(nudges: nudges))
            if let amountIssue {
                FormErrorText(message: amountIssue.message)
            }
            if showsRateWarning, let foreign, let paid = foreign.paidCurrencyCode, let account = selected?.currency {
                rateWarning(foreign, pair: "\(paid)/\(account)")
            }
        }
        // Turned away as soon as a problem arrives or changes kind — never
        // as one clears, which is the user fixing it — and again each time
        // Save is tapped at one already showing.
        .onChange(of: amountIssue) { old, new in
            if new != nil && new != old { shake() }
        }
        .onChange(of: showsRateWarning) { _, shows in
            if shows { nudge() }
        }
        .onChange(of: amountRejections) {
            if amountIssue != nil { shake() }
        }
        .sensoryFeedback(AppTheme.Feedback.rejection, trigger: shakes)
        .sensoryFeedback(AppTheme.Feedback.warning, trigger: nudges)
        .sheet(isPresented: $isCalculatorPresented) {
            CalculatorSheet(targets: calculatorTargets.map(\.target), initialTarget: calculatorStart)
        }
    }

    private func shake() {
        withAnimation(AppTheme.Motion.reject) { shakes += 1 }
    }

    private func nudge() {
        withAnimation(AppTheme.Motion.nudge) { nudges += 1 }
    }

    private var block: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
            // The picker is the amount's header: a figure shown in full on a
            // line of its own sends the currency pill and calculator up into
            // this row, and the account's name gives up the width.
            //
            // **One calculator per block**, at its bottom-right: on this
            // field until the charge appears beneath it, then on the charge,
            // where it fills either figure (`calculatorTargets`).
            AmountField(
                text: edits(.paid, $amountText),
                currency: paidCurrency,
                isEnabled: isAmountEditable,
                onPickCurrency: foreign?.onPickCurrency,
                showsCalculator: showsAmountCalculator && !isForeign,
                size: AppTheme.Typography.Number.balance
            ) {
                AccountPickerRow(selection: $accountId, accounts: accounts, excluding: excluding)
            }

            if isForeign, let foreign {
                chargedBlock(foreign)
            }
        }
        .padding(AppTheme.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            let shape = RoundedRectangle(cornerRadius: AppTheme.Radius.card)
            shape.fill(AppTheme.Palette.bgSurfaceRaised)
                .overlay {
                    // A wrong figure outranks a missing rate: red is the
                    // thing to fix first.
                    shape.fill(amountIssue == nil ? AppTheme.Palette.statusWarning : AppTheme.Palette.statusNegative)
                        .opacity(amountIssue == nil && !showsRateWarning ? 0 : AppTheme.Opacity.fill)
                }
                // Scoped to the wash: on the block itself this would
                // animate the text field and the chip along with it.
                .animation(AppTheme.Motion.colorSafe, value: amountIssue == nil)
                .animation(AppTheme.Motion.colorSafe, value: showsRateWarning)
        }
    }

    /// The figure's binding, noting which field the user typed into. A
    /// `Binding` setter runs only when the control writes — a derived charge
    /// assigned by the form never trips it — so this is "typed", exactly.
    private func edits(_ figure: Figure, _ text: Binding<String>) -> Binding<String> {
        Binding(
            get: { text.wrappedValue },
            set: {
                text.wrappedValue = $0
                lastEdited = figure
            }
        )
    }

    /// **The caption carries the provenance.** Which rate produced this
    /// figure is what decides whether the user accepts the number or
    /// replaces it with what their bank actually charged (money rule 6), so
    /// it belongs in the line that introduces the figure. With no rate it
    /// says only what the figure is — the warning under the block already
    /// says the rest.
    private func chargedBlock(_ foreign: ForeignAmount) -> some View {
        AmountField(
            text: edits(.charged, foreign.$chargedText),
            currency: selected?.currencyInfo,
            onCalculator: { isCalculatorPresented = true },
            size: AppTheme.Typography.Number.metricCompact,
            headerSpacing: AppTheme.Spacing.xxs,
            header: {
                Text(chargedCaption(foreign))
                    .font(AppTheme.Typography.nano)
                    .foregroundStyle(AppTheme.Palette.textSecondary)
                    .lineLimit(1)
            }
        )
        .padding(.top, AppTheme.Spacing.xs)
    }

    private func chargedCaption(_ foreign: ForeignAmount) -> String {
        guard let rateDate = foreign.rateDate else { return "Charged to account" }
        return "Charged to account based on \(PostgresDate.dateOnlyLabel(rateDate, calendar: .current)) Rate"
    }

    /// Says plainly that there is no number rather than showing a zero
    /// (money rule 5), and names the actual pair, because "no rate" on its
    /// own reads as a fault in the app rather than a gap in the ECB's table
    /// for the two currencies this purchase happens to span. The way out
    /// sits right beside the problem it fixes.
    private func rateWarning(_ foreign: ForeignAmount, pair: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.xs) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(AppTheme.Palette.statusWarning)
            Text("\(pair) rate not available")
                .foregroundStyle(AppTheme.Palette.textSecondary)
            refreshRatesButton(foreign)
                .padding(.leading, AppTheme.Spacing.xs)
        }
        .font(AppTheme.Typography.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

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
                    .font(AppTheme.Typography.captionEmphasis)
                    .foregroundStyle(AppTheme.Palette.brandPrimary)
            }
        }
        .buttonStyle(.plain)
        .disabled(isRefreshingRates)
    }

    // MARK: - The one calculator

    /// Both figures when both can be worked out; the charge alone on a
    /// capture, whose paid figure is the Wallet's and not the user's.
    private var calculatorTargets: [(figure: Figure, target: CalculatorTarget)] {
        guard let foreign, let account = selected?.currencyInfo else { return [] }
        let charged = CalculatorTarget(
            label: "Charged · \(account.code)", minorUnit: account.minorUnit, initialText: foreign.chargedText
        ) { result in
            foreign.chargedText = result
            lastEdited = .charged
        }
        guard showsAmountCalculator && isAmountEditable, let paid = paidCurrency else {
            return [(.charged, charged)]
        }
        let paidTarget = CalculatorTarget(
            label: "Paid · \(paid.code)", minorUnit: paid.minorUnit, initialText: amountText
        ) { result in
            amountText = result
            lastEdited = .paid
        }
        return [(.paid, paidTarget), (.charged, charged)]
    }

    private var calculatorStart: Int {
        calculatorTargets.firstIndex { $0.figure == lastEdited } ?? 0
    }
}
