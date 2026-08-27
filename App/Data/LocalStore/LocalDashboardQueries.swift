import Foundation
import GRDB
import KeepoCore

/// The dashboard's own local reads — the figures no existing screen already
/// computed. Every one of them is built on the L4 primitives rather than on
/// fresh SQL of its own: `scopedAccountIds` for scope, `accountBalance` for a
/// native balance, and `LocalMoneyConversion.convert` for every single
/// currency conversion. Nothing here does FX arithmetic (see
/// `LocalMoneyQueries`' header for why that lives in exactly one place), and
/// nothing here re-derives a balance.
///
/// These have no server counterpart to referee against, unlike L4's ported
/// functions — they are client-side derivations of already-refereed
/// primitives, so their correctness rests on those plus their own tests.
enum LocalDashboardQueries {
    // MARK: - Upcoming transactions

    /// Every occurrence of an active recurring rule falling inside `window` —
    /// money going out **and** money coming in.
    ///
    /// The expense-only filter this used to carry is gone: the widget above
    /// it is "Transactions Next 2 Weeks", and a fortnight that contains a
    /// salary as well as a rent payment is a different fortnight from one
    /// that contains only the rent. Direction is read from the **sign**, not
    /// from the category's kind — not a shortcut, since
    /// `validate_recurring_rule_sign` enforces the two to agree on every
    /// insert and update, and the sign is the value money rule 1 makes
    /// authoritative.
    ///
    /// Transfers can never appear here: `recurring_rules.category_id` is
    /// `not null`, and a transfer leg has no category. Nothing filters them
    /// out because nothing can produce one.
    ///
    /// Archived and deleted accounts are excluded, matching `net_worth`'s own
    /// exclusion — a bill on an account you've archived is not a bill you're
    /// still being asked about.
    static func upcomingTransactions(
        _ database: Database, _ moneyScope: LocalMoneyScope, window: ClosedRange<Date>, now: Date
    ) throws -> [UpcomingTransactionLocal] {
        let scopeClause = LocalMoneyQueries.scopeFilterSQL(moneyScope.scope, accountIdColumn: "r.account_id")
        let rows = try Row.fetchAll(
            database,
            sql: """
            SELECT r.id, r.amount_e4, r.currency, r.frequency, r.next_due_at,
                   c.name AS category_name, c.icon AS category_icon, c.color AS category_color,
                   a.name AS account_name
            FROM recurring_rules r
            JOIN categories c ON c.id = r.category_id
            JOIN accounts a ON a.id = r.account_id
            WHERE r.active = 1
              AND a.deleted_at IS NULL AND a.archived_at IS NULL AND c.deleted_at IS NULL
              AND (\(scopeClause))
            """
        )
        // `today` is the conversion date for every occurrence, deliberately —
        // not the occurrence's own future date. There is no rate for a day
        // that hasn't happened, so `fx_rate_on` would carry today's forward
        // anyway; naming today says what the figure actually is (what this
        // would cost at today's rate) instead of implying a forecast.
        let today = PostgresDate.dateOnlyString(now, calendar: utcCalendar)
        return try rows.flatMap { row in
            try occurrences(database, row: row, window: window, baseCurrency: moneyScope.baseCurrency, today: today)
        }
        .sorted { $0.dueOn < $1.dueOn }
    }

    private static func occurrences(
        _ database: Database, row: Row, window: ClosedRange<Date>, baseCurrency: String, today: String
    ) throws -> [UpcomingTransactionLocal] {
        guard let anchor = PostgresDate.dateOnly(from: row["next_due_at"], calendar: utcCalendar),
              let frequency = PublicSchema.RecurringFrequency(rawValue: row["frequency"])
        else { return [] }

        let amountE4: Int64 = row["amount_e4"]
        let currency: String = row["currency"]
        let converted = try LocalMoneyConversion.convert(
            database, amountE4: amountE4, from: currency, toCurrency: baseCurrency, date: today
        )
        let dates = RecurrenceSchedule.occurrences(
            anchoredAt: anchor, frequency: frequency, in: window, calendar: utcCalendar
        )
        return dates.map { dueOn in
            UpcomingTransactionLocal(
                ruleId: row["id"], dueOn: dueOn, categoryName: row["category_name"],
                categoryIcon: row["category_icon"], categoryColor: row["category_color"],
                accountName: row["account_name"], amountBaseE4: converted, nativeAmountE4: amountE4,
                nativeCurrency: currency
            )
        }
    }

