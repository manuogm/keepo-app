import Charts
import SwiftUI

/// The trajectory behind a collapsed widget's figure — a stock-ticker line,
/// no axes, no labels, no interaction.
///
/// Replaces `NetWorthChartView`, generalised to any series and either
/// shape, because Net Worth and FX Rate both want exactly this picture and
/// the difference between them is only which numbers go in.
///
/// Renders nothing at all for a series with no shape, rather than an
/// apology. A widget with no trajectory shows its own blank state, and a
/// chart drawing its own "no data" text inside a tile would be a second,
/// competing empty state in the same twelve points of space.
struct WidgetSparkline: View {
    let points: [MetricPoint]
    var color: Color = .primary
    /// `nil` fills whatever height the caller gives it.
    var height: CGFloat?
    /// The gradient wash under the line. Off for anything drawn behind
    /// dense text, where it muddies the figure it sits under.
    var showsArea = true

    var body: some View {
        if hasTrajectory {
            chart
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartLegend(.hidden)
                .chartYScale(domain: domain)
                .frame(height: height)
                .frame(maxHeight: height == nil ? .infinity : nil)
                .allowsHitTesting(false)
        }
    }

    /// Three points, not two. Two can only render as a single straight
    /// segment, which carries no more information than the trend badge above
    /// it while looking exactly like a real chart. A series whose values
    /// never change is the literal flat line the design rules out. Both come
    /// up honestly — a bucket whose total can't be converted is dropped
    /// rather than zeroed, so a user whose FX history is younger than the
    /// window genuinely has only a few plottable buckets.
    private var hasTrajectory: Bool {
        let values = points.compactMap(\.value)
        return values.count >= 3 && Set(values).count > 1
    }

    private var chart: some View {
        Chart(plotted, id: \.bucket) { entry in
            if showsArea {
                // `yStart` is the domain floor, not the default zero
                // baseline. A running balance charted with an area anchored
                // at zero drags the whole domain down to 0 — which is what
                // turned a real month of movement into a flat rule near the
                // top of the tile.
                AreaMark(
                    x: .value("Period", entry.bucket),
                    yStart: .value("Floor", domain.lowerBound),
                    yEnd: .value("Value", entry.value)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [color.opacity(0.25), color.opacity(0)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
            }
            LineMark(x: .value("Period", entry.bucket), y: .value("Value", entry.value))
                .foregroundStyle(color)
                .interpolationMethod(.monotone)
        }
    }

    private var plotted: [(bucket: Date, value: Double)] {
        points.compactMap { point in
            point.value.map { (bucket: point.bucket, value: $0) }
        }
    }

    /// The band the values actually occupy, padded so the line doesn't graze
    /// the tile's edges.
    private var domain: ClosedRange<Double> {
        let values = plotted.map(\.value)
        guard let low = values.min(), let high = values.max() else { return 0 ... 1 }
        guard high > low else { return (low - 1) ... (high + 1) }
        let padding = (high - low) * 0.18
        return (low - padding) ... (high + padding)
    }
}
