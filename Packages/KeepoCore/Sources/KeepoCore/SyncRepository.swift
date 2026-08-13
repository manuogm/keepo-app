import Foundation
import Supabase

/// Thin wrapper over the `pull_changes` RPC (Phase L5,
/// `keepo-local-first-plan.md`) — the on-device `SyncEngine` (App target,
/// since it drives the GRDB store) is the only caller. Kept here rather
/// than in the App target because the RPC call itself is portable —
/// exactly the same shape as every other repository in this file's
/// sibling files.
public enum SyncRepository {
    public static func pullChanges(
        client: SupabaseClient, cursor: Int64, globalCursor: Int64
    ) async throws -> PullChangesResult {
        let params = PullChangesParams(cursor: cursor, globalCursor: globalCursor)
        let rows: [PullChangesResult] = try await client.rpc("pull_changes", params: params).execute().value
        guard let result = rows.first else {
            throw SyncRepositoryError.emptyResponse
        }
        return result
    }
}

public enum SyncRepositoryError: Error {
    case emptyResponse
}

/// `payload` is `jsonb` — one key per syncable table, each an array of that
/// table's changed rows (`to_jsonb(row)`, so keys match the local GRDB
/// schema's column names exactly). Decoded as `AnyJSON` rather than a
/// per-table `Codable` struct: 16 tables' worth of duplicate shape
/// declarations here, one of which (`Outbox`'s own storage) already has no
/// server-side Codable counterpart, would be exactly the kind of
/// parallel-copy-of-the-schema CLAUDE.md's reuse principle warns against —
/// `SyncEngine`'s generic upsert reads column names off the JSON object
/// directly instead.
public struct PullChangesResult: Decodable, Sendable {
    public let payload: AnyJSON
    public let nextCursor: Int64
    public let nextGlobalCursor: Int64
    public let syncEpoch: Int64

    public init(payload: AnyJSON, nextCursor: Int64, nextGlobalCursor: Int64, syncEpoch: Int64) {
        self.payload = payload
        self.nextCursor = nextCursor
        self.nextGlobalCursor = nextGlobalCursor
        self.syncEpoch = syncEpoch
    }

    enum CodingKeys: String, CodingKey {
        case payload
        case nextCursor = "next_cursor"
        case nextGlobalCursor = "next_global_cursor"
        case syncEpoch = "sync_epoch"
    }
}

private struct PullChangesParams: Encodable {
    let cursor: Int64
    let globalCursor: Int64
    enum CodingKeys: String, CodingKey {
        case cursor = "p_cursor"
        case globalCursor = "p_global_cursor"
    }
}
