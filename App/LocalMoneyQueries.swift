import Foundation
import GRDB
import KeepoCore

/// SQLite port of the server's money-layer functions (Phase L4,
/// `keepo-local-first-plan.md` — "the make-or-break phase"). Every function
/// here does what the identically-named Postgres function/view does,
/// against the local mirror instead of Postgres: same predicates, same
/// money rules, same null propagation (money rule 5 — unresolvable is
/// `nil`, never `0`).
///
/// FX conversion is deliberately **not** ported to SQL, per the plan:
/// "One shared Swift function, exact wide arithmetic, implementing the L1
/// rounding contract, called at the display boundary on already-aggregated
/// native-currency figures." Every function in this enum returns
/// NATIVE-currency results — `LocalMoneyConversion.swift` is the only place
/// that calls `LocalFxConvert` to produce a base-currency figure, and it
/// does so at exactly the granularity Postgres itself rounds at:
///
///  - a value that is *itself* single-currency (an account balance, a
///    budget's own amount) is summed natively in SQL, then converted ONCE
///    in Swift — Postgres does the same, so this is exact by construction.
///  - a value built by summing across transactions that can carry
///    *different* currencies/dates (spending, income/expense, a budget's
///    spent side) is fetched here as individual native rows, and converted
///    + rounded ROW BY ROW in `LocalMoneyConversion` before summing —
///    matching Postgres's `sum(fx_convert(...))`, which rounds inside the
///    aggregate, once per row. Grouping natively by currency and converting
///    once per group would NOT match: two same-currency same-day
///    transactions round independently server-side, and rounding a
///    pre-summed total produces a different bigint in general.
///
/// Dates: every `TEXT` timestamp column here is compared as a string, never
/// reparsed (`LocalStore.swift`'s own rule) — safe only because every string
/// that ever lands in these columns shares one format
/// (`PostgresDate.sqliteTimestampBoundaryString`/PostgREST's own rendering:
/// six fractional digits, `+00:00`). A `date`-only value (`occurred_at`'s
/// calendar day) is the first 10 characters of that same string — exact
/// because Supabase's session timezone is UTC, the same zone PostgREST
/// renders `timestamptz` values in, so this is a literal substring of an
/// already-UTC string, not a re-derivation in a different zone (the bug
/// `PostgresDate` itself exists to avoid).
enum LocalMoneyQueries {
    // MARK: - account_balance_on / account_balances

    /// Port of `account_balance_on(p_account_id, p_date)`. `asOf` is a
    /// `YYYY-MM-DD` string; `now` bounds a same-day `asOf` to "so far today"
    /// exactly like Postgres's `least(p_date + 1 day, now())`.
    static func accountBalance(_ database: Database, accountId: String, asOf: String, now: Date) throws -> Int64? {
        guard let account = try Row.fetchOne(
            database, sql: "SELECT kind, currency, opening_balance_e4 FROM accounts WHERE id = ?",
            arguments: [accountId]
        ) else { return nil }

        let boundary = occurredAtBoundary(asOf: asOf, now: now)
        let kind: String = account["kind"]

        if kind == "ledger" {
            let openingBalance: Int64 = account["opening_balance_e4"]
            let delta: Int64 = try Int64.fetchOne(
                database,
                sql: """
                SELECT COALESCE(SUM(amount_e4), 0) FROM transactions
                WHERE account_id = ? AND deleted_at IS NULL AND status = 'confirmed' AND occurred_at <= ?
                """,
                arguments: [accountId, boundary]
            ) ?? 0
            return openingBalance + delta
        }

        // Prefer the latest snapshot at-or-before asOf; if none exists, fall
        // back to the account's earliest snapshot overall rather than
        // returning nil for the account's entire pre-history — mirrors
        // account_balance_on's own fallback (20260818100000), which keeps a
        // ledger account computable via opening_balance_e4 in the same
        // situation. Still nil if the account has no snapshot at all.
        guard let snapshot = try Row.fetchOne(
            database,
            sql: """
            SELECT id, value_e4, created_at FROM balance_snapshots
            WHERE account_id = ?
            ORDER BY
                CASE WHEN as_of <= ? THEN 0 ELSE 1 END,
                CASE WHEN as_of <= ? THEN as_of END DESC,
                CASE WHEN as_of <= ? THEN created_at END DESC,
                CASE WHEN as_of > ? THEN as_of END ASC,
                CASE WHEN as_of > ? THEN created_at END ASC
            LIMIT 1
            """,
            arguments: [accountId, asOf, asOf, asOf, asOf, asOf]
        ) else { return nil }

        let snapshotValue: Int64 = snapshot["value_e4"]
        let snapshotCreatedAt: String = snapshot["created_at"]
        let delta: Int64 = try Int64.fetchOne(
            database,
            sql: """
            SELECT COALESCE(SUM(amount_e4), 0) FROM transactions
            WHERE account_id = ? AND deleted_at IS NULL AND status = 'confirmed'
              AND occurred_at <= ? AND occurred_at > ?
            """,
            arguments: [accountId, boundary, snapshotCreatedAt]
        ) ?? 0
        return snapshotValue + delta
    }

