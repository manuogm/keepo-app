import KeepoCore
import SwiftUI

/// Transactions Next 2 Weeks — 2×2 collapsed, 4×2 expanded.
///
/// Collapsed: what the next fortnight nets out to, how many payments each way
/// make it up, and the fourteen days themselves as a strip of rings — so the
/// tile answers "am I about to be up or down" and "when" without opening.
///
/// Expanded: the same carousel becomes interactive. Tapping a day lists it;
/// tapping an entry opens the rule behind it.
///
/// Every figure here is **signed** and stays that way (money rule 1) — which
/// is what lets the headline be a net rather than a total of outflows. A
/// fortnight containing a salary can legitimately be positive, and the old
/// expense-only version of this widget could not say so.
///
/// Nothing here is a transaction yet. Recurring rules project occurrences at
/// read time and only `materialize_recurring()` ever turns a due one into a
/// real row — so these are forecasts, and the rule is the only thing there is
/// to open.
struct UpcomingBillsWidget: View {
    let metrics: UpcomingTransactionsMetrics?
    let currency: CurrencyInfo?
    let isExpanded: Bool
    /// Asks the canvas to open a recurring rule's form. The canvas owns the
    /// sheet because it owns the session — a widget that presented its own
    /// would need one, and the catalogue draws these same widgets with no
    /// session at all.
    let openRule: (String) -> Void
    let onTap: () -> Void

    @State private var selectedDay: Date?

    var body: some View {
        WidgetChrome(
            title: DashboardWidgetKind.upcomingBills.title,
            guide: isExpanded ? DashboardWidgetKind.upcomingBills.guide : nil,
            onTap: onTap
        ) {
            if let metrics, !metrics.items.isEmpty {
                if isExpanded {
                    expanded(metrics)
                } else {
                    collapsed(metrics)
                }
            } else {
                WidgetEmptyState(
                    systemImage: "calendar.badge.checkmark",
                    message: "Nothing due in the next two weeks."
                )
            }
        }
        .onChange(of: isExpanded) { _, expanded in
            if !expanded { selectedDay = nil }
        }
    }

    // MARK: - Collapsed

    /// The net for the fortnight, what makes it up, and the days it lands on.
    ///
    /// This used to be a single cramped row: the tile was half-height, which
    /// left about 27 points of content once the card's padding and header
    /// were taken out. It is a full-height tile now — same as every other
    /// collapsed widget — so the fortnight gets a strip of day rings, which
    /// is the part that answers "when".
    ///
    /// Figure, then the fortnight, then what it is made of.
    ///
    /// The rings sit **directly under the figure**, with the slack below them
    /// rather than above. Pinned to the bottom of the tile they sat about
    /// forty points lower than the same rings on the expanded one, so
    /// expanding slid the whole fortnight upwards past the figure — the one
    /// thing on screen that had not changed appeared to move the most.
    ///
    /// The counts read **under** the rings, not beside the figure. They are a
    /// summary of the strip above them ("three of those rings are money going
    /// out"), and on the figure's line they read as a caption on the net
    /// instead. Expanded keeps them on the headline's line, where the rings
    /// are followed immediately by a list that needs the width.
    private func collapsed(_ metrics: UpcomingTransactionsMetrics) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
            MetricHeadline(value: .money(metrics.totalE4, currency), size: WidgetStyle.metric)
            carousel(metrics, isInteractive: false)
            counts(metrics)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func counts(_ metrics: UpcomingTransactionsMetrics) -> some View {
        HStack(spacing: AppTheme.Spacing.s) {
            if metrics.inboundCount > 0 {
                countLabel(metrics.inboundCount, "in", CashflowPalette.income)
            }
            if metrics.outboundCount > 0 {
                countLabel(metrics.outboundCount, "out", CashflowPalette.expense)
            }
        }
    }

