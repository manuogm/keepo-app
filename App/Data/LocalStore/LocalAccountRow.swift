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
struct LocalAccountRow: Identifiable {
    let id: UUID
    let name: String
    let currency: String
    let currencyInfo: CurrencyInfo
    let kind: PublicSchema.AccountKind
    let icon: String
    let color: String
    let archivedAt: String?
    let version: Int
    let isShared: Bool
    let balanceE4: Int64?
    let balanceBaseE4: Int64?
    let baseCurrencyInfo: CurrencyInfo?

    static func fetchAll(_ database: Database, ownerId: String, baseCurrency: String) throws -> [LocalAccountRow] {
        let accounts = try Row.fetchAll(
            database,
            sql: """
            SELECT id, name, currency, kind, icon, color, archived_at, version FROM accounts
            WHERE deleted_at IS NULL AND (
                owner_id = ? OR id IN (
                    SELECT ha.account_id FROM household_accounts ha
                    JOIN household_members hm ON hm.household_id = ha.household_id
                    WHERE hm.user_id = ? AND hm.deleted_at IS NULL AND ha.deleted_at IS NULL
                )
            )
            ORDER BY name
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
                kind: PublicSchema.AccountKind(rawValue: kindRaw) ?? .ledger,
                icon: row["icon"], color: row["color"], archivedAt: row["archived_at"],
                version: row["version"], isShared: sharedIds.contains(accountId), balanceE4: balance,
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
