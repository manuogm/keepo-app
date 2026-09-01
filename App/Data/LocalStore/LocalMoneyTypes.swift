import Foundation
import GRDB

// Shared support types for `LocalMoneyQueries`/`LocalMoneyConversion`
// (Phase L4, `keepo-local-first-plan.md`) — split into their own file
// purely to stay under this project's `file_length`/`type_body_length`
// lint limits; there is no ordering dependency between them.

// MARK: - calendars

/// Every date/bucket computation in L4 works in UTC — the same zone
/// PostgREST renders `timestamptz` values in (Supabase's session timezone),
/// so a `date`-only value derived here always agrees with what Postgres's
/// own `::date` cast or `date_trunc` would have produced.
let utcCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = utcTimeZone
    return calendar
}()

/// `TimeZone(identifier:)` is technically failable, but "UTC" is a
/// guaranteed-valid IANA identifier on every platform this app ships to —
/// the fallback chain avoids a force-unwrap without pretending the
/// fallback path can actually be exercised.
private let utcTimeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0) ?? .current

// MARK: - accumulator

/// Row-by-row convert-then-round-then-sum, matching Postgres's
/// `sum(fx_convert(...))` exactly: once any row's rate is unresolvable the
/// running total is permanently `nil` (money rule 5), but earlier
/// successfully-converted rows are never un-summed — same as `bool_or(...)`
/// not short-circuiting the rows already aggregated into `sum(...)`.
struct RunningTotal {
    private var total: Int64 = 0
    private var hasMissingRate = false

    var result: Int64? { hasMissingRate ? nil : total }

    mutating func add(
        _ amountE4: Int64, from currency: String, at date: String,
        convert: (Int64, String, String) throws -> Int64?
    ) rethrows {
        guard !hasMissingRate else { return }
        if let converted = try convert(amountE4, currency, date) {
            total += converted
        } else {
            hasMissingRate = true
        }
    }
}

// MARK: - result types

struct BudgetProgressLocal {
    let budgetId: String
    let categoryId: String?
    let categoryName: String?
    let budgetedE4: Int64?
    let spentE4: Int64?
    let currency: String
}

// MARK: - fx memo

/// A memo over `fx_rates`, for the lifetime of one read.
///
/// `fxRateOn` is one `SELECT` per `(currency, date)` pair, and the money
/// layer asks for the same handful of pairs over and over: converting N
/// accounts into the base currency at one date looks up the *base*
/// currency's rate N times and each account's currency once per account
/// sharing it. Across the dashboard's twelve month-end readings that was
/// thousands of executions of a query with at most a few dozen distinct
/// answers.
///
/// Deliberately **not** process-wide, and deliberately not `Sendable`.
/// `fx_rates` is append-only, but a sync pull can append to it between
/// reads, and "the newest row at or before this date" is exactly the kind
/// of answer that must not survive one. One instance per `dbQueue.read`
/// block, thrown away with it.
final class LocalFxCache {
    private struct Key: Hashable {
        let currency: String
        let date: String
    }

    /// A `nil` *value* is a cached miss — a currency with no published rate
    /// at or before this date. Distinct from an absent key, which means "not
    /// asked yet"; without that, a missing rate (money rule 5's whole
    /// subject) would be the one case that re-queried every time.
    private var rates: [Key: Decimal?] = [:]

    func rate(
        _ database: Database, currency: String, date: String,
        load: (Database, String, String) throws -> Decimal?
    ) rethrows -> Decimal? {
        let key = Key(currency: currency, date: date)
        if let cached = rates[key] { return cached }
        let rate = try load(database, currency, date)
        rates[key] = rate
        return rate
    }
}

// MARK: - account predicates

/// Which accounts a balance query covers — a SQL fragment plus its
/// arguments, travelling together.
///
/// Every caller of `LocalMoneyQueries.accountBalances` wants a different
/// slice (in scope; in scope and an investment; visible to this user,
/// archived included; one account by id) but the *balance formula* must stay
/// one formula — money rule 1. Passing the predicate in is what lets there
/// be exactly one query computing a balance, rather than one per caller.
struct AccountFilter {
    let sql: String
    let arguments: [DatabaseValueConvertible]

    init(_ sql: String, _ arguments: [DatabaseValueConvertible] = []) {
        self.sql = sql
        self.arguments = arguments
    }
}

// MARK: - conversion context

/// "Convert into this base currency, at this date, memoized" — the three
/// values that always travel together once a read is converting more than
/// one row.
///
/// A type rather than three parameters because several of these functions
/// are already at this project's `function_parameter_count` limit, and
/// because the memo is only correct alongside the date it was filled for.
struct BaseConversion {
    let baseCurrency: String
    let date: String
    let cache: LocalFxCache

    init(_ baseCurrency: String, at date: String, cache: LocalFxCache = LocalFxCache()) {
        self.baseCurrency = baseCurrency
        self.date = date
        self.cache = cache
    }

    func callAsFunction(_ database: Database, _ amountE4: Int64, from currency: String) throws -> Int64? {
        try LocalMoneyConversion.convert(
            database, amountE4: amountE4, from: currency, toCurrency: baseCurrency, date: date, cache: cache
        )
    }
}
