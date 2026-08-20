import KeepoCore
import SwiftUI

/// Maps a widget kind to the view that draws it — the single switch, used by
/// both the dashboard and the catalogue. That is the point: a catalogue
/// preview built from its own parallel switch would be a second rendering of
/// the same widget, free to drift from the real one, and the preview's whole
/// job is to promise what the user is about to get.
///
/// The catalogue simply passes `DashboardData.sample` and no interaction;
/// the dashboard passes real data and real callbacks.
struct DashboardWidgetView: View {
    let kind: DashboardWidgetKind
    let data: DashboardData
    /// `nil` when collapsed, otherwise an index into `kind.expandedSizes`.
    /// A step rather than a bool because Cashflow has two expanded sizes
    /// that mean genuinely different things.
    var expansionStep: Int?
    /// Asks the canvas for a size. `nil` collapses.
    var onExpand: (Int?) -> Void = { _ in }
    var loadSeries: (Date, Date) async -> [DashboardSeriesPoint]? = { _, _ in nil }
    var loadFxTrend: (String) async -> [DashboardSeriesPoint]? = { _ in nil }
    var loadCashflow: (CashflowPeriod) async -> CashflowMetrics? = { _ in nil }
    var loadRatioHistory: () async -> [InvestingRatioPoint]? = { nil }

    private var isExpanded: Bool { expansionStep != nil }

    /// What a plain tap on the card means for a widget with one expanded
    /// size: open it, or close it again.
    private var toggle: () -> Void {
        { onExpand(isExpanded ? nil : 0) }
    }

    var body: some View {
        switch kind {
        case .netWorth:
            NetWorthWidget(
                metrics: data.netWorth, currency: data.baseCurrency,
                isExpanded: isExpanded, loadSeries: loadSeries, onTap: toggle
            )
        case .upcomingBills:
            UpcomingBillsWidget(
                metrics: data.upcomingBills, currency: data.baseCurrency,
                isExpanded: isExpanded, onTap: toggle
            )
        case .currencyExposure:
            CurrencyExposureWidget(
                metrics: data.currencyExposure, currency: data.baseCurrency,
                isExpanded: isExpanded, loadTrend: loadFxTrend, onTap: toggle
            )
        case .investingRatio:
            InvestingRatioWidget(
                metrics: data.investingRatio, isExpanded: isExpanded,
                loadHistory: loadRatioHistory, onTap: toggle
            )
        case .cashflow:
            CashflowWidget(
                metrics: data.cashflow, currency: data.baseCurrency,
                expansionStep: expansionStep, load: loadCashflow, onExpand: onExpand
            )
        }
    }
}
