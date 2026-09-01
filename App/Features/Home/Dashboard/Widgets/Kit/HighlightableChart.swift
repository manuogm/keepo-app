import Charts
import KeepoCore
import SwiftUI

/// One mark, ready to draw: which slot on the x axis it occupies, which
/// bucket that is (for the highlight test), and what to plot.
///
/// `id` is the **series** plus the slot, not the slot alone. Marks are
/// identified inside one `Chart`, so three series numbering their own marks
/// 0, 1, 2 collide: Cashflow drew its net line and neither of its two bar
/// series, because the bars' ids had already been claimed. Nothing about the
/// data was wrong — the domain even included the bar values — which is what
/// made it look like a Swift Charts bug rather than an identity one.
private struct PlottedMark: Identifiable {
    let id: String
    /// The slot, **as a `Double`**, because that is the type the rest of this
    /// chart's x axis is expressed in: the scale domain is a
    /// `ClosedRange<Double>`, `AxisMarks` is given `[Double]`, the scroll
    /// position binds a `Double`, and hit-testing asks `proxy.value(atX:as:
    /// Double.self)`. Plotted as `Int` the marks still drew — `Int`'s
    /// primitive plottable *is* `Double`, so the axis labels resolved fine —
    /// but `chartScrollPosition(x:)` could not match a `Double` binding
    /// against an `Int` x scale, so every drag was reset and the chart would
    /// not scroll at all.
    let position: Double
    let bucket: Date
    let value: Double
}

/// The expanded widgets' chart: scrollable and highlightable.
///
/// **The x axis is a bucket index, not a date.** Two reasons, both of which
/// bit the earlier version: with real dates, monthly bars come out visibly
/// different widths (February against July), and `chartXVisibleDomain`'s
/// length has to be guessed as a `TimeInterval` that no month actually is.
/// Indices make a bucket a bucket, so "show 12 of them" is exact and every
/// bar is the same width. The dates come back at the axis labels, which is
/// the only place they were ever wanted.
///
/// Everything not highlighted is drawn dimmed. That is what ties the chart
/// to the number above it: the headline always shows the highlighted
/// bucket's figure, so there is always exactly one mark on screen that
/// visibly *is* the number being read.
struct HighlightableChart: View {
    /// The x domain, in order. Built by stepping the calendar, so a bucket
    /// with no data still occupies its slot and the axis stays evenly
    /// spaced.
    let buckets: [Date]
    let series: [ChartSeries]
    let granularity: MetricGranularity
    /// Which bucket the headline is currently reading. Never `nil` in
    /// practice — a widget picks a default (the latest bucket, or the last
    /// closed one for a flow) before it draws.
    @Binding var highlighted: Date?
    /// How many buckets fit on screen. Read-only now: the timeframe
    /// segments are the only thing that changes it.
    ///
    /// It used to be a binding, written by a pinch gesture that also moved
    /// the granularity under the user. Pinching a chart this size — a
    /// two-finger gesture inside a card that is itself inside a scrolling,
    /// reorderable grid — was fussy to start and easy to trigger by
    /// accident, and it competed with the horizontal scroll for the same
    /// touches. W/M/Y says the same thing in one tap.
    let visibleBuckets: Int
    /// The leading edge of the visible window, in bucket indices. Owned
    /// outside so the widget can start scrolled to "now" and can re-window
    /// its data as this moves.
    @Binding var scrollIndex: Double

    /// Fewest buckets a chart is drawn at. Below about four, a line has no
    /// shape left and a bar chart is a row of blocks.
    private let minimumVisible = 4

    /// What `chartXSelection` last reported, in x-scale units. Mapped onto a
    /// bucket by `select(_:)` rather than used directly — the scale is
    /// continuous, so a tap between two bars lands on a fraction.
    @State private var selectedPosition: Double?

    /// Never wider than the data. Left unclamped, a widget on a two-month-old
    /// account asked for twelve buckets of room and drew its three points
    /// squashed into the left quarter of the tile with dead space beside
    /// them — which looked like a broken chart rather than like a young
    /// account.
    private var visibleLength: Int {
        max(min(visibleBuckets, buckets.count), min(minimumVisible, max(buckets.count, 1)))
    }

