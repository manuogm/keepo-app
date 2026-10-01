import Foundation
import GRDB
import KeepoCore

/// The reads an export needs beyond the rows themselves — how many there are,
/// what they add up to, and their tags. Every one goes through
/// `LocalTransactionRow.filteredSource`, the same `FROM … WHERE …` the
/// Transactions list reads through, so the count on the Export button, the
/// totals in the PDF and the rows in the file are one selection.
///
/// Scope is always `.total` here: an export names its accounts explicitly
/// (`TransactionFilter.accountIds`), so the Total/Private/Household banner
/// has already been turned into the list of accounts it stands for.
enum LocalExportQueries {
    /// Ledger **entries**, not rows: a transfer with both legs in the
    /// selection is one thing on screen and is counted once, so the button
    /// says the number the user saw in the list.
    static func entryCount(_ database: Database, filter: TransactionFilter, ownerId: String) throws -> Int {
        let source = LocalTransactionRow.filteredSource(filter: filter, scope: .total, ownerId: ownerId)
        return try Int.fetchOne(
            database,
            sql: "SELECT COUNT(DISTINCT COALESCE(t.transfer_group_id, t.id)) \(source.sql)",
            arguments: StatementArguments(source.arguments)
        ) ?? 0
    }

    /// Income, expenses and their net, per currency — summed **in SQL**
    /// (money rule 3), never from decoded rows. Transfers are left out of all
    /// three: moving money between your own accounts is neither income nor
    /// spending, and counting it would inflate both sides of the statement.
    /// Per currency and never converted, because a statement's figures have
    /// to match the accounts they summarise.
    static func totals(_ database: Database, filter: TransactionFilter, ownerId: String) throws -> [CurrencyTotals] {
        let source = LocalTransactionRow.filteredSource(filter: filter, scope: .total, ownerId: ownerId)
        let rows = try Row.fetchAll(
            database,
            sql: """
            SELECT t.currency, cur.minor_unit,
                   SUM(CASE WHEN t.transfer_group_id IS NULL AND t.amount_e4 > 0 THEN t.amount_e4 ELSE 0 END)
                       AS income_e4,
                   SUM(CASE WHEN t.transfer_group_id IS NULL AND t.amount_e4 < 0 THEN t.amount_e4 ELSE 0 END)
                       AS expenses_e4,
                   SUM(CASE WHEN t.transfer_group_id IS NULL THEN t.amount_e4 ELSE 0 END) AS net_e4
            \(source.sql) AND t.currency IS NOT NULL
            GROUP BY t.currency, cur.minor_unit
            ORDER BY t.currency
            """,
            arguments: StatementArguments(source.arguments)
        )
        return rows.map { row in
            CurrencyTotals(
                currency: CurrencyInfo(code: row["currency"], minorUnit: row["minor_unit"] ?? 2),
                incomeE4: row["income_e4"], expensesE4: row["expenses_e4"], netE4: row["net_e4"]
            )
        }
    }

    struct CurrencyTotals: Equatable {
        let currency: CurrencyInfo
        let incomeE4: Int64
        let expensesE4: Int64
        let netE4: Int64
    }

    /// Live tag names per transaction, sorted, for the rows being exported —
    /// one query per chunk rather than one per row. Chunked so a very long
    /// export never approaches SQLite's bound-parameter limit.
    static func tagNames(_ database: Database, transactionIds: [String]) throws -> [String: [String]] {
        var names: [String: [String]] = [:]
        for start in stride(from: 0, to: transactionIds.count, by: Self.chunk) {
            let ids = Array(transactionIds[start..<min(start + Self.chunk, transactionIds.count)])
            let rows = try Row.fetchAll(
                database,
                sql: """
                SELECT tt.transaction_id, tg.name FROM transaction_tags tt
                JOIN tags tg ON tg.id = tt.tag_id
                WHERE tt.deleted_at IS NULL AND tg.deleted_at IS NULL
                  AND tt.transaction_id IN (\(databaseQuestionMarks(count: ids.count)))
                ORDER BY tg.name COLLATE NOCASE
                """,
                arguments: StatementArguments(ids)
            )
            for row in rows {
                let id: String = row["transaction_id"]
                names[id.uppercased(), default: []].append(row["name"])
            }
        }
        return names
    }

    private static let chunk = 500
}
