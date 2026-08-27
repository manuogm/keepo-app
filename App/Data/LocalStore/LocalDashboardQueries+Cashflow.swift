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
    /// **Transfers count only when they cross the scope's boundary.** A
    /// transfer has `category_id IS NULL` (the schema's "exactly one of
    /// transfer_group_id/category_id" CHECK), so the categorised query below
    /// drops every leg structurally — which is right whenever both legs are
    /// inside the scope being viewed, because the two cancel and moving money
    /// into savings is neither earning nor spending. But narrow the scope to
    /// Personal and a household→personal transfer has only *one* leg inside
    /// it: that is real money arriving, and a cashflow that ignored it would
    /// under-report the month. Those legs are picked up by a second query and
    /// rolled up under a "Transfers" pseudo-category, so the breakdown says
    /// where the money came from rather than burying it in the total.
    ///
    /// Conversion is **row by row**, at each transaction's own date, before
    /// summing — matching Postgres's `sum(fx_convert(...))`, which rounds
    /// once per row. Grouping natively and converting a pre-summed total
    /// would produce a different bigint in general (see `LocalMoneyQueries`'
    /// header).
    static func cashflow(
        _ database: Database, _ moneyScope: LocalMoneyScope, period: ClosedRange<Date>
    ) throws -> CashflowTotalsLocal {
        var accumulator = FlowAccumulator(baseCurrency: moneyScope.baseCurrency)
        let bounds = [
            PostgresDate.dateOnlyString(period.lowerBound, calendar: utcCalendar),
            PostgresDate.dateOnlyString(period.upperBound, calendar: utcCalendar)
        ]

        let scopeClause = LocalMoneyQueries.scopeFilterSQL(moneyScope.scope, accountIdColumn: "t.account_id")
        let categorised = try Row.fetchAll(
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
            arguments: StatementArguments(bounds)
        )
        for row in categorised {
            let kind = PublicSchema.CategoryKind(rawValue: row["category_kind"]) ?? .expense
            try accumulator.add(database, row: row, bucket: CategoryBucket(row: row, kind: kind))
        }

        for row in try crossingTransfers(database, moneyScope, bounds: bounds) {
            let amountE4: Int64 = row["amount_e4"]
            try accumulator.add(database, row: row, bucket: .transfers(inbound: amountE4 > 0))
        }

        return accumulator.resolved()
    }

    /// Transfer legs whose counterparty account sits **outside** the current
    /// scope.
    ///
    /// The `NOT EXISTS` is the whole rule. At Total scope the scope predicate
    /// is `1 = 1`, so the sibling leg always matches and nothing qualifies —
    /// which is correct, since inside one scope a transfer is money changing
    /// pockets. At Personal or Household scope it qualifies exactly when the
    /// other side is somewhere this view can't see.
    private static func crossingTransfers(
        _ database: Database, _ moneyScope: LocalMoneyScope, bounds: [String]
    ) throws -> [Row] {
        let legInScope = LocalMoneyQueries.scopeFilterSQL(moneyScope.scope, accountIdColumn: "t.account_id")
        let siblingInScope = LocalMoneyQueries.scopeFilterSQL(moneyScope.scope, accountIdColumn: "o.account_id")
        return try Row.fetchAll(
            database,
            sql: """
            SELECT t.amount_e4, t.currency, substr(t.occurred_at, 1, 10) AS occurred_date
            FROM transactions t
            WHERE t.deleted_at IS NULL AND t.status = 'confirmed'
              AND t.transfer_group_id IS NOT NULL
              AND substr(t.occurred_at, 1, 10) BETWEEN ? AND ?
              AND (\(legInScope))
              AND NOT EXISTS (
                  SELECT 1 FROM transactions o
                  WHERE o.transfer_group_id = t.transfer_group_id AND o.id <> t.id
                    AND o.deleted_at IS NULL AND (\(siblingInScope))
              )
            """,
            arguments: StatementArguments(bounds)
        )
    }

    /// Running totals for one period: the two directions, and the split by
    /// whatever bucket each row belongs to.
    ///
    /// A type rather than three locals because both row sources feed the same
    /// three things, and the direction rule — a row's **sign** decides which
    /// side it lands on — has to be identical for a categorised row and a
    /// transfer leg. Money rule 1: nothing re-signs anything on the way in.
    private struct FlowAccumulator {
        let baseCurrency: String
        var moneyIn = RunningTotal()
        var moneyOut = RunningTotal()
        var buckets: [String: CategoryBucket] = [:]

        mutating func add(_ database: Database, row: Row, bucket: CategoryBucket) throws {
            let amountE4: Int64 = row["amount_e4"]
            let currency: String = row["currency"]
            let occurredDate: String = row["occurred_date"]
            let base = baseCurrency
            let convert: (Int64, String, String) throws -> Int64? = {
                try LocalMoneyConversion.convert(
                    database, amountE4: $0, from: $1, toCurrency: base, date: $2
                )
            }
            if bucket.isInbound {
                try moneyIn.add(amountE4, from: currency, at: occurredDate, convert: convert)
            } else {
                try moneyOut.add(amountE4, from: currency, at: occurredDate, convert: convert)
            }
            var existing = buckets[bucket.id] ?? bucket
            try existing.total.add(amountE4, from: currency, at: occurredDate, convert: convert)
            buckets[bucket.id] = existing
        }

        func resolved() -> CashflowTotalsLocal {
            CashflowTotalsLocal(
                moneyInE4: moneyIn.result,
                moneyOutE4: moneyOut.result,
                byCategory: buckets.values
                    .map { $0.resolved() }
                    // Largest magnitude first — income is positive and expense
                    // negative, so sorting on the raw value would interleave
                    // them.
                    .sorted { abs($0.amountE4 ?? 0) > abs($1.amountE4 ?? 0) }
            )
        }
    }

    /// One line of the breakdown: a real category, or the transfers roll-up.
    ///
    /// Carries the presentation columns along with the total so the group-by
    /// doesn't need a second lookup per category to find its own icon.
    private struct CategoryBucket {
        let id: String
        let name: String
        let icon: String
        let color: String
        let kind: PublicSchema.CategoryKind
        var total = RunningTotal()

        var isInbound: Bool { kind == .income }

        init(row: Row, kind: PublicSchema.CategoryKind) {
            self.id = row["category_id"]
            self.name = row["category_name"]
            self.icon = row["category_icon"]
            self.color = row["category_color"]
            self.kind = kind
        }

        private init(id: String, name: String, icon: String, color: String, kind: PublicSchema.CategoryKind) {
            self.id = id
            self.name = name
            self.icon = icon
            self.color = color
            self.kind = kind
        }

        /// The transfers roll-up, one per direction. Its id is deliberately
        /// **not** a UUID: it has no category to open in Transactions, and
        /// `UUID(uuidString:)` failing is what tells the widget to filter by
        /// kind instead of by category.
        static func transfers(inbound: Bool) -> CategoryBucket {
            CategoryBucket(
                id: inbound ? CashflowCategoryLocal.transfersInId : CashflowCategoryLocal.transfersOutId,
                name: "Transfers",
                icon: "arrow.left.arrow.right",
                // The neutral chart colour, as a hex string because that is
                // what every other row on this screen carries. Transfers are
                // movement rather than earning or spending, so they take the
                // colour that means neither.
                color: "#8E8E93",
                kind: inbound ? .income : .expense
            )
        }

        func resolved() -> CashflowCategoryLocal {
            CashflowCategoryLocal(
                categoryId: id, name: name, icon: icon, color: color, kind: kind, amountE4: total.result
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

    /// How many accounts the user has declared as investments.
    ///
    /// The count rather than a boolean, because two callers want different
    /// things from the same `COUNT(*)`: the catalogue only needs to know
    /// whether the widget has anything to say (0 is the difference between
    /// "your ratio is 0%" and "this widget is not for you yet"), while the
    /// collapsed tile names the number underneath its figure. Asking twice
    /// for a number we already had would be two queries for one fact.
    static func investmentAccountCount(_ database: Database, scope: PublicSchema.AccountScope) throws -> Int {
        let scopeClause = LocalMoneyQueries.scopeFilterSQL(scope, accountIdColumn: "id")
        return try Int.fetchOne(
            database,
            sql: """
            SELECT COUNT(*) FROM accounts
            WHERE deleted_at IS NULL AND archived_at IS NULL AND kind = 'investment' AND (\(scopeClause))
            """
        ) ?? 0
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
    /// A real category's UUID, or one of the two transfer sentinels below.
    let categoryId: String
    let name: String
    let icon: String
    let color: String
    let kind: PublicSchema.CategoryKind
    /// Signed, like every amount in this app.
    let amountE4: Int64?

    var id: String { categoryId }

    static let transfersInId = "transfers-in"
    static let transfersOutId = "transfers-out"

    /// Whether this row is the transfers roll-up rather than a category the
    /// user created. Asked by sentinel rather than by name, so a category
    /// someone actually called "Transfers" is not mistaken for it.
    var isTransfers: Bool {
        categoryId == Self.transfersInId || categoryId == Self.transfersOutId
    }
}
