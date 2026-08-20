import Foundation
import GRDB
import KeepoCore

/// The account-list row shape `AccountsListView`/`HomeView`-adjacent screens
/// need (Phase L6) — every account visible to the signed-in user (owned, or
/// shared into a household they belong to), with its native and
/// base-currency balance computed fresh from the local mirror. Unlike
/// `LocalMoneyQueries`' other result types, this one isn't a straight port
/// of a Postgres view (`accounts_with_balances` bakes in `is_shared`/
/// `base_currency` columns this file derives instead) — it's the shape one
/// specific screen wants, built from the same underlying reads.
///
/// Ordered the way the Accounts list reads top to bottom: Everyday group
/// first, then Investments, each in the user's own drag arrangement
/// (`sort_order`), with name as the tiebreak for rows never dragged.
///
/// The `kind` term is load-bearing, not cosmetic. `sort_order` is only
/// unique WITHIN a kind (see the migration's own trigger), so ordering by
/// it alone interleaves the two groups — every consumer of this flat list
/// then sees a jumbled order. Caught in the simulator: a new expense
/// defaulted to the brokerage account, because a `sort_order` of 1 in the
/// Investments group tied with `sort_order` 1 in Everyday and lost the
/// tiebreak on name.
struct LocalAccountRow: Identifiable {
    let id: UUID
    let name: String
    let currency: String
    let currencyInfo: CurrencyInfo
    let kind: PublicSchema.AccountKind
    let icon: String
    let color: String
    let archivedAt: String?
    let sortOrder: Int
    let version: Int
    let isShared: Bool
    let balanceE4: Int64?
    let balanceBaseE4: Int64?
    let baseCurrencyInfo: CurrencyInfo?

    static func fetchAll(_ database: Database, ownerId: String, baseCurrency: String) throws -> [LocalAccountRow] {
        let accounts = try Row.fetchAll(
            database,
            sql: """
            SELECT id, name, currency, kind, icon, color, sort_order, archived_at, version FROM accounts
            WHERE deleted_at IS NULL AND (
                owner_id = ? OR id IN (
                    SELECT ha.account_id FROM household_accounts ha
                    JOIN household_members hm ON hm.household_id = ha.household_id
                    WHERE hm.user_id = ? AND hm.deleted_at IS NULL AND ha.deleted_at IS NULL
                )
            )
            ORDER BY CASE kind WHEN 'regular' THEN 0 ELSE 1 END, sort_order, name
            """,
            arguments: [ownerId, ownerId]
        )
        let sharedIds = try sharedAccountIds(database, ownerId: ownerId)
        let currencies = Dictionary(
            uniqueKeysWithValues: try LocalTableQueries.currencies(database).map { ($0.code, Int($0.minorUnit)) }
        )
        let baseMinorUnit = currencies[baseCurrency]
        let today = PostgresDate.dateOnlyString(Date(), calendar: utcCalendar)
        let now = Date()

        return try accounts.map { row in
            let accountId: String = row["id"]
            let currency: String = row["currency"]
            let kindRaw: String = row["kind"]
            let balance = try LocalMoneyQueries.accountBalance(database, accountId: accountId, asOf: today, now: now)
            let balanceBase = try balance.flatMap {
                try LocalMoneyConversion.convert(
                    database, amountE4: $0, from: currency, toCurrency: baseCurrency, date: today
                )
            }
            return LocalAccountRow(
                id: UUID(uuidString: accountId) ?? UUID(), name: row["name"], currency: currency,
                currencyInfo: CurrencyInfo(code: currency, minorUnit: currencies[currency] ?? 2),
                kind: PublicSchema.AccountKind(rawValue: kindRaw) ?? .regular,
                icon: row["icon"], color: row["color"], archivedAt: row["archived_at"],
                sortOrder: row["sort_order"], version: row["version"],
                isShared: sharedIds.contains(accountId), balanceE4: balance,
                balanceBaseE4: balanceBase,
                baseCurrencyInfo: baseMinorUnit.map { CurrencyInfo(code: baseCurrency, minorUnit: $0) }
            )
        }
    }

    private static func sharedAccountIds(_ database: Database, ownerId: String) throws -> Set<String> {
        let rows = try Row.fetchAll(
            database,
            sql: """
            SELECT ha.account_id FROM household_accounts ha
            JOIN household_members hm ON hm.household_id = ha.household_id
            WHERE hm.user_id = ? AND hm.deleted_at IS NULL AND ha.deleted_at IS NULL
            """,
            arguments: [ownerId]
        )
        return Set(rows.map { $0["account_id"] as String })
    }
}