    /// One native `(accountId, currency, balanceE4)` row per non-deleted
    /// account, at `asOf` — the local counterpart to `account_balances`
    /// (which is always "as of today" server-side; L4 generalizes it to any
    /// date since `net_worth_series` needs exactly that, and recomputing
    /// per day is the plan's explicit choice over caching a
    /// `net_worth_daily` equivalent on-device).
    static func nativeAccountBalances(_ database: Database, asOf: String, now: Date) throws -> [NativeAccountBalance] {
        let accounts = try Row.fetchAll(
            database, sql: "SELECT id, currency FROM accounts WHERE deleted_at IS NULL"
        )
        return try accounts.map { row in
            let accountId: String = row["id"]
            let balance = try accountBalance(database, accountId: accountId, asOf: asOf, now: now)
            return NativeAccountBalance(accountId: accountId, currency: row["currency"], balanceE4: balance)
        }
    }

    private static func occurredAtBoundary(asOf: String, now: Date) -> String {
        guard let asOfDate = PostgresDate.dateOnly(from: asOf, calendar: utcCalendar) else {
            return PostgresDate.sqliteTimestampBoundaryString(now)
        }
        let nextDay = utcCalendar.date(byAdding: .day, value: 1, to: asOfDate) ?? asOfDate
        return PostgresDate.sqliteTimestampBoundaryString(min(nextDay, now))
    }

    // MARK: - scope filtering

    /// Mirrors the `(p_scope = 'me' and not exists (...)) or (p_scope =
    /// 'household' and exists (...)) or p_scope = 'total'` clause repeated
    /// in every scoped Postgres function — built once here since `p_scope`
    /// is a fixed Swift enum, not user input, so string interpolation is
    /// safe (never done with a value that reaches SQL from outside this file).
    static func scopeFilterSQL(_ scope: PublicSchema.AccountScope, accountIdColumn: String) -> String {
        let sharedExists = """
        EXISTS (SELECT 1 FROM household_accounts ha \
        WHERE ha.account_id = \(accountIdColumn) AND ha.deleted_at IS NULL)
        """
        switch scope {
        case .me: return "NOT \(sharedExists)"
        case .household: return sharedExists
        case .total: return "1 = 1"
        }
    }

    static func categoryNames(_ database: Database) throws -> [String: String] {
        let rows = try Row.fetchAll(database, sql: "SELECT id, name FROM categories")
        return Dictionary(uniqueKeysWithValues: rows.map { ($0["id"] as String, $0["name"] as String) })
    }

    // MARK: - needs_review (no money conversion at all — a straight port)

    static func needsReview(_ database: Database) throws -> [NeedsReviewLocalRow] {
        var rows: [NeedsReviewLocalRow] = []

        rows += try Row.fetchAll(
            database,
            sql: """
            SELECT id, table_name, row_id, client_version, server_version, created_at
            FROM sync_conflicts WHERE resolved_at IS NULL AND deleted_at IS NULL
            """
        ).map { row in
            let tableName: String = row["table_name"]
            let rowId: String = row["row_id"]
            let clientVersion: Int = row["client_version"]
            let serverVersion: Int = row["server_version"]
            return NeedsReviewLocalRow(
                kind: "sync_conflict", itemId: row["id"],
                accountId: tableName == "accounts" ? rowId : nil,
                occurredAt: row["created_at"],
                title: "Sync conflict — \(tableName)",
                subtitle: "your version \(clientVersion) vs. the saved version \(serverVersion)",
                amountE4: nil, currency: nil
            )
        }

        rows += try Row.fetchAll(
            database,
            sql: """
            SELECT t.id, t.account_id, t.occurred_at, t.merchant_raw, t.amount_e4, t.currency,
                   c.is_default, c.name
            FROM transactions t JOIN categories c ON c.id = t.category_id
            WHERE t.source = 'capture' AND t.status = 'pending' AND t.deleted_at IS NULL
            """
        ).map { row in
            let isDefault: Bool = row["is_default"]
            let categoryName: String = row["name"]
            return NeedsReviewLocalRow(
                kind: "pending_capture", itemId: row["id"], accountId: row["account_id"],
                occurredAt: row["occurred_at"],
                title: "Review capture — \((row["merchant_raw"] as String?) ?? "Unknown merchant")",
                subtitle: isDefault ? "Uncategorized" : "Suggested: \(categoryName)",
                amountE4: row["amount_e4"], currency: row["currency"]
            )
        }

        rows += try Row.fetchAll(
            database, sql: "SELECT id, card_identifier, created_at FROM card_mappings WHERE account_id IS NULL"
        ).map { row in
            NeedsReviewLocalRow(
                kind: "ambiguous_card", itemId: row["id"], accountId: nil, occurredAt: row["created_at"],
                title: "Unmapped card — \(row["card_identifier"] as String)", subtitle: nil,
                amountE4: nil, currency: nil
            )
        }

        return rows
    }
}

// MARK: - Row types

struct NativeAccountBalance {
    let accountId: String
    let currency: String
    /// `nil` propagates money rule 5 — a valuation account with no snapshot
    /// yet has no computable balance, never a `0`.
    let balanceE4: Int64?
}

struct NeedsReviewLocalRow {
    let kind: String
    let itemId: String
    let accountId: String?
    let occurredAt: String
    let title: String
    let subtitle: String?
    let amountE4: Int64?
    let currency: String?
}
