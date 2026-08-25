import Charts
import KeepoCore
import SwiftUI

/// One bucket of a charted metric.
///
/// `value` is `nil` for a bucket that could not be computed — a month with
/// no resolvable FX rate, a ratio against a zero net worth. The chart draws
/// **nothing** there rather than a zero, which is money rule 5 expressed as
/// a gap in a line instead of a dip to the axis.
struct MetricPoint: Identifiable, Equatable, Sendable {
    let bucket: Date
    let value: Double?
    /// The same figure as signed minor-unit money, when the metric is money
    /// at all. `nil` for ratios, and for a bucket with no value. Kept
    /// alongside rather than derived, so the headline can format money
    /// through `MoneyFormatter` while the chart plots a `Double` — no
    /// rounding happens twice, and nothing sums the `Double`s (money rule 3).
    let amountE4: Int64?
    /// For a ratio metric, what the value is a share **of** — net worth, for
    /// the investing ratio. Carried alongside rather than loaded as a second
    /// series because it is computed in the same pass anyway, and because it
    /// is the only way to draw a bar proportional to the whole *and* filled
    /// to the share: reading magnitude and ratio off one mark.
    let denominatorE4: Int64?

    var id: Date { bucket }

    init(bucket: Date, value: Double?, amountE4: Int64? = nil, denominatorE4: Int64? = nil) {
        self.bucket = bucket
        self.value = value
        self.amountE4 = amountE4
        self.denominatorE4 = denominatorE4
    }

    /// A money bucket, where the charted value is just the amount at display
    /// scale.
    init(bucket: Date, amountE4: Int64?) {
        self.bucket = bucket
        self.value = amountE4.map { Double($0) / 10_000 }
        self.amountE4 = amountE4
        self.denominatorE4 = nil
    }
}

/// One drawable series. A chart takes several because Cashflow needs three
/// at once (money in, money out, and the net line over them) — every other
/// widget passes one, and passing one is not a special case.
struct ChartSeries: Identifiable, Equatable {
    let id: String
    let points: [MetricPoint]
    let visualization: MetricVisualization
    /// The series' full-strength colour. What actually gets drawn is this
    /// dimmed everywhere except the highlighted bucket — see
    /// `WidgetPalette.mark`.
    let color: Color
    /// Bars whose height should be read against the *series'* own maximum
    /// rather than the chart's. Investing Ratio uses it: its bars are
    /// proportional to net worth, with the invested share filled inside.
    var backdrop: [MetricPoint]?
}

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