    /// Half a bucket of the *next* one, shown past the right-hand edge.
    ///
    /// The scroll was invisible. A chart that fits its window exactly and a
    /// chart with two more years hidden behind it look identical, so the
    /// only way to find out there was more was to try dragging one — and a
    /// user who doesn't know a view scrolls doesn't try. Half a bar at the
    /// edge is the same promise a `LazyHStack` of cards makes, and it costs
    /// half a slot of width.
    ///
    /// Zero when everything already fits, because there is nothing to hint
    /// at and the dead half-slot would just make the last bar look adrift.
    private var peek: Double { visibleLength < buckets.count ? 0.5 : 0 }

    /// One bucket's share of the plot. The unit both the bar width and the
    /// axis labels are sized against, so a bar and its label can't disagree
    /// about how much room a bucket has.
    private func slotWidth(plotWidth: CGFloat) -> CGFloat {
        plotWidth / CGFloat(max(Double(visibleLength) + peek, 1))
    }

    /// The band the y axis covers.
    ///
    /// **Bars are anchored at zero and lines are not**, and that is not a
    /// style preference. A bar's meaning is its length from the baseline, so
    /// a floating baseline silently multiplies every difference between
    /// them. A line's meaning is its shape, and anchoring a running balance
    /// at zero flattens a real month of movement into a rule near the top of
    /// the tile — the exact bug this chart's predecessor shipped with.
    ///
    /// Walked in a single pass rather than built as `flatMap` +
    /// `compactMap` over `points + backdrop`. That spelling allocated three
    /// intermediate arrays per series, and `body` re-runs on every frame of
    /// a scroll or a scrub — so a chart of a few hundred buckets was
    /// allocating and throwing away several thousand elements per frame for
    /// two numbers.
    private var yDomain: ClosedRange<Double> {
        var low: Double?
        var high: Double?
        for series in series {
            for point in series.points { track(point.value, &low, &high) }
            for point in series.backdrop ?? [] { track(point.value, &low, &high) }
        }
        guard let low, let high else { return 0 ... 1 }
        if series.contains(where: { $0.visualization == .bar }) {
            let floor = min(low, 0)
            let ceiling = max(high, 0)
            return floor == ceiling ? floor ... (ceiling + 1) : floor ... ceiling
        }
        guard high > low else { return (low - 1) ... (high + 1) }
        let padding = (high - low) * 0.18
        return (low - padding) ... (high + padding)
    }

    private func track(_ value: Double?, _ low: inout Double?, _ high: inout Double?) {
        guard let value else { return }
        low = low.map { Swift.min($0, value) } ?? value
        high = high.map { Swift.max($0, value) } ?? value
    }

    /// Each bucket's slot on the x axis, built **once per body**.
    ///
    /// `plotted` used to build this dictionary itself, so it was rebuilt
    /// once per series *and* once per backdrop — three to six times a frame
    /// on Cashflow and Investing Ratio, over every bucket in the timeline
    /// (which is the whole of "All time", not just the visible window).
    private var bucketPositions: [Date: Int] {
        Dictionary(uniqueKeysWithValues: buckets.enumerated().map { ($0.element, $0.offset) })
    }

