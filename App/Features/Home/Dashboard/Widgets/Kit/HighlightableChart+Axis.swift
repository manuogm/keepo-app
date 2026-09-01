import Charts
import KeepoCore
import SwiftUI

// The x axis and its gridlines — split from `HighlightableChart.swift`
// purely to stay under this project's `file_length` lint, same convention as
// `DashboardAutoScroll.swift`.

extension HighlightableChart {
    // Not `private`: `HighlightableChart.body` lives in the other file, and
    // a `private` member is invisible to its own type across files.
    //
    /// Every bucket gets a label, written at whichever form fits.
    ///
    /// The previous version thinned the labels instead — one every second
    /// or fourth bucket — and inset the first one so it wouldn't be clipped
    /// by the plot edge. Both were wrong for a chart this short: the
    /// thinning left the reader counting bars to find March, and the inset
    /// moved labels off the buckets they named, which is the misalignment
    /// that was visible on the device. A label centred on its own bucket
    /// and narrow enough to fit that bucket's slot needs neither trick —
    /// the domain already runs half a slot past each end, so a label that
    /// fits one slot cannot hang off the plot.
    func xAxis(slot: CGFloat) -> AxisMarks<some AxisMark> {
        let labels = ChartAxisLabels.fitted(buckets: buckets, granularity: granularity, slotWidth: slot)
        let gridStride = gridStride(slot: slot)
        return AxisMarks(values: buckets.indices.map(Double.init)) { value in
            let index = value.as(Double.self).map { Int($0.rounded()) }
            if showsGridLines, let index, index.isMultiple(of: gridStride) {
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                    .foregroundStyle(AppTheme.Palette.fillStrong)
            }
            // `anchor: .top` — UnitPoint(0.5, 0) — is what actually centres
            // the label on its tick.
            //
            // Given custom content, `AxisValueLabel`'s default anchor puts
            // the label's *leading* edge at the tick, so every label sat
            // half its own width to the right of the bar it named. Measured
            // with a temporary `AxisGridLine`: the gridlines landed exactly
            // on the marks, and the labels landed 14pt to the right of the
            // gridlines. Naming the anchor puts the label's horizontal
            // centre on the tick and its top edge on the axis, which is
            // where a bottom-axis label belongs.
            //
            // Not `centered: true`, which is a different thing — that
            // centres a label within the *step* after its tick, which is
            // right for categorical bars and would move ours half a bucket
            // further right still.
            AxisValueLabel(anchor: .top) {
                if let index, labels.indices.contains(index) {
                    Text(labels[index])
                        .font(AppTheme.Typography.micro)
                        .foregroundStyle(AppTheme.Palette.textSecondary)
                        .lineLimit(1)
                        // **No `fixedSize()`.** It is what put every label
                        // half its own width to the right of the bar it
                        // names — measured on device: three points at
                        // x = 0, 1, 2 carried labels sitting at 0.12, 1.11
                        // and 2.15. A fixed-size label reports a width
                        // larger than the slot Swift Charts allotted it, and
                        // the overflow spills to one side instead of being
                        // centred on the tick. It was there to stop a long
                        // label being truncated; the fitting pass above now
                        // guarantees the label is narrow enough, so the
                        // workaround has nothing left to protect and was
                        // costing the alignment it was hiding behind.
                }
            }
        }
    }

    /// Whether to rule the plot.
    ///
    /// **Line charts only.** A dotted rule is what lets a reader carry a
    /// point on the line down to the month underneath it — without one, a
    /// value halfway along a smooth curve has nothing to be measured
    /// against. A bar does that job itself: it *is* a vertical mark standing
    /// on its own label, so a dotted line drawn through it adds nothing and
    /// takes contrast away from the bar.
    private var showsGridLines: Bool {
        !series.contains { $0.visualization == .bar }
    }

    /// Every bucket where there is room, every other where there isn't.
    ///
    /// Ruled at every bucket a wide chart is legible and a crowded one turns
    /// into hatching — the rules stop reading as reference lines and start
    /// reading as a texture over the data. The threshold is a slot width
    /// rather than a bucket count so it answers the real question (how close
    /// together would these actually be drawn) on any tile size and at any
    /// Dynamic Type setting.
    private func gridStride(slot: CGFloat) -> Int {
        slot >= 24 ? 1 : 2
    }
}
