import KeepoCore
import SwiftUI

// One row of the Recurring list. Split out of RecurringRulesView.swift for
// the project's file-length lint, same precedent as TransactionRow.swift
// standing apart from TransactionsListView.swift — and for the same reason
// beyond the lint: the screen is about loading and ordering rules, the row is
// about drawing one.

/// One rule, drawn like one transaction — `TransactionRow`'s anatomy, with a
/// switch where the ledger has nothing.
///
/// Not `TransactionRow` itself: that row renders a
/// `TransactionsWithDetailsSelect`, and a rule is not a transaction row. What
/// the two share is every decision about how money is drawn — ledger sign
/// style, `PrivateText`, the base-currency line — and those are shared by
/// using the same components, not by forcing one type into the other's shape.
struct RecurringRuleRow: View {
    let rule: LocalRecurringRuleRow
    let isActive: Bool
    /// A write is in flight for this row. The switch stays put and stops
    /// accepting taps rather than bouncing between two truths.
    let isBusy: Bool
    let onToggle: (Bool) -> Void
    let onOpen: () -> Void

    @Environment(\.isPrivacyMode) private var isPrivacyMode

    var body: some View {
        HStack(spacing: AppTheme.Spacing.m) {
            // A `Button`, not `.onTapGesture`: a bare tap gesture inside a
            // `List` loses races with the scroll recogniser (the "first tap
            // does nothing after scrolling" bug) and draws no press state.
            // Deliberately only over the label, so the switch beside it is
            // not inside the tap target that opens the form.
            Button(action: onOpen) {
                HStack(spacing: AppTheme.Spacing.m) {
                    CategoryIconView(icon: rule.subject.icon, color: Color(hex: rule.subject.color))

                    // **Two rows pairing across, not two columns pairing
                    // down.** `TransactionRow` puts its label stack and its
                    // figure stack side by side, which works because it has
                    // three things in a row. This one has four: the switch
                    // costs about 60pt the ledger never spends, and with the
                    // figures in a column of their own the detail line was
                    // left roughly 144pt and truncated to "Euro Pot ·
                    // Monthly…" — losing the date, the single thing this
                    // screen knows that the ledger does not.
                    //
                    // Pairing across gives that line the whole label width
                    // minus one short figure, and it loses nothing: the
                    // amount still sits beside the name, the conversion
                    // still sits under the amount.
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                        HStack(spacing: AppTheme.Spacing.s) {
                            Text(rule.displayName)
                                .foregroundStyle(AppTheme.Palette.textPrimary)
                                .lineLimit(1)
                            Spacer(minLength: AppTheme.Spacing.xs)
                            PrivateText(formattedAmount)
                                .font(AppTheme.Typography.bodyEmphasis)
                                .monospacedDigit()
                                .foregroundStyle(amountColor)
                        }

                        // **The restated figure yields, and it yields by
                        // leaving rather than by shrinking.**
                        //
                        // Two earlier attempts at this line both failed on
                        // the foreign-currency row, which is the only one
                        // carrying a conversion at all. Giving the schedule
                        // `layoutPriority` wrapped the conversion to
                        // "$536.6 / 6" and made the row taller than its
                        // neighbour; making the conversion incompressible
                        // truncated the schedule back to "Euro Pot · Monthly
                        // · Sep…". Neither is acceptable: a money figure
                        // must not wrap or truncate, and the schedule is the
                        // one thing this screen knows that the ledger does
                        // not.
                        //
                        // There is simply not room for both at 402pt once
                        // the switch has taken its 60. So the conversion —
                        // which is the figure directly above it said again
                        // in another currency, and the only thing here that
                        // is a restatement rather than a fact — is dropped
                        // whole on a row that cannot fit it, and kept on
                        // every row that can.
                        ViewThatFits(in: .horizontal) {
                            detailRow(includingConversion: true)
                            detailRow(includingConversion: false)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressableRow)

            Toggle("", isOn: Binding(get: { isActive }, set: onToggle))
                .labelsHidden()
                .tint(AppTheme.Palette.statusPositive)
                .disabled(isBusy)
                .accessibilityLabel(isActive ? "Pause \(rule.displayName)" : "Resume \(rule.displayName)")
        }
        // `.m`, not the ledger row's `.xs`: `TransactionRow` sits inside a
        // `List`, which adds its own generous cell insets on top. These rows
        // are laid out by hand on a plain card, so the whole row height is
        // this number — at `.xs` the two rows sat about 8pt apart and read as
        // one block of text rather than two instructions.
        .padding(.vertical, AppTheme.Spacing.m)
        // The whole row dims when paused, the switch included — one state,
        // said once. A greyed amount alone (which is all this list used to
        // do) reads as a formatting quirk rather than as "this one is off".
        .opacity(isActive ? 1 : AppTheme.Opacity.muted)
        .animation(AppTheme.Motion.colorSafe, value: isActive)
    }

    /// The second line, with and without the restated figure — the two
    /// candidates `ViewThatFits` chooses between. Both keep the schedule
    /// whole; only the conversion differs, which is the whole point.
    @ViewBuilder
    private func detailRow(includingConversion: Bool) -> some View {
        HStack(spacing: AppTheme.Spacing.s) {
            // Two texts, so that when the line is too long it is the lead —
            // which account, and for a titled rule which category — that
            // gives way, and never the schedule, the one fact this screen
            // knows that the ledger does not.
            HStack(spacing: 0) {
                Text(detailLead)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(" · \(schedule)")
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .font(AppTheme.Typography.micro)
            .foregroundStyle(AppTheme.Palette.textSecondary)
            Spacer(minLength: AppTheme.Spacing.xs)
            if includingConversion, !isPrivacyMode {
                CurrencyConversionLabel(
                    nativeCurrency: rule.currencyInfo.code,
                    amountBase: rule.amountBaseE4,
                    baseCurrency: rule.baseCurrencyInfo?.code,
                    baseMinorUnit: rule.baseCurrencyInfo.map { Int16($0.minorUnit) },
                    hasMissingRate: rule.amountBaseE4 == nil,
                    signStyle: .ledger
                )
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    /// "Euro Pot · Monthly · 25 Sep" — account, how often, when next.
    ///
    /// **Three facts on one line, and the line is narrower than the ledger's.**
    /// This row spends about 60pt on its switch that `TransactionRow` does
    /// not, which leaves the label roughly 180pt. The first build of it read
    /// "Euro Pot · Every month · next 25 Sep" and truncated to "Euro Pot ·
    /// Every m…" on a 402pt phone — losing the schedule, which is the only
    /// thing this screen knows that the ledger does not. So the wording is
    /// the short form throughout: `shortLabel` rather than `everyLabel`, and
    /// a bare date rather than "next 25 Sep", since a rule's dates are all
    /// in the future and "next" was carrying no information the column
    /// header of the whole screen does not already give.
    ///
    /// A transfer leads with a lowercase "from", so the line reads on from
    /// the title: "Savings / from Current · Monthly · 2 Oct". The title
    /// names where the money lands, and without the preposition the row
    /// would be silent about which of the two accounts is which.
    ///
    /// **A titled rule moves its subject down here**, the same move
    /// `TransactionRow` makes: the title took the first line, and the
    /// category — or, for a transfer, the destination — is still a fact the
    /// row owes the reader. A titled transfer names both ends with an arrow,
    /// because the title no longer says where the money lands.
    private var detailLead: String {
        switch (rule.title != nil, rule.subject) {
        case (false, .transfer):
            return "from \(rule.accountName)"
        case (false, .category):
            return rule.accountName
        case (true, .transfer(let destination, _, _)):
            return "\(rule.accountName) → \(destination)"
        case (true, .category(let category, _, _)):
            return "\(category) · \(rule.accountName)"
        }
    }

    private var schedule: String {
        "\(rule.frequency.shortLabel) · \(nextDueLabel)"
    }

    /// Formatted in `utcCalendar` — the same calendar the due date was
    /// decoded in. `Date.formatted` would use the device's zone and render
    /// every rule a day early for anyone west of UTC (see
    /// `PostgresDate.dateOnlyLabel`).
    ///
    /// A date in the past is named as overdue rather than printed, because
    /// "12 Aug" on a screen the user is reading in October reads as a bug in
    /// the app rather than as materialization having fallen behind.
    ///
    /// A paused rule says so instead of naming a date: its `next_due_at` is
    /// still sitting there in the column, but it is not going to happen, and
    /// printing it would be the row promising something the switch beside it
    /// has switched off.
    private var nextDueLabel: String {
        guard isActive else { return "paused" }
        guard let date = rule.nextDueAt else { return "—" }
        // `PostgresDate.currentDateOnly`, never `utcCalendar.startOfDay(for:
        // Date())` — that is UTC's today, not the user's, so west of UTC
        // every rule due tomorrow read as "today" from mid-afternoon on, and
        // east of it a rule due today never said so. See that helper's own
        // note; this row is one of the two sites it was extracted for.
        guard let today = PostgresDate.currentDateOnly(in: utcCalendar) else {
            return PostgresDate.dateOnlyLabel(date, calendar: utcCalendar)
        }
        if date < today { return "overdue" }
        if date == today { return "today" }
        return PostgresDate.dateOnlyLabel(date, calendar: utcCalendar)
    }

    /// `.ledger`, exactly like the same money in the Transactions tab: an
    /// outflow drops its minus sign and an inflow gains an explicit `+`. The
    /// stored value is untouched (money rule 1) — the row already says which
    /// direction this goes by the category or the arrow beside it.
    private var formattedAmount: String {
        MoneyFormatter.format(rule.amountE4, currency: rule.currencyInfo, signStyle: .ledger)
    }

    /// Green means money arrives, by sign — the same rule `TransactionRow`
    /// applies, which is why a transfer's outflow is not green here either.
    private var amountColor: Color {
        rule.amountE4 > 0 ? AppTheme.Palette.statusPositive : AppTheme.Palette.textPrimary
    }
}