    // MARK: - Currency exposure

    /// What every account is worth, in base currency, grouped by the currency
    /// it is actually held in — and, inside each currency, the accounts that
    /// make it up.
    ///
    /// The per-account detail is loaded here rather than by a second read the
    /// expanded widget fires when it opens, because it is a by-product of the
    /// work this already does: the currency totals *are* these balances
    /// summed. A separate "accounts in this currency" query would recompute
    /// every balance a second time, and could disagree with the total it sits
    /// under if a write landed between the two.
    ///
    /// Returns `nil` — the whole result, not one slice — if any account's
    /// balance or conversion is unresolvable. That is deliberate and stricter
    /// than dropping the bad slice: this widget's output is a set of *shares*,
    /// and a share computed against an incomplete denominator is a wrong
    /// number wearing a percent sign. Money rule 5 says the honest answer is
    /// "—", and here that has to mean the whole figure.
    static func currencyExposure(
        _ database: Database, _ moneyScope: LocalMoneyScope, now: Date
    ) throws -> [CurrencyExposureLocal]? {
        let today = PostgresDate.dateOnlyString(now, calendar: utcCalendar)
        // The same account predicate `net_worth` uses (not deleted, not
        // archived, in scope), fetched in one go with the presentation
        // columns rather than one `SELECT currency` per id — the accounts are
        // the rows now, not just a list of ids.
        let scopeClause = LocalMoneyQueries.scopeFilterSQL(moneyScope.scope, accountIdColumn: "a.id")
        let rows = try Row.fetchAll(
            database,
            sql: """
            SELECT a.id, a.name, a.currency, a.icon, a.color, a.kind, cur.minor_unit
            FROM accounts a
            LEFT JOIN currencies cur ON cur.code = a.currency
            WHERE a.deleted_at IS NULL AND a.archived_at IS NULL AND (\(scopeClause))
            ORDER BY a.sort_order, a.name
            """
        )

        var byCurrency: [String: [CurrencyAccountLocal]] = [:]
        for row in rows {
            let accountId: String = row["id"]
            let currency: String = row["currency"]
            guard let native = try LocalMoneyQueries.accountBalance(
                database, accountId: accountId, asOf: today, now: now
            ), let converted = try LocalMoneyConversion.convert(
                database, amountE4: native, from: currency, toCurrency: moneyScope.baseCurrency, date: today
            ) else { return nil }
            byCurrency[currency, default: []].append(
                CurrencyAccountLocal(
                    accountId: accountId, name: row["name"], icon: row["icon"], color: row["color"],
                    kind: PublicSchema.AccountKind(rawValue: row["kind"] ?? "") ?? .regular,
                    // Its own minor unit, read rather than assumed — JPY has
                    // none, and a hardcoded 2 would render ¥1,200 as ¥12.00
                    // (money rule 2).
                    currencyInfo: CurrencyInfo(code: currency, minorUnit: row["minor_unit"] ?? 2),
                    amountBaseE4: converted, nativeAmountE4: native
                )
            )
        }

        return byCurrency
            .compactMap { _, accounts -> CurrencyExposureLocal? in
                // Every account in a group is in the same currency by
                // construction, so the first one's `CurrencyInfo` is the
                // group's. A group is never empty — the dictionary is only
                // written by appending — but reading it as an optional keeps
                // that a fact about the code rather than a force-unwrap.
                guard let currencyInfo = accounts.first?.currencyInfo else { return nil }
                return CurrencyExposureLocal(
                    currencyInfo: currencyInfo,
                    amountBaseE4: accounts.reduce(0) { $0 + $1.amountBaseE4 },
                    nativeAmountE4: accounts.reduce(0) { $0 + $1.nativeAmountE4 },
                    accounts: accounts.sorted { $0.amountBaseE4 > $1.amountBaseE4 }
                )
            }
            .sorted { $0.amountBaseE4 > $1.amountBaseE4 }
    }

