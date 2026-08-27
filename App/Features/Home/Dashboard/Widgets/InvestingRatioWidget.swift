import KeepoCore
import SwiftUI

/// Investing Ratio — 2×1 collapsed, 4×2 expanded.
///
/// The ratio is **invested ÷ net worth**, where net worth is assets minus
/// liabilities — so it answers "how much of what I actually own is
/// invested", and can legitimately pass 100% for someone holding
/// investments against debt. That is shown as it is rather than clamped: a
/// bar pinned at full while the number reads 140% is a truer picture than a
/// number quietly rewritten to fit the bar.
///
/// Collapsed: the percentage, its change, and a bar filled to it. Expanded:
/// the bar rotates into a column at the right-hand end of a run of them, one
/// per period. **Each column's height is that period's net worth**, filled to
/// the invested share — so a ratio that held steady while the money doubled
/// reads as two short bars becoming two tall ones, which a row of
/// equal-height percentage bars would hide completely.
struct InvestingRatioWidget: View {
    let metrics: InvestingRatioMetrics?
    let isExpanded: Bool
    let context: SeriesWidgetState.Context?
    let onTap: () -> Void

    @State private var series = SeriesWidgetState(kind: .investingRatio)
    @State private var showsDrivers = false

    var body: some View {
        SeriesWidgetChrome(
            kind: .investingRatio, series: series, isExpanded: isExpanded, context: context, onTap: onTap
        ) {
            if let metrics, metrics.hasInvestmentAccounts {
                if isExpanded {
                    expanded(metrics)
                } else {
                    collapsed(metrics)
                }
            } else {
                WidgetEmptyState(
                    systemImage: "chart.pie",
                    message: "Mark an account as an investment to track this."
                )
            }
        }
        .onChange(of: isExpanded) { _, expanded in
            if !expanded { showsDrivers = false }
        }
    }

    // MARK: - Collapsed

    /// The bar stands **up the right-hand edge**, full height, rather than
    /// lying along the bottom.
    ///
    /// A ratio is a height, not a distance: this is the one collapsed tile
    /// whose bar means "how full", and standing it up says so before the
    /// figure is read. It also rhymes with what the widget becomes when it
    /// opens — a run of vertical columns — so expanding reads as the same
    /// bar joined by its own history rather than as a change of picture.
    private func collapsed(_ metrics: InvestingRatioMetrics) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                // The caption is stated in full even here, on a 2×1. It does
                // not fit on one line at this width, so the pill wraps onto two
                // — which is the right trade: "-2.2 pts" alone does not say
                // what it is 2.2 points down *against*, and that is the half of
                // the badge a reader actually needs.
                //
                // "pts" rather than "%", even though "%" is two characters
                // shorter and would just fit. This metric is already a
                // percentage, so a move from 30% to 33% is +3 percentage
                // points; writing it "+3%" would be read as three percent of
                // the ratio, which is a different and wrong number.
                MetricHeadlineBlock(
                    value: .percent(metrics.ratio), size: WidgetStyle.metric,
                    percentChange: metrics.changeInPoints, unit: "pts",
                    caption: TrendCaption.collapsed(.month)
                )
                Spacer(minLength: 0)
                accountCount(metrics)
            }
            WidgetFillBar(share: metrics.ratio, axis: .vertical, thickness: 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// How many accounts the figure is spread across — collapsed only, at
    /// the foot of the tile.
    ///
    /// Under the trend badge it was a third line in a stack already two deep,
    /// and read as part of the badge's own caption. On the tile's baseline,
    /// beside the bar, it reads as what it is: a fact about the tile rather
    /// than about the trend.
    ///
    /// Expanded, it isn't drawn at all — the chart is a run of periods by
    /// then, and an account count sitting over it would look like a property
    /// of the highlighted bar rather than of today.
    private func accountCount(_ metrics: InvestingRatioMetrics) -> some View {
        let count = metrics.investmentAccountCount
        return Text(count == 1 ? "1 Account" : "\(count) Accounts")
            .font(.subheadline)
            .foregroundStyle(Color.secondary)
            .lineLimit(1)
    }

    // MARK: - Expanded

    private func expanded(_ metrics: InvestingRatioMetrics) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            MetricHeadlineBlock(
                value: .percent(series.highlightedPoint?.value ?? metrics.ratio), size: WidgetStyle.metricExpanded,
                percentChange: series.pointChange, unit: "pts", caption: badgeCaption
            ) {
                driversToggle
                if showsDrivers {
                    drivers
                }
            }
            chart
        }
    }

    /// What actually moved the ratio. A ratio can fall because investments
    /// shrank *or* because everything else grew, and those are opposite
    /// pieces of news — the chevron is there because the number alone
    /// genuinely cannot tell you which happened.
    ///
    /// `hitTarget` rather than a 44pt `frame`: a real frame made the
    /// headline's whole row 44 points tall, so the trend badge underneath sat
    /// visibly lower than the same badge on the collapsed tile — a gap that
    /// appeared on expand and belonged to nothing on screen.
    private var driversToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.22)) { showsDrivers.toggle() }
        } label: {
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.secondary)
                .rotationEffect(.degrees(showsDrivers ? 90 : 0))
                // A 12pt glyph is far under HIG's 44pt minimum, and this
                // one sits beside the headline where a miss collapses the
                // widget.
                .hitTarget()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(showsDrivers ? "Hide what moved the ratio" : "Show what moved the ratio")
    }

    /// Opens **along the figure's line**, to the right of the chevron.
    ///
    /// Below the trend badge is where these used to go, and it cost the chart
    /// a row of height every time they were shown — the bars visibly shrank
    /// to make room, so asking why the ratio moved changed the picture of how
    /// it moved. The headline's row has empty space to its right at every
    /// width this tile is drawn at, so opening into it costs the chart
    /// nothing.
    private var drivers: some View {
        HStack(spacing: 10) {
            driver(change(\.amountE4), "Investments")
            driver(change(\.denominatorE4), "Networth")
        }
        .transition(.opacity.combined(with: .move(edge: .leading)))
    }

    private func driver(_ percentChange: Double?, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(percentChange.map { String(format: "%+.0f%%", $0) } ?? "—")
                .monospacedDigit()
            Text(label)
        }
        .font(.caption)
        .foregroundStyle(Color.secondary)
        .lineLimit(1)
    }

    /// One side's period-over-period change, in percent. `nil` when either
    /// end is missing or the baseline is zero — money rule 5's shape, so a
    /// driver never reads `0%` when the honest answer is "can't say".
    private func change(_ keyPath: KeyPath<MetricPoint, Int64?>) -> Double? {
        guard let current = series.highlightedPoint?[keyPath: keyPath],
              let previous = series.previousPoint?[keyPath: keyPath], previous != 0
        else { return nil }
        return Double(current - previous) / Double(abs(previous)) * 100
    }

    /// Bars carry two figures at once: the column is net worth, the fill is
    /// what is invested inside it.
    private var chart: some View {
        SeriesChartOrMessage(
            series: series,
            color: WidgetPalette.neutral,
            points: series.points.map { MetricPoint(bucket: $0.bucket, amountE4: $0.amountE4) },
            backdrop: series.points.map { MetricPoint(bucket: $0.bucket, amountE4: $0.denominatorE4) }
        )
    }

    private var badgeCaption: String {
        series.isHighlightingPast
            ? TrendCaption.expanded(series.granularity)
            : TrendCaption.collapsed(series.granularity)
    }
}
