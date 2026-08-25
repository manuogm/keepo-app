import Charts
import KeepoCore
import SwiftUI

/// One wedge of a donut. `value` is always the **magnitude** — a donut can't
/// draw a negative share, so anything signed has to be resolved into
/// something meaningful by the caller before it gets here, not silently
/// absolute-valued at draw time.
struct DonutSlice: Identifiable, Equatable {
    let id: String
    let label: String
    let value: Double
    let color: Color
}

/// The dashboard's donut, with whatever the caller wants in the hole. Shared
/// rather than per-widget so a share of a whole reads identically everywhere
/// it appears — the ring thickness, the inset between wedges, and the way the
/// centre sits inside it are one decision.
struct DonutChartView<Center: View>: View {
    let slices: [DonutSlice]
    /// Fraction of the radius left empty. Wide enough that the ring reads as
    /// a ring at 1×1 rather than as a pie with a dot in it.
    var innerRadius: CGFloat = 0.7
    @ViewBuilder var center: () -> Center

    var body: some View {
        Chart(slices) { slice in
            SectorMark(
                angle: .value(slice.label, slice.value),
                innerRadius: .ratio(innerRadius),
                angularInset: 1.2
            )
            .foregroundStyle(slice.color)
            .cornerRadius(2)
        }
        .chartLegend(.hidden)
        .overlay {
            center()
        }
    }
}

// `CurrencyColor` and `CashflowPalette` used to live here. They moved to
// `Kit/WidgetPalette.swift` once a third widget needed the same answers —
// this file draws a donut and nothing else now.
