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

    /// The two shapes a rule can take, as one value rather than two
    /// optionals a caller could set both of or neither of.
    ///
    /// The server says the same thing as a CHECK
    /// (`recurring_rules_shape_check`): a category and no destination, or a
    /// destination and no category. Modelling it as an enum here means the
    /// impossible combinations cannot be typed, so the only way to hit that
    /// CHECK is a bug somewhere far stranger than a call site.
    public enum Target: Equatable, Sendable {
        /// An expense or income rule, filed under a category.
        case category(UUID)
        /// A transfer rule, moving money to another account of the same
        /// owner in the same currency. Both restrictions are the server's
        /// (see migration 20260927100000) — there is no destination amount
        /// because a cross-currency recurring transfer has no honest one to
        /// store.
        case transfer(toAccountId: UUID)

        /// `public` because the App target's local write-through reads them
        /// too: mirroring an edit has to clear the other shape's column, and
        /// it has to do that from the same value the server write used.
        public var categoryId: UUID? {
            if case .category(let id) = self { return id }
            return nil
        }

        public var toAccountId: UUID? {
            if case .transfer(let id) = self { return id }
            return nil
        }
    }

    @discardableResult
    // swiftlint:disable:next function_parameter_count
    public static func create(
        client: SupabaseClient,
        ownerId: UUID,
        accountId: UUID,
        target: Target,
        amountE4: Int64,
        currency: String,
        frequency: PublicSchema.RecurringFrequency,
        nextDueAt: Date,
        notes: String?,
        title: String? = nil
    ) async throws -> UUID {
        let id = UUID()
        let row = PublicSchema.RecurringRulesInsert(
            accountId: accountId, active: true, amountE4: amountE4, categoryId: target.categoryId, createdAt: nil,
            createdBy: ownerId, currency: currency, frequency: frequency, id: id, lastMaterializedAt: nil,
            nextDueAt: PostgresDate.dateOnlyString(nextDueAt), notes: notes, ownerId: ownerId, syncSeq: nil,
            title: title, toAccountId: target.toAccountId, updatedAt: nil, version: nil
        )
        try await client.from("recurring_rules").insert(row).execute()
        return id
    }

    // Edits the rule itself — every occurrence materialized from here on
    // uses the new values. A transaction already materialized from this
    // rule is untouched (it's a real historical row, edited if at all
    // through the ordinary `TransactionRepository.update`, never rewritten
    // by a rule change).
    // **Not `PublicSchema.RecurringRulesUpdate`, and that is load-bearing.**
    // Swift's synthesized `Encodable` uses `encodeIfPresent` for optionals, so
    // a nil field is OMITTED rather than sent as JSON null — which is exactly
    // what `setActive` below relies on, and exactly what this call cannot
    // afford. Changing a rule's shape has to clear the other shape's column:
    // an expense rule turned into a transfer would keep its `category_id`
    // alongside its new `to_account_id`, which is the one combination
    // `recurring_rules_shape_check` refuses. The save would fail rather than
    // corrupt anything, but failing on a perfectly legal edit is its own bug.
    // `RecurringRuleShapePatch` encodes both columns by hand, one of them as
    // a real null. Same reasoning, same fix as
    // `ProfileRepository`'s own onboarding-reset patch.
    // swiftlint:disable:next function_parameter_count
    public static func update(
        client: SupabaseClient,
        id: UUID,
        accountId: UUID,
        target: Target,
        amountE4: Int64,
        currency: String,
        frequency: PublicSchema.RecurringFrequency,
        nextDueAt: Date,
        active: Bool,
        notes: String?,
        title: String? = nil
    ) async throws {
        let patch = RecurringRuleShapePatch(
            accountId: accountId,
            categoryId: target.categoryId,
            toAccountId: target.toAccountId,
            amountE4: amountE4,
            currency: currency,
            frequency: frequency,
            nextDueAt: PostgresDate.dateOnlyString(nextDueAt),
            active: active,
            notes: notes,
            title: title
        )
        try await client.from("recurring_rules").update(patch).eq("id", value: id).execute()
    }

    /// Replaces a rule's tags with `tagIds`, writing only the difference.
    ///
    /// **Soft-deletes and revives rather than deleting**, exactly like
    /// `transaction_tags`: `(recurring_rule_id, tag_id)` is a primary key and
    /// the rows are tombstones the other device pulls, so removing a tag and
    /// re-adding it must land on the same key rather than fail on it. That is
    /// why re-adding is an upsert with `deleted_at = null` and not an insert.
    ///
    /// `ownerId` is passed but discarded server-side — the trigger derives it
    /// from the rule, because it has to match for the row to land in the
    /// right sync domain. It is here only because the generated Insert type
    /// makes it non-optional.
    public static func setTags(
        client: SupabaseClient, ruleId: UUID, ownerId: UUID, tagIds: Set<UUID>, previous: Set<UUID>
    ) async throws {
        let added = tagIds.subtracting(previous)
        let removed = previous.subtracting(tagIds)

        if !added.isEmpty {
            let rows = added.map { tagId in
                RecurringRuleTagUpsert(recurringRuleId: ruleId, tagId: tagId, ownerId: ownerId)
            }
            try await client.from("recurring_rule_tags")
                .upsert(rows, onConflict: "recurring_rule_id,tag_id")
                .execute()
        }

        for tagId in removed {
            try await client.from("recurring_rule_tags")
                .update(RecurringRuleTagTombstone(deletedAt: PostgresDate.timestampString(Date())))
                .eq("recurring_rule_id", value: ruleId)
                .eq("tag_id", value: tagId)
                .execute()
        }
    }

    /// Pausing and resuming — the list's per-row switch, and the only write
    /// `delete_account` leaves the client to make explicit.
    ///
    /// Here the omit-nil behaviour described above is precisely what is
    /// wanted: every other field stays nil so the patch carries `active`
    /// alone and touches nothing else about the rule.
    public static func setActive(client: SupabaseClient, id: UUID, active: Bool) async throws {
        let patch = PublicSchema.RecurringRulesUpdate(
            accountId: nil, active: active, amountE4: nil, categoryId: nil, createdAt: nil, createdBy: nil,
            currency: nil, frequency: nil, id: nil, lastMaterializedAt: nil, nextDueAt: nil, notes: nil,
            ownerId: nil, syncSeq: nil, title: nil, toAccountId: nil, updatedAt: nil, version: nil
        )
        try await client.from("recurring_rules").update(patch).eq("id", value: id).execute()
    }
}

