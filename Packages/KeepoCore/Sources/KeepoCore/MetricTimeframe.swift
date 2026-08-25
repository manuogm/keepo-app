import Foundation

/// What the timeframe filter is set to — the M/Y (and, for FX, W) segments,
/// or a custom period, or all of it.
///
/// The granularity is *not* stored alongside a custom range or all-time:
/// both derive it from how much time they actually cover, using the same
/// thresholds the pinch gesture uses (`MetricZoom`). One number decides it
/// everywhere, so a two-year custom range and a two-year pinch produce the
/// same chart rather than two different opinions about the same span.
public enum MetricTimeframe: Sendable, Equatable, Codable {
    /// A rolling window at a fixed resolution, ending at today — the W/M/Y
    /// segments. How *many* buckets are shown is the chart's business (it
    /// depends on the tile's width and the zoom), not this type's.
    case rolling(MetricGranularity)
    /// An explicit period. Month-and-year precision at the picker, but a
    /// date range here, because the chart still has to know where inside
    /// the first and last month to start and stop.
    case custom(ClosedRange<Date>)
    /// Everything there is, fitted to the tile.
    case allTime

    public static let `default` = MetricTimeframe.rolling(.month)

    /// Whether this is the calendar (📅) segment — the two cases that need
    /// the period sheet rather than a plain tap.
    public var isCustom: Bool {
        switch self {
        case .rolling: return false
        case .custom, .allTime: return true
        }
    }

    /// The resolution to draw at. `available` is the span the user's data
    /// actually covers, which is the only thing all-time can be measured
    /// against.
    public func granularity(availableSpan: DateInterval?, calendar: Calendar) -> MetricGranularity {
        switch self {
        case .rolling(let granularity):
            return granularity
        case .custom(let range):
            return MetricZoom.granularity(forVisibleMonths: Self.months(of: range, calendar: calendar))
        case .allTime:
            guard let availableSpan else { return .month }
            return MetricZoom.granularity(
                forVisibleMonths: Self.months(of: availableSpan.start ... availableSpan.end, calendar: calendar)
            )
        }
    }

    static func months(of range: ClosedRange<Date>, calendar: Calendar) -> Double {
        let days = calendar.dateComponents([.day], from: range.lowerBound, to: range.upperBound).day ?? 0
        return Double(days) / 30.44
    }
}

/// Where the granularity boundaries sit, and the hysteresis that stops a
/// chart flickering between two of them while a pinch hovers on the line.
///
/// Thresholds are in **months of visible span**, not in bucket counts, and
/// that is what makes them usable from both sides: "18 months" describes
/// the same boundary whether you are at monthly resolution zooming out or
/// at yearly zooming in. Expressed as bucket counts they would be 18 and
/// 1.5 respectively, which is the same rule written twice in units that
/// have to be kept in agreement by hand.
///
/// The gap between each pair is deliberate. Escalating out of monthly at 18
/// months but only returning to it below 15 means a pinch that settles near
/// the boundary stays where it landed instead of oscillating.
public enum MetricZoom {
    /// Above this many visible months, step out to the next-coarser
    /// resolution.
    static func coarsenAbove(_ granularity: MetricGranularity) -> Double? {
        switch granularity {
        case .week: return 2
        case .month: return 18
        case .year: return nil
        }
    }

    /// Below this many visible months, step in to the next-finer one.
    static func refineBelow(_ granularity: MetricGranularity) -> Double? {
        switch granularity {
        case .week: return nil
        case .month: return 1.5
        case .year: return 15
        }
    }

    /// The resolution a span of this width should be drawn at, ignoring
    /// where it came from — used when there is no "current" to be sticky
    /// about (a custom range, all-time, a first render).
    public static func granularity(
        forVisibleMonths months: Double, allowed: [MetricGranularity] = [.month, .year]
    ) -> MetricGranularity {
        let ordered = allowed.sorted { $0.months < $1.months }
        guard let finest = ordered.first else { return .month }
        // The coarsest resolution whose own "coarsen above" line this span
        // has not crossed. Walking fine → coarse means the first match is
        // the finest one that can hold the span.
        for granularity in ordered {
            guard let ceiling = coarsenAbove(granularity) else { return granularity }
            if months <= ceiling { return granularity }
        }
        return ordered.last ?? finest
    }

    /// The resolution to move to given where the pinch *was*. Applies the
    /// hysteresis: a span between the two thresholds keeps `current`.
    public static func granularity(
        forVisibleMonths months: Double, current: MetricGranularity, allowed: [MetricGranularity]
    ) -> MetricGranularity {
        let ordered = allowed.sorted { $0.months < $1.months }
        guard ordered.contains(current) else {
            return granularity(forVisibleMonths: months, allowed: ordered)
        }
        guard let index = ordered.firstIndex(of: current) else { return current }
        if let ceiling = coarsenAbove(current), months > ceiling, index + 1 < ordered.count {
            return ordered[index + 1]
        }
        if let floor = refineBelow(current), months < floor, index > 0 {
            return ordered[index - 1]
        }
        return current
    }
}

/// The slice of a series that is actually loaded, and the rule for when
/// that slice stops being enough.
///
/// Widgets never load a whole timeline. Every point costs a full balance
/// recomputation across every account plus an FX conversion, so "all time"
/// on a five-year-old account is hundreds of them — for a chart showing
/// twelve. Instead a window covers what is visible plus one screenful
/// either side, so scrolling has somewhere to go before it has to wait, and
/// re-windows only when the visible range escapes what is loaded.
public struct SeriesWindow: Sendable, Equatable {
    public let granularity: MetricGranularity
    /// Inclusive bucket starts.
    public let from: Date
    public let through: Date

    public init(granularity: MetricGranularity, from: Date, through: Date) {
        self.granularity = granularity
        self.from = from
        self.through = through
    }

    /// The window to load for a given visible range: the range itself, one
    /// visible width of padding on each side, clamped to `limit` when the
    /// data does not go back that far (or forward at all — there is nothing
    /// to know about next month).
    public static func covering(
        visibleFrom: Date, visibleThrough: Date, granularity: MetricGranularity,
        limit: ClosedRange<Date>?, calendar: Calendar
    ) -> SeriesWindow {
        let visible = max(granularity.bucketCount(from: visibleFrom, through: visibleThrough, calendar: calendar), 1)
        var from = granularity.advance(visibleFrom, by: -visible, calendar: calendar)
        var through = granularity.advance(visibleThrough, by: visible, calendar: calendar)
        if let limit {
            from = max(from, granularity.bucketStart(for: limit.lowerBound, calendar: calendar))
            through = min(through, granularity.bucketStart(for: limit.upperBound, calendar: calendar))
        }
        return SeriesWindow(
            granularity: granularity,
            from: granularity.bucketStart(for: min(from, through), calendar: calendar),
            through: granularity.bucketStart(for: max(from, through), calendar: calendar)
        )
    }

    /// Whether what is already loaded still covers a visible range — the
    /// question that decides whether a scroll costs a read or costs nothing.
    /// A resolution change never covers: the buckets themselves are
    /// different values, not a subset.
    public func covers(visibleFrom: Date, visibleThrough: Date, granularity other: MetricGranularity) -> Bool {
        granularity == other && from <= visibleFrom && through >= visibleThrough
    }
}
