import Foundation

/// The Cashflow widget's window: a whole month or a whole year, and always
/// the last **complete** one.
///
/// That is the entire reason this type exists rather than "this month". A
/// partial period is not comparable to anything: on the 3rd, month-to-date
/// spending is a tenth of a month measured against a full one, and the
/// resulting trend badge would read as a collapse in spending every time the
/// month rolled over. Comparing August-so-far to all of July is not a
/// smaller number, it is a different question.
public enum CashflowPeriod: String, CaseIterable, Identifiable, Sendable {
    case month
    case year

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .month: return "Month"
        case .year: return "Year"
        }
    }

    /// The last complete period before `now` — the month or year that has
    /// actually finished.
    public func bounds(now: Date, calendar: Calendar) -> ClosedRange<Date> {
        bounds(now: now, calendar: calendar, stepsBack: 1)
    }

    /// The period before `bounds` — what the trend badge compares against.
    public func previousBounds(now: Date, calendar: Calendar) -> ClosedRange<Date> {
        bounds(now: now, calendar: calendar, stepsBack: 2)
    }

    /// A name for the window the user is looking at ("July 26", "2025"), so
    /// the tile never leaves them guessing which period a figure describes.
    ///
    /// The month carries its year. It reads as redundant in August and is
    /// the whole point in January, when the last finished month belongs to
    /// the year before — and a tile that only said "December" would be
    /// ambiguous for the eleven months after it.
    public func label(now: Date, calendar: Calendar, locale: Locale = .current) -> String {
        let start = bounds(now: now, calendar: calendar).lowerBound
        switch self {
        case .month:
            return FormatterCache.dateOnly(calendar: calendar, template: "MMMMyy", locale: locale)
                .string(from: start)
        case .year:
            return FormatterCache.dateOnly(calendar: calendar, template: "y", locale: locale)
                .string(from: start)
        }
    }

    /// `stepsBack: 1` is the most recently finished period, `2` the one
    /// before it. Both bounds are inclusive and land on real calendar
    /// boundaries — the last day of the period, not the first day of the
    /// next one, so a caller comparing `occurred_at::date BETWEEN` can't
    /// double-count a transaction on the seam.
    private func bounds(now: Date, calendar: Calendar, stepsBack: Int) -> ClosedRange<Date> {
        let component: Calendar.Component = self == .month ? .month : .year
        let currentStart = calendar.dateInterval(of: component, for: now)?.start ?? now
        let start = calendar.date(byAdding: component, value: -stepsBack, to: currentStart) ?? currentStart
        let nextStart = calendar.date(byAdding: component, value: 1, to: start) ?? start
        let end = calendar.date(byAdding: .day, value: -1, to: nextStart) ?? start
        return start ... end
    }
}
