import Foundation

/// What a **new** transaction opens on, handed to the form by whoever
/// presented it.
///
/// It exists so that narrowing the ledger and adding to it are the same
/// gesture. A user looking at one account, one category, one type or one
/// month has already answered those questions by filtering; asking them
/// again in the form is asking them to repeat themselves, which is the
/// single largest source of taps in manual entry.
///
/// Every field is optional and means "leave the form's own default alone",
/// so a seed built from an empty filter changes nothing — the unfiltered
/// Add button behaves exactly as it always has.
public struct TransactionSeed: Equatable, Sendable {
    public var accountId: UUID?
    public var categoryId: UUID?
    /// `TransactionFilter.kind`'s own vocabulary — `"expense"`, `"income"`
    /// or `"transfer"` — so nothing translates between the pill the user
    /// tapped and the tab the form opens on.
    public var kind: String?
    /// `nil` means "whatever the form would have chosen", which is now.
    public var occurredAt: Date?

    public init(accountId: UUID? = nil, categoryId: UUID? = nil, kind: String? = nil, occurredAt: Date? = nil) {
        self.accountId = accountId
        self.categoryId = categoryId
        self.kind = kind
        self.occurredAt = occurredAt
    }

    /// The seed a ledger narrowed to `filter`, showing `visible`, hands to
    /// the form.
    ///
    /// `visible` is passed separately because `TransactionFilter` never
    /// carries the period: the Transactions screen keeps that in its own
    /// period/anchor state and folds it into the filter only at query time.
    /// It is **optional** because All Time is not a wide range, it is the
    /// absence of one — nothing is off screen, so there is nothing to clamp
    /// into and the entry is simply dated now.
    public init(
        filter: TransactionFilter,
        visible: DateInterval?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) {
        self.init(
            accountId: filter.accountId,
            categoryId: filter.categoryId,
            kind: filter.kind,
            occurredAt: visible.map { Self.date(in: $0, now: now, calendar: calendar) } ?? now
        )
    }

    /// Now, unless now is outside the period being looked at — in which
    /// case the nearest instant inside it.
    ///
    /// **Clamping, not defaulting to now, is what keeps a saved transaction
    /// on the screen it was added from.** The list filters `occurred_at`
    /// between the period's two bounds, so a transaction dated today and
    /// entered while looking at March saves correctly and then vanishes,
    /// which reads as a save that failed.
    ///
    /// The time of day travels across from `now` rather than resetting to
    /// midnight: the ledger sorts by `occurred_at desc` within a day, so a
    /// row added to an older month lands among that day's rows the same way
    /// one added today does.
    public static func date(in range: DateInterval, now: Date = Date(), calendar: Calendar = .current) -> Date {
        guard now < range.start || now > range.end else { return now }
        // Every non-custom period is built with `Calendar.dateInterval(of:for:)`,
        // whose `end` is the FIRST instant of the next period — so the last
        // day actually inside the range is the one a second before it.
        let day = now < range.start ? range.start : range.end.addingTimeInterval(-1)
        let time = calendar.dateComponents([.hour, .minute, .second], from: now)
        let candidate = calendar.date(
            bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: time.second ?? 0, of: day
        ) ?? day
        // A custom range ends at the instant the user picked rather than at
        // a day boundary, so the carried-over time of day can overshoot it.
        return min(max(candidate, range.start), range.end)
    }
}
