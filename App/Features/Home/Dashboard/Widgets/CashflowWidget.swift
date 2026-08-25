import KeepoCore
import SwiftUI

/// Which side of the ledger the breakdown is about.
enum CashflowDirection: String, Identifiable, Equatable, CaseIterable {
    case moneyIn
    case moneyOut

    var id: String { rawValue }
    var title: String { self == .moneyIn ? "Money In" : "Money Out" }
    var shortTitle: String { self == .moneyIn ? "In" : "Out" }
    var color: Color { self == .moneyIn ? CashflowPalette.income : CashflowPalette.expense }
    var categoryKind: PublicSchema.CategoryKind { self == .moneyIn ? .income : .expense }
    var metric: MetricKind { self == .moneyIn ? .moneyIn : .moneyOut }
}

/// Cashflow Breakdown — 2×2 collapsed, 6×2 expanded.
///
/// Collapsed: what was left over last period, and the two directions that
/// produced it. Expanded: the same figures as a history — money in and money
/// out as bars either side of zero with the net running across them as a
/// line — and, under it, where the selected side's money actually went.
///
/// **One toggle drives both.** Picking In or Out brings that side's bars to
/// full strength *and* is what the donut and the list below are breaking
/// down. Two controls would have let the chart and the list disagree about
/// which question was being asked.
///
/// The net line is always drawn and always neutral, whichever side is
/// selected: it is the answer the widget's headline is reading, so it can
/// never be the thing that gets dimmed away.
struct CashflowWidget: View {
    /// The preloaded last-complete period, which is what the collapsed tile
    /// shows. Arrives with the dashboard's own refresh, so a collapsed
    /// Cashflow costs no read of its own.
    let metrics: CashflowMetrics?
    let currency: CurrencyInfo?
    let isExpanded: Bool
    let context: SeriesWidgetState.Context?
    /// One period's categories. Called only while expanded, and only when the
    /// highlighted bucket changes — the breakdown follows the bar the user
    /// tapped, so it has to be read for that bucket rather than for whichever
    /// window happened to be preloaded.
    let loadBreakdown: (ClosedRange<Date>) async -> CashflowTotalsLocal?
    let onTap: () -> Void

    @State private var series = SeriesWidgetState(kind: .cashflow)
    @State private var direction: CashflowDirection = .moneyOut
    @State private var breakdown: CashflowTotalsLocal?

    var body: some View {
        SeriesWidgetChrome(
            kind: .cashflow, series: series, isExpanded: isExpanded, context: context, onTap: onTap
        ) {
            content
        }
        .onChange(of: isExpanded) { _, expanded in
            if !expanded {
                direction = .moneyOut
                breakdown = nil
            }
        }
        .task(id: breakdownKey) { await refreshBreakdown() }
    }

    @ViewBuilder
    private var content: some View {
        if isExpanded {
            expanded
        } else if let metrics, metrics.totals.moneyInE4 != nil || metrics.totals.moneyOutE4 != nil {
            collapsed(metrics)
        } else {
            WidgetEmptyState(
                systemImage: "arrow.up.arrow.down",
                message: "Nothing moved in \(metrics?.periodLabel ?? "this period")."
            )
        }
    }

    // MARK: - Collapsed

