import Foundation

/// The one place a Postgres `timestamptz`/`date` column becomes a Swift
/// `Date` and back — parallel to `AmountParser`/`AmountFormatter` for money.
/// Every repository call and form previously instantiated its own
/// `ISO8601DateFormatter()` (8 sites). One of those built a `date`-only
/// column by string-slicing an ISO8601 *timestamp* to its first 10
/// characters — `ISO8601DateFormatter` renders in UTC by default, so that
/// slice is the UTC calendar day, not the device's local day. Anyone within
/// a few hours of UTC midnight got tomorrow's (or yesterday's) date written
/// to `balance_snapshots.as_of`/`accounts.opening_balance_at` silently.
public enum PostgresDate {
    /// Encodes a `timestamptz` column (`occurred_at`, `deleted_at`, `onboarded_at`, ...).
    public static func timestampString(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    /// Decodes a `timestamptz` column back into a `Date`.
    public static func date(fromTimestamp string: String) -> Date? {
        ISO8601DateFormatter().date(from: string)
    }

    /// Encodes a `date`-only column (`balance_snapshots.as_of`,
    /// `accounts.opening_balance_at`) as the device's local calendar day,
    /// `YYYY-MM-DD` — never by truncating a UTC timestamp string, the bug
    /// this replaces.
    public static func dateOnlyString(_ date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// Decodes a `date`-only column (PostgREST renders it as a bare
    /// `YYYY-MM-DD` string, not a full timestamp) — `date(fromTimestamp:)`
    /// above expects timezone-qualified ISO8601 and fails on this format.
    public static func dateOnly(from string: String, calendar: Calendar = .current) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: string)
    }

    /// Same instant as `timestampString(_:)`, but formatted to match
    /// PostgREST's own `timestamptz` rendering exactly: a fixed 6-digit
    /// fractional-second field and a `+00:00` offset (`2026-08-11T13:38:16.320521+00:00`),
    /// not `ISO8601DateFormatter`'s whole-second `Z`-suffixed default.
    ///
    /// The local SQLite store (`keepo-local-first-plan.md` L4) never
    /// reparses its `TEXT` timestamp columns — it compares them as strings,
    /// which is only correct if every string sharing a column was rendered
    /// with the identical format. A `2026-08-11T13:38:16Z` boundary built
    /// with the default formatter sorts *before* a same-second
    /// `2026-08-11T13:38:16.320521+00:00` row (`.` < `Z` at that byte
    /// position), silently excluding a transaction that occurred earlier in
    /// the same second than the boundary's whole-second truncation implies.
    /// This is the one place a boundary gets built for that comparison, so
    /// it exists here rather than reintroducing the ad-hoc-formatter bug
    /// `timestampString` itself was written to close.
    public static func sqliteTimestampBoundaryString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        return formatter.string(from: date) + "000+00:00"
    }
}
