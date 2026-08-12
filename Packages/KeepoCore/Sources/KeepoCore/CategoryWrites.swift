import Foundation
import Supabase

public enum CategoryRepository {
    /// `deleted_at is null` filtered here, the one place every caller (the
    /// Categories list, every category picker) goes through — same
    /// convention as `account_balances`' own `where a.deleted_at is null`;
    /// categories have no view of their own to hold this, so it lives on
    /// the query directly.
    public static func fetchAll(client: SupabaseClient) async throws -> [PublicSchema.CategoriesSelect] {
        try await client.from("categories")
            .select()
            .is("deleted_at", value: nil)
            .order("kind")
            .order("name")
            .execute()
            .value
    }

    /// `id` defaults to a fresh `UUID()` for an ordinary online caller; the
    /// offline outbox is the one caller that supplies its own, generated
    /// once before the first send attempt, so a retry of this exact call
    /// reuses the same id and hits `categories`' primary key instead of
    /// inserting a duplicate row — same convention as
    /// `TransactionRepository.create`. `icon`/`color` default to the
    /// name-based heuristic / a random palette entry (`CategoryAppearance`)
    /// when omitted — the caller only ever needs to pass them explicitly
    /// if the user picked something other than the default before saving.
    @discardableResult
    public static func create(
        client: SupabaseClient,
        id: UUID = UUID(),
        ownerId: UUID,
        kind: PublicSchema.CategoryKind,
        name: String,
        icon: String? = nil,
        color: String = CategoryAppearance.randomColor()
    ) async throws -> UUID {
        let resolvedIcon = icon ?? CategoryAppearance.defaultIcon(forName: name, kind: kind)
        let row = NewCategoryRow(id: id, ownerId: ownerId, kind: kind, name: name, icon: resolvedIcon, color: color)
        try await client.from("categories").insert(row).execute()
        return id
    }

    /// Name, icon, and color always saved together — the edit sheet has
    /// nothing to gain from three separate round trips for one Save tap.
    public static func update(
        client: SupabaseClient, categoryId: UUID, name: String, icon: String, color: String
    ) async throws {
        try await client.from("categories")
            .update(AppearancePatch(name: name, icon: icon, color: color))
            .eq("id", value: categoryId)
            .execute()
    }

    /// Rejected by the DB (prevent_default_category_deletion trigger, not
    /// just a hidden UI affordance) if this is one of the two default
    /// "Other" categories.
    public static func softDelete(client: SupabaseClient, categoryId: UUID) async throws {
        try await client.from("categories")
            .update(DeletedAtPatch(deletedAt: PostgresDate.timestampString(Date())))
            .eq("id", value: categoryId)
            .execute()
    }
}

private struct NewCategoryRow: Encodable {
    let id: UUID
    let ownerId: UUID
    let kind: PublicSchema.CategoryKind
    let name: String
    let icon: String
    let color: String
    enum CodingKeys: String, CodingKey {
        case id, kind, name, icon, color
        case ownerId = "owner_id"
    }
}

private struct AppearancePatch: Encodable {
    let name: String
    let icon: String
    let color: String
}

private struct DeletedAtPatch: Encodable {
    let deletedAt: String
    enum CodingKeys: String, CodingKey {
        case deletedAt = "deleted_at"
    }
}

private struct DeleteCategoryParams: Encodable {
    let categoryId: UUID
    enum CodingKeys: String, CodingKey {
        case categoryId = "p_category_id"
    }
}

public extension CategoryRepository {
    /// Read before showing the "N transactions will move to Other" warning
    /// — a plain count under RLS, not an RPC; `transactions_select`'s grant
    /// was never revoked, only `UPDATE` was (Phase 3), so this needs no
    /// elevated access.
    static func transactionCount(client: SupabaseClient, categoryId: UUID) async throws -> Int {
        let response = try await client.from("transactions")
            .select("id", head: true, count: .exact)
            .eq("category_id", value: categoryId)
            .is("deleted_at", value: nil)
            .execute()
        return response.count ?? 0
    }

    /// Reassigns every transaction still pointing at `categoryId` to the
    /// owner's default "Other" category of the same kind, then soft-deletes
    /// it — one atomic server call (`delete_category_and_reassign`), never
    /// two client round-trips, so a dropped connection between them can't
    /// leave a transaction pointing at a gone category. Online-only by
    /// design: the count the confirmation shows is only meaningful if it's
    /// live, so this is deliberately never routed through the offline
    /// outbox (see CategoriesView's confirm-then-call flow).
    @discardableResult
    static func deleteWithReassign(client: SupabaseClient, categoryId: UUID) async throws -> Int {
        try await client.rpc("delete_category_and_reassign", params: DeleteCategoryParams(categoryId: categoryId))
            .execute()
            .value
    }
}
