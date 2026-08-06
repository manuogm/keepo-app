import Foundation
import Supabase

/// One inbox, one query — `needs_review` is a view with a stable column
/// contract that later phases (12/14/18/19) each extend with their own
/// `UNION ALL` branch, never a schema change this repository has to track.
public enum NeedsReviewRepository {
    public static func fetchAll(client: SupabaseClient) async throws -> [PublicSchema.NeedsReviewSelect] {
        try await client.from("needs_review").select().order("occurred_at", ascending: false).execute().value
    }

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
