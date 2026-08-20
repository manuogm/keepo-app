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
    // MARK: - Upcoming bills

    /// Every occurrence of an active *expense* rule falling inside `window`.
    ///
    /// "Expense" is `amount_e4 < 0` — the sign, not the category's kind.
    /// That's not a shortcut: `validate_recurring_rule_sign` enforces the
    /// two to agree on every insert and update, and the sign is the value
    /// money rule 1 makes authoritative.
    ///
    /// Archived and deleted accounts are excluded, matching `net_worth`'s own
    /// exclusion — a bill on an account you've archived is not a bill you're
    /// still being asked about.
    static func upcomingBills(
        _ database: Database, _ moneyScope: LocalMoneyScope, window: ClosedRange<Date>, now: Date
    ) throws -> [UpcomingBillLocal] {
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
            WHERE r.active = 1 AND r.amount_e4 < 0
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
            try bills(database, row: row, window: window, baseCurrency: moneyScope.baseCurrency, today: today)
        }
        .sorted { $0.dueOn < $1.dueOn }
    }

    private static func bills(
        _ database: Database, row: Row, window: ClosedRange<Date>, baseCurrency: String, today: String
    ) throws -> [UpcomingBillLocal] {
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
            UpcomingBillLocal(
                ruleId: row["id"], dueOn: dueOn, categoryName: row["category_name"],
                categoryIcon: row["category_icon"], categoryColor: row["category_color"],
                accountName: row["account_name"], amountBaseE4: converted, nativeAmountE4: amountE4,
                nativeCurrency: currency
            )
        }
    }

    // MARK: - Currency exposure

    /// What every account is worth, in base currency, grouped by the currency
    /// it is actually held in.
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
        let accountIds = try LocalMoneyConversion.scopedAccountIds(database, scope: moneyScope.scope)
        var totals: [String: Int64] = [:]

        for accountId in accountIds {
            guard let currency = try String.fetchOne(
                database, sql: "SELECT currency FROM accounts WHERE id = ?", arguments: [accountId]
            ) else { continue }
            guard let native = try LocalMoneyQueries.accountBalance(
                database, accountId: accountId, asOf: today, now: now
            ), let converted = try LocalMoneyConversion.convert(
                database, amountE4: native, from: currency, toCurrency: moneyScope.baseCurrency, date: today
            ) else { return nil }
            totals[currency, default: 0] += converted
        }

        return totals
            .map { CurrencyExposureLocal(currency: $0.key, amountBaseE4: $0.value) }
            .sorted { $0.amountBaseE4 > $1.amountBaseE4 }
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

struct UpcomingBillLocal: Equatable, Identifiable {
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

    /// One rule can occur several times inside a two-week window, so the
    /// rule's own id is not unique in this list — the occurrence date is what
    /// distinguishes them.
    var id: String { "\(ruleId)-\(dueOn.timeIntervalSince1970)" }
}

struct CurrencyExposureLocal: Equatable, Identifiable {
    let currency: String
    /// Signed: a currency you are net short in (a credit card, an overdraft)
    /// is negative, and the widget says so rather than hiding it.
    let amountBaseE4: Int64

    var id: String { currency }
}
