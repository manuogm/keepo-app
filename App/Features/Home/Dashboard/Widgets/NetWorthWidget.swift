import KeepoCore
import SwiftUI

/// Networth Analysis — 2×2 collapsed, 4×2 expanded.
///
/// Collapsed: the figure and its month-over-month badge, with the
/// trajectory drawn faintly behind both and running the full width of the
/// tile, coloured green or red by that trend the way a stock app colours a
/// ticker.
///
/// Expanded: the same trajectory becomes the subject — full size, scrollable
/// through time, zoomable, and highlightable. The headline shrinks and
/// starts reading whichever bucket is highlighted, so the number and the
/// chart are never describing different months.
struct NetWorthWidget: View {
    let metrics: NetWorthMetrics?
    let currency: CurrencyInfo?
    let isExpanded: Bool
    let context: SeriesWidgetState.Context?
    let onTap: () -> Void

    @State private var series = SeriesWidgetState(kind: .netWorth)

    var body: some View {
        SeriesWidgetChrome(
            kind: .netWorth, series: series, isExpanded: isExpanded, context: context, onTap: onTap
        ) {
            if let metrics, metrics.current != nil {
                content(metrics)
            } else {
                WidgetEmptyState(
                    systemImage: "chart.line.flattrend.xyaxis",
                    message: "Not enough data yet to work out your net worth."
                )
            }
        }
    }

    @ViewBuilder
    private func content(_ metrics: NetWorthMetrics) -> some View {
        if isExpanded {
            expanded
        } else {
            collapsed(metrics)
        }
    }

    // MARK: - Collapsed

    /// Figure and badge sit top-left with the trajectory pinned along the
    /// bottom, behind them.
    ///
    /// Deliberately a `.background` rather than a `ZStack`: a `ZStack` sizes
    /// to its tallest child, so the chart and the figure end up the same
    /// height and draw straight through each other. The background modifier
    /// measures against the filled content frame, which is the whole tile.
    private func collapsed(_ metrics: NetWorthMetrics) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            MetricHeadlineBlock(
                value: .money(metrics.current, currency), size: WidgetStyle.metric,
                percentChange: metrics.percentChange, caption: TrendCaption.collapsed(.month)
            )
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(alignment: .bottom) {
            // Absent, never flat: a trajectory with nothing in it draws as a
            // straight rule, which reads as a broken chart rather than as
            // "nothing has happened yet".
            WidgetSparkline(
                points: metrics.series.map { MetricPoint(bucket: $0.date, amountE4: $0.value) },
                color: DashboardTrend.color(for: metrics.percentChange),
                height: 64
            )
            .opacity(0.5)
            .padding(.horizontal, -WidgetStyle.padding)
        }
        // The trajectory is drawn the full width of the tile, headline
        // included — that is what makes the tile read as a ticker rather
        // than a label. The wash is what keeps the figure legible where the
        // line passes behind it.
        .metricLegibilityScrim()
    }

    // MARK: - Expanded

    private var expanded: some View {
        VStack(alignment: .leading, spacing: 8) {
            MetricHeadlineBlock(
                value: .money(series.highlightedPoint?.amountE4, currency), size: WidgetStyle.metricExpanded,
                percentChange: series.percentChange, caption: badgeCaption
            )
            SeriesChartOrMessage(series: series, color: trendColor)
        }
    }

    /// Green or red by the movement across the stretch of time on screen —
    /// not by the highlighted bucket's own comparison. Highlighting the
    /// earliest bucket has no predecessor to compare against, and colouring
    /// the line by that turned the whole chart grey while the trajectory it
    /// was drawing had not changed at all.
    private var trendColor: Color {
        DashboardTrend.color(for: series.overallChange)
    }

    private var badgeCaption: String {
        series.isHighlightingPast
            ? TrendCaption.expanded(series.granularity)
            : TrendCaption.collapsed(series.granularity)
    }
}
