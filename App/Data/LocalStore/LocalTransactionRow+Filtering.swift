import Foundation
import GRDB
import KeepoCore

/// How a `TransactionFilter` becomes SQL — the `WHERE` terms and nothing else.
///
/// Its own file because it is the part of `LocalTransactionRow` that grows:
/// every axis the ledger's drop-down gains is a clause here, while the queries
/// it serves (the ledger's rows, and the export's count and totals, both
/// through `filteredSource`) do not change when one is added. The main file
/// being at the project's file-length limit is the immediate reason, but the
/// seam was already there.
///
/// `append` and `kindExpression` are internal rather than `private` only
/// because they are read across this seam — `filteredSource` calls the first,
/// and all three of that file's `SELECT`s project the second.
extension LocalTransactionRow {
    /// The user's own filter terms, appended to `sql` with their arguments
    /// in the same order. Split out of `fetchFiltered` purely to keep that
    /// function under the project's `function_body_length` lint.
    static func append(
        _ filter: TransactionFilter, to sql: inout String, arguments: inout [DatabaseValueConvertible]
    ) {
        if let accountId = filter.accountId {
            sql += " AND t.account_id = ?"
            arguments.append(accountId.uuidString)
        }
        appendIn(
            filter.accountIds.map { $0.map(\.uuidString) }, column: "t.account_id",
            to: &sql, arguments: &arguments
        )
        appendIn(
            filter.categoryIds.map { $0.map(\.uuidString) }, column: "t.category_id",
            to: &sql, arguments: &arguments
        )
        appendIn(
            filter.createdByIds.map { $0.map(\.uuidString) }, column: "t.created_by",
            to: &sql, arguments: &arguments
        )
        appendIn(
            filter.sources.map { $0.map(\.rawValue) }, column: "t.source",
            to: &sql, arguments: &arguments
        )
        appendIn(filter.kinds.map { Array($0) }, column: kindExpression, to: &sql, arguments: &arguments)
        if let from = filter.from {
            sql += " AND t.occurred_at >= ?"
            arguments.append(PostgresDate.sqliteTimestampBoundaryString(from))
        }
        if let through = filter.through {
            sql += " AND t.occurred_at <= ?"
            arguments.append(PostgresDate.sqliteTimestampBoundaryString(through))
        }
        appendSearch(filter, to: &sql, arguments: &arguments)
    }

    /// One term against **everything the user typed into the transaction**:
    /// its title, the merchant a capture recorded, its note, its category,
    /// its account, its tags — and its amount.
    ///
    /// Text matches are `LIKE '%term%'` on columns whose collation is already
    /// case-insensitive (`.nocase`, see `LocalStore`'s schema), so no `lower()`
    /// is needed and none is added — wrapping a column in a function is also
    /// how an index stops being used.
    ///
    /// **Tags are an `EXISTS`, not a join.** A transaction with three matching
    /// tags is one row in this list, and a join would make it three; `EXISTS`
    /// asks the question the search is actually asking ("does this one have a
    /// tag like that?") and stops at the first hit.
    ///
    /// **The amount is an exact match on the magnitude**, and only when the
    /// term reads as a number at all (`TransactionFilter.searchAmountE4`, which
    /// is also where the sign is dropped). Exact, because a prefix match would
    /// make "15" return every 15.00, 15.50 and 150.00 on the screen at once —
    /// noise dressed as recall. Both the account-currency figure and the
    /// originally-paid one are compared, since a foreign purchase was entered
    /// as the latter and that is the number its owner remembers.
    private static func appendSearch(
        _ filter: TransactionFilter, to sql: inout String, arguments: inout [DatabaseValueConvertible]
    ) {
        guard let search = filter.search, !search.isEmpty else { return }
        sql += """
         AND (t.title LIKE ? OR t.merchant_raw LIKE ? OR t.merchant_normalized LIKE ?
              OR t.notes LIKE ? OR c.name LIKE ? OR a.name LIKE ?
              OR EXISTS (
                  SELECT 1 FROM transaction_tags tt
                  JOIN tags tg ON tg.id = tt.tag_id AND tg.deleted_at IS NULL
                  WHERE tt.transaction_id = t.id AND tt.deleted_at IS NULL AND tg.name LIKE ?
              )
        """
        let pattern = "%\(search)%"
        arguments.append(contentsOf: Array(repeating: pattern, count: 7))
        if let amountE4 = filter.searchAmountE4 {
            sql += " OR abs(t.amount_e4) = ? OR abs(t.original_amount_e4) = ?"
            arguments.append(contentsOf: [amountE4, amountE4])
        }
        sql += ")"
    }

