import Observation

/// The seam that fixes a real bug: SwiftUI's `.task {}` fires once per view
/// identity, not once per appearance — switching `TabView` tabs never
/// retriggers it, so a write made on one tab left every other tab showing
/// stale data until the app relaunched (found while building Phases 1–4;
/// documented in version-logs/lessons-learned.md). Every mutating call in
/// the app bumps `token` once it succeeds; every list screen keys its load
/// off `.task(id: coordinator.token)` instead of a bare `.task {}`, so a
/// write anywhere invalidates every screen, not just the one that made it.
///
/// This is also the seam Phase 11 plugs offline persistence into — `bump()`
/// is exactly where a queued outbox drain will need to trigger the same
/// invalidation once writes can happen without a live network call.
@Observable
@MainActor
public final class RefreshCoordinator {
    public private(set) var token = 0

    public init() {}

    public func bump() {
        token += 1
    }
}