    /// Every currency the user holds an account in, other than the one
    /// given. Names only — no balances, no conversion — because the one
    /// question it answers is "is there anything to price against the base
    /// currency", which a balance would not make more true.
    ///
    /// Mirrors `net_worth`'s account predicate (not deleted, not archived,
    /// in scope) so the FX widget offers exactly the currencies the
    /// Currency Exposure widget breaks down.
    static func heldCurrencies(
        _ database: Database, scope: PublicSchema.AccountScope, excluding baseCurrency: String
    ) throws -> [String] {
        let scopeClause = LocalMoneyQueries.scopeFilterSQL(scope, accountIdColumn: "id")
        return try String.fetchAll(
            database,
            sql: """
            SELECT DISTINCT currency FROM accounts
            WHERE deleted_at IS NULL AND archived_at IS NULL AND currency <> ? AND (\(scopeClause))
            ORDER BY currency
            """,
            arguments: [baseCurrency]
        )
    }

    /// The oldest date this user's money exists on — the earliest
    /// transaction, or the earliest account's opening balance date.
    ///
    /// This is what "all time" means, and what stops a chart's window
    /// padding wandering into years that were never going to have anything
    /// in them. An account with no transactions still counts, and
    /// `opening_balance_at` rather than `created_at` is why: the opening
    /// balance is real money from the date it is effective, which is
    /// routinely long before the day the account was typed into the app.
    static func earliestActivity(_ database: Database, scope: PublicSchema.AccountScope) throws -> Date? {
        let accountClause = LocalMoneyQueries.scopeFilterSQL(scope, accountIdColumn: "id")
        let transactionClause = LocalMoneyQueries.scopeFilterSQL(scope, accountIdColumn: "t.account_id")
        let earliest = try String.fetchOne(
            database,
            sql: """
            SELECT MIN(day) FROM (
                SELECT MIN(substr(t.occurred_at, 1, 10)) AS day
                FROM transactions t
                WHERE t.deleted_at IS NULL AND (\(transactionClause))
                UNION ALL
                SELECT MIN(substr(opening_balance_at, 1, 10)) AS day
                FROM accounts
                WHERE deleted_at IS NULL AND archived_at IS NULL AND (\(accountClause))
            )
            """
        )
        guard let earliest else { return nil }
        return PostgresDate.dateOnly(from: earliest, calendar: utcCalendar)
    }

    // MARK: - FX trend

    /// What one unit of `currency` has been worth in the base currency, day
    /// by day.
    ///
    /// Built by converting a single unit through `LocalMoneyConversion
    /// .convert` rather than by reading `fx_rates` and doing the cross-rate
    /// arithmetic here. That is the whole point: the rate this chart draws is
    /// by construction the same rate every balance on the dashboard was
    /// converted at, including the EUR-pivot and the rounding contract. A
    /// second implementation would be free to disagree with the numbers
    /// beside it.
    static func fxTrend(
        _ database: Database, currency: String, baseCurrency: String, from: Date, through: Date
    ) throws -> [(date: Date, value: Int64)] {
        guard currency != baseCurrency else { return [] }
        var cursor = from
        var points: [(date: Date, value: Int64)] = []
        while cursor <= through {
            let day = PostgresDate.dateOnlyString(cursor, calendar: utcCalendar)
            // A day with no rate yet is omitted, never zeroed — a gap in FX
            // history is not a currency that became worthless.
            if let value = try LocalMoneyConversion.convert(
                database, amountE4: oneUnitE4, from: currency, toCurrency: baseCurrency, date: day
            ) {
                points.append((date: cursor, value: value))
            }
            guard let next = utcCalendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return points
    }

    /// 1.0000 at the fixed-point scale every money value in this app uses.
    private static let oneUnitE4: Int64 = 10_000
}

// MARK: - Row types

struct UpcomingTransactionLocal: Equatable, Identifiable {
    let ruleId: String
    let dueOn: Date
    let categoryName: String
    let categoryIcon: String
    let categoryColor: String
    let accountName: String
    /// Base currency, and **signed** — an expense stays negative all the way
    /// to the display boundary, where `MoneySignStyle.ledger` drops the minus
    /// for a figure whose direction the label already states. Money rule 1:
    /// nothing re-signs it on the way. `nil` when the rate is unresolvable.
    let amountBaseE4: Int64?
    let nativeAmountE4: Int64
    let nativeCurrency: String

