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

/// A currency's colour, everywhere it appears. Keyed on the code through
/// `StableSeed`, never on its position in a sorted list — a currency whose
/// balance grows past another's must not swap colours with it.
///
/// Reuses `CategoryAppearance.palette` rather than introducing a second set
/// of chart colours: those values were already chosen to read clearly against
/// both light and dark surfaces, and nothing about them is category-specific.
///
/// The palette's neutral grey is dropped here, and only here. It is a fine
/// default for a category tile, where it reads as "unremarkable", but as a
/// wedge in a chart it reads as "missing" — and this widget already uses grey
/// for the one thing that genuinely is missing. Filtering by value rather
/// than by index keeps this correct if the palette is ever reordered.
enum CurrencyColor {
    private static let palette = CategoryAppearance.palette.filter { $0 != neutral }
    private static let neutral = "#8E8E93"

    static func color(for code: String) -> Color {
        guard !palette.isEmpty else { return Color(hex: neutral) }
        return Color(hex: palette[StableSeed.index(code, upperBound: palette.count)])
    }
}

/// Income and expense, everywhere either appears on the dashboard.
///
/// **Income is blue, not green.** Coral-vs-green is the canonical red-green
/// colour-vision failure (ΔE 7.6); coral-vs-blue clears it (ΔE 19.5). Both
/// values were validated against actual CVD tooling rather than picked by
/// eye — see app-architecture.md §5 — so they are carried forward rather
/// than re-derived. Each has a lighter dark-mode variant, because the light
/// values sit too dark against a dark surface.
///
/// This is not the trend palette: `DashboardTrend` stays green/red, because
/// there "up" genuinely is good news, whereas income and expense are
/// directions rather than verdicts.
enum CashflowPalette {
    static var income: Color { adaptive(light: "#2A78D6", dark: "#3987E5") }
    static var expense: Color { adaptive(light: "#FF5A5F", dark: "#F04A50") }

    private static func adaptive(light: String, dark: String) -> Color {
        Color(uiColor: UIColor { traits in
            UIColor(Color(hex: traits.userInterfaceStyle == .dark ? dark : light))
        })
    }
}
