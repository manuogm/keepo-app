import Foundation
import GRDB
import KeepoCore

/// Cashflow and Investing Ratio's reads — split from `LocalDashboardQueries`
/// purely to stay under this project's file-length lint, same convention as
/// `LocalMoneyConversionBudget`. See that file's header for the rules these
/// follow.
extension LocalDashboardQueries {
    // MARK: - Cashflow

    /// Money in and money out over a period, plus the same figures split by
    /// category.
    ///
    /// Transfers are excluded structurally rather than by a filter of their
    /// own: a transfer has `category_id IS NULL` (the schema's "exactly one
    /// of transfer_group_id/category_id" CHECK), so joining `categories`
    /// drops every transfer leg. That matters — moving money into savings is
    /// not income and not an expense, and counting it as either would make
    /// the headline figure meaningless.
    ///
    /// Conversion is **row by row**, at each transaction's own date, before
    /// summing — matching Postgres's `sum(fx_convert(...))`, which rounds
    /// once per row. Grouping natively and converting a pre-summed total
    /// would produce a different bigint in general (see `LocalMoneyQueries`'
    /// header).
    static func cashflow(
        _ database: Database, _ moneyScope: LocalMoneyScope, period: ClosedRange<Date>
    ) throws -> CashflowTotalsLocal {
        let scopeClause = LocalMoneyQueries.scopeFilterSQL(moneyScope.scope, accountIdColumn: "t.account_id")
        let rows = try Row.fetchAll(
            database,
            sql: """
            SELECT t.amount_e4, t.currency, substr(t.occurred_at, 1, 10) AS occurred_date,
                   c.id AS category_id, c.name AS category_name, c.icon AS category_icon,
                   c.color AS category_color, c.kind AS category_kind
            FROM transactions t
            JOIN categories c ON c.id = t.category_id
            WHERE t.deleted_at IS NULL AND t.status = 'confirmed'
              AND substr(t.occurred_at, 1, 10) BETWEEN ? AND ?
              AND (\(scopeClause))
            """,
            arguments: [
                PostgresDate.dateOnlyString(period.lowerBound, calendar: utcCalendar),
                PostgresDate.dateOnlyString(period.upperBound, calendar: utcCalendar)
            ]
        )

        var moneyIn = RunningTotal()
        var moneyOut = RunningTotal()
        var byCategory: [String: CategoryAccumulator] = [:]

        for row in rows {
            let amountE4: Int64 = row["amount_e4"]
            let currency: String = row["currency"]
            let occurredDate: String = row["occurred_date"]
            let kind = PublicSchema.CategoryKind(rawValue: row["category_kind"]) ?? .expense
            let convert: (Int64, String, String) throws -> Int64? = {
                try LocalMoneyConversion.convert(
                    database, amountE4: $0, from: $1, toCurrency: moneyScope.baseCurrency, date: $2
                )
            }

            if kind == .income {
                try moneyIn.add(amountE4, from: currency, at: occurredDate, convert: convert)
            } else {
                try moneyOut.add(amountE4, from: currency, at: occurredDate, convert: convert)
            }

            let categoryId: String = row["category_id"]
            var accumulator = byCategory[categoryId] ?? CategoryAccumulator(row: row, kind: kind)
            try accumulator.total.add(amountE4, from: currency, at: occurredDate, convert: convert)
            byCategory[categoryId] = accumulator
        }

        return CashflowTotalsLocal(
            moneyInE4: moneyIn.result,
            moneyOutE4: moneyOut.result,
            byCategory: byCategory
                .map { $0.value.resolved(categoryId: $0.key) }
                // Largest magnitude first — income is positive and expense
                // negative, so sorting on the raw value would interleave them.
                .sorted { abs($0.amountE4 ?? 0) > abs($1.amountE4 ?? 0) }
        )
    }

    /// One category's running total plus the presentation columns that come
    /// along with it, so the group-by doesn't need a second lookup per
    /// category to find its own icon.
    private struct CategoryAccumulator {
        let name: String
        let icon: String
        let color: String
        let kind: PublicSchema.CategoryKind
        var total = RunningTotal()

