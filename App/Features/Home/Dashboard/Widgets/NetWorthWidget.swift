import KeepoCore
import SwiftUI

/// Net Worth — 1×2 collapsed, 2×2 expanded.
///
/// Collapsed: the figure, a month-over-month badge, and the trajectory drawn
/// faintly behind both, coloured green or red by that trend the way a stock
/// app colours a ticker. Expanded: the same trajectory full-size with axes,
/// plus the range filter, which loads its own series on demand — a range the
/// user never opens is never computed.
struct NetWorthWidget: View {
    let metrics: NetWorthMetrics?
    let currency: CurrencyInfo?
    let isExpanded: Bool
    /// Loads a series between two dates. Supplied by the dashboard rather
    /// than reached for directly, so this view stays previewable with sample
    /// data and owns no database access of its own. Deliberately takes dates
    /// and not a `NetWorthRange`: what "Custom" means lives in this view,
    /// and handing the caller an enum it can't resolve would make the custom
    /// range silently unloadable.
    let loadSeries: (Date, Date) async -> [DashboardSeriesPoint]?
    /// Expand/collapse, owned by the dashboard — the widget knows whether it
    /// is expanded, never how it got that way.
    let onTap: () -> Void

    @State private var range: NetWorthRange = .month
    @State private var rangeSeries: [DashboardSeriesPoint]?
    @State private var customRange: ClosedRange<Date>?
    @State private var isPickingCustomRange = false

    var body: some View {
        WidgetChrome(
            title: DashboardWidgetKind.netWorth.title, systemImage: DashboardWidgetKind.netWorth.systemImage,
            onTap: onTap
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
        .sheet(isPresented: $isPickingCustomRange) {
            DateRangePickerSheet(range: $customRange)
                .presentationDetents([.medium])
        }
        // Keyed on the range rather than fired on appear: switching W→M→Y
        // reloads exactly once per switch, and collapsing the widget stops
        // it reloading at all.
        .task(id: RangeLoadKey(range: range, custom: customRange, isExpanded: isExpanded)) {
            guard isExpanded else { return }
            let bounds = dateBounds
            rangeSeries = await loadSeries(bounds.from, bounds.through)
        }
    }

    @ViewBuilder
    private func content(_ metrics: NetWorthMetrics) -> some View {
        if isExpanded {
            expanded(metrics)
        } else {
            collapsed(metrics)
        }
    }

    // MARK: - Collapsed

    /// The figure sits top-left with the trajectory pinned along the bottom
    /// of the tile, behind it. Deliberately a `.background` rather than a
    /// `ZStack`: a `ZStack` sizes to its tallest child, so the chart and the
    /// figure end up the same height and draw straight through each other —
    /// the background modifier measures against the filled content frame,
    /// which is the whole tile.
    private func collapsed(_ metrics: NetWorthMetrics) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            BalanceHeaderView(amount: metrics.current, currency: currency, size: 30)
            WidgetTrendBadge(percentChange: metrics.percentChange, caption: "this month")
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(alignment: .bottom) {
            // Absent, never flat: a trajectory with nothing in it draws as a
            // straight rule, which reads as a broken chart rather than as
            // "nothing has happened yet".
            if metrics.hasTrajectory {
                NetWorthChartView(
                    seriesPoints: metrics.series, showAxes: false, height: 58,
                    trendColor: DashboardTrend.color(for: metrics.percentChange)
                )
                .opacity(0.45)
                .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Expanded

    private func expanded(_ metrics: NetWorthMetrics) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                BalanceHeaderView(amount: metrics.current, currency: currency, size: 30)
                Spacer(minLength: 8)
                WidgetTrendBadge(percentChange: metrics.percentChange, caption: "this month")
            }
            chart(metrics)
            rangePicker
        }
    }

    @ViewBuilder
    private func chart(_ metrics: NetWorthMetrics) -> some View {
        let points = rangeSeries ?? metrics.series
        if points.count >= 2 {
            NetWorthChartView(
                seriesPoints: points, showAxes: true,
                trendColor: DashboardTrend.color(for: metrics.percentChange)
            )
            .frame(maxWidth: .infinity)
        } else {
            // Not the widget-level blank state: the figure above is real and
            // still worth showing — it's this one range that has nothing to
            // draw, so say that and leave the rest standing.
            Text("No movement in this range.")
                .font(.caption)
                .foregroundStyle(Color.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var rangePicker: some View {
        HStack(spacing: 0) {
            ForEach(NetWorthRange.allCases) { option in
                Button {
                    if option == .custom {
                        isPickingCustomRange = true
                    }
                    range = option
                } label: {
                    Text(option.label)
                        .font(.caption2.weight(range == option ? .bold : .regular))
                        .foregroundStyle(range == option ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(
                            range == option ? Color.secondary.opacity(0.15) : Color.clear,
                            in: Capsule()
                        )
                }
                .buttonStyle(.pressableRow)
            }
        }
        .sensoryFeedback(.selection, trigger: range)
    }

    /// The dates the current filter actually means. "Custom" before a range
    /// has been picked falls back to a month rather than to an empty chart —
    /// the user has selected the option but not yet answered the question.
    private var dateBounds: (from: Date, through: Date) {
        let today = Date()
        if range == .custom, let customRange {
            return (customRange.lowerBound, customRange.upperBound)
        }
        let days = range.days ?? NetWorthRange.month.days ?? 30
        return (utcCalendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today, today)
    }
}

/// `.task(id:)` needs one `Equatable` id — bundling all three means a range
/// change, a custom-range change, or a collapse triggers exactly one reload.
private struct RangeLoadKey: Equatable {
    let range: NetWorthRange
    let custom: ClosedRange<Date>?
    let isExpanded: Bool
}

/// The expanded widget's range filter. `custom` carries no dates of its own —
/// the widget holds the picked range, because a case with associated values
/// can't be `CaseIterable`, and the picker needs to list every option
/// including the one not yet configured.
enum NetWorthRange: String, CaseIterable, Identifiable, Equatable {
    case week, month, year, custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .week: return "W"
        case .month: return "M"
        case .year: return "Y"
        case .custom: return "Custom"
        }
    }

    /// Days back from today. `custom` has none — the widget substitutes the
    /// picked range before it ever asks.
    var days: Int? {
        switch self {
        case .week: return 7
        case .month: return 30
        case .year: return 365
        case .custom: return nil
        }
    }
}