    var body: some View {
        // The width is measured rather than left to `MarkDimension.ratio`.
        // A ratio is a fraction of the scale's *step*, and this chart's x
        // scale is a continuous `Double` domain (that is what makes exact
        // `chartXVisibleDomain` lengths and uniform bar spacing possible) —
        // it has no step, so every `BarMark` resolved to zero width and no
        // bar chart on the dashboard drew a single bar. Nothing was wrong
        // with the data; the y axis even scaled to include it.
        GeometryReader { geometry in
            let slot = slotWidth(plotWidth: geometry.size.width)
            chart(barWidth: barWidth(slot: slot), positions: bucketPositions)
                .chartLegend(.hidden)
            .chartYAxis(.hidden)
            .chartXScale(domain: -0.5 ... Double(max(buckets.count, 1)) - 0.5)
            .chartYScale(domain: yDomain)
            .chartScrollableAxes(.horizontal)
            .chartXVisibleDomain(length: Double(visibleLength) + peek)
            .chartScrollPosition(x: $scrollIndex)
            .chartXAxis { xAxis(slot: slot) }
            // Selection through the chart's own API, not a transparent plate
            // in `chartOverlay`.
            //
            // The plate is why this chart would not scroll. `chartOverlay`
            // content is layered over the plot as a *sibling* of the scroll
            // view Swift Charts creates for `chartScrollableAxes` — not a
            // descendant of it. A hit-testable view there wins the hit test,
            // and gesture recognizers are only collected from the hit view
            // and its ancestors, so the scroll view's pan was never in the
            // chain: every touch on the plot went to the tap handler and the
            // chart sat still. Nothing about the overlay says "this disables
            // scrolling", which is why it read as a Swift Charts bug.
            .chartXSelection(value: $selectedPosition)
            // A plain tap, on top of the press-and-hold scrub
            // `chartXSelection` gives on its own.
            //
            // Held alone, selection on a *scrollable* chart is gated behind
            // a long press — it has to be, or every scrub would fight the
            // pan for the same drag. But nothing about a bar says "hold
            // me", so the chart read as unresponsive to anyone who tapped
            // one and waited. `chartGesture` hands the gesture the chart's
            // own proxy and lets it live alongside the scroll view's pan
            // rather than in front of it, which is exactly what the
            // `chartOverlay` plate this replaced could not do.
            .chartGesture { proxy in
                SpatialTapGesture()
                    .onEnded { value in proxy.selectXValue(at: value.location.x) }
            }
            .onChange(of: selectedPosition) { _, position in
                select(position)
            }
                .sensoryFeedback(AppTheme.Feedback.selection, trigger: highlighted)
        }
    }

    /// How wide a bar is drawn: its share of the slot, **capped**.
    ///
    /// Proportional alone is right at twelve buckets and wrong at four —
    /// each bar becomes a broad slab, and a chart of five months looked
    /// like a different component from the same chart showing twelve. The
    /// cap holds the bar at a width chosen to look right and lets the *gaps*
    /// grow instead, so the bars stay recognisably the same object at every
    /// resolution. Floored so a crowded chart still draws something.
    private func barWidth(slot: CGFloat) -> CGFloat {
        max(min(slot * 0.58, 16), 4)
    }

    private func chart(barWidth: CGFloat, positions: [Date: Int]) -> some View {
        Chart {
            ForEach(series) { series in
                if let backdrop = series.backdrop {
                    marks(for: backdrop, in: series, isBackdrop: true, style: MarkStyle(barWidth, positions))
                }
                marks(for: series.points, in: series, isBackdrop: false, style: MarkStyle(barWidth, positions))
            }
        }
    }

    /// The two things every mark needs and neither series owns — bundled so
    /// `marks`/`plotted` stay inside the project's `function_parameter_count`
    /// limit while `positions` is passed in rather than rebuilt.
    private struct MarkStyle {
        let barWidth: CGFloat
        let positions: [Date: Int]

        init(_ barWidth: CGFloat, _ positions: [Date: Int]) {
            self.barWidth = barWidth
            self.positions = positions
        }
    }

