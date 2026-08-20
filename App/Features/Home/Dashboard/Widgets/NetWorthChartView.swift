import Charts
import SwiftUI

/// The net-worth trajectory line — drawn once here, in both the places it
/// appears: faint and axis-free behind the collapsed Net Worth widget's
/// figure, and full-size with axes once that widget is expanded.
/// `trendColor` (green/red, from `DashboardTrend`) sets both the line and the
/// gradient under it, for the stock-app read the widget wants.
///
/// Renders nothing at all for an empty series rather than an apology — a
/// widget with no trajectory shows its own blank state, and a chart that
/// draws its own "no data" text inside a tile would be a second, competing
/// empty state in the same 12 points of space.
struct NetWorthChartView: View {
    let seriesPoints: [DashboardSeriesPoint]
    var showAxes = true
    /// `nil` fills whatever height the caller gives it — what the expanded
    /// widget wants, since its tile is a fixed size and the chart should use
    /// all of it rather than leave a band of dead space underneath.
    var height: CGFloat?
    var trendColor: Color = .primary

    var body: some View {
        if !seriesPoints.isEmpty {
            chart
                .chartXAxis(showAxes ? .visible : .hidden)
                .chartYAxis(showAxes ? .visible : .hidden)
                .chartYScale(domain: yDomain)
                .frame(height: height)
                .frame(maxHeight: height == nil ? .infinity : nil)
        }
    }

    private var chart: some View {
        Chart(seriesPoints, id: \.date) { point in
            // Charting is display-only — converting to Double here never
            // feeds back into stored or compared money, so it doesn't touch
            // money rule 3.
            //
            // `yStart` is the domain floor, not the default zero baseline. A
            // net worth trajectory is a running balance, and an area anchored
            // at zero drags the whole domain down to 0 — which is what turned
            // a real month of movement into a flat rule near the top of the
            // chart. Anchoring the fill to the visible floor keeps the area
            // shading without letting it dictate the scale.
            AreaMark(
                x: .value("Date", point.date),
                yStart: .value("Floor", yDomain.lowerBound),
                yEnd: .value("Net worth", displayValue(point))
            )
            .foregroundStyle(
                LinearGradient(
                    colors: [trendColor.opacity(0.25), trendColor.opacity(0)],
                    startPoint: .top, endPoint: .bottom
                )
            )
            LineMark(
                x: .value("Date", point.date), y: .value("Net worth", displayValue(point))
            )
            .foregroundStyle(trendColor)
            .interpolationMethod(.monotone)
        }
    }

    private func displayValue(_ point: DashboardSeriesPoint) -> Double {
        Double(point.value) / 10_000
    }

    /// The band the values actually occupy, padded so the line doesn't graze
    /// the tile's edges. An unchanging series would otherwise produce a
    /// zero-width domain, which Swift Charts renders as an empty plot — the
    /// widget already refuses to draw that case, so this is a floor rather
    /// than a real branch.
    private var yDomain: ClosedRange<Double> {
        let values = seriesPoints.map(displayValue)
        guard let low = values.min(), let high = values.max() else { return 0 ... 1 }
        guard high > low else { return (low - 1) ... (high + 1) }
        let padding = (high - low) * 0.18
        return (low - padding) ... (high + padding)
    }
}
