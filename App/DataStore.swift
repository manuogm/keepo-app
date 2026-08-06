import Observation

/// One shared load/loading/error shape for every list screen (Accounts,
/// Transactions, Categories, and everything after), instead of each screen
/// carrying its own trio of `@State` properties and its own copy of the
/// same try/catch. Paired with `RefreshCoordinator`: a screen calls
/// `load(fetch:)` from `.task(id: coordinator.token)`.
///
/// Deliberately just this much for now — no persistence, no offline
/// replay. Phase 11 adds `persist`/`restore` to this exact type once a
/// second real behaviour (a read-through cache surviving app restart)
/// exists to justify it; inventing that shape now, before it's needed,
/// would be exactly the speculative abstraction CLAUDE.md warns against.
@Observable
@MainActor
public final class DataStore<Item> {
    public private(set) var items: [Item] = []
    public private(set) var isLoading = true
    public private(set) var errorMessage: String?

    public init() {}

    public func load(_ fetch: () async throws -> [Item]) async {
        do {
            items = try await fetch()
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }
        isLoading = false
    }
}
