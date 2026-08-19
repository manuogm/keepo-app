import Foundation
import GRDB
import KeepoCore
import Supabase

/// Optimistic local write-through (Phase L6, `keepo-local-first-plan.md`).
///
/// Every `Outbox.submitX` applies its write here, into the SAME table
/// `LocalMoneyQueries` reads, before the network attempt even starts (L7's
/// non-blocking-writes pass — see `Outbox.attempt`'s own header) — the local
/// GRDB mirror otherwise only advances via `SyncEngine.pull()` (sign-in/
/// foreground/reconnect), not immediately after a write. Once every screen
/// reads balances from that local mirror instead of a server-fetched cache
/// (L6), a write that hasn't been pulled back down yet would be invisible —
/// offline, or for the entire (now backgrounded) network round-trip while
/// online — which is exactly the gap `PendingOverlay` used to paper over on
/// top of the *old* cache-based read path. Deleting `PendingOverlay` only
/// stays correct if this file exists: applied here whether the network
/// attempt that follows ultimately succeeds or queues, doesn't matter, it's
/// optimistic either way.
///
/// The eventual real sync pull is what actually corrects this: it upserts
/// the authoritative server row over the same primary key, via
/// `SyncApply.upsertRow` — the identical function this file calls — so an
/// optimistic guess here is never a second, competing source of truth, only
/// a temporary stand-in until the real one arrives. `sync_seq` is written as
/// `0` (never read by any money query — see `LocalMoneyQueries`'s own header
/// on why the local store does no arithmetic keyed on it) purely so the
/// NOT NULL constraint is satisfied; the real pull overwrites it.
///
/// Every write here is best-effort (`try?` at the call site in
/// `Outbox.swift`) — a failure to optimistically reflect a write locally
/// must never block or corrupt the write itself, which is why this file
/// never throws out to a caller that would treat it as the write failing.
///
/// Not covered: `captureTransaction`. Unlike every write here, it needs a
/// read (card → account, merchant → category) before it knows whether it
/// even *can* write anything — see `CaptureLocalWrite.swift`, its own
/// resolve-then-optionally-write counterpart, kept separate for that reason.
enum OutboxLocalWrite {
    static func createTransaction(_ payload: CreateTransactionPayload, in database: Database) throws {
        let now = PostgresDate.sqliteTimestampBoundaryString(Date())
        let categoryKind = try categoryKind(database, categoryId: payload.categoryId.uuidString)
        try SyncApply.upsertRow(
            [
                "id": .string(payload.id.uuidString), "owner_id": .string(payload.ownerId.uuidString),
                "created_by": .string(payload.ownerId.uuidString), "account_id": .string(payload.accountId.uuidString),
                "category_id": .string(payload.categoryId.uuidString),
                "category_kind": categoryKind.map(AnyJSON.string) ?? .null,
                "amount_e4": .integer(Int(payload.amountE4)), "currency": .string(payload.currency),
                "occurred_at": .string(PostgresDate.sqliteTimestampBoundaryString(payload.occurredAt)),
                "notes": payload.notes.map(AnyJSON.string) ?? .null,
                "source": .string("manual"), "status": .string("confirmed"), "version": .integer(1),
                "created_at": .string(now), "updated_at": .string(now), "sync_seq": .integer(0)
            ],
            table: "transactions", in: database
        )
    }

