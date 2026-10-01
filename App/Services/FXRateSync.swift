import Supabase

/// Fetching fresh ECB rates, in the one place both callers reach for —
/// Profile's "Sync Exchange Rates" row and the transaction form's "Refresh
/// FX rates" button, which appears exactly when a foreign purchase has no
/// rate to convert at (money rule 5).
///
/// **The pull is the half that is easy to leave out, and without it the
/// button does nothing a user can see.** `sync-fx-rates` writes to
/// Postgres, while every conversion the app performs reads the GRDB mirror
/// through `LocalMoneyConversion`. Bumping `RefreshCoordinator` only re-runs
/// each screen's own load against a mirror that has not moved, so the sync
/// has to be followed by `SyncEngine.pull()` before any of it is visible.
/// Profile's row was missing that step and reported success while leaving
/// every local conversion exactly as it found it.
@MainActor
enum FXRateSync {
    /// What Profile has always asked for: enough history to price a
    /// transaction dated a year back, plus the weekends and holidays the
    /// ECB publishes no rate on.
    private static let days = 400

    /// - Parameter invalidatesScreens: bumps `RefreshCoordinator`, so every
    ///   screen reloads against the rates that just landed. **Pass false
    ///   from inside a sheet.** The token is what list screens key their
    ///   `.task(id:)` on, and invalidating the screen presenting a modal
    ///   tears the modal down under the user — which is what the
    ///   transaction form's own Refresh button did before this parameter
    ///   existed. That form re-derives its one figure itself, and whatever
    ///   is behind it reloads when it closes.
    static func run(session: SessionStore, invalidatesScreens: Bool = true) async throws {
        struct Body: Encodable { let days: Int }
        try await session.client.functions.invoke(
            "sync-fx-rates", options: FunctionInvokeOptions(body: Body(days: days))
        )
        await session.syncEngine?.pull()
        if invalidatesScreens { session.refresh.bump() }
    }
}
