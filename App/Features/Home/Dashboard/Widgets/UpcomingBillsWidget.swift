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
            systemImage: DashboardWidgetKind.upcomingBills.systemImage,
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
    /// collapsed widget — so the counts get their own line and the fortnight
    /// gets a strip of day rings, which is the part that answers "when".
    private func collapsed(_ metrics: UpcomingTransactionsMetrics) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                MetricHeadline(value: .money(metrics.totalE4, currency), size: 30)
                Spacer(minLength: 4)
            }
            counts(metrics)
            Spacer(minLength: 0)
            carousel(metrics, isInteractive: false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func counts(_ metrics: UpcomingTransactionsMetrics) -> some View {
        HStack(spacing: 8) {
            if metrics.inboundCount > 0 {
                countLabel(metrics.inboundCount, "in", CashflowPalette.income)
            }
            if metrics.outboundCount > 0 {
                countLabel(metrics.outboundCount, "out", CashflowPalette.expense)
            }
        }
    }

    private func countLabel(_ count: Int, _ noun: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text("\(count) \(noun)")
                .font(.caption)
                .foregroundStyle(Color.secondary)
                .monospacedDigit()
        }
        .lineLimit(1)
    }

    // MARK: - Expanded

    private func expanded(_ metrics: UpcomingTransactionsMetrics) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                MetricHeadline(value: .money(metrics.totalE4, currency), size: 28)
                Spacer(minLength: 4)
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
    private func carousel(_ metrics: UpcomingTransactionsMetrics, isInteractive: Bool) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(metrics.days(from: today, calendar: utcCalendar), id: \.self) { day in
                    let items = metrics.items(on: day, calendar: utcCalendar)
                    let ring = DaySplitRing(
                        day: day, segments: segments(items),
                        isSelected: isInteractive && selectedDay == day, isToday: day == today,
                        calendar: utcCalendar
                    )
                    if isInteractive {
                        Button {
                            withAnimation(.snappy(duration: 0.2)) {
                                selectedDay = selectedDay == day ? nil : day
                            }
                        } label: {
                            // HIG's minimum, around a 38pt ring.
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
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
        .sensoryFeedback(.selection, trigger: selectedDay)
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
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(items) { item in
                            row(item)
                            if item.id != items.last?.id {
                                Divider().padding(.leading, 38)
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
            HStack(spacing: 10) {
                CategoryIconView(icon: item.categoryIcon, color: Color(hex: item.categoryColor), diameter: 28)
                VStack(alignment: .leading, spacing: 0) {
                    Text(item.categoryName)
                        .font(.subheadline)
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                    Text("\(dueLabel(item.dueOn)) · \(item.accountName)")
                        .font(.caption2)
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Text(amountLabel(item.amountBaseE4))
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(item.isInbound ? CashflowPalette.income : Color.primary)
            }
            // Opens the recurring rule's form — worth HIG's full 44pt.
            .padding(.vertical, 5)
            .frame(minHeight: WidgetStyle.minimumTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressableRow)
    }

    // MARK: - Helpers

    /// Truncated to a UTC day, so it is stable across re-renders and lines up
    /// with the date-only values the occurrences carry.
    private var today: Date { utcCalendar.startOfDay(for: Date()) }

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
