import SwiftUI

/// The period model behind the header's filter panel — which range is being
/// looked at, how it is labelled, and how another screen hands this one a
/// slice of the ledger to show. The controls that drive it live in
/// `TransactionsListView+Filters.swift`, drawn on the banner itself. Split
/// out of TransactionsListView.swift purely to keep that file under the
/// project's file-length/type-body-length lint thresholds.
extension TransactionsListView {
    /// The window on screen — or `nil` for **All Time**, which is the
    /// absence of a window rather than a very wide one. The query then
    /// drops both bounds instead of inventing a start nobody chose, and
    /// nothing downstream has to agree on how far back "everything" goes.
    ///
    /// **The custom branch is written defensively, and that is a fix
    /// rather than a precaution.** `DateInterval(start:end:)` *traps* on a
    /// reversed interval, and this used to read the two dates straight off
    /// two independent pickers — setting From later than Through took the
    /// app down, with no way back in but a relaunch. `CustomRangeSheet`
    /// cannot produce that pair any more (a tap before the start begins a
    /// new selection), and the `max` here is what guarantees nothing else
    /// ever will.
    ///
    /// The custom end is the **start of the day after** `customThrough`,
    /// not that day's last second: it matches what every other period
    /// already does (`dateInterval(of:for:)` ends at the next period's
    /// first instant) and it cannot lose a row in the final second of the
    /// day the way a `23:59:59` bound can, since timestamps here carry
    /// milliseconds.
    var range: DateInterval? {
        guard let component = period.component else {
            guard !isAllTime else { return nil }
            let start = calendar.startOfDay(for: customFrom)
            let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: customThrough)) ?? start
            return DateInterval(start: start, end: max(start, end))
        }
        return calendar.dateInterval(of: component, for: anchor) ?? DateInterval(start: anchor, duration: 0)
    }

    /// Adopts a period another screen asked for — the Cashflow widget's
    /// category chevron — and clears the request.
    ///
    /// Clearing is what stops the filter reappearing every time the user
    /// comes back to this tab, long after they changed it to something else.
    func applyPendingRequest() {
        guard let navigation, let request = navigation.transactionsRequest else { return }
        filter.categoryId = request.categoryId
        filter.kind = request.kind
        period = .custom
        isAllTime = false
        customFrom = request.from
        customThrough = request.through
        navigation.transactionsRequest = nil
        // The ask came from another screen, so the controls that produced
        // this state are not the ones on screen — open the panel so the
        // period and category the user is now looking at are visible rather
        // than hidden behind the funnel.
        isFiltersExpanded = true
    }

    /// Picking "Custom" opens the range sheet; *becoming* custom does not.
    ///
    /// The difference matters now that another screen can hand this one a
    /// period to show (`TransactionsRequest`), which arrives as a custom
    /// range already chosen. Watching the value with `.onChange` couldn't
    /// tell the two apart and popped the sheet over a list the user had just
    /// been sent to. A binding's setter only runs when the control writes it,
    /// which is exactly the distinction — the sheet belongs to the tap, not
    /// to the value.
    var periodBinding: Binding<Period> {
        Binding(
            get: { period },
            set: { chosen in
                period = chosen
                if chosen == .custom { isCustomRangePresented = true }
            }
        )
    }

    /// The range picker itself lives in `CustomRangeSheet.swift` — it is a
    /// calendar rather than two fields now, and it edits a **draft** it
    /// only commits on Done, so the ledger behind it does not reload
    /// against a half-made selection.
    var customRangeSheet: some View {
        CustomRangeSheet(
            from: customFrom, through: customThrough, isAllTime: isAllTime
        ) { selection in
            isAllTime = selection.isAllTime
            if let range = selection.range {
                customFrom = range.lowerBound
                customThrough = range.upperBound
            }
            isCustomRangePresented = false
        }
    }

    var rangeLabel: String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        switch period {
        case .day:
            formatter.dateFormat = "MMM d, yyyy"
            return formatter.string(from: anchor)
        case .week:
            formatter.dateFormat = "MMM d"
            // Built from the anchor rather than from `range`, which is
            // optional now — a week is never All Time, but a `guard` here
            // to say so would be answering a question nobody asked.
            let week = calendar.dateInterval(of: .weekOfYear, for: anchor)
            let start = week?.start ?? anchor
            let end = week.flatMap { calendar.date(byAdding: .day, value: -1, to: $0.end) } ?? anchor
            return "\(formatter.string(from: start)) – \(formatter.string(from: end))"
        case .month:
            formatter.dateFormat = "MMMM yyyy"
            return formatter.string(from: anchor)
        case .year:
            formatter.dateFormat = "yyyy"
            return formatter.string(from: anchor)
        case .custom:
            guard !isAllTime else { return "All Time" }
            formatter.dateFormat = "MMM d, yyyy"
            let from = formatter.string(from: customFrom)
            // One day picked twice is one day, and saying it twice reads as
            // a mistake in the app rather than a range the user chose.
            let through = formatter.string(from: customThrough)
            return from == through ? from : "\(from) – \(through)"
        }
    }

    func step(_ direction: Int) {
        guard let component = period.component else { return }
        anchor = calendar.date(byAdding: component, value: direction, to: anchor) ?? anchor
    }
}
