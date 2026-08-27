import Foundation

/// How finely a widget's chart slices time — the vocabulary shared by the
/// timeframe filter, the zoom gesture, the axis labels, and the trend
/// badge's caption.
///
/// One type rather than one per widget, because the four widgets that chart
/// anything all have to agree on what "a month" means: the bucket the point
/// is computed for, the date that point is computed *at*, the label under
/// it, and the noun the badge says ("vs previous month"). Four
/// re-derivations of that would drift, and the drift would be invisible —
/// two widgets side by side quietly bucketing differently.
///
/// **This is deliberately a user control**, which reverses the older rule
/// that granularity is "derived from the span, never a user control"
/// (app-architecture.md §5). That rule was written for the collapsed
/// trajectories, and it lived in a `DateBucketing` type this replaced — the
/// collapsed Net Worth line is built from these buckets too now, so there is
/// one granularity model rather than two with opposite rules. Picking the
/// resolution *is* the interaction on an expanded widget.
public enum MetricGranularity: String, Sendable, Codable, CaseIterable, Identifiable {
    case week
    case month
    case year

    public var id: String { rawValue }

    /// The segment's label in the timeframe filter.
    public var label: String {
        switch self {
        case .week: return "W"
        case .month: return "M"
        case .year: return "Y"
        }
    }

    /// What the trend badge calls the period it compares against, once the
    /// widget is expanded and the user has highlighted a specific point:
    /// "vs previous **month**".
    public var noun: String {
        switch self {
        case .week: return "week"
        case .month: return "month"
        case .year: return "year"
        }
    }

    var component: Calendar.Component {
        switch self {
        case .week: return .weekOfYear
        case .month: return .month
        case .year: return .year
        }
    }

    /// Roughly how many months one bucket spans — the unit the zoom
    /// thresholds are expressed in, so that a single set of numbers can
    /// describe a boundary from either side of it. Approximate by
    /// construction (a week is not 12/52 of every month) and only ever used
    /// to decide which side of a threshold a pinch is on, never to compute a
    /// date.
    public var months: Double {
        switch self {
        case .week: return 12.0 / 52.0
        case .month: return 1
        case .year: return 12
        }
    }

    // MARK: - Buckets

    /// The start of the bucket `date` falls in. Every point in a series is
    /// keyed on this, so two series computed from different raw dates land
    /// on the same x-positions.
    public func bucketStart(for date: Date, calendar: Calendar) -> Date {
        switch self {
        case .week:
            let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
            return calendar.date(from: components) ?? date
        case .month:
            return calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
        case .year:
            return calendar.date(from: calendar.dateComponents([.year], from: date)) ?? date
        }
    }

    /// `count` buckets from `date` — negative to step backwards.
    public func advance(_ date: Date, by count: Int, calendar: Calendar) -> Date {
        calendar.date(byAdding: component, value: count, to: date) ?? date
    }

    /// The date a bucket's value is actually computed at: its **last day**,
    /// or today when the bucket is the current one.
    ///
    /// The clamp is the whole point. A net worth "as of" 31 December
    /// evaluated in August would just repeat today's number under
    /// December's label — a flat run of identical future points that looks
    /// like real data. Clamping means the current bucket reads
    /// "so far this month", which is what the user's own spec asks for.
    public func evaluationDate(forBucket bucket: Date, now: Date, calendar: Calendar) -> Date {
        let next = advance(bucketStart(for: bucket, calendar: calendar), by: 1, calendar: calendar)
        let lastDay = calendar.date(byAdding: .day, value: -1, to: next) ?? next
        return min(lastDay, now)
    }

    /// Whether a bucket is still open — its figure will keep moving until
    /// the period ends. The Cashflow widget highlights the last *closed*
    /// bucket by default for exactly this reason.
    public func isCurrent(bucket: Date, now: Date, calendar: Calendar) -> Bool {
        bucketStart(for: bucket, calendar: calendar) == bucketStart(for: now, calendar: calendar)
    }

    /// Every bucket start from `from` through `through`, inclusive. The x
    /// domain a chart draws over — built by stepping rather than by
    /// filtering the data, so a bucket with no data is a *gap in a known
    /// axis* rather than a bucket that silently doesn't exist.
    public func buckets(from: Date, through: Date, calendar: Calendar) -> [Date] {
        var cursor = bucketStart(for: from, calendar: calendar)
        let end = bucketStart(for: through, calendar: calendar)
        var result: [Date] = []
        // Bounded independently of the date arithmetic: a calendar that
        // fails to advance would otherwise spin here forever.
        while cursor <= end, result.count < 4_096 {
            result.append(cursor)
            let next = advance(cursor, by: 1, calendar: calendar)
            guard next > cursor else { break }
            cursor = next
        }
        return result
    }

