import Foundation

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