    private func collapsed(_ metrics: CashflowMetrics) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            MetricHeadlineBlock(
                value: .money(metrics.totals.netE4, currency), size: 30,
                percentChange: metrics.percentChange, caption: "vs. previous"
            ) {
                Text(metrics.periodLabel)
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
            }
            Text(rateLabel(metrics.totals.savingsRate, period: metrics.periodLabel))
                .font(.caption)
                .foregroundStyle(Color.secondary)
                .monospacedDigit()
            Spacer(minLength: 0)
            ForEach(CashflowDirection.allCases) { side in
                directionRow(side, amountE4: amount(metrics.totals, side), fill: metrics.fill(of: amount(
                    metrics.totals, side
                )))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// "kept 32% of what came in". Not "of income": once a transfer crossing
    /// the scope boundary counts as an inflow, the denominator is money that
    /// arrived rather than money that was earned, and the label has to say
    /// which. `nil` — nothing came in — names the period instead of a 0% that
    /// would read as a real result.
    private func rateLabel(_ rate: Double?, period: String) -> String {
        guard let rate else { return "in \(period)" }
        return "kept \(rate.formatted(.percent.precision(.fractionLength(0)))) of what came in"
    }

    private func directionRow(_ side: CashflowDirection, amountE4: Int64?, fill: Double) -> some View {
        HStack(spacing: 8) {
            Text(side.title)
                .font(.caption)
                .foregroundStyle(Color.secondary)
                .frame(width: 74, alignment: .leading)
            WidgetFillBar(share: fill, color: side.color, thickness: 8)
            Text(amountLabel(amountE4))
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(Color.primary)
                .lineLimit(1)
        }
    }

    private func amount(_ totals: CashflowTotalsLocal, _ side: CashflowDirection) -> Int64? {
        side == .moneyIn ? totals.moneyInE4 : totals.moneyOutE4
    }

    // MARK: - Expanded

    private var expanded: some View {
        VStack(alignment: .leading, spacing: 8) {
            MetricHeadlineBlock(
                value: .money(series.highlightedPoint?.amountE4, currency), size: 28,
                percentChange: series.percentChange, caption: badgeCaption
            ) {
                Text(bucketLabel)
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
            }
            toggle
            SeriesChartOrMessage(series: series, color: WidgetPalette.neutral, charted: chartSeries)
                .frame(minHeight: 130)
            Divider()
            CashflowBreakdownView(
                totals: breakdown, direction: direction, currency: currency,
                period: highlightedRange, isLoading: breakdown == nil
            )
        }
    }

    /// In and Out keep their own colours here rather than taking the neutral
    /// selected-state treatment: those two words are blue and coral everywhere
    /// else on this dashboard, and a toggle is the last place they should stop
    /// being.
    private var toggle: some View {
        HStack(spacing: 4) {
            ForEach(CashflowDirection.allCases) { side in
                WidgetSegment(isSelected: direction == side, tint: side.color, action: {
                    withAnimation(.snappy(duration: 0.2)) { direction = side }
                }, label: {
                    Text(side.title).font(.caption)
                })
            }
            Spacer(minLength: 0)
            Text(directionTotalLabel)
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(direction.color)
        }
        .sensoryFeedback(.selection, trigger: direction)
    }

    /// Three series on one axis: the two directions as bars either side of
    /// zero, the net as a line across them. The unselected direction is
    /// muted at source rather than by the chart, which dims by *highlight* —
    /// the two are different questions and stacking them would leave the
    /// selected side's un-highlighted bars almost invisible.
    private var chartSeries: [ChartSeries] {
        CashflowDirection.allCases.map { side in
            ChartSeries(
                id: side.rawValue,
                points: series.series(side.metric),
                visualization: .bar,
                color: side == direction ? side.color : side.color.opacity(0.3)
            )
        } + [
            ChartSeries(
                id: "net", points: series.points, visualization: .line, color: WidgetPalette.neutral
            )
        ]
    }

    private var directionTotalLabel: String {
        amountLabel(series.series(direction.metric).first { $0.bucket == series.highlighted }?.amountE4)
    }

    private var bucketLabel: String {
        guard let bucket = series.highlighted else { return "" }
        return series.granularity.fullLabel(for: bucket, calendar: utcCalendar)
    }

    private var badgeCaption: String {
        series.isHighlightingPast
            ? TrendCaption.expanded(series.granularity)
            : TrendCaption.collapsed(series.granularity)
    }

    // MARK: - Breakdown loading

    /// The days the highlighted bucket covers — the window the breakdown is
    /// read over, and the period the Transactions screen is handed when a
    /// category's chevron is tapped.
    private var highlightedRange: ClosedRange<Date>? {
        guard let bucket = series.highlighted else { return nil }
        let granularity = series.granularity
        let start = granularity.bucketStart(for: bucket, calendar: utcCalendar)
        let end = granularity.evaluationDate(forBucket: bucket, now: Date(), calendar: utcCalendar)
        return start ... max(start, end)
    }

    private func refreshBreakdown() async {
        guard isExpanded, let range = highlightedRange else {
            breakdown = nil
            return
        }
        breakdown = await loadBreakdown(range)
    }

    private var breakdownKey: CashflowBreakdownKey {
        CashflowBreakdownKey(
            isExpanded: isExpanded, bucket: series.highlighted, granularity: series.granularity,
            token: context?.token ?? 0, scope: context?.scope ?? .total
        )
    }

    private func amountLabel(_ amountE4: Int64?) -> String {
        guard let currency else { return "—" }
        return MoneyFormatter.format(amountE4, currency: currency, signStyle: .ledger)
    }
}

private struct CashflowBreakdownKey: Equatable {
    let isExpanded: Bool
    let bucket: Date?
    let granularity: MetricGranularity
    let token: Int
    let scope: PublicSchema.AccountScope
}
