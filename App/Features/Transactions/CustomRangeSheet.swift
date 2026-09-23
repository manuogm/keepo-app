import SwiftUI

/// The Custom period's picker: a calendar you scroll, rather than two
/// fields you set one at a time.
///
/// It replaces a `Form` holding two independent `DatePicker`s, which had
/// two problems. The small one is that two dates never showed the *shape*
/// of the period — you read "Aug 12" and "Aug 23" and did the arithmetic
/// yourself. The large one is that the two could disagree: nothing stopped
/// From landing after Through, and `TransactionsListView.range` handed that
/// pair straight to `DateInterval(start:end:)`, which **traps on a reversed
/// interval**. The app died where it stood. Here a tap before the start
/// begins a new selection instead, so the reversed pair has nowhere to come
/// from — the crash is closed at the layer that produced it, and `range`'s
/// own `max` is the backstop rather than the fix.
///
/// It edits a **draft** and commits once, on Done. The ledger underneath
/// reloads whenever the period changes, and half a selection — "from the
/// 12th to nowhere" — is not a period anyone asked to see.
///
/// The calendar itself is `RangeCalendar`, shared with Export's period page;
/// this sheet is the draft, the All Time row, and Done.
struct CustomRangeSheet: View {
    let onDone: (Selection) -> Void

    /// What the sheet hands back. `range` is day-start bounds, inclusive at
    /// both ends; it is `nil` only when the user leaves with All Time on,
    /// where there is no range to carry.
    struct Selection {
        var range: ClosedRange<Date>?
        var isAllTime: Bool
    }

    @Environment(\.dismiss) private var dismiss

    /// Never without a start here: the sheet always opens on the period
    /// already being looked at. The end goes `nil` while a new selection is
    /// half made — which is also the one state Done refuses to commit.
    @State private var range: DayRange
    @State private var focus: Date?

    private let calendar = Calendar.current

    init(from: Date, through: Date, isAllTime: Bool, onDone: @escaping (Selection) -> Void) {
        self.onDone = onDone
        let calendar = Calendar.current
        // `min`/`max`, not the arguments in order: a reversed pair is what
        // this sheet exists to make impossible, and it must not be able to
        // arrive from stale state either.
        let first = min(calendar.startOfDay(for: from), calendar.startOfDay(for: through))
        let last = max(calendar.startOfDay(for: from), calendar.startOfDay(for: through))
        _range = State(initialValue: DayRange(start: first, end: last, isAllTime: isAllTime))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.Palette.bgCanvas.ignoresSafeArea()

                VStack(spacing: 0) {
                    HStack(spacing: AppTheme.Spacing.m) {
                        CheckboxRow(title: "All Time", isOn: range.isAllTime) { range.isAllTime.toggle() }
                        MonthJumpMenu(range: range, focus: $focus)
                    }
                    .padding(.horizontal, AppTheme.Spacing.l)
                    .padding(.bottom, AppTheme.Spacing.m)
                    RangeCalendar(range: $range, focus: $focus)
                    summaryBar
                }
                .padding(.top, AppTheme.Spacing.m)
            }
            .navigationTitle("Custom Range")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { commit() } label: { Image(systemName: "checkmark") }
                        .disabled(range.days == nil && !range.isAllTime)
                }
            }
        }
    }

    private func commit() {
        onDone(Selection(range: range.isAllTime ? nil : range.days, isAllTime: range.isAllTime))
        dismiss()
    }

    // MARK: - Summary

    /// Says what the taps add up to — including "how many days", which is
    /// the question two dates on their own never answered.
    private var summaryBar: some View {
        Text(summary)
            .font(AppTheme.Typography.label)
            .foregroundStyle(AppTheme.Palette.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, AppTheme.Spacing.m)
    }

    private var summary: String {
        if range.isAllTime { return "All Time" }
        guard let start = range.start, let end = range.end else { return "Now pick the last day" }
        let days = (calendar.dateComponents([.day], from: start, to: end).day ?? 0) + 1
        let label = start == end
            ? start.formatted(date: .abbreviated, time: .omitted)
            : "\(start.formatted(date: .abbreviated, time: .omitted)) – "
                + end.formatted(date: .abbreviated, time: .omitted)
        return "\(label) · \(days) day\(days == 1 ? "" : "s")"
    }
}
