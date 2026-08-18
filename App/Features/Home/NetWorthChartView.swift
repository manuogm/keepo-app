import Charts
import SwiftUI

/// The net-worth trajectory line — shared by `HomeView`'s compact card
/// (`showAxes: false`) and `NetWorthDetailView`'s full chart (`showAxes:
/// true`), so the two only ever draw from one implementation. `trendColor`
/// (green/red by month-over-month change, computed once by the caller) sets
/// both the line and a gradient fill under it, for the stock-app look both
/// screens want.
struct NetWorthChartView: View {
    let seriesPoints: [(date: Date, value: Int64)]
    var showAxes = true
    var height: CGFloat = 220
    var trendColor: Color = .primary

    var body: some View {
        if seriesPoints.isEmpty {
            Text("No trajectory yet for this scope.")
                .font(.callout)
                .foregroundStyle(Color.secondary)
        } else {
            Chart(seriesPoints, id: \.date) { point in
                // Charting is display-only — converting to Double here never
                // feeds back into stored or compared money, so it doesn't
                // touch money rule 3.
                AreaMark(
                    x: .value("Date", point.date), y: .value("Net worth", Double(point.value) / 10_000)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [trendColor.opacity(0.25), trendColor.opacity(0)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                LineMark(
                    x: .value("Date", point.date), y: .value("Net worth", Double(point.value) / 10_000)
                )
                .foregroundStyle(trendColor)
            }
            .chartXAxis(showAxes ? .visible : .hidden)
            .chartYAxis(showAxes ? .visible : .hidden)
            .frame(height: height)
        }
    }
}

/// Month-over-month change, colored by `HomeView`/`NetWorthDetailView`'s
/// shared trend logic — "—" (money rule 5), never a misleading percentage,
/// when `percentChange` couldn't be computed.
struct TrendBadge: View {
    let percentChange: Double?
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            if let percentChange {
                Image(systemName: percentChange >= 0 ? "arrow.up.right" : "arrow.down.right")
                Text(String(format: "%.1f%% this month", abs(percentChange)))
            } else {
                Text("—")
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.15), in: Capsule())
    }
}