    /// `ChartContentBuilder` rather than a `ForEach` over a computed array:
    /// a mark's identity has to be stable across a re-render for Swift
    /// Charts to animate it instead of rebuilding it.
    @ChartContentBuilder
    private func marks(
        for points: [MetricPoint], in series: ChartSeries, isBackdrop: Bool, style: MarkStyle
    ) -> some ChartContent {
        ForEach(plotted(points, series: series.id, isBackdrop: isBackdrop, positions: style.positions)) { entry in
            switch series.visualization {
            case .line:
                LineMark(
                    x: .value("Period", entry.position),
                    y: .value("Value", entry.value),
                    series: .value("Series", series.id)
                )
                .foregroundStyle(series.color.opacity(WidgetPalette.dimmedOpacity + 0.25))
                .interpolationMethod(.monotone)
                PointMark(x: .value("Period", entry.position), y: .value("Value", entry.value))
                    .foregroundStyle(colour(series, bucket: entry.bucket, isBackdrop: isBackdrop))
                    .symbolSize(isHighlighted(entry.bucket) ? 90 : 30)
            case .bar:
                // `yStart`/`yEnd` rather than a plain `y`, and that is not a
                // spelling preference: given only `y`, Swift Charts stacks
                // bars that share an x position and a sign. Investing Ratio
                // draws its invested bar *over* a net-worth backdrop, and
                // stacked they summed instead — a full-height backdrop with
                // the invested bar pushed above the top of the y domain,
                // where all that showed was a sliver. Naming both ends says
                // each bar runs from the baseline to its own value.
                BarMark(
                    x: .value("Period", entry.position),
                    yStart: .value("Baseline", 0),
                    yEnd: .value("Value", entry.value),
                    width: .fixed(style.barWidth)
                )
                    .foregroundStyle(colour(series, bucket: entry.bucket, isBackdrop: isBackdrop))
                    // Fully rounded ends rather than a fixed 3pt softening.
                    // Half the bar's own width makes the cap a semicircle at
                    // every width the cap above can produce, so the shape is
                    // one decision rather than a radius that reads as barely
                    // rounded on a wide bar and almost circular on a narrow
                    // one. Swift Charts clamps the radius against the bar's
                    // short side, so a near-zero bar stays a sliver rather
                    // than becoming a dot.
                    .cornerRadius(style.barWidth / 2, style: .continuous)
            }
        }
    }

    /// A backdrop bar is the *scale* rather than the value — Investing
    /// Ratio's net worth behind its invested share — so it stays faint even
    /// when its bucket is the highlighted one. Colouring it like the value
    /// would make two bars compete to be the answer.
    private func colour(_ series: ChartSeries, bucket: Date, isBackdrop: Bool) -> Color {
        guard !isBackdrop else { return series.color.opacity(AppTheme.Opacity.fill) }
        return WidgetPalette.mark(series.color, isHighlighted: isHighlighted(bucket))
    }

    private func isHighlighted(_ bucket: Date) -> Bool { highlighted == bucket }

    /// Points that can actually be drawn, paired with their x position.
    /// A `nil` value is dropped here — that is the gap.
    private func plotted(
        _ points: [MetricPoint], series: String, isBackdrop: Bool, positions: [Date: Int]
    ) -> [PlottedMark] {
        let prefix = isBackdrop ? "\(series)-backdrop" : series
        return points.compactMap { point in
            guard let value = point.value, let index = positions[point.bucket] else { return nil }
            return PlottedMark(
                id: "\(prefix)-\(index)", position: Double(index), bucket: point.bucket, value: value
            )
        }
    }

    // MARK: - Highlighting

    /// Turns a selected x position into the bucket the user meant.
    ///
    /// Clamped rather than rejected: the domain runs half a slot past the
    /// last bucket so the newest bar isn't drawn against the plot edge, and
    /// `rounded()` rounds away from zero — so a tap on the outer half of that
    /// bar resolves to `buckets.count`, which is exactly the bar most likely
    /// to be tapped.
    ///
    /// `isFinite` before `Int(_:)`, because converting a NaN or an infinity
    /// is a hard trap rather than a wrong answer, and this value is produced
    /// by inverting a scale — a division by a plot width that is zero until
    /// the chart has been measured.
    private func select(_ position: Double?) {
        guard let position, position.isFinite, !buckets.isEmpty else { return }
        let bucket = buckets[min(max(Int(position.rounded()), 0), buckets.count - 1)]
        guard bucket != highlighted else { return }
        withAnimation(Self.highlightAnimation) { highlighted = bucket }
    }

    /// **A curve, not a spring** — what stopped bars and points flashing
    /// when tapped. Almost everything a highlight changes is a *colour*:
    /// every mark moves between dimmed and lit (`WidgetPalette.mark`). A
    /// spring overshoots by design, and an overshoot on an interpolated
    /// colour has nowhere to go — it clamps at the end of the ramp and comes
    /// back, which reads as the mark flashing rather than as bounce. The
    /// same `.snappy` was behind the Cashflow toggle's flicker.
    ///
    /// Still animated rather than instant, unlike that toggle: the headline
    /// rolls its digits through `contentTransition(.numericText())`, which
    /// needs a transaction, and a line's point mark really does change size
    /// here. Both want a curve; neither wants bounce.
    private static let highlightAnimation = AppTheme.Motion.colorSafe
}