    /// Mirrors `update_transaction`'s own new auto-link step server-side:
    /// resolving a previously-null account on a capture links its card to
    /// that account locally too, so a *second* capture on the same card
    /// resolves through `CaptureLocalWrite` before the next sync pull ever
    /// runs. Reads the row's pre-update state first — `account_id`/
    /// `source`/`card_identifier`/`owner_id` — since the upsert below
    /// overwrites `account_id` unconditionally.
    static func updateTransaction(_ payload: UpdateTransactionPayload, in database: Database) throws {
        let previous = try Row.fetchOne(
            database, sql: "SELECT account_id, source, card_identifier, owner_id FROM transactions WHERE id = ?",
            arguments: [payload.id.uuidString]
        )

        let now = PostgresDate.sqliteTimestampBoundaryString(Date())
        let categoryKind = try categoryKind(database, categoryId: payload.categoryId.uuidString)
        try SyncApply.upsertRow(
            [
                "id": .string(payload.id.uuidString), "account_id": .string(payload.accountId.uuidString),
                "category_id": .string(payload.categoryId.uuidString),
                "category_kind": categoryKind.map(AnyJSON.string) ?? .null,
                "amount_e4": .integer(Int(payload.amountE4)), "currency": .string(payload.currency),
                "occurred_at": .string(PostgresDate.sqliteTimestampBoundaryString(payload.occurredAt)),
                "merchant_raw": payload.merchantRaw.map(AnyJSON.string) ?? .null,
                "notes": payload.notes.map(AnyJSON.string) ?? .null,
                "version": .integer(payload.expectedVersion + 1), "updated_at": .string(now)
            ],
            table: "transactions", in: database
        )

        if let previous, (previous["account_id"] as String?) == nil, (previous["source"] as String?) == "capture",
           let cardIdentifier = previous["card_identifier"] as String?, let ownerId = previous["owner_id"] as String? {
            try linkCardLocally(
                ownerId: ownerId, cardIdentifier: cardIdentifier, accountId: payload.accountId.uuidString, in: database
            )
        }
    }

    /// Mirrors `delete_transaction`'s own fix: deleting an unreviewed
    /// capture takes its orphaned placeholder `card_mappings` row with it
    /// — see `retireOrphanedCardMappingIfNeeded` in
    /// `OutboxLocalWrite+Cards.swift` (split out purely for file-length).
    /// Reads the row's pre-delete `source`/`card_identifier`/`owner_id`
    /// first, same reason `updateTransaction` above does.
    static func deleteTransaction(_ payload: DeleteTransactionPayload, in database: Database) throws {
        let previous = try Row.fetchOne(
            database, sql: "SELECT source, card_identifier, owner_id FROM transactions WHERE id = ?",
            arguments: [payload.id.uuidString]
        )

        let now = PostgresDate.sqliteTimestampBoundaryString(Date())
        try database.execute(
            sql: "UPDATE transactions SET deleted_at = ?, updated_at = ? WHERE id = ?",
            arguments: [now, now, payload.id.uuidString]
        )

        if let previous, (previous["source"] as String?) == "capture",
           let cardIdentifier = previous["card_identifier"] as String?, let ownerId = previous["owner_id"] as String? {
            try retireOrphanedCardMappingIfNeeded(ownerId: ownerId, cardIdentifier: cardIdentifier, in: database)
        }
    }

    /// Both legs get an explicit id from the payload (`fromId`/`toId`) —
    /// unlike edit/delete, a create never has to guess which existing row is
    /// which. `toAmountE4` can be `nil` (a cross-currency transfer whose
    /// receiving-side amount isn't known yet); a leg this file can't price
    /// is simply not written, exactly like the server-side create leaves it
    /// pending — nothing here decides an amount the server itself hasn't.
    static func createTransfer(_ payload: CreateTransferPayload, in database: Database) throws {
        guard
            let ownerId = try accountOwnerId(database, accountId: payload.fromAccountId.uuidString),
            let fromCurrency = try accountCurrency(database, accountId: payload.fromAccountId.uuidString)
        else { return }
        let now = PostgresDate.sqliteTimestampBoundaryString(Date())
        let occurredAt = PostgresDate.sqliteTimestampBoundaryString(payload.occurredAt)
        let groupId = payload.fromId.uuidString

        try SyncApply.upsertRow(
            transferLegRow(
                id: payload.fromId, ownerId: ownerId, accountId: payload.fromAccountId, amountE4: payload.fromAmountE4,
                currency: fromCurrency, occurredAt: occurredAt, groupId: groupId, now: now
            ),
            table: "transactions", in: database
        )
        guard
            let toAmountE4 = payload.toAmountE4,
            let toCurrency = try accountCurrency(database, accountId: payload.toAccountId.uuidString)
        else { return }
        try SyncApply.upsertRow(
            transferLegRow(
                id: payload.toId, ownerId: ownerId, accountId: payload.toAccountId, amountE4: toAmountE4,
                currency: toCurrency, occurredAt: occurredAt, groupId: groupId, now: now
            ),
            table: "transactions", in: database
        )
    }

