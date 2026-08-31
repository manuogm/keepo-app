import SwiftUI

/// The period model behind the header's filter panel — which range is being
/// looked at, how it is labelled, and how another screen hands this one a
/// slice of the ledger to show. The controls that drive it live in
/// `TransactionsListView+Filters.swift`, drawn on the banner itself. Split
/// out of TransactionsListView.swift purely to keep that file under the
/// project's file-length/type-body-length lint thresholds.
extension TransactionsListView {
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

    var customRangeSheet: some View {
        NavigationStack {
            Form {
                DatePicker("From", selection: $customFrom, displayedComponents: .date)
                DatePicker("Through", selection: $customThrough, displayedComponents: .date)
            }
            .navigationTitle("Custom Range")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { isCustomRangePresented = false } label: { Image(systemName: "checkmark") }
                }
            }
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
            let end = calendar.date(byAdding: .day, value: -1, to: range.end) ?? range.end
            return "\(formatter.string(from: range.start)) – \(formatter.string(from: end))"
        case .month:
            formatter.dateFormat = "MMMM yyyy"
            return formatter.string(from: anchor)
        case .year:
            formatter.dateFormat = "yyyy"
            return formatter.string(from: anchor)
        case .custom:
            formatter.dateFormat = "MMM d, yyyy"
            return "\(formatter.string(from: customFrom)) – \(formatter.string(from: customThrough))"
        }
    }

    func step(_ direction: Int) {
        guard let component = period.component else { return }
        anchor = calendar.date(byAdding: component, value: direction, to: anchor) ?? anchor
    }
}