    /// How many buckets fit between two dates — the zoom gesture's unit.
    public func bucketCount(from: Date, through: Date, calendar: Calendar) -> Int {
        let start = bucketStart(for: from, calendar: calendar)
        let end = bucketStart(for: through, calendar: calendar)
        return (calendar.dateComponents([component], from: start, to: end).value(for: component) ?? 0) + 1
    }

    // MARK: - Labels

    /// The x-axis label: "Jan", "2025", "1–7 May".
    ///
    /// The week form names both ends because a week has no name of its own —
    /// "W23" is a label only a calendar app's users can read.
    public func axisLabel(for bucket: Date, calendar: Calendar, locale: Locale = .current) -> String {
        let start = bucketStart(for: bucket, calendar: calendar)
        switch self {
        case .month:
            return FormatterCache.dateOnly(calendar: calendar, template: "MMM", locale: locale).string(from: start)
        case .year:
            return FormatterCache.dateOnly(calendar: calendar, template: "y", locale: locale).string(from: start)
        case .week:
            return weekLabel(start: start, calendar: calendar, locale: locale)
        }
    }

    /// The x-axis label at every width it can be written in, longest first.
    ///
    /// The chart picks the longest form that fits inside one bucket's slot,
    /// so a month is "Jan" where there is room and "J" where there isn't.
    /// That replaces the axis's previous answer to a crowded scale, which
    /// was to **drop** labels until the survivors fitted — and a reader
    /// looking at five bars with two labels under them cannot tell which
    /// bar "Mar" belongs to. A label under every bar, shortened, says more
    /// than a full label under one bar in three.
    ///
    /// Always non-empty; the last element is the shortest form this
    /// granularity has, so a caller that runs out of room still draws
    /// something rather than nothing.
    public func axisLabelCandidates(
        for bucket: Date, calendar: Calendar, locale: Locale = .current
    ) -> [String] {
        let start = bucketStart(for: bucket, calendar: calendar)
        let full = axisLabel(for: start, calendar: calendar, locale: locale)
        switch self {
        case .month:
            // "MMMMM" is the *narrow* month, which is exactly the "J, F, M"
            // form asked for — and it is localised, unlike taking the first
            // character of "Jan" (which is wrong in any language whose
            // month names share initials by a different rule).
            return [full, FormatterCache.dateOnly(
                calendar: calendar, template: "MMMMM", locale: locale
            ).string(from: start)]
        case .year:
            return [full, "’" + String(full.suffix(2))]
        case .week:
            // A week has no name, so its ladder drops detail rather than
            // characters: both ends, then just the start, then its day.
            let dayMonth = FormatterCache.dateOnly(calendar: calendar, template: "d MMM", locale: locale)
            let day = FormatterCache.dateOnly(calendar: calendar, template: "d", locale: locale)
            return [full, dayMonth.string(from: start), day.string(from: start)]
        }
    }

    /// "1–7 May", or "28 Apr–4 May" when the week straddles two months —
    /// naming the month twice only when it actually changes.
    private func weekLabel(start: Date, calendar: Calendar, locale: Locale) -> String {
        let end = calendar.date(byAdding: .day, value: 6, to: start) ?? start
        let day = FormatterCache.dateOnly(calendar: calendar, template: "d", locale: locale)
        let dayMonth = FormatterCache.dateOnly(calendar: calendar, template: "d MMM", locale: locale)
        let sameMonth = calendar.component(.month, from: start) == calendar.component(.month, from: end)
        return sameMonth
            ? "\(day.string(from: start))–\(dayMonth.string(from: end))"
            : "\(dayMonth.string(from: start))–\(dayMonth.string(from: end))"
    }

    /// The full name of a bucket, for the headline and the badge caption
    /// where there is room for one: "May 2026", "2026", "week of 1 May".
    public func fullLabel(for bucket: Date, calendar: Calendar, locale: Locale = .current) -> String {
        let start = bucketStart(for: bucket, calendar: calendar)
        switch self {
        case .month:
            return FormatterCache.dateOnly(calendar: calendar, template: "MMMM y", locale: locale).string(from: start)
        case .year:
            return FormatterCache.dateOnly(calendar: calendar, template: "y", locale: locale).string(from: start)
        case .week:
            return weekLabel(start: start, calendar: calendar, locale: locale)
        }
    }
}