/// The expanded widgets' chart: scrollable, zoomable, and highlightable.
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
    /// How many buckets fit on screen. The pinch gesture writes here, and
    /// the owning widget watches it to decide whether the granularity should
    /// change (`MetricZoom`).
    @Binding var visibleBuckets: Int
    /// The leading edge of the visible window, in bucket indices. Owned
    /// outside so the widget can start scrolled to "now" and can re-window
    /// its data as this moves.
    @Binding var scrollIndex: Double

    /// Fewest buckets a pinch can zoom into. Below about four, a line has no
    /// shape left and a bar chart is a row of blocks.
    private let minimumVisible = 4

    @State private var zoomAnchor: Int?
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

    /// The band the y axis covers.
    ///
    /// **Bars are anchored at zero and lines are not**, and that is not a
    /// style preference. A bar's meaning is its length from the baseline, so
    /// a floating baseline silently multiplies every difference between
    /// them. A line's meaning is its shape, and anchoring a running balance
    /// at zero flattens a real month of movement into a rule near the top of
    /// the tile — the exact bug this chart's predecessor shipped with.
    private var yDomain: ClosedRange<Double> {
        let values = series.flatMap { series in
            (series.points + (series.backdrop ?? [])).compactMap(\.value)
        }
        guard let low = values.min(), let high = values.max() else { return 0 ... 1 }
        if series.contains(where: { $0.visualization == .bar }) {
            let floor = min(low, 0)
            let ceiling = max(high, 0)
            return floor == ceiling ? floor ... (ceiling + 1) : floor ... ceiling
        }
        guard high > low else { return (low - 1) ... (high + 1) }
        let padding = (high - low) * 0.18
        return (low - padding) ... (high + padding)
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
            chart(barWidth: barWidth(plotWidth: geometry.size.width))
                .chartLegend(.hidden)
            .chartYAxis(.hidden)
            .chartXScale(domain: -0.5 ... Double(max(buckets.count, 1)) - 0.5)
            .chartYScale(domain: yDomain)
            .chartScrollableAxes(.horizontal)
            .chartXVisibleDomain(length: Double(visibleLength))
            .chartScrollPosition(x: $scrollIndex)
            .chartXAxis { xAxis }
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
            .onChange(of: selectedPosition) { _, position in
                select(position)
            }
            // Pinch coexists with the chart's own horizontal scroll rather
            // than replacing it: `.simultaneousGesture` lets the scroll view
            // keep the pan while the magnification is recognised alongside.
            // Attached with `.gesture` instead, a two-finger touch cancelled
            // the scroll outright and the chart felt stuck.
                .simultaneousGesture(zoomGesture)
                .sensoryFeedback(.selection, trigger: highlighted)
        }
    }

    /// One bucket's slot, less the gutter that keeps neighbouring bars apart.
    /// Floored at two points so a chart zoomed all the way out still draws
    /// something rather than nothing.
    private func barWidth(plotWidth: CGFloat) -> CGFloat {
        max(plotWidth / CGFloat(max(visibleLength, 1)) * 0.62, 2)
    }

    private func chart(barWidth: CGFloat) -> some View {
        Chart {
            ForEach(series) { series in
                if let backdrop = series.backdrop {
                    marks(for: backdrop, in: series, isBackdrop: true, barWidth: barWidth)
                }
                marks(for: series.points, in: series, isBackdrop: false, barWidth: barWidth)
            }
        }
    }

    /// `ChartContentBuilder` rather than a `ForEach` over a computed array:
    /// a mark's identity has to be stable across a re-render for Swift
    /// Charts to animate it instead of rebuilding it.
    @ChartContentBuilder
    private func marks(
        for points: [MetricPoint], in series: ChartSeries, isBackdrop: Bool, barWidth: CGFloat
    ) -> some ChartContent {
        ForEach(plotted(points, series: series.id, isBackdrop: isBackdrop)) { entry in
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
                    width: .fixed(barWidth)
                )
                    .foregroundStyle(colour(series, bucket: entry.bucket, isBackdrop: isBackdrop))
                    .cornerRadius(3)
            }
        }
    }

    /// A backdrop bar is the *scale* rather than the value — Investing
    /// Ratio's net worth behind its invested share — so it stays faint even
    /// when its bucket is the highlighted one. Colouring it like the value
    /// would make two bars compete to be the answer.
    private func colour(_ series: ChartSeries, bucket: Date, isBackdrop: Bool) -> Color {
        guard !isBackdrop else { return series.color.opacity(0.14) }
        return WidgetPalette.mark(series.color, isHighlighted: isHighlighted(bucket))
    }

    private func isHighlighted(_ bucket: Date) -> Bool { highlighted == bucket }

    /// Points that can actually be drawn, paired with their x position.
    /// A `nil` value is dropped here — that is the gap.
    private func plotted(_ points: [MetricPoint], series: String, isBackdrop: Bool) -> [PlottedMark] {
        let positions = Dictionary(uniqueKeysWithValues: buckets.enumerated().map { ($0.element, $0.offset) })
        let prefix = isBackdrop ? "\(series)-backdrop" : series
        return points.compactMap { point in
            guard let value = point.value, let index = positions[point.bucket] else { return nil }
            return PlottedMark(
                id: "\(prefix)-\(index)", position: Double(index), bucket: point.bucket, value: value
            )
        }
    }

    // MARK: - Axis

    /// Labels thinned so they never collide: at twelve visible buckets every
    /// one is labelled, at forty every fourth is. Derived from what is on
    /// screen rather than from the total, so zooming out thins the labels
    /// instead of overprinting them.
    private var xAxis: AxisMarks<some AxisMark> {
        AxisMarks(values: labelIndices) { value in
            AxisValueLabel {
                if let index = value.as(Double.self).map({ Int($0.rounded()) }),
                   buckets.indices.contains(index) {
                    Text(granularity.axisLabel(for: buckets[index], calendar: utcCalendar))
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                        // Without this a week label ("28 Apr–4 May") is
                        // truncated to an ellipsis by the tick's own width
                        // allowance, which reads as a rendering fault.
                        .lineLimit(1)
                        .fixedSize()
                }
            }
        }
    }

    /// Which buckets get a label.
    ///
    /// Two rules, both learned by looking at it. **Density** comes from
    /// what is on screen rather than from the total, so zooming out thins
    /// the labels instead of overprinting them — and a week ("Jul 26–Aug
    /// 1") gets more room than a month ("Jul"). **Position** starts half a
    /// stride in rather than at bucket zero: a label is centred on its
    /// bucket, so one on the very first bucket hangs half its width off the
    /// left edge of the plot and is clipped. Insetting costs nothing — the
    /// axis is a scale, not a list, and the reader takes the interval from
    /// any two labels.
    private var labelIndices: [Double] {
        let perScreen: Double = granularity == .week ? 3 : 5
        let stride = max(Int((Double(visibleLength) / perScreen).rounded(.up)), 1)
        // A week's label is about twice a month's, so it needs twice the
        // inset to clear the plot edge — "Jun 28–Jul 4" starting one bucket
        // in still hung off the left.
        let inset = granularity == .week ? stride : max(stride / 2, 1)
        return Swift.stride(from: inset, to: buckets.count, by: stride).map(Double.init)
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
        withAnimation(.snappy(duration: 0.2)) { highlighted = bucket }
    }

    // MARK: - Zoom

    /// Pinch changes how many buckets are on screen. The owning widget
    /// decides whether that has crossed a resolution boundary — this
    /// gesture only ever reports a count, so the M/Y segments and the pinch
    /// stay one control rather than two that have to agree.
    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let anchor = zoomAnchor ?? visibleBuckets
                if zoomAnchor == nil { zoomAnchor = anchor }
                let scaled = Double(anchor) / max(value.magnification, 0.1)
                visibleBuckets = min(max(Int(scaled.rounded()), minimumVisible), max(buckets.count, minimumVisible))
            }
            .onEnded { _ in zoomAnchor = nil }
    }
}
