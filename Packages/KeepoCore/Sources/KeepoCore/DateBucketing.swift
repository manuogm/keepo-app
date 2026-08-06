import Foundation

/// Bucket granularity is derived from the span, never a user control
/// (app-architecture.md §5) — a 30/90-day range buckets weekly, anything
/// longer buckets monthly. No daily option exists even for short ranges:
/// daily income-vs-expense is dominated by the one day salary lands, and a
/// user-facing granularity toggle is a control nobody asked for.
public enum DateBucketing {
    public enum Granularity {
        case weekly
        case monthly
    }

    public static func granularity(from: Date, through: Date, calendar: Calendar = .current) -> Granularity {
        let days = calendar.dateComponents([.day], from: from, to: through).day ?? 0
        return days <= 90 ? .weekly : .monthly
    }

    /// Buckets an ascending series of `(date, value)` points, keeping the
    /// LAST point in each bucket. A net worth trajectory is a running
    /// balance, not a flow — "where it ended up" is the right
    /// representative for a period, never a sum or average of balances.
    public static func bucket<Value>(
        _ points: [(date: Date, value: Value)],
        granularity: Granularity,
        calendar: Calendar = .current
    ) -> [(date: Date, value: Value)] {
        var lastByBucket: [Date: (date: Date, value: Value)] = [:]
        var order: [Date] = []
        for point in points {
            let key = bucketStart(for: point.date, granularity: granularity, calendar: calendar)
            if lastByBucket[key] == nil {
                order.append(key)
            }
            lastByBucket[key] = point
        }
        return order.compactMap { lastByBucket[$0] }
    }

    private static func bucketStart(for date: Date, granularity: Granularity, calendar: Calendar) -> Date {
        switch granularity {
        case .weekly:
            let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
            return calendar.date(from: components) ?? date
        case .monthly:
            let components = calendar.dateComponents([.year, .month], from: date)
            return calendar.date(from: components) ?? date
        }
    }
}
