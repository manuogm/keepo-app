import Foundation
import Supabase

/// Plain RLS-scoped table reads/writes, not a versioned RPC layer like
/// `TransactionRepository` — a recurring rule is edited far less often and
/// by nobody but its own owner/household in practice, so the concurrent-
/// edit hazard the transaction RPCs exist to close doesn't apply here with
/// the same force. `owner_id` is derived server-side from `account_id` by
/// trigger (never trusted from the client) — the value passed into
/// `create`/`update` below is a required field in the generated Insert/
/// Update types only because Postgres has no way to express "always
/// overwritten by a BEFORE trigger" in its own NOT NULL metadata; it is
/// discarded the moment the trigger runs.
public enum RecurringRuleRepository {
    public static func fetchAll(client: SupabaseClient) async throws -> [PublicSchema.RecurringRulesSelect] {
        try await client.from("recurring_rules")
            .select()
            .order("next_due_at")
            .execute()
            .value
    }

    public static func fetchOne(client: SupabaseClient, id: UUID) async throws -> PublicSchema.RecurringRulesSelect? {
        let rows: [PublicSchema.RecurringRulesSelect] = try await client.from("recurring_rules")
            .select()
            .eq("id", value: id)
            .execute()
            .value
        return rows.first
    }

    @discardableResult
    // swiftlint:disable:next function_parameter_count
    public static func create(
        client: SupabaseClient,
        ownerId: UUID,
        accountId: UUID,
        categoryId: UUID,
        amountE4: Int64,
        currency: String,
        frequency: PublicSchema.RecurringFrequency,
        nextDueAt: Date
    ) async throws -> UUID {
        let id = UUID()
        let row = PublicSchema.RecurringRulesInsert(
            accountId: accountId, active: true, amountE4: amountE4, categoryId: categoryId, createdAt: nil,
            createdBy: ownerId, currency: currency, frequency: frequency, id: id, lastMaterializedAt: nil,
            nextDueAt: PostgresDate.dateOnlyString(nextDueAt), ownerId: ownerId, updatedAt: nil, version: nil
        )
        try await client.from("recurring_rules").insert(row).execute()
        return id
    }

    // Edits the rule itself — every occurrence materialized from here on
    // uses the new values. A transaction already materialized from this
    // rule is untouched (it's a real historical row, edited if at all
    // through the ordinary `TransactionRepository.update`, never rewritten
    // by a rule change).
    // swiftlint:disable:next function_parameter_count
    public static func update(
        client: SupabaseClient,
        id: UUID,
        accountId: UUID,
        categoryId: UUID,
        amountE4: Int64,
        currency: String,
        frequency: PublicSchema.RecurringFrequency,
        nextDueAt: Date,
        active: Bool
    ) async throws {
        let patch = PublicSchema.RecurringRulesUpdate(
            accountId: accountId, active: active, amountE4: amountE4, categoryId: categoryId, createdAt: nil,
            createdBy: nil, currency: currency, frequency: frequency, id: nil, lastMaterializedAt: nil,
            nextDueAt: PostgresDate.dateOnlyString(nextDueAt), ownerId: nil, updatedAt: nil, version: nil
        )
        try await client.from("recurring_rules").update(patch).eq("id", value: id).execute()
    }

    public static func setActive(client: SupabaseClient, id: UUID, active: Bool) async throws {
        let patch = PublicSchema.RecurringRulesUpdate(
            accountId: nil, active: active, amountE4: nil, categoryId: nil, createdAt: nil, createdBy: nil,
            currency: nil, frequency: nil, id: nil, lastMaterializedAt: nil, nextDueAt: nil, ownerId: nil,
            updatedAt: nil, version: nil
        )
        try await client.from("recurring_rules").update(patch).eq("id", value: id).execute()
    }
}