    /// Legs aren't identified by id here (the payload never carried one) —
    /// matched by their CURRENT sign instead, the same "negative outflow,
    /// positive inflow" convention money rule 1 fixes everywhere else in
    /// this codebase. A transfer edit never flips which side is the send
    /// side, so the sign a leg had before this edit is still the right key
    /// to find it by.
    static func updateTransfer(_ payload: UpdateTransferPayload, in database: Database) throws {
        let now = PostgresDate.sqliteTimestampBoundaryString(Date())
        let occurredAt = PostgresDate.sqliteTimestampBoundaryString(payload.occurredAt)
        try database.execute(
            sql: """
            UPDATE transactions SET amount_e4 = ?, occurred_at = ?, updated_at = ?
            WHERE transfer_group_id = ? AND amount_e4 < 0
            """,
            arguments: [payload.fromAmountE4, occurredAt, now, payload.transferGroupId.uuidString]
        )
        try database.execute(
            sql: """
            UPDATE transactions SET amount_e4 = ?, occurred_at = ?, updated_at = ?
            WHERE transfer_group_id = ? AND amount_e4 > 0
            """,
            arguments: [payload.toAmountE4, occurredAt, now, payload.transferGroupId.uuidString]
        )
    }

    static func deleteTransfer(_ payload: DeleteTransferPayload, in database: Database) throws {
        let now = PostgresDate.sqliteTimestampBoundaryString(Date())
        try database.execute(
            sql: "UPDATE transactions SET deleted_at = ?, updated_at = ? WHERE transfer_group_id = ?",
            arguments: [now, now, payload.transferGroupId.uuidString]
        )
    }

    static func createAccount(_ payload: CreateAccountPayload, in database: Database) throws {
        let now = PostgresDate.sqliteTimestampBoundaryString(Date())
        let today = PostgresDate.dateOnlyString(Date())
        try SyncApply.upsertRow(
            [
                "id": .string(payload.id.uuidString), "owner_id": .string(payload.ownerId.uuidString),
                "created_by": .string(payload.ownerId.uuidString), "kind": .string(payload.kind.rawValue),
                "name": .string(payload.name),
                "currency": .string(payload.currency), "opening_balance_e4": .integer(Int(payload.openingBalanceE4)),
                "opening_balance_at": .string(today), "include_in_total": .bool(true),
                "icon": .string(payload.icon), "color": .string(payload.color),
                "version": .integer(1), "created_at": .string(now),
                "updated_at": .string(now), "sync_seq": .integer(0)
            ],
            table: "accounts", in: database
        )
    }

    static func updateAccount(_ payload: UpdateAccountPayload, in database: Database) throws {
        let now = PostgresDate.sqliteTimestampBoundaryString(Date())
        try SyncApply.upsertRow(
            [
                "id": .string(payload.id.uuidString), "name": .string(payload.name),
                "opening_balance_e4": .integer(Int(payload.openingBalanceE4)),
                "include_in_total": .bool(payload.includeInTotal),
                "icon": .string(payload.icon), "color": .string(payload.color),
                "version": .integer(payload.expectedVersion + 1), "updated_at": .string(now)
            ],
            table: "accounts", in: database
        )
    }

    static func archiveAccount(_ payload: ArchiveAccountPayload, in database: Database) throws {
        let now = PostgresDate.sqliteTimestampBoundaryString(Date())
        try SyncApply.upsertRow(
            [
                "id": .string(payload.id.uuidString),
                "archived_at": payload.archived ? .string(now) : .null,
                "version": .integer(payload.expectedVersion + 1), "updated_at": .string(now)
            ],
            table: "accounts", in: database
        )
    }

