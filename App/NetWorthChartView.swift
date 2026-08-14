import Charts
import SwiftUI

/// The net-worth trajectory line — shared by `HomeView`'s compact card
/// (`showAxes: false`) and `NetWorthDetailView`'s full chart (`showAxes:
/// true`), so the two only ever draw from one implementation.
struct NetWorthChartView: View {
    let seriesPoints: [(date: Date, value: Int64)]
    var showAxes = true
    var height: CGFloat = 220

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
                LineMark(
                    x: .value("Date", point.date), y: .value("Net worth", Double(point.value) / 10_000)
                )
            }
            .foregroundStyle(Color.primary)
            .chartXAxis(showAxes ? .visible : .hidden)
            .chartYAxis(showAxes ? .visible : .hidden)
            .frame(height: height)
        }
    }
}