    /// Which sources the viewer's ledger actually contains, in the order the
    /// drop-down lists them.
    ///
    /// **Derived rather than enumerated**, which is what keeps the Source
    /// filter honest in two directions at once. A hardcoded list of the enum's
    /// five cases would offer "Imported" to somebody who never imported a CSV
    /// (the feature is gone; only old rows can still carry the label) and
    /// "Balance correction" to somebody who has never corrected one — options
    /// that can only ever return nothing. Deriving it also makes the axis
    /// *complete* by construction: every source on screen is on offer, so
    /// ticking them all is the same list as ticking none, and no row can be
    /// unreachable through a filter that looks fully open.
    ///
    /// Scoped by visibility and by the scope card, but **not** by the user's
    /// own filter terms or period: the options are a property of the ledger,
    /// and a list that shrank as you filtered would take away the tick you
    /// were about to undo.
    static func availableSources(
        _ database: Database, scope: PublicSchema.AccountScope, ownerId: String
    ) throws -> [PublicSchema.TransactionSource] {
        let source = filteredSource(filter: TransactionFilter(), scope: scope, ownerId: ownerId)
        let rows = try String.fetchAll(
            database,
            sql: "SELECT DISTINCT t.source \(source.sql)",
            arguments: StatementArguments(source.arguments)
        )
        let present = Set(rows.compactMap(PublicSchema.TransactionSource.init(rawValue:)))
        // A fixed order, so the sheet does not reshuffle as a ledger gains its
        // first recurring instance or its first capture.
        return [.capture, .manual, .recurring, .adjustment, .csvImport].filter(present.contains)
    }

    /// `AND <column> IN (…)` for one of `TransactionFilter`'s set-valued
    /// axes, with its arguments in order — **the** place all five of them
    /// (accounts, categories, authors, sources, types) get their clause, so
    /// they cannot drift into five ideas of what an empty set means.
    ///
    /// An empty set is "none of them", not "any of them": `IN ()` is not
    /// valid SQLite, so it is spelled as a clause that is false. The UI never
    /// sends one — unticking the last option resets the axis to `nil` — but
    /// the export can, and "no accounts chosen" has to produce an empty file
    /// rather than the whole ledger.
    ///
    /// `column` is an arbitrary SQL expression rather than a column name so
    /// the derived type axis can pass `kindExpression`; nothing user-supplied
    /// ever reaches it, and every value still travels as a bound argument.
    private static func appendIn(
        _ values: [DatabaseValueConvertible]?, column: String,
        to sql: inout String, arguments: inout [DatabaseValueConvertible]
    ) {
        guard let values else { return }
        guard !values.isEmpty else {
            sql += " AND 0"
            return
        }
        sql += " AND \(column) IN (\(databaseQuestionMarks(count: values.count)))"
        arguments.append(contentsOf: values)
    }

    /// How a transaction's `kind` is derived — the one copy of it, projected
    /// by every query here as `kind` and filtered on by `append` above. It
    /// mirrors `transactions_with_details`'s own definition (migration
    /// 20260815100000_money_as_integers.sql): a transfer is anything with a
    /// group, and everything else is told apart by sign.
    ///
    /// Written out four times before this, once per query plus the filter
    /// clause, which is three places for the server's view definition and
    /// this file to fall out of step.
    static let kindExpression = """
    (CASE WHEN t.transfer_group_id IS NOT NULL THEN 'transfer'
          WHEN t.amount_e4 < 0 THEN 'expense' ELSE 'income' END)
    """
}
