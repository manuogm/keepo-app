import Foundation
import Supabase

/// `needs_review` the view still backs conflict resolution — every local
/// read of the inbox itself goes through `LocalMoneyQueries.needsReview`
/// instead (X-01: RootView's tab badge and HomeView's bell dot used to
/// compute independently, one from this network view and one from the
/// local mirror, and could disagree — especially offline, where the
/// network read failed silently to an empty list. One source now.)
public enum NeedsReviewRepository {
    /// Idempotent — resolving an already-resolved conflict is a no-op on
    /// the DB side, not an error, so a client retry after a dropped
    /// connection can't fail on the second attempt.
    public static func resolveSyncConflict(client: SupabaseClient, id: UUID) async throws {
        try await client.rpc("resolve_sync_conflict", params: ResolveSyncConflictParams(id: id)).execute()
    }
}

private struct ResolveSyncConflictParams: Encodable {
    let id: UUID
    enum CodingKeys: String, CodingKey {
        case id = "p_id"
    }
}
