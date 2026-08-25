import KeepoCore
import SwiftUI

/// Maps a widget kind to the view that draws it — the single switch, used by
/// both the dashboard and the catalogue. That is the point: a catalogue
/// preview built from its own parallel switch would be a second rendering of
/// the same widget, free to drift from the real one, and the preview's whole
/// job is to promise what the user is about to get.
///
/// The catalogue passes `DashboardData.sample` and **no context**, which is
/// what makes a preview a picture rather than a live tile: with no context
/// nothing queries the database, so opening the catalogue costs no reads at
/// all however many widgets are in it.
struct DashboardWidgetView: View {
    let kind: DashboardWidgetKind
    let data: DashboardData
    /// `nil` when collapsed, otherwise an index into `kind.expandedSizes`.
    /// A step rather than a bool because expansion is the canvas's business
    /// and a widget only ever asks for a size it declared.
    var expansionStep: Int?
    /// Asks the canvas for a size. `nil` collapses.
    var onExpand: (Int?) -> Void = { _ in }
    /// Everything a charting widget needs to load its own series. `nil` in
    /// the catalogue.
    var seriesContext: SeriesWidgetState.Context?
    /// One period's cashflow categories, for the expanded Cashflow widget's
    /// breakdown. Defaults to nothing so the catalogue's previews stay reads
    /// of the database they don't have.
    var loadBreakdown: (ClosedRange<Date>) async -> CashflowTotalsLocal? = { _ in nil }
    /// Opens a recurring rule's edit form. Owned by the canvas, which has the
    /// session a form needs.
    var openRule: (String) -> Void = { _ in }

    private var isExpanded: Bool { expansionStep != nil }

    /// What a plain tap on the card means: open it, or close it again.
    private var toggle: () -> Void {
        { onExpand(isExpanded ? nil : 0) }
    }

    var body: some View {
        switch kind {
        case .netWorth:
            NetWorthWidget(
                metrics: data.netWorth, currency: data.baseCurrency,
                isExpanded: isExpanded, context: seriesContext, onTap: toggle
            )
        case .fxRate:
            FxRateWidget(
                capabilities: data.capabilities, currency: data.baseCurrency,
                isExpanded: isExpanded, context: seriesContext, onTap: toggle
            )
        case .upcomingBills:
            UpcomingBillsWidget(
                metrics: data.upcomingBills, currency: data.baseCurrency,
                isExpanded: isExpanded, openRule: openRule, onTap: toggle
            )
        case .currencyExposure:
            CurrencyExposureWidget(
                metrics: data.currencyExposure, currency: data.baseCurrency,
                isExpanded: isExpanded, onTap: toggle
            )
        case .investingRatio:
            InvestingRatioWidget(
                metrics: data.investingRatio, isExpanded: isExpanded,
                context: seriesContext, onTap: toggle
            )
        case .cashflow:
            CashflowWidget(
                metrics: data.cashflow, currency: data.baseCurrency, isExpanded: isExpanded,
                context: seriesContext, loadBreakdown: loadBreakdown, onTap: toggle
            )
        }
    }
}