    /// Mirrors `set_account_balance`'s own single path now: every account
    /// kind gets an adjustment transaction for the gap between today's
    /// computed balance and the new one (never a stored balance — money
    /// rule "never store a balance").
    static func setAccountBalance(_ payload: SetAccountBalancePayload, in database: Database) throws {
        guard let account = try Row.fetchOne(
            database, sql: "SELECT currency, owner_id FROM accounts WHERE id = ?",
            arguments: [payload.accountId.uuidString]
        ) else { return }
        let now = PostgresDate.sqliteTimestampBoundaryString(Date())
        let today = PostgresDate.dateOnlyString(Date())
        let currency: String = account["currency"]
        let ownerId: String = account["owner_id"]

        let current = try LocalMoneyQueries.accountBalance(
            database, accountId: payload.accountId.uuidString, asOf: today, now: Date()
        ) ?? 0
        let delta = payload.newBalanceE4 - current
        guard delta != 0 else { return }
        try SyncApply.upsertRow(
            [
                "id": .string(payload.id.uuidString), "owner_id": .string(ownerId), "created_by": .string(ownerId),
                "account_id": .string(payload.accountId.uuidString), "category_id": .null,
                "amount_e4": .integer(Int(delta)), "currency": .string(currency), "occurred_at": .string(now),
                "source": .string("adjustment"), "status": .string("confirmed"), "version": .integer(1),
                "created_at": .string(now), "updated_at": .string(now), "sync_seq": .integer(0)
            ],
            table: "transactions", in: database
        )
    }

    static func createCategory(_ payload: CreateCategoryPayload, in database: Database) throws {
        let now = PostgresDate.sqliteTimestampBoundaryString(Date())
        try SyncApply.upsertRow(
            [
                "id": .string(payload.id.uuidString), "owner_id": .string(payload.ownerId.uuidString),
                "kind": .string(payload.kind.rawValue), "name": .string(payload.name), "is_default": .bool(false),
                "icon": .string(payload.icon), "color": .string(payload.color), "version": .integer(1),
                "created_at": .string(now), "updated_at": .string(now), "sync_seq": .integer(0)
            ],
            table: "categories", in: database
        )
    }

    static func updateCategory(_ payload: UpdateCategoryPayload, in database: Database) throws {
        let now = PostgresDate.sqliteTimestampBoundaryString(Date())
        try SyncApply.upsertRow(
            [
                "id": .string(payload.id.uuidString), "name": .string(payload.name), "icon": .string(payload.icon),
                "color": .string(payload.color), "updated_at": .string(now)
            ],
            table: "categories", in: database
        )
    }

    // MARK: - helpers

    /// Not `private` — `OutboxLocalWrite+Capture.swift`'s `reviewCaptureTransaction`
    /// needs it too, same cross-file reuse `linkCardLocally`
    /// (`OutboxLocalWrite+Cards.swift`) already has.
    static func categoryKind(_ database: Database, categoryId: String) throws -> String? {
        try String.fetchOne(database, sql: "SELECT kind FROM categories WHERE id = ?", arguments: [categoryId])
    }

    private static func accountOwnerId(_ database: Database, accountId: String) throws -> String? {
        try String.fetchOne(database, sql: "SELECT owner_id FROM accounts WHERE id = ?", arguments: [accountId])
    }

    private static func accountCurrency(_ database: Database, accountId: String) throws -> String? {
        try String.fetchOne(database, sql: "SELECT currency FROM accounts WHERE id = ?", arguments: [accountId])
    }

    // swiftlint:disable:next function_parameter_count
    private static func transferLegRow(
        id: UUID, ownerId: String, accountId: UUID, amountE4: Int64, currency: String, occurredAt: String,
        groupId: String, now: String
    ) -> JSONObject {
        [
            "id": .string(id.uuidString), "owner_id": .string(ownerId), "created_by": .string(ownerId),
            "account_id": .string(accountId.uuidString), "category_id": .null,
            "amount_e4": .integer(Int(amountE4)), "currency": .string(currency),
            "occurred_at": .string(occurredAt), "transfer_group_id": .string(groupId), "source": .string("manual"),
            "status": .string("confirmed"), "version": .integer(1), "created_at": .string(now),
            "updated_at": .string(now), "sync_seq": .integer(0)
        ]
    }
}
