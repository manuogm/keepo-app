import SwiftUI

/// A range of whole days being picked on `RangeCalendar`, or All Time.
///
/// Both ends optional: Export's period page opens with nothing chosen, and a
/// selection is half made — a first day and no last — between two taps.
/// `days` is the only complete answer.
struct DayRange: Equatable {
    var start: Date?
    var end: Date?
    var isAllTime = false

    /// Day-start bounds, inclusive at both ends, once both are picked.
    var days: ClosedRange<Date>? {
        guard let start, let end else { return nil }
        return start...end
    }

    /// Three rules, in this order, and the second is the one that closes the
    /// reversed-interval crash `CustomRangeSheet` exists to prevent: **a tap
    /// before the start is a new start**, never an end that would sort
    /// before it.
    mutating func select(_ day: Date) {
        guard let start, end == nil, day >= start else {
            self.start = day
            end = nil
            return
        }
        end = day
    }

    enum DayState: Equatable {
        case none, start, end, between, single

        var isEndpoint: Bool { self == .start || self == .end || self == .single }
    }

    func state(of day: Date) -> DayState {
        guard !isAllTime, let start else { return .none }
        guard let end else { return day == start ? .single : .none }
        if day == start { return start == end ? .single : .start }
        if day == end { return .end }
        return day > start && day < end ? .between : .none
    }

    // MARK: - Months

    static func monthStart(of day: Date, calendar: Calendar) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: day)) ?? day
    }

    /// Six years back and one forward, widened to whatever the current
    /// selection needs. Forward at all because a ledger can hold a future
    /// date — a recurring rule's next occurrence, a bill entered early —
    /// and a picker that cannot reach it would make that row unfilterable.
    func monthWindow(calendar: Calendar) -> [Date] {
        let today = Date()
        let back = calendar.date(byAdding: .year, value: -6, to: today) ?? today
        let forward = calendar.date(byAdding: .year, value: 1, to: today) ?? today
        var cursor = Self.monthStart(of: min(back, start ?? back), calendar: calendar)
        let last = Self.monthStart(of: max(forward, end ?? start ?? forward), calendar: calendar)
        var months: [Date] = []
        while cursor <= last {
            months.append(cursor)
            guard let next = calendar.date(byAdding: .month, value: 1, to: cursor) else { break }
            cursor = next
        }
        return months
    }
}

/// The app's one range picker: a calendar you scroll, rather than two fields
/// you set one at a time. The Transactions list's Custom period shows it in
/// `CustomRangeSheet`; Export's period page shows it inline, under its own
/// quick picks.
///
/// It draws and edits a `DayRange` and nothing else — no draft, no Done.
/// The sheet keeps its own draft and commits on Done; Export binds it to the
/// live answer. While All Time is on the days dim and stop taking taps, which
/// says what All Time does more plainly than a sentence could.
struct RangeCalendar: View {
    @Binding var range: DayRange
    /// A month to bring into view — set by `MonthJumpMenu` or a quick pick,
    /// cleared once the calendar has scrolled to it.
    @Binding var focus: Date?

    // Not `private` — read from RangeCalendar+Grid.swift, an extension in a
    // different file (kept there purely for file-length).
    @Environment(\.colorScheme) var colorScheme
    let calendar = Calendar.current

    var months: [Date] { range.monthWindow(calendar: calendar) }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                weekdayHeader
                // A short fade at the bottom too: the default is sized for
                // the floating tab bar, and nothing floats over this
                // calendar — at that length the last visible week read as
                // days that could not be picked.
                calendarScroll(proxy)
                    .fadingEdges(bottom: AppTheme.Spacing.xl)
            }
            .opacity(range.isAllTime ? AppTheme.Opacity.dim : 1)
            .disabled(range.isAllTime)
        }
    }
}

/// Any month in the calendar's window, in two taps — because "March 2021"
/// is four years of flicking away, and a calendar you can only walk through
/// is one you cannot use for last year's tax return.
///
/// A nested `Menu` rather than a wheel or a second sheet: it is the smallest
/// control that answers "which month" without taking a permanent strip of the
/// screen away from the calendar itself. Unanimated on purpose — a five-year
/// scroll rendered at speed is a blur that tells the eye nothing and takes a
/// second to finish.
struct MonthJumpMenu: View {
    let range: DayRange
    @Binding var focus: Date?

    private let calendar = Calendar.current

    var body: some View {
        Menu {
            ForEach(monthsByYear, id: \.year) { group in
                Menu(String(group.year)) {
                    ForEach(group.months, id: \.self) { month in
                        Button(month.formatted(.dateTime.month(.wide))) { focus = month }
                    }
                }
            }
        } label: {
            HStack(spacing: AppTheme.Spacing.xs) {
                Image(systemName: "calendar")
                    .font(AppTheme.Typography.captionEmphasis)
                Text("Jump to")
                    .font(AppTheme.Typography.label)
                Image(systemName: "chevron.down")
                    .font(AppTheme.Typography.nanoEmphasis)
            }
            .foregroundStyle(AppTheme.Palette.textSecondary)
            .padding(.horizontal, AppTheme.Spacing.m)
            .padding(.vertical, AppTheme.Spacing.s)
            .background(AppTheme.Palette.fillSubtle, in: Capsule())
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.pressableCard)
        .transaction { $0.animation = nil }
    }

    /// The window grouped one submenu per year, holding only the months the
    /// calendar actually draws, so the menu can never offer a month it would
    /// have nothing to scroll to.
    private var monthsByYear: [(year: Int, months: [Date])] {
        let grouped = Dictionary(grouping: range.monthWindow(calendar: calendar)) {
            calendar.component(.year, from: $0)
        }
        return grouped.keys.sorted(by: >).map { year in
            (year: year, months: (grouped[year] ?? []).sorted())
        }
    }
}