    /// Which way the money goes, from the sign of the rule's own amount —
    /// which the server's `validate_recurring_rule_sign` keeps in agreement
    /// with the category's kind. Read from `nativeAmountE4` rather than the
    /// converted figure so an unresolvable rate leaves the direction known
    /// even when the amount isn't.
    var isInbound: Bool { nativeAmountE4 > 0 }

    /// One rule can occur several times inside a two-week window, so the
    /// rule's own id is not unique in this list — the occurrence date is what
    /// distinguishes them.
    var id: String { "\(ruleId)-\(dueOn.timeIntervalSince1970)" }
}

struct CurrencyExposureLocal: Equatable, Identifiable {
    /// The currency itself, with its own minor unit — read from
    /// `currencies`, never assumed to be two (money rule 2). Carried as the
    /// full `CurrencyInfo` rather than a bare code because the expanded
    /// widget formats `nativeAmountE4` below in *this* currency, and a slice
    /// that had to reach into its own first account to find out how to round
    /// itself would be one refactor away from rendering ¥1,200 as ¥12.00.
    let currencyInfo: CurrencyInfo
    /// Signed, converted to the user's base currency: a currency you are net
    /// short in (a credit card, an overdraft) is negative, and the widget
    /// says so rather than hiding it. This is the figure every **share** is
    /// taken against, because it is the only one comparable across
    /// currencies.
    let amountBaseE4: Int64
    /// Signed, in the currency's own units — what the user would see in the
    /// bank app for these accounts. The expanded widget leads with it, and
    /// leads with the converted figure underneath, so the row is
    /// recognisable *and* comparable rather than one or the other.
    let nativeAmountE4: Int64
    /// What the total is made of, largest first. Always present — the
    /// expanded widget breaks a currency down without a second read.
    let accounts: [CurrencyAccountLocal]

    var currency: String { currencyInfo.code }
    var id: String { currency }

    /// Accounts the user is net *long* in. These are the ones that can be
    /// drawn as a share of the currency's total; a negative account is an
    /// offset against them, not a slice of them.
    var positiveAccounts: [CurrencyAccountLocal] {
        accounts.filter { $0.amountBaseE4 > 0 }
    }

    /// The denominator for an account's share. The sum of the *positive*
    /// accounts, not the currency's net total: a currency holding €1,000 in
    /// savings against a −€900 card has a net of €100, and calling the
    /// savings account "1,000% of EUR" would be arithmetically true and
    /// useless. Shares are read against what is actually held.
    var positiveTotalE4: Int64 {
        positiveAccounts.reduce(0) { $0 + $1.amountBaseE4 }
    }
}

/// One account's contribution to a currency's exposure.
struct CurrencyAccountLocal: Equatable, Identifiable {
    let accountId: String
    let name: String
    let icon: String
    let color: String
    /// The user's own declaration that this account is an investment.
    /// Presentational only — it never touches a balance (money rule 1) — and
    /// carried here so the expanded widget can badge the row without a second
    /// read of `accounts`.
    let kind: PublicSchema.AccountKind
    /// The currency the account is held in, with its own minor unit — the
    /// same for every account in one `CurrencyExposureLocal`, carried along
    /// so a row can format its own native figure without reaching back up to
    /// its parent or assuming two decimals.
    let currencyInfo: CurrencyInfo
    /// Signed, in base currency.
    let amountBaseE4: Int64
    /// Signed, in the account's own currency. What the user recognises when
    /// the account isn't in their base currency — the base figure is the one
    /// that makes accounts comparable, this is the one they'd see in their
    /// bank app.
    let nativeAmountE4: Int64

    var id: String { accountId }
}
