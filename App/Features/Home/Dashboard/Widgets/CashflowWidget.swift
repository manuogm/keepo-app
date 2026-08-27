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
/// produced it as a bar diverging from the tile's centre. Expanded: the same
/// figures as a history — money in and money out as bars either side of zero
/// with the net running across them as a line — and, under it, where the
/// selected side's money actually went.
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
            kind: .cashflow, series: series, isExpanded: isExpanded, context: context, onTap: onTap,
            collapsedAccessory: periodPill
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

    /// The net, then the two directions that produced it.
    ///
    /// The period is not named down here any more. It sits in the header, in
    /// the pill the timeframe filter takes over the moment the widget opens
    /// — the two answer the same question, so only one of them is ever on
    /// screen. Moving it up there also gives the headline its line back:
    /// sharing it with a date meant `minimumScaleFactor` shrank the figure,
    /// and Cashflow's net was visibly smaller than every other tile's
    /// headline while nominally being the same size.
    private func collapsed(_ metrics: CashflowMetrics) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            MetricHeadlineBlock(
                value: .money(metrics.totals.netE4, currency), size: WidgetStyle.metric,
                percentChange: metrics.percentChange, caption: TrendCaption.expanded(.month)
            )
            Spacer(minLength: 0)
            directions(metrics)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Money in growing left from the tile's centre, money out growing
    /// right, each with its own total at the end it reaches for.
    ///
    /// Both halves are scaled against whichever direction was larger
    /// (`CashflowMetrics.fill`), so the month's shape *is* the answer: the
    /// longer side is the side that dominated, read before either figure is.
    /// The two left-aligned bars this replaces shared a start point, which
    /// made "which was bigger" a comparison of two lengths instead.
    private func directions(_ metrics: CashflowMetrics) -> some View {
        VStack(spacing: 4) {
            HStack(alignment: .bottom, spacing: 8) {
                directionTotal(.moneyIn, amountE4: amount(metrics.totals, .moneyIn), alignment: .leading)
                Spacer(minLength: 8)
                directionTotal(.moneyOut, amountE4: amount(metrics.totals, .moneyOut), alignment: .trailing)
            }
            divergingBar(metrics)
        }
    }

    /// The direction, over its own figure, at the outer end of the half it
    /// describes.
    ///
    /// `.magnitude` rather than `.ledger`: the word directly above already
    /// says which way the money went, and a `+` on one column with nothing
    /// on the other would be a third statement of it.
    private func directionTotal(
        _ side: CashflowDirection, amountE4: Int64?, alignment: HorizontalAlignment
    ) -> some View {
        VStack(alignment: alignment, spacing: 0) {
            Text(side.title)
                .font(.caption)
                .foregroundStyle(Color.secondary)
            PrivateText(compactLabel(amountE4))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(side.color)
        }
        .lineLimit(1)
    }

    /// Two halves of the tile, meeting in the middle.
    ///
    /// The left one is the shared fill bar **mirrored**, not a second bar
    /// type: `WidgetFillBar` fills from its leading edge, and flipping it
    /// horizontally puts that edge on the centre line so the fill runs
    /// outward. Reflecting the one bar every widget draws is what keeps the
    /// track weight, the corner and the leftover-track rule identical on
    /// both sides — a hand-rolled trailing-aligned twin would be free to
    /// drift from all three.
    private func divergingBar(_ metrics: CashflowMetrics) -> some View {
        HStack(spacing: 2) {
            WidgetFillBar(
                share: metrics.fill(of: metrics.totals.moneyInE4),
                color: CashflowDirection.moneyIn.color, thickness: 8
            )
            .scaleEffect(x: -1, y: 1)
            WidgetFillBar(
                share: metrics.fill(of: metrics.totals.moneyOutE4),
                color: CashflowDirection.moneyOut.color, thickness: 8
            )
        }
    }

    /// The last finished period's name, for the header's trailing slot.
    /// `nil` — and so no pill at all — when there are no metrics to name.
    private var periodPill: (() -> AnyView)? {
        guard let label = metrics?.periodLabel else { return nil }
        return { AnyView(WidgetHeaderPill(label: label)) }
    }

    private func amount(_ totals: CashflowTotalsLocal, _ side: CashflowDirection) -> Int64? {
        side == .moneyIn ? totals.moneyInE4 : totals.moneyOutE4
    }

    // MARK: - Expanded

    private var expanded: some View {
        VStack(alignment: .leading, spacing: 8) {
            MetricHeadlineBlock(
                value: .money(series.highlightedPoint?.amountE4, currency), size: WidgetStyle.metricExpanded,
                percentChange: series.percentChange, caption: badgeCaption
            )
            SeriesChartOrMessage(series: series, color: WidgetPalette.neutral, charted: chartSeries)
                .frame(minHeight: 128)
            Divider()
            directionNav
            CashflowBreakdownView(
                totals: breakdown, direction: direction, currency: currency,
                period: highlightedRange, isLoading: breakdown == nil
            )
        }
    }

    /// In on one side, Out on the other, the selected side's total between
    /// them — sitting directly on top of the breakdown bar the three of them
    /// govern.
    ///
    /// The two flexible frames are what centres that figure. Equal-priority
    /// flexible views split the leftover width evenly, so the total lands on
    /// the tile's midline whatever the two labels happen to measure; and
    /// unlike an overlay it is still laid out, so an unusually long figure
    /// pushes the buttons apart rather than drawing over them.
    private var directionNav: some View {
        HStack(spacing: 8) {
            segment(.moneyIn)
                .frame(maxWidth: .infinity, alignment: .leading)
            PrivateText(directionTotalLabel)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(direction.color)
                .lineLimit(1)
            segment(.moneyOut)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .sensoryFeedback(.selection, trigger: direction)
    }

    /// In and Out keep their own colours here rather than taking the neutral
    /// selected-state treatment: those two words are blue and coral everywhere
    /// else on this dashboard, and a toggle is the last place they should stop
    /// being.
    /// Switching direction is **not** animated, and that is the fix for a
    /// visible flicker rather than a taste call.
    ///
    /// It used to run inside `withAnimation(.snappy)`. `.snappy` is a spring,
    /// springs overshoot, and what was being sprung here is a *colour*: the
    /// two bar series trade full strength for `opacity(0.3)`. An overshoot on
    /// an interpolated colour clamps at each end and comes back, so both
    /// series bounced past their target and settled — read as the chart
    /// flickering twice. The same transaction also cross-faded the breakdown's
    /// text against itself, which put two amounts on top of each other for the
    /// length of the animation.
    ///
    /// Instant is also the consistent answer: the W/M/Y segments in this same
    /// card's header switch with no animation, and these are the same control.
    private func segment(_ side: CashflowDirection) -> some View {
        WidgetSegment(isSelected: direction == side, tint: side.color, action: {
            direction = side
        }, label: {
            Text(side.title).font(.caption)
        })
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

    /// Rounded and abbreviated, for the collapsed tile only — see
    /// `MoneyFormatter.compact`. The expanded widget has the width for the
    /// exact figure and uses `amountLabel`.
    private func compactLabel(_ amountE4: Int64?) -> String {
        guard let currency else { return "—" }
        return MoneyFormatter.compact(amountE4, currency: currency, signStyle: .magnitude)
    }
}

private struct CashflowBreakdownKey: Equatable {
    let isExpanded: Bool
    let bucket: Date?
    let granularity: MetricGranularity
    let token: Int
    let scope: PublicSchema.AccountScope
}
