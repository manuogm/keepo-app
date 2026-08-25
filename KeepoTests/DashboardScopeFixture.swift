import Foundation
import GRDB

/// A two-pocket world: one personal account, one shared into a household, and
/// the three kinds of movement between them.
///
/// Exists for the rule the Cashflow widget turns on — a transfer counts only
/// when its counterparty sits **outside** the scope being viewed — which
/// cannot be tested without two scopes and a transfer that straddles them.
/// Deliberately separate from `RefereeFixture`, which pins numbers captured
/// from real Postgres and must not gain rows.
enum ScopeFixture {
    static let ownerId = "55555555-5555-5555-5555-555555555555"
    static let householdId = "66666666-6666-6666-6666-666666666666"
    /// Not shared — visible at Total and Personal scope.
    static let personal = "11111111-0000-0000-0000-000000000001"
    /// Shared into the household — visible at Total and Household scope.
    static let shared = "11111111-0000-0000-0000-000000000002"
    static let groceries = "22222222-0000-0000-0000-000000000001"
    static let salary = "22222222-0000-0000-0000-000000000002"

    static let day = "2026-07-10"
    private static let timestamp = "2026-07-10T09:00:00.000000+00:00"
    private static let epoch = "2026-01-01T00:00:00.000000+00:00"

    static func seed(_ database: Database) throws {
        try database.execute(
            sql: "INSERT INTO currencies (code, minor_unit, sync_seq) VALUES ('EUR', 2, 1)"
        )
        try database.execute(
            sql: """
            INSERT INTO profiles (id, base_currency, onboarded_at, created_at, updated_at, sync_epoch, sync_seq)
            VALUES (?, 'EUR', ?, ?, ?, 1, 1)
            """,
            arguments: [ownerId, epoch, epoch, epoch]
        )
        for (id, kind) in [(groceries, "expense"), (salary, "income")] {
            try database.execute(
                sql: """
                INSERT INTO categories (
                    id, owner_id, kind, name, is_default, icon, color, version, created_at, updated_at, sync_seq
                ) VALUES (?, ?, ?, ?, 0, 'cart', '#FF0000', 1, ?, ?, 1)
                """,
                arguments: [id, ownerId, kind, id, epoch, epoch]
            )
        }
        for id in [personal, shared] {
            try database.execute(
                sql: """
                INSERT INTO accounts (
                    id, owner_id, created_by, kind, name, currency, opening_balance_e4, opening_balance_at,
                    include_in_total, icon, color, version, created_at, updated_at, sync_seq
                ) VALUES (?, ?, ?, 'regular', ?, 'EUR', 1000000, '2026-01-01', 1, 'banknote', '#8E8E93', 1, ?, ?, 1)
                """,
                arguments: [id, ownerId, ownerId, id, epoch, epoch]
            )
        }
        try database.execute(
            sql: "INSERT INTO households (id, created_at, sync_seq) VALUES (?, ?, 1)",
            arguments: [householdId, epoch]
        )
        try database.execute(
            sql: """
            INSERT INTO household_members (household_id, user_id, joined_at, sync_seq) VALUES (?, ?, ?, 1)
            """,
            arguments: [householdId, ownerId, epoch]
        )
        try database.execute(
            sql: """
            INSERT INTO household_accounts (household_id, account_id, shared_at, sync_seq) VALUES (?, ?, ?, 1)
            """,
            arguments: [householdId, shared, epoch]
        )
        try seedTransactions(database)
    }

    private static func seedTransactions(_ database: Database) throws {
        // A plain expense and a plain income, both on the personal account —
        // the baseline every scope should agree on.
        try insert(database, id: "aaaa0001", account: personal, category: groceries, kind: "expense", amount: -500_000)
        try insert(database, id: "aaaa0002", account: personal, category: salary, kind: "income", amount: 2_000_000)
        // A transfer *out* of the household account into the personal one.
        // Both legs are in Total scope, so Total must see nothing; Personal
        // sees the inbound leg only, Household the outbound leg only.
        try insert(database, id: "bbbb0001", account: shared, transferGroup: "gggg0001", amount: -800_000)
        try insert(database, id: "bbbb0002", account: personal, transferGroup: "gggg0001", amount: 800_000)
    }

    private static func insert(
        _ database: Database, id: String, account: String, category: String? = nil,
        kind: String? = nil, transferGroup: String? = nil, amount: Int64
    ) throws {
        try database.execute(
            sql: """
            INSERT INTO transactions (
                id, owner_id, created_by, account_id, category_id, category_kind, transfer_group_id,
                amount_e4, currency, occurred_at, source, status, version, created_at, updated_at, sync_seq
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'EUR', ?, 'manual', 'confirmed', 1, ?, ?, 1)
            """,
            arguments: [
                id, ownerId, ownerId, account, category, kind, transferGroup,
                amount, timestamp, timestamp, timestamp
            ]
        )
    }
}
