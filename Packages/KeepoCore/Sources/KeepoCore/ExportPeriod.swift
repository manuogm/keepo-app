import Foundation

/// Which stretch of time an export covers.
///
/// Four presets are the answers people actually give — this month for a
/// budget check, last month for a statement, this year and the last twelve
/// months for taxes and reviews — plus everything, and `custom` is the rest.
/// The Export screen asks on the same range calendar the Transactions list's
/// Custom period uses (`RangeCalendar`): All Time is its checkbox, the
/// presets are pills that fill in its days, and any other range of days is
/// `custom`.
///
/// **An interval's end is exclusive**: the first instant of the day after the
/// last one included, exactly as `TransactionsListView.range` builds it, so an
/// export and the ledger it was launched from select the same rows.
public enum ExportPeriod: Hashable, Sendable {
    case thisMonth
    case lastMonth
    case thisYear
    case lastTwelveMonths
    case allTime
    /// Inclusive, day-start bounds — the shape `CustomRangeSheet` produces.
    case custom(from: Date, through: Date)

    /// The quick picks over the calendar. All Time is not one of them — it is
    /// the checkbox above them, because it is the absence of a range rather
    /// than one more range.
    public static let presets: [ExportPeriod] = [.thisMonth, .lastMonth, .thisYear, .lastTwelveMonths]

    /// The pill's own words. `nil` for a custom range, which is described by
    /// its dates instead (`label`).
    public var presetTitle: String? {
        switch self {
        case .thisMonth: return "This month"
        case .lastMonth: return "Last month"
        case .thisYear: return "This year"
        case .lastTwelveMonths: return "Last 12 months"
        case .allTime: return "All time"
        case .custom: return nil
        }
    }

    public var isCustom: Bool {
        if case .custom = self { return true }
        return false
    }

    /// `nil` for All Time — the absence of a window rather than a very wide
    /// one, so nothing has to agree on how far back "everything" goes.
    public func interval(now: Date, calendar: Calendar) -> DateInterval? {
        switch self {
        case .thisMonth:
            return calendar.dateInterval(of: .month, for: now)
        case .lastMonth:
            guard let previous = calendar.date(byAdding: .month, value: -1, to: now) else { return nil }
            return calendar.dateInterval(of: .month, for: previous)
        case .thisYear:
            return calendar.dateInterval(of: .year, for: now)
        case .lastTwelveMonths:
            // Through today, back to the same day twelve months ago — "the
            // last year" as people mean it, not twelve whole calendar months
            // that would leave the current one out.
            let end = Self.dayAfter(now, calendar: calendar)
            guard let start = calendar.date(byAdding: .month, value: -12, to: end) else { return nil }
            return DateInterval(start: start, end: end)
        case .allTime:
            return nil
        case .custom(let from, let through):
            let start = calendar.startOfDay(for: min(from, through))
            let end = Self.dayAfter(max(from, through), calendar: calendar)
            return DateInterval(start: start, end: end)
        }
    }

    /// The first and last day included, as day starts — the shape the range
    /// calendar draws. `nil` for All Time.
    public func days(now: Date, calendar: Calendar) -> ClosedRange<Date>? {
        guard let interval = interval(now: now, calendar: calendar) else { return nil }
        let lastDay = calendar.date(byAdding: .day, value: -1, to: interval.end) ?? interval.start
        return interval.start...max(interval.start, lastDay)
    }

    /// The period a range of days on the calendar is: the preset that covers
    /// exactly those days if there is one, otherwise a custom range. So
    /// tapping the 1st and the 30th of this month *is* "This month" — its
    /// pill lights up and the file is named for it — rather than an
    /// anonymous range that happens to match.
    public static func named(from: Date, through: Date, now: Date, calendar: Calendar) -> ExportPeriod {
        let custom = ExportPeriod.custom(from: from, through: through)
        let days = custom.days(now: now, calendar: calendar)
        return presets.first { $0.days(now: now, calendar: calendar) == days } ?? custom
    }

    /// The dates in words: "September 2026", "2026", "Sep 23, 2026",
    /// "Aug 1 – Sep 23, 2026" or "All time". A range that is exactly a
    /// calendar month or year is named as one, because that is how the user
    /// would say it — and a window handed over from a ledger filtered to
    /// "Month" arrives as exactly that.
    public func label(now: Date, calendar: Calendar, locale: Locale = .current) -> String {
        guard let interval = interval(now: now, calendar: calendar) else { return "All time" }
        return Self.label(for: interval, calendar: calendar, locale: locale)
    }

    /// The window a ledger was showing, as a period — `nil` (the ledger's All
    /// Time) becomes `.allTime`, anything else a custom range over the same
    /// days.
    public static func matching(_ interval: DateInterval?, calendar: Calendar) -> ExportPeriod {
        guard let interval else { return .allTime }
        let lastDay = calendar.date(byAdding: .day, value: -1, to: interval.end) ?? interval.start
        return .custom(
            from: calendar.startOfDay(for: interval.start),
            through: calendar.startOfDay(for: max(interval.start, lastDay))
        )
    }

    // MARK: - Private

    private static func dayAfter(_ date: Date, calendar: Calendar) -> Date {
        let start = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: 1, to: start) ?? start
    }

    private static func label(for interval: DateInterval, calendar: Calendar, locale: Locale) -> String {
        let start = interval.start
        let lastDay = calendar.date(byAdding: .day, value: -1, to: interval.end) ?? start
        let style = Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale, calendar: calendar,
                                     timeZone: calendar.timeZone)

        if calendar.dateInterval(of: .year, for: start) == interval {
            return start.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
                .year())
        }
        if calendar.dateInterval(of: .month, for: start) == interval {
            return start.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
                .month(.wide).year())
        }
        if calendar.isDate(start, inSameDayAs: lastDay) {
            return start.formatted(style)
        }
        return "\(start.formatted(style)) – \(lastDay.formatted(style))"
    }
}
