import KeepoCore
import SwiftUI

/// Every colour decision the dashboard makes, in one place.
///
/// Gathered here from `DonutChartView` (which now only draws a donut) once a
/// third widget needed the same answers. Six widgets that each decided
/// locally what green meant, or how faint an unselected bar should be, would
/// read as six designs — and the user's requirement is the opposite of that:
/// these widgets are meant to be recognisably one family.
enum WidgetPalette {
    /// The default series colour, for anything that is neither a verdict
    /// (up is good, down is bad) nor a user-chosen identity (a category, an
    /// account). Investing Ratio's bars and Cashflow's net line are drawn in
    /// it.
    ///
    /// A real colour set with both appearances, not a literal: `#262626` is
    /// near-black, which is right on the light card and invisible on the
    /// dark one.
    static let neutral = Color("Neutral chart color")

    /// How far back an un-highlighted mark sits.
    ///
    /// The whole chart is drawn dimmed except the highlighted bucket, so the
    /// figure in the headline always has something on the chart that
    /// visibly *is* that figure. One constant rather than a per-widget
    /// opacity, because the contrast between dim and bright is the signal —
    /// two widgets disagreeing about it would read as one of them being
    /// broken.
    static let dimmedOpacity: Double = 0.32

    /// A series colour at the right emphasis for its state.
    static func mark(_ color: Color, isHighlighted: Bool) -> Color {
        isHighlighted ? color : color.opacity(dimmedOpacity)
    }

    /// One step of a ranked ramp of `neutral` — darkest for the largest
    /// share, lighter for each one after it.
    ///
    /// Currency Exposure's bar used to be a different hue per currency,
    /// derived from the code so a currency could never swap colours with
    /// another as balances moved. That guarantee is not worth what it cost:
    /// four unrelated hues on a 2×1 tile read as four *categories*, when the
    /// only thing the bar says is "this one is bigger than that one". A
    /// single-hue ramp says exactly that and nothing more — the ordering is
    /// the information, so the ordering is what the colour encodes.
    ///
    /// The floor matters. Past the fifth currency the shares are slivers a
    /// few points wide, and a ramp that kept lightening would run them into
    /// the card's own fill and lose them entirely.
    static func shade(rank: Int) -> Color {
        neutral.opacity(max(1 - Double(max(rank, 0)) * 0.18, 0.25))
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
/// directions rather than verdicts. The widget spec asks for green income in
/// several places; it loses to the CVD finding, deliberately and on the
/// user's own call.
enum CashflowPalette {
    static var income: Color { adaptive(light: "#2A78D6", dark: "#3987E5") }
    static var expense: Color { adaptive(light: "#FF5A5F", dark: "#F04A50") }
    /// Transfers that cross the current scope's boundary — real movement,
    /// but neither earning nor spending, so it takes the neutral colour
    /// rather than a third hue competing with the two that mean something.
    static var transfer: Color { WidgetPalette.neutral }

    private static func adaptive(light: String, dark: String) -> Color {
        Color(uiColor: UIColor { traits in
            UIColor(Color(hex: traits.userInterfaceStyle == .dark ? dark : light))
        })
    }
}
