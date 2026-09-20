import SwiftUI

// The month grid `CustomRangeSheet` scrolls: the weekday rule, one month's
// worth of day cells, and how a day draws itself given where it falls in
// the selection. Split out of CustomRangeSheet.swift for the project's
// file-length and type-body-length lints, same precedent as
// TransactionFormView+Date.swift.
//
// Nothing here decides anything — `select(_:)` and `commit()` stay with the
// state they mutate. This file only draws.

extension CustomRangeSheet {
    // MARK: - Calendar

    /// Outside the scroll view on purpose — a day column you have to
    /// remember the heading of is a day column you misread.
    var weekdayHeader: some View {
        HStack(spacing: 0) {
            ForEach(weekdaySymbols, id: \.self) { symbol in
                Text(symbol)
                    .font(AppTheme.Typography.nanoEmphasis)
                    .foregroundStyle(AppTheme.Palette.textSecondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, AppTheme.Spacing.l)
        .padding(.bottom, AppTheme.Spacing.xs)
    }

    func calendarScroll(_ proxy: ScrollViewProxy) -> some View {
        ScrollView {
            LazyVStack(spacing: AppTheme.Spacing.l) {
                ForEach(months, id: \.self) { month in
                    monthSection(month)
                        .id(month)
                }
            }
            .padding(.horizontal, AppTheme.Spacing.l)
            .padding(.vertical, AppTheme.Spacing.s)
        }
        // The sheet opens on the month being looked at rather than at one
        // end of a seven-year list.
        //
        // A `ScrollViewReader` and not `scrollPosition(id:)`: that
        // modifier, handed an initial id the lazy stack has not built yet,
        // scrolled to an offset with nothing at it and the calendar came up
        // **blank** — verified in the Simulator. The `yield` is the same
        // problem's other half, and is why this is a `task` rather than an
        // `onAppear`: the jump has to happen after the first layout pass,
        // or there is nothing to jump to.
        .task {
            await Task.yield()
            proxy.scrollTo(scrolledMonth, anchor: .top)
        }
    }

    /// Any month in the window, in two taps — because "March 2021" is four
    /// years of flicking away, and a calendar you can only walk through is
    /// one you cannot use for last year's tax return.
    ///
    /// A nested `Menu` rather than a wheel or a second sheet: it is the
    /// smallest control that answers "which month" without taking a
    /// permanent strip of the screen away from the calendar itself.
    /// Unanimated on purpose — a five-year scroll rendered at speed is a
    /// blur that tells the eye nothing and takes a second to finish.
    func jumpToMenu(_ proxy: ScrollViewProxy) -> some View {
        Menu {
            ForEach(monthsByYear, id: \.year) { group in
                Menu(String(group.year)) {
                    ForEach(group.months, id: \.self) { month in
                        Button(month.formatted(.dateTime.month(.wide))) {
                            scrolledMonth = month
                            proxy.scrollTo(month, anchor: .top)
                        }
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

    private func monthSection(_ month: Date) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
            Text(month.formatted(.dateTime.month(.wide).year()))
                .font(AppTheme.Typography.labelEmphasis)
                .foregroundStyle(AppTheme.Palette.textPrimary)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 0) {
                ForEach(0..<leadingBlanks(of: month), id: \.self) { _ in
                    Color.clear.frame(height: AppTheme.Size.touchTarget)
                }
                ForEach(days(of: month), id: \.self) { day in
                    dayCell(day)
                }
            }
        }
    }

    /// The band is drawn as the cell's own background with **no grid
    /// spacing**, which is the whole reason the columns are flush: a gap
    /// between cells would break the fill into seven islands and the run of
    /// days would stop reading as one period.
    ///
    /// Neutral grey (`fillSubtle`), not a tint of the brand colour: the
    /// band can cover most of the screen, and a month washed in amber
    /// competes with the two ends, which are the part that has to stand
    /// out. The endpoints are `textPrimary` discs, so the shape reads as
    /// grey-between-two-marks.
    private func dayCell(_ day: Date) -> some View {
        let state = state(of: day)
        return Text(day.formatted(.dateTime.day()))
            .font(state.isEndpoint ? AppTheme.Typography.labelEmphasis : AppTheme.Typography.label)
            .monospacedDigit()
            .foregroundStyle(
                state.isEndpoint ? AppTheme.Palette.inkOnPrimaryFill(colorScheme) : AppTheme.Palette.textPrimary
            )
            .frame(maxWidth: .infinity)
            .frame(height: AppTheme.Size.touchTarget)
            .background(alignment: .center) {
                ZStack {
                    band(for: state)
                    if state.isEndpoint {
                        Circle()
                            .fill(AppTheme.Palette.textPrimary)
                            .frame(width: AppTheme.Size.icon, height: AppTheme.Size.icon)
                    } else if calendar.isDateInToday(day) {
                        Circle()
                            .strokeBorder(AppTheme.Palette.fillStrong, lineWidth: 1)
                            .frame(width: AppTheme.Size.icon, height: AppTheme.Size.icon)
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { select(day) }
            .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
            .accessibilityAddTraits(state == .none ? [] : .isSelected)
    }

    private func band(for state: DayState) -> some View {
        SelectionBand(state: state).fill(AppTheme.Palette.fillSubtle)
    }

    enum DayState: Equatable {
        case none, start, end, between, single

        var isEndpoint: Bool { self == .start || self == .end || self == .single }
    }

    func state(of day: Date) -> DayState {
        guard !isEverything else { return .none }
        guard let end else { return day == start ? .single : .none }
        if day == start { return start == end ? .single : .start }
        if day == end { return .end }
        return day > start && day < end ? .between : .none
    }
}

// The month grid's own arithmetic. In an extension rather than in the
// struct for the type-body-length lint, and it reads better here anyway:
// none of it knows what a selection is.
extension CustomRangeSheet {

    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let offset = calendar.firstWeekday - 1
        return Array(symbols[offset...] + symbols[..<offset])
    }

    private func leadingBlanks(of month: Date) -> Int {
        (calendar.component(.weekday, from: month) - calendar.firstWeekday + 7) % 7
    }

    private func days(of month: Date) -> [Date] {
        guard let count = calendar.range(of: .day, in: .month, for: month)?.count else { return [] }
        return (0..<count).compactMap { calendar.date(byAdding: .day, value: $0, to: month) }
    }

    /// The window grouped for the "Jump to" menu — one submenu per year,
    /// holding only the months the window actually contains, so the menu
    /// can never offer a month the list would have nothing to scroll to.
    var monthsByYear: [(year: Int, months: [Date])] {
        let grouped = Dictionary(grouping: months) { calendar.component(.year, from: $0) }
        return grouped.keys.sorted(by: >).map { year in
            (year: year, months: (grouped[year] ?? []).sorted())
        }
    }

    static func monthStart(of day: Date, calendar: Calendar) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: day)) ?? day
    }

    /// Six years back and one forward, widened to whatever the current
    /// selection needs. Forward at all because a ledger can hold a future
    /// date — a recurring rule's next occurrence, a bill entered early —
    /// and a picker that cannot reach it would make that row unfilterable.
    static func monthWindow(covering selection: ClosedRange<Date>, calendar: Calendar) -> [Date] {
        let today = Date()
        let back = calendar.date(byAdding: .year, value: -6, to: today) ?? today
        let forward = calendar.date(byAdding: .year, value: 1, to: today) ?? today
        var cursor = min(
            monthStart(of: back, calendar: calendar), monthStart(of: selection.lowerBound, calendar: calendar)
        )
        let last = max(
            monthStart(of: forward, calendar: calendar), monthStart(of: selection.upperBound, calendar: calendar)
        )
        var months: [Date] = []
        while cursor <= last {
            months.append(cursor)
            guard let next = calendar.date(byAdding: .month, value: 1, to: cursor) else { break }
            cursor = next
        }
        return months
    }
}

/// The grey behind a selected day: a full-height bar between the ends, and
/// at each end a circle centred on the cell — concentric with the endpoint
/// disc drawn over it — joined to the bar by the half of the cell the range
/// continues into.
///
/// **One `Shape`, filled once, and that is the whole reason it exists.**
/// This was a `ZStack` of a circle over a half-width rectangle, which looks
/// identical on paper and wrong on screen: `fillSubtle` is a *translucent*
/// grey, so wherever the two overlapped the alpha composited twice and the
/// cap came out a visibly darker shade than the band it belonged to. A
/// single path has no overlap to composite — the union is filled in one
/// pass, at one opacity.
private struct SelectionBand: Shape {
    let state: CustomRangeSheet.DayState

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard state != .none else { return path }
        if state == .between {
            path.addRect(rect)
            return path
        }
        // `min`, so the cap can never be wider than the column it is drawn
        // in on a narrow phone — at which point it would bleed into the
        // neighbouring day.
        let diameter = min(rect.height, rect.width)
        path.addEllipse(
            in: CGRect(
                x: rect.midX - diameter / 2, y: rect.midY - diameter / 2, width: diameter, height: diameter
            )
        )
        // The half the range runs into. A single day has none: it is a
        // circle and nothing else.
        switch state {
        case .start:
            path.addRect(CGRect(x: rect.midX, y: rect.minY, width: rect.width / 2, height: rect.height))
        case .end:
            path.addRect(CGRect(x: rect.minX, y: rect.minY, width: rect.width / 2, height: rect.height))
        default:
            break
        }
        return path
    }
}
