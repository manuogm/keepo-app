import Charts
import KeepoCore
import SwiftUI

/// Investing Ratio — 1×1 collapsed, 2×2 expanded.
///
/// Collapsed: the share of net worth held in investment accounts, a bar
/// filled to that share, and how it moved this month. Expanded: the same
/// reading at each of the last twelve month-ends.
///
/// The ratio is **invested ÷ net worth**, where net worth is assets minus
/// liabilities — so it answers "how much of what I actually own is
/// invested", and can legitimately pass 100% for someone holding
/// investments against debt. That is shown as it is rather than clamped: a
/// bar pinned at full while the number reads 140% is a truer picture than a
/// number quietly rewritten to fit the bar.
struct InvestingRatioWidget: View {
    let metrics: InvestingRatioMetrics?
    let isExpanded: Bool
    let loadHistory: () async -> [InvestingRatioPoint]?
    let onTap: () -> Void

    @State private var history: [InvestingRatioPoint]?

    var body: some View {
        WidgetChrome(
            title: DashboardWidgetKind.investingRatio.title,
            systemImage: DashboardWidgetKind.investingRatio.systemImage,
            onTap: onTap
        ) {
            content
        }
        .task(id: isExpanded) {
            guard isExpanded, history == nil else { return }
            history = await loadHistory()
        }
    }

    @ViewBuilder
    private var content: some View {
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

    // MARK: - Collapsed

    private func collapsed(_ metrics: InvestingRatioMetrics) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(ratioLabel(metrics.ratio))
                .font(.system(size: 30, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(Color.primary)
                .contentTransition(.numericText())
            fillBar(metrics.ratio)
            WidgetTrendBadge(percentChange: metrics.changeInPoints, unit: "pts", caption: "this month")
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Fills to the ratio, capped at full. The cap is only visual — the
    /// number above it still says 140% when that is the truth.
    private func fillBar(_ ratio: Double?) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.18))
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: proxy.size.width * min(max(ratio ?? 0, 0), 1))
            }
        }
        .frame(height: 6)
    }

    /// Money rule 5's shape, applied to a ratio: unresolvable renders "—",
    /// never 0%.
    private func ratioLabel(_ ratio: Double?) -> String {
        guard let ratio else { return "—" }
        return ratio.formatted(.percent.precision(.fractionLength(0)))
    }

    // MARK: - Expanded

    private func expanded(_ metrics: InvestingRatioMetrics) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(ratioLabel(metrics.ratio))
                    .font(.system(size: 30, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(Color.primary)
                WidgetTrendBadge(percentChange: metrics.changeInPoints, unit: "pts", caption: "this month")
                Spacer(minLength: 0)
            }
            historyChart
        }
    }

    @ViewBuilder
    private var historyChart: some View {
        if let history, history.count >= 2 {
            Chart(history) { point in
                BarMark(
                    x: .value("Month", point.month, unit: .month),
                    y: .value("Invested", point.ratio)
                )
                .foregroundStyle(Color.accentColor.opacity(0.85))
                .cornerRadius(3)
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let ratio = value.as(Double.self) {
                            Text(ratio.formatted(.percent.precision(.fractionLength(0))))
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .month, count: 3)) { _ in
                    AxisValueLabel(format: .dateTime.month(.narrow))
                    AxisTick()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // A single month is not a history, and a chart of one bar reads
            // as a bug rather than as "come back next month".
            Text("A few months of history will show up here.")
                .font(.caption)
                .foregroundStyle(Color.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}
