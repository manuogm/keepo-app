import Foundation
import Supabase

/// A tag is **a name and nothing else** — no category, no icon, no colour,
/// no target. It is a label that deliberately cuts across categories, which
/// is the one thing a category cannot do.
///
/// Written by direct PostgREST insert/update under RLS, not through an RPC
/// — the same shape `CategoryRepository` uses, and for the same
/// reason: there is no multi-row invariant to hold atomically. `tags_insert`
/// (`owner_id = auth.uid()`) and the `set_transaction_tag_derived_columns`
/// trigger between them enforce everything the server cares about, so an RPC
/// would only be a second name for the same INSERT.
///
/// Every write here goes through the outbox at the call site, never directly
/// — an offline tag edit queues rather than erroring, exactly like an
/// offline category edit.
public enum TagRepository {
    /// `id` defaults to a fresh `UUID()` for an ordinary caller; the outbox
    /// supplies its own, generated once before the first send attempt, so a
    /// retry hits the primary key instead of inserting a duplicate — the
    /// same convention `CategoryRepository.create` uses.
    @discardableResult
    public static func create(
        client: SupabaseClient, id: UUID = UUID(), ownerId: UUID, name: String
    ) async throws -> UUID {
        let row = NewTagRow(id: id, ownerId: ownerId, name: name)
        try await client.from("tags").insert(row).execute()
        return id
    }

    /// A tag is name and nothing else, so a rename is the whole of editing
    /// one — which is why the client edits it inline rather than in a form.
    public static func update(client: SupabaseClient, tagId: UUID, name: String) async throws {
        try await client.from("tags")
            .update(TagPatch(name: name))
            .eq("id", value: tagId)
            .execute()
    }

    /// Soft delete. The server's `tags_cascade_soft_delete` trigger carries
    /// every `transaction_tags` link with it — a tombstone on the tag alone
    /// would leave the other device rendering a chip for a tag that is gone.
    public static func softDelete(client: SupabaseClient, tagId: UUID) async throws {
        try await client.from("tags")
            .update(DeletedAtPatch(deletedAt: PostgresDate.timestampString(Date())))
            .eq("id", value: tagId)
            .execute()
    }

    /// Applying and un-applying are one upsert, not an insert and a delete:
    /// `transaction_tags` is soft-deleted like every other syncable table, so
    /// re-tagging a transaction has to revive the existing row rather than
    /// insert a second one over the same primary key.
    ///
    /// `ownerId` is sent because the column is NOT NULL, but the server
    /// overwrites it from the transaction — see
    /// `set_transaction_tag_derived_columns`. Whatever is sent here is
    /// discarded; it exists only to satisfy the insert.
    public static func setApplied(
        client: SupabaseClient, transactionId: UUID, tagId: UUID, ownerId: UUID, isApplied: Bool
    ) async throws {
        let row = TransactionTagRow(
            transactionId: transactionId,
            tagId: tagId,
            ownerId: ownerId,
            deletedAt: isApplied ? nil : PostgresDate.timestampString(Date())
        )
        try await client.from("transaction_tags")
            .upsert(row, onConflict: "transaction_id,tag_id")
            .execute()
    }
}

private struct NewTagRow: Encodable {
    let id: UUID
    let ownerId: UUID
    let name: String
    enum CodingKeys: String, CodingKey {
        case id, name
        case ownerId = "owner_id"
    }
}

private struct TagPatch: Encodable {
    let name: String
}

private struct TransactionTagRow: Encodable {
    let transactionId: UUID
    let tagId: UUID
    let ownerId: UUID
    let deletedAt: String?
    enum CodingKeys: String, CodingKey {
        case transactionId = "transaction_id"
        case tagId = "tag_id"
        case ownerId = "owner_id"
        case deletedAt = "deleted_at"
    }
}

private struct DeletedAtPatch: Encodable {
    let deletedAt: String
    enum CodingKeys: String, CodingKey {
        case deletedAt = "deleted_at"
    }
}
