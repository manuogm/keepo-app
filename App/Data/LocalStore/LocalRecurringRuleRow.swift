import Foundation
import GRDB
import KeepoCore

/// One row of the Recurring list, resolved in a single read.
///
/// The screen used to load rules, accounts and categories as three separate
/// queries and then `first { $0.id == … }` its way back to a name per row per
/// render. That is the shape `LocalAccountRow` and `UpcomingTransactionLocal`
/// both already avoid, and it cost the list the one thing every other money
/// row in the app has: a base-currency line. Converting client-side to get
/// one is not an option (money rule 3), so the conversion happens here,
/// through the same `BaseConversion` the dashboard's own reads use.
///
/// **A rule is one of two shapes**, mirroring the server's
/// `recurring_rules_shape_check`: a category, or a destination account.
/// `subject` is what the row actually draws from, so the view never asks
/// which shape it is holding — it asks what to put on the line.
struct LocalRecurringRuleRow: Identifiable, Equatable {
    /// What the rule is *about*, ready to draw: a category, or the account
    /// money is being moved into. Both carry a name, an icon and a colour,
    /// because both are drawn by the same `CategoryIconView` + title.
    enum Subject: Equatable {
        case category(name: String, icon: String, color: String)
        /// The destination account of a recurring transfer. It keeps the
        /// account's own icon and colour rather than borrowing the ledger's
        /// grey arrows glyph: on this screen the useful question is *which
        /// account*, and the arrow in the subtitle already says it is a
        /// transfer.
        case transfer(toAccountName: String, icon: String, color: String)

        var name: String {
            switch self {
            case .category(let name, _, _): return name
            case .transfer(let name, _, _): return name
            }
        }

        var icon: String {
            switch self {
            case .category(_, let icon, _), .transfer(_, let icon, _): return icon
            }
        }

        var color: String {
            switch self {
            case .category(_, _, let color), .transfer(_, _, let color): return color
            }
        }

        var isTransfer: Bool {
            if case .transfer = self { return true }
            return false
        }
    }

    let id: UUID
    let subject: Subject
    /// The user's own name for the rule, which every occurrence also carries.
    let title: String?
    /// What the row is called: the title when there is one, which is the
    /// whole reason a rule can have one — "Gym" says more than "Health".
    var displayName: String { title ?? subject.name }

    let accountName: String
    /// **Signed**, straight off the column — negative for an expense and for
    /// a transfer's outflow, positive for income. Money rule 1: nothing here
    /// re-signs it, and the row decides how to *draw* it (`.ledger`) at the
    /// display boundary, exactly like `TransactionRow`.
    let amountE4: Int64
    let currencyInfo: CurrencyInfo
    /// The same figure in the viewer's base currency, converted in the query
    /// (money rule 3). `nil` when no rate resolves for the pair, which the
    /// row draws as `—` rather than as a zero (money rule 5).
    let amountBaseE4: Int64?
    /// `nil` when the rule is already in the base currency, so the row draws
    /// no redundant second line.
    let baseCurrencyInfo: CurrencyInfo?
    let frequency: PublicSchema.RecurringFrequency
    let nextDueAt: Date?
    let active: Bool

    /// Ordered the way the list reads: soonest first, and a rule whose
    /// materialization has fallen behind sorts to the very top — its
    /// `next_due_at` is in the past, which is the truest possible statement
    /// of "this one needs looking at".
    ///
    /// Archived and deleted accounts drop out at either end of a transfer:
    /// a standing instruction into an account the user has archived is not
    /// something the list should still be offering to edit.
    static func fetchAll(_ database: Database, baseCurrency: String) throws -> [LocalRecurringRuleRow] {
        let rows = try Row.fetchAll(
            database,
            sql: """
            SELECT r.id, r.title, r.amount_e4, r.currency, r.frequency, r.next_due_at, r.active,
                   a.name AS account_name,
                   c.name AS category_name, c.icon AS category_icon, c.color AS category_color,
                   d.name AS to_account_name, d.icon AS to_account_icon, d.color AS to_account_color
            FROM recurring_rules r
            JOIN accounts a ON a.id = r.account_id
            LEFT JOIN categories c ON c.id = r.category_id AND c.deleted_at IS NULL
            LEFT JOIN accounts d ON d.id = r.to_account_id
            WHERE a.deleted_at IS NULL AND a.archived_at IS NULL
              AND (r.to_account_id IS NULL OR (d.deleted_at IS NULL AND d.archived_at IS NULL))
            ORDER BY r.active DESC, r.next_due_at
            """
        )

        let currencies = Dictionary(
            uniqueKeysWithValues: try LocalTableQueries.currencies(database).map { ($0.code, Int($0.minorUnit)) }
        )
        let baseInfo = currencies[baseCurrency].map { CurrencyInfo(code: baseCurrency, minorUnit: $0) }
        // Today's rate, for the reason `upcomingTransactions` gives: a rule's
        // next occurrence has not happened, so there is no rate for its date
        // and the honest figure is what it would be worth today.
        let convert = BaseConversion(
            baseCurrency, at: PostgresDate.dateOnlyString(Date(), calendar: utcCalendar)
        )

        return try rows.compactMap { row in
            try make(row, currencies: currencies, baseInfo: baseInfo, convert: convert, database: database)
        }
    }

    /// Returns `nil` for a row whose shape cannot be resolved — a rule whose
    /// category has been deleted out from under it, or whose frequency is a
    /// value this build does not know. Dropped rather than drawn as `—`:
    /// this is a list of standing instructions, and one the app cannot
    /// describe is not something to offer an edit form for.
    private static func make(
        _ row: Row,
        currencies: [String: Int],
        baseInfo: CurrencyInfo?,
        convert: BaseConversion,
        database: Database
    ) throws -> LocalRecurringRuleRow? {
        guard let id = UUID(uuidString: row["id"]),
              let frequency = PublicSchema.RecurringFrequency(rawValue: row["frequency"])
        else { return nil }

        let subject: Subject
        if let toName: String = row["to_account_name"] {
            subject = .transfer(
                toAccountName: toName, icon: row["to_account_icon"], color: row["to_account_color"]
            )
        } else if let categoryName: String = row["category_name"] {
            subject = .category(
                name: categoryName, icon: row["category_icon"], color: row["category_color"]
            )
        } else {
            return nil
        }

        let amountE4: Int64 = row["amount_e4"]
        let currency: String = row["currency"]
        let converted = try convert(database, amountE4, from: currency)

        return LocalRecurringRuleRow(
            id: id,
            subject: subject,
            title: row["title"],
            accountName: row["account_name"],
            amountE4: amountE4,
            currencyInfo: CurrencyInfo(code: currency, minorUnit: currencies[currency] ?? 2),
            amountBaseE4: converted,
            baseCurrencyInfo: baseInfo?.code == currency ? nil : baseInfo,
            frequency: frequency,
            nextDueAt: PostgresDate.dateOnly(from: row["next_due_at"], calendar: utcCalendar),
            active: row["active"]
        )
    }
}