/// Every field an edit may change, with `category_id` and `to_account_id`
/// **always both present** — one of them as an explicit JSON null.
///
/// See `RecurringRuleRepository.update` for why the generated Update type
/// cannot do this. Only the columns an edit is allowed to touch appear here:
/// `owner_id` is a trigger's to set, `version` a trigger's to bump, and
/// `last_materialized_at` belongs to `materialize_recurring` alone.
private struct RecurringRuleShapePatch: Encodable {
    let accountId: UUID
    let categoryId: UUID?
    let toAccountId: UUID?
    let amountE4: Int64
    let currency: String
    let frequency: PublicSchema.RecurringFrequency
    let nextDueAt: String
    let active: Bool
    /// Nullable and always sent, for the same reason the two shape columns
    /// are: clearing a note has to reach the server as a real null.
    let notes: String?
    /// Sent the same way, for the same reason as `notes`.
    let title: String?

    enum CodingKeys: String, CodingKey {
        case accountId = "account_id"
        case categoryId = "category_id"
        case toAccountId = "to_account_id"
        case amountE4 = "amount_e4"
        case currency = "currency"
        case frequency = "frequency"
        case nextDueAt = "next_due_at"
        case active = "active"
        case notes = "notes"
        case title = "title"
    }

    /// Written out rather than synthesized: `encode` (not `encodeIfPresent`)
    /// on the two optionals is the entire point of this type existing.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(accountId, forKey: .accountId)
        try container.encode(categoryId, forKey: .categoryId)
        try container.encode(toAccountId, forKey: .toAccountId)
        try container.encode(amountE4, forKey: .amountE4)
        try container.encode(currency, forKey: .currency)
        try container.encode(frequency, forKey: .frequency)
        try container.encode(nextDueAt, forKey: .nextDueAt)
        try container.encode(active, forKey: .active)
        try container.encode(notes, forKey: .notes)
        try container.encode(title, forKey: .title)
    }
}

/// An added tag link. `deleted_at` is sent as an explicit null so re-adding a
/// tag revives its tombstone rather than colliding with it.
private struct RecurringRuleTagUpsert: Encodable {
    let recurringRuleId: UUID
    let tagId: UUID
    let ownerId: UUID

    enum CodingKeys: String, CodingKey {
        case recurringRuleId = "recurring_rule_id"
        case tagId = "tag_id"
        case ownerId = "owner_id"
        case deletedAt = "deleted_at"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(recurringRuleId, forKey: .recurringRuleId)
        try container.encode(tagId, forKey: .tagId)
        try container.encode(ownerId, forKey: .ownerId)
        try container.encode(String?.none, forKey: .deletedAt)
    }
}

private struct RecurringRuleTagTombstone: Encodable {
    let deletedAt: String
    enum CodingKeys: String, CodingKey {
        case deletedAt = "deleted_at"
    }
}
