import KeepoCore
import SwiftUI

/// The card, the header, the timeframe filter, and the loading loop — the
/// parts every charting widget needs and none of them should own.
///
/// A widget passes its own body; this decides when to load, when to reset,
/// and where the filter sits. That last one matters more than it sounds:
/// the filter appearing in the header's trailing corner *only* when expanded
/// is what makes the collapsed tile stay a clean figure-and-trend card while
/// the expanded one becomes an instrument.
struct SeriesWidgetChrome<Content: View>: View {
    let kind: DashboardWidgetKind
    let series: SeriesWidgetState
    let isExpanded: Bool
    /// `nil` in the catalogue, where the widget is a picture rather than a
    /// live tile — nothing loads, and the preview draws from
    /// `DashboardData.sample`.
    let context: SeriesWidgetState.Context?
    let onTap: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        WidgetChrome(
            title: kind.title,
            systemImage: kind.systemImage,
            accessory: accessory,
            onTap: onTap,
            content: content
        )
        // Keyed on everything that can change what needs loading. Scroll
        // position is rounded to a whole bucket, so dragging through one
        // bucket fires once rather than once a frame — and `refresh` itself
        // returns immediately when the loaded window already covers the
        // visible range, which is the common case while scrolling.
        .task(id: loadKey) {
            guard let context else {
                // No context means the catalogue: show the sample series so
                // the entry is a picture of a working widget, and read
                // nothing.
                series.showPreview(DashboardData.sampleSeries(for: series.config.metric))
                return
            }
            guard isExpanded else { return }
            await series.refresh(context)
        }
        // Collapsing resets the widget to its defaults. The user's own
        // decision: a widget always opens in a known state.
        .onChange(of: isExpanded) { _, expanded in
            if !expanded { series.reset() }
        }
    }

    private var accessory: (() -> AnyView)? {
        guard isExpanded, kind.hasTimeframeFilter else { return nil }
        return {
            AnyView(
                TimeframeFilterView(
                    granularities: kind.allowedGranularities,
                    precision: kind.allowedGranularities.contains(.week) ? .dayMonthYear : .monthYear,
                    timeframe: Binding(
                        get: { series.config.timeframe },
                        // `select`, not a plain assignment: an explicit
                        // choice also resets the bucket count, so the new
                        // resolution isn't immediately zoomed back out of.
                        set: { series.select($0) }
                    )
                )
            )
        }
    }

    private var loadKey: SeriesLoadKey {
        SeriesLoadKey(
            isExpanded: isExpanded,
            timeframe: series.config.timeframe,
            quoteCurrency: series.config.quoteCurrency,
            visibleBuckets: series.visibleBuckets,
            scrollBucket: Int(series.scrollIndex.rounded()),
            token: context?.token ?? 0,
            scope: context?.scope ?? .total
        )
    }
}

/// `.task(id:)` needs one `Equatable` id, and bundling every input means a
/// change to any of them triggers exactly one reload rather than several
/// racing each other.
private struct SeriesLoadKey: Equatable {
    let isExpanded: Bool
    let timeframe: MetricTimeframe
    let quoteCurrency: String?
    let visibleBuckets: Int
    let scrollBucket: Int
    let token: Int
    let scope: PublicSchema.AccountScope
}

/// The expanded chart, or the reason there isn't one.
///
/// Not the widget-level blank state: the headline above is a real figure and
/// still worth showing. It is *this stretch of time* that has nothing to
/// draw, so it says so and leaves the rest standing.
struct SeriesChartOrMessage: View {
    let series: SeriesWidgetState
    let color: Color
    /// What to draw, when it isn't simply the state's own points.
    ///
    /// Investing Ratio is the case this exists for: its points carry the
    /// ratio as their value — which is what the headline and the badge
    /// read — but its *bars* plot the invested amount, so that a column can
    /// be as tall as that period's net worth and filled to the share. The
    /// number and the picture answer the same question in different units,
    /// and forcing one representation on both would break one of them.
    var points: [MetricPoint]?
    /// Drawn faintly behind the bars as the scale they are read against.
    var backdrop: [MetricPoint]?
    /// Several series on one axis, for the widget that needs more than the
    /// one its state is configured for.
    ///
    /// Cashflow is that widget: money in, money out and the net line share an
    /// axis and a highlight, and the toggle above them decides which of the
    /// three is at full strength. Given this, `points`/`backdrop`/`color` are
    /// ignored — the caller has said exactly what to draw.
    var charted: [ChartSeries]?

    private var drawn: [ChartSeries] {
        charted ?? [
            ChartSeries(
                id: series.config.metric.rawValue,
                points: points ?? series.points,
                visualization: series.config.visualization,
                color: color,
                backdrop: backdrop
            )
        ]
    }

    var body: some View {
        if plottable >= 2 {
            HighlightableChart(
                buckets: series.buckets,
                series: drawn,
                granularity: series.granularity,
                highlighted: Binding(get: { series.highlighted }, set: { series.highlighted = $0 }),
                // Through `zoom`, so the chart's pinch is the only thing that
                // can move the granularity — see `SeriesWidgetState.didPinch`.
                visibleBuckets: Binding(get: { series.visibleBuckets }, set: { series.zoom(to: $0) }),
                // Swift Charts owns the writes to this one, and a chart whose
                // plot has not been measured yet can hand back a non-finite
                // position. It is read back as `Int(_:)` in `loadKey`, where
                // a NaN is a hard trap rather than a wrong number, so the
                // invariant is kept at the one place the framework can break
                // it rather than defended at every reader.
                scrollIndex: Binding(
                    get: { series.scrollIndex },
                    set: { if $0.isFinite { series.scrollIndex = $0 } }
                )
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text(series.isLoading ? "Working this out…" : "Not enough history in this period yet.")
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Buckets with a value, across every series drawn. A window can be
    /// twelve months wide and hold two real readings — a missing FX rate
    /// produces no point rather than a zero (money rule 5), so "how many
    /// buckets" is not the question.
    private var plottable: Int {
        drawn.map { $0.points.count { $0.value != nil } }.max() ?? 0
    }
}
