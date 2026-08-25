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

    private func collapsed(_ metrics: InvestingRatioMetrics) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            // No caption here, unlike the expanded tile. This is a 2×1 —
            // one grid column — and at the dashboard's type size the pill
            // cannot hold "-2.2 pts vs last month" without truncating to
            // "vs last mo…", which tells the reader less than leaving it out
            // does. The comparison is stated in full the moment the widget
            // is opened.
            MetricHeadlineBlock(
                value: .percent(metrics.ratio), size: 34,
                percentChange: metrics.changeInPoints, unit: "pts"
            )
            Spacer(minLength: 0)
            WidgetFillBar(share: metrics.ratio, thickness: 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Expanded

    private func expanded(_ metrics: InvestingRatioMetrics) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            MetricHeadlineBlock(
                value: .percent(series.highlightedPoint?.value ?? metrics.ratio), size: 28,
                percentChange: series.pointChange, unit: "pts", caption: badgeCaption
            ) {
                driversToggle
            }
            if showsDrivers {
                drivers
            }
            chart
        }
    }

    /// What actually moved the ratio. A ratio can fall because investments
    /// shrank *or* because everything else grew, and those are opposite
    /// pieces of news — the chevron is there because the number alone
    /// genuinely cannot tell you which happened.
    private var driversToggle: some View {
        Button {
            withAnimation(.snappy(duration: 0.22)) { showsDrivers.toggle() }
        } label: {
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.secondary)
                .rotationEffect(.degrees(showsDrivers ? 90 : 0))
                // A 12pt glyph is far under HIG's 44pt minimum, and this one
                // sits beside the headline where a miss collapses the widget.
                .frame(width: WidgetStyle.minimumTarget, height: WidgetStyle.minimumTarget, alignment: .trailing)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(showsDrivers ? "Hide what moved the ratio" : "Show what moved the ratio")
    }

    private var drivers: some View {
        HStack(spacing: 10) {
            driver(change(\.amountE4), "Investments")
            driver(change(\.denominatorE4), "Networth")
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func driver(_ percentChange: Double?, _ label: String) -> some View {
        HStack(spacing: 3) {
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