    private func countLabel(_ count: Int, _ noun: String, _ color: Color) -> some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Circle().fill(color).frame(width: AppTheme.Size.dot, height: AppTheme.Size.dot)
            Text("\(count) \(noun)")
                .font(AppTheme.Typography.micro)
                .foregroundStyle(AppTheme.Palette.textSecondary)
                .monospacedDigit()
        }
        .lineLimit(1)
    }

    // MARK: - Expanded

    private func expanded(_ metrics: UpcomingTransactionsMetrics) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.s) {
                MetricHeadline(value: .money(metrics.totalE4, currency), size: WidgetStyle.metricExpanded)
                Spacer(minLength: AppTheme.Spacing.xs)
                counts(metrics)
            }
            carousel(metrics, isInteractive: true)
            dayList(metrics)
        }
    }

    /// Scrolls rather than fitting fourteen circles across the tile: at the
    /// width two grid columns give, fitting them all would put each day in
    /// about 20 points, and a date needs more than that to stay legible.
    /// `isInteractive` is off on the collapsed tile: the rings are there to
    /// show *when* the fortnight's activity falls, and a tap should open the
    /// widget like a tap anywhere else on the card. Wrapping them in buttons
    /// there would put fourteen targets over a card whose only job is to
    /// expand, and picking a day you cannot yet see the list for.
    /// The day rings' size. Everything inside a ring is drawn as a fraction
    /// of this, so the date and its weekday letter grow with it — which is
    /// what the extra height freed by moving the counts up actually bought.
    private var ringDiameter: CGFloat { 46 }

    private func carousel(_ metrics: UpcomingTransactionsMetrics, isInteractive: Bool) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: AppTheme.Spacing.s) {
                ForEach(metrics.days(from: today, calendar: utcCalendar), id: \.self) { day in
                    let items = metrics.items(on: day, calendar: utcCalendar)
                    let ring = DaySplitRing(
                        day: day, segments: segments(items),
                        isSelected: isInteractive && selectedDay == day, isToday: day == today,
                        diameter: ringDiameter, calendar: utcCalendar
                    )
                    if isInteractive {
                        Button {
                            withAnimation(AppTheme.Motion.quick) {
                                selectedDay = selectedDay == day ? nil : day
                            }
                        } label: {
                            // A 46pt ring already clears HIG's 44, but the
                            // frame stays: it is what guarantees that, not
                            // the diameter happening to be larger today.
                            ring.frame(minWidth: WidgetStyle.minimumTarget, minHeight: WidgetStyle.minimumTarget)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(accessibilityLabel(day, items: items))
                    } else {
                        ring.accessibilityLabel(accessibilityLabel(day, items: items))
                    }
                }
            }
            .padding(.vertical, AppTheme.Spacing.xs)
        }
        .scrollIndicators(.hidden)
        .sensoryFeedback(AppTheme.Feedback.selection, trigger: selectedDay)
    }

    /// One arc per occurrence, coloured by direction. `share` is unused by
    /// the ring — it splits by count — but is filled in honestly rather than
    /// zeroed, so the segment means the same thing it would in a bar.
    private func segments(_ items: [UpcomingTransactionLocal]) -> [FillSegment] {
        let step = items.isEmpty ? 0 : 1.0 / Double(items.count)
        return items.map { item in
            FillSegment(
                id: item.id, share: step,
                color: item.isInbound ? CashflowPalette.income : CashflowPalette.expense
            )
        }
    }

    /// The selected day's entries, or the whole fortnight when no day is
    /// picked — so the tile is useful the moment it opens rather than only
    /// after a tap.
    private func dayList(_ metrics: UpcomingTransactionsMetrics) -> some View {
        let items = selectedDay.map { metrics.items(on: $0, calendar: utcCalendar) } ?? metrics.items
        return Group {
            if items.isEmpty {
                Text("Nothing due this day.")
                    .font(AppTheme.Typography.label)
                    .foregroundStyle(AppTheme.Palette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(items) { item in
                            row(item)
                            if item.id != items.last?.id {
                                Divider()
                                    .padding(
                                        .leading,
                                        AppTheme.Size.dividerInset(icon: AppTheme.Size.icon, leading: 0)
                                    )
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Opens the **rule**, not an instance.
    ///
    /// A deliberate departure from the Transactions list, which offers "this
    /// one" or "all future" — that choice exists there because the row
    /// tapped is a real transaction that has already happened. Nothing in
    /// this widget has happened yet, so "edit this one" would have nothing
    /// to edit.
    private func row(_ item: UpcomingTransactionLocal) -> some View {
        Button {
            openRule(item.ruleId)
        } label: {
            HStack(spacing: AppTheme.Spacing.m) {
                CategoryIconView(icon: item.categoryIcon, color: Color(hex: item.categoryColor))
                VStack(alignment: .leading, spacing: 0) {
                    Text(item.categoryName)
                        .font(AppTheme.Typography.label)
                        .foregroundStyle(AppTheme.Palette.textPrimary)
                        .lineLimit(1)
                    Text("\(dueLabel(item.dueOn)) · \(item.accountName)")
                        .font(AppTheme.Typography.nano)
                        .foregroundStyle(AppTheme.Palette.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: AppTheme.Spacing.xs)
                PrivateText(amountLabel(item.amountBaseE4))
                    .font(AppTheme.Typography.labelEmphasis)
                    .foregroundStyle(item.isInbound ? CashflowPalette.income : AppTheme.Palette.textPrimary)
            }
            // Opens the recurring rule's form — worth HIG's full 44pt.
            .padding(.vertical, AppTheme.Spacing.xs)
            .frame(minHeight: WidgetStyle.minimumTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressableRow)
    }

    // MARK: - Helpers

    /// The **user's** calendar day, expressed in UTC so it lines up with the
    /// date-only values the occurrences carry, and stable across re-renders.
    ///
    /// `utcCalendar.startOfDay(for: Date())` is the spelling this used to
    /// have and is UTC's today, not the device's — so the ring marked "today"
    /// was the wrong circle for anyone west of UTC from mid-afternoon on, and
    /// the strip started a day late. See `PostgresDate.currentDateOnly`.
    private var today: Date {
        PostgresDate.currentDateOnly(in: utcCalendar) ?? utcCalendar.startOfDay(for: Date())
    }

    private func accessibilityLabel(_ day: Date, items: [UpcomingTransactionLocal]) -> String {
        let date = PostgresDate.dateOnlyLabel(day, calendar: utcCalendar)
        guard !items.isEmpty else { return "\(date), nothing due" }
        return "\(date), \(items.count) due"
    }

    /// Formatted in `utcCalendar` — the same calendar the due date was
    /// decoded in. `Date.formatted` would use the device's zone and render
    /// every item a day early for anyone west of UTC; see
    /// `PostgresDate.dateOnlyLabel`.
    private func dueLabel(_ date: Date) -> String {
        PostgresDate.dateOnlyLabel(date, calendar: utcCalendar)
    }

    /// `.ledger`, so an outflow reads as its magnitude beside a row that
    /// already says which way it goes. The headline above keeps its sign,
    /// because there "up or down" is the whole answer.
    private func amountLabel(_ amountE4: Int64?) -> String {
        guard let currency else { return "—" }
        return MoneyFormatter.format(amountE4, currency: currency, signStyle: .ledger)
    }
}
