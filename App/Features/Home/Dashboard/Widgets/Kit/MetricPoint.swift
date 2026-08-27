import KeepoCore
import SwiftUI

/// What a dashboard chart is handed: buckets of a metric, grouped into
/// drawable series.
///
/// Split out of `HighlightableChart` because these are the *data* the charts
/// agree on rather than anything about drawing them — the widgets build them,
/// `SeriesWidgetState` loads them, and `WidgetSparkline` plots them without
/// ever involving the interactive chart.

/// One bucket of a charted metric.
///
/// `value` is `nil` for a bucket that could not be computed — a month with
/// no resolvable FX rate, a ratio against a zero net worth. The chart draws
/// **nothing** there rather than a zero, which is money rule 5 expressed as
/// a gap in a line instead of a dip to the axis.
struct MetricPoint: Identifiable, Equatable, Sendable {
    let bucket: Date
    let value: Double?
    /// The same figure as signed minor-unit money, when the metric is money
    /// at all. `nil` for ratios, and for a bucket with no value. Kept
    /// alongside rather than derived, so the headline can format money
    /// through `MoneyFormatter` while the chart plots a `Double` — no
    /// rounding happens twice, and nothing sums the `Double`s (money rule 3).
    let amountE4: Int64?
    /// For a ratio metric, what the value is a share **of** — net worth, for
    /// the investing ratio. Carried alongside rather than loaded as a second
    /// series because it is computed in the same pass anyway, and because it
    /// is the only way to draw a bar proportional to the whole *and* filled
    /// to the share: reading magnitude and ratio off one mark.
    let denominatorE4: Int64?

    var id: Date { bucket }

    init(bucket: Date, value: Double?, amountE4: Int64? = nil, denominatorE4: Int64? = nil) {
        self.bucket = bucket
        self.value = value
        self.amountE4 = amountE4
        self.denominatorE4 = denominatorE4
    }

    /// A money bucket, where the charted value is just the amount at display
    /// scale.
    init(bucket: Date, amountE4: Int64?) {
        self.bucket = bucket
        self.value = amountE4.map { Double($0) / 10_000 }
        self.amountE4 = amountE4
        self.denominatorE4 = nil
    }
}

/// One drawable series. A chart takes several because Cashflow needs three
/// at once (money in, money out, and the net line over them) — every other
/// widget passes one, and passing one is not a special case.
struct ChartSeries: Identifiable, Equatable {
    let id: String
    let points: [MetricPoint]
    let visualization: MetricVisualization
    /// The series' full-strength colour. What actually gets drawn is this
    /// dimmed everywhere except the highlighted bucket — see
    /// `WidgetPalette.mark`.
    let color: Color
    /// Bars whose height should be read against the *series'* own maximum
    /// rather than the chart's. Investing Ratio uses it: its bars are
    /// proportional to net worth, with the invested share filled inside.
    var backdrop: [MetricPoint]?
}