        init(row: Row, kind: PublicSchema.CategoryKind) {
            self.name = row["category_name"]
            self.icon = row["category_icon"]
            self.color = row["category_color"]
            self.kind = kind
        }

        func resolved(categoryId: String) -> CashflowCategoryLocal {
            CashflowCategoryLocal(
                categoryId: categoryId, name: name, icon: icon, color: color,
                kind: kind, amountE4: total.result
            )
        }
    }

    // MARK: - Invested total

    /// What the accounts the user has marked as investments are worth, in
    /// base currency.
    ///
    /// This is the one place `kind` is read for a money figure, and it is a
    /// classification, not a formula: the balance of every account here is
    /// computed by the same `accountBalance` every other account uses, and
    /// `kind` only decides which ones are summed. CLAUDE.md's money rule 1
    /// allows exactly this and forbids the other thing — no second balance
    /// formula exists, and none is introduced here.
    ///
    /// The rest of the predicate mirrors `net_worth`'s own exactly (not
    /// deleted, not archived, in scope), because this figure's denominator
    /// *is* net worth — if the two disagreed about which accounts count, the
    /// ratio would be nonsense.
    static func investedTotal(
        _ database: Database, _ moneyScope: LocalMoneyScope, asOf: String, now: Date
    ) throws -> Int64? {
        let scopeClause = LocalMoneyQueries.scopeFilterSQL(moneyScope.scope, accountIdColumn: "id")
        let accounts = try Row.fetchAll(
            database,
            sql: """
            SELECT id, currency FROM accounts
            WHERE deleted_at IS NULL AND archived_at IS NULL AND kind = 'investment' AND (\(scopeClause))
            """
        )
        var total: Int64 = 0
        for row in accounts {
            let accountId: String = row["id"]
            guard let native = try LocalMoneyQueries.accountBalance(
                database, accountId: accountId, asOf: asOf, now: now
            ), let converted = try LocalMoneyConversion.convert(
                database, amountE4: native, from: row["currency"], toCurrency: moneyScope.baseCurrency, date: asOf
            ) else { return nil }
            total += converted
        }
        return total
    }

    /// Whether the user has any investment accounts at all — the difference
    /// between "your ratio is 0%" and "this widget has nothing to say to
    /// you yet", which want different blank states.
    static func hasInvestmentAccounts(_ database: Database, scope: PublicSchema.AccountScope) throws -> Bool {
        let scopeClause = LocalMoneyQueries.scopeFilterSQL(scope, accountIdColumn: "id")
        return try Int.fetchOne(
            database,
            sql: """
            SELECT COUNT(*) FROM accounts
            WHERE deleted_at IS NULL AND archived_at IS NULL AND kind = 'investment' AND (\(scopeClause))
            """
        ) ?? 0 > 0
    }
}

// MARK: - Row types

struct CashflowTotalsLocal: Equatable {
    /// Positive. `nil` when any contributing row's rate is unresolvable.
    let moneyInE4: Int64?
    /// **Negative** — an outflow keeps its sign all the way to the display
    /// boundary (money rule 1).
    let moneyOutE4: Int64?
    let byCategory: [CashflowCategoryLocal]

    /// What was left over: inflow plus outflow, which is a subtraction only
    /// because the outflow is already negative. Nothing re-signs anything.
    var netE4: Int64? {
        guard let moneyInE4, let moneyOutE4 else { return nil }
        return moneyInE4 + moneyOutE4
    }

    /// Net as a share of income — the "ratio to income" the widget shows
    /// beside the absolute figure. `nil` rather than 0 when there was no
    /// income to take a share of.
    var savingsRate: Double? {
        guard let netE4, let moneyInE4, moneyInE4 > 0 else { return nil }
        return Double(netE4) / Double(moneyInE4)
    }

    func categories(_ kind: PublicSchema.CategoryKind) -> [CashflowCategoryLocal] {
        byCategory.filter { $0.kind == kind }
    }
}

struct CashflowCategoryLocal: Equatable, Identifiable {
    let categoryId: String
    let name: String
    let icon: String
    let color: String
    let kind: PublicSchema.CategoryKind
    /// Signed, like every amount in this app.
    let amountE4: Int64?

    var id: String { categoryId }
}
