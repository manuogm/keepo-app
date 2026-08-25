import Foundation
import KeepoCore

/// What the canvas hands its widgets so they can read what only they know
/// they need — split out of `DashboardCanvasView.swift` purely for file
/// length, same convention as `DashboardAutoScroll` and
/// `DashboardCanvasCatalog`.
///
/// Everything here exists because the dashboard's own preload can't answer
/// the question: which bucket the user highlighted, which rule they tapped,
/// which window a chart scrolled to. What it deliberately does *not* do is
/// let a widget reach for the database itself — the canvas owns the session,
/// so the catalogue can draw the same widgets with none of this and cost no
/// reads at all.
extension DashboardCanvasView {
    /// What a charting widget needs to load its own series — the queue, the
    /// scope, the base currency, and the refresh token that scopes the series
    /// cache.
    var seriesContext: SeriesWidgetState.Context? {
        guard let baseCurrency = session.profile?.baseCurrency else { return nil }
        return SeriesWidgetState.Context(
            dbQueue: session.dbQueue, scope: session.scope,
            baseCurrency: baseCurrency, token: session.refresh.token
        )
    }

    /// One period's cashflow categories. Read on demand rather than preloaded
    /// with the rest of the dashboard: the expanded widget breaks down
    /// whichever bucket the user highlighted, which is not knowable until they
    /// tap one.
    func loadBreakdown(_ period: ClosedRange<Date>) async -> CashflowTotalsLocal? {
        guard let baseCurrency = session.profile?.baseCurrency else { return nil }
        let moneyScope = LocalMoneyScope(scope: session.scope, baseCurrency: baseCurrency)
        return try? await session.dbQueue.read { database in
            try LocalDashboardQueries.cashflow(database, moneyScope, period: period)
        }
    }

    /// Opens the rule behind an upcoming occurrence.
    ///
    /// The *rule*, not an instance: nothing the Upcoming widget lists has
    /// happened yet — `materialize_recurring()` is the only thing that turns
    /// a due occurrence into a real transaction row, and only up to today.
    func openRule(_ ruleId: String) {
        Task {
            editingRule = try? await session.dbQueue.read { database in
                try LocalTableQueries.recurringRule(database, id: ruleId)
            }
        }
    }
}
