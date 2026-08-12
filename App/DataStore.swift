import Foundation
import KeepoCore
import Observation

/// One shared load/loading/error shape for every list screen (Accounts,
/// Transactions, Categories, and everything after), instead of each screen
/// carrying its own trio of `@State` properties and its own copy of the
/// same try/catch. Paired with `RefreshCoordinator`: a screen calls
/// `load(fetch:)` from `.task(id: coordinator.token)`.
///
/// `cacheKey`/`restore`/`persist` (Phase 11) are the read-through half of
/// the offline design: `restore` replays whatever the last successful
/// fetch decoded, stamped with `asOf`, so a screen shows *something*
/// immediately on a cold start or while offline instead of a blank
/// spinner. `load` always tries the network first; a failure leaves
/// `items`/`asOf` exactly as they were (stale-but-present) rather than
/// clearing them — the banner elsewhere is what tells the user the data
/// might be old, this type just refuses to make it disappear.
@Observable
@MainActor
public final class DataStore<Item: Codable> {
    public private(set) var items: [Item] = []
    public private(set) var isLoading = true
    public private(set) var errorMessage: String?
    /// `nil` means "live" (the last successful fetch was a real network
    /// round trip this session); set means "restored from the on-device
    /// cache as of this time," never both at once.
    public private(set) var asOf: Date?

    private let cacheKey: String?

    public init(cacheKey: String? = nil) {
        self.cacheKey = cacheKey
    }

    /// Call once, before the first `load`, so cached rows render
    /// immediately rather than waiting on the network.
    public func restore(from cache: PayloadCache) {
        guard let cacheKey, let (data, fetchedAt) = cache.load(key: cacheKey) else { return }
        guard let decoded = try? JSONDecoder().decode([Item].self, from: data) else { return }
        items = decoded
        asOf = fetchedAt
        isLoading = false
    }

    public func load(_ fetch: () async throws -> [Item], cache: PayloadCache? = nil) async {
        do {
            let fetched = try await fetch()
            items = fetched
            asOf = nil
            errorMessage = nil
            if let cacheKey, let cache, let data = try? JSONEncoder().encode(fetched) {
                cache.save(key: cacheKey, data: data)
            }
        } catch {
            // Offline is ambient state, surfaced by the persistent status
            // indicator elsewhere on screen — not a per-fetch red error.
            // Any other failure (RLS, a genuine server error) still shows.
            errorMessage = UserFacingError.isOffline(error) ? nil : UserFacingError.describe(error)
        }
        isLoading = false
    }
}
