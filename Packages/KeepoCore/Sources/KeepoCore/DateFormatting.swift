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
}
