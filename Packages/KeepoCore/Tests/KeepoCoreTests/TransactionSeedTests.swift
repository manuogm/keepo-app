import Foundation
import Testing
@testable import KeepoCore

/// A new transaction inherits whatever the ledger behind it was narrowed
/// to. The account, category and type are a straight carry-over; the date
/// is the only one with a decision in it.
@Suite("Transaction seed")
struct TransactionSeedTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)) ?? Date()
    }

    /// The period the Transactions screen builds for a month:
    /// `Calendar.dateInterval(of:for:)`, whose end is the first instant of
    /// the next month.
    private func month(_ year: Int, _ month: Int) -> DateInterval {
        let start = date(year, month, 1)
        return calendar.dateInterval(of: .month, for: start) ?? DateInterval(start: start, duration: 0)
    }

    @Test("Every filter the ledger has on travels to the form")
    func filtersTravel() {
        let account = UUID()
        let category = UUID()
        let filter = TransactionFilter(accountId: account, categoryId: category, kind: "income")
        let seed = TransactionSeed(
            filter: filter, visible: month(2026, 9), now: date(2026, 9, 18, 14, 32), calendar: calendar
        )

        #expect(seed.accountId == account)
        #expect(seed.categoryId == category)
        #expect(seed.kind == "income")
    }

    /// An unfiltered Add has to behave exactly as it did before any of
    /// this: nothing chosen, and the date left at now.
    @Test("An empty filter seeds nothing but the date")
    func emptyFilterSeedsNothing() {
        let now = date(2026, 9, 18, 14, 32)
        let seed = TransactionSeed(filter: TransactionFilter(), visible: month(2026, 9), now: now, calendar: calendar)

        #expect(seed.accountId == nil)
        #expect(seed.categoryId == nil)
        #expect(seed.kind == nil)
        #expect(seed.occurredAt == now)
    }

    /// All Time is the absence of a period rather than a very wide one, so
    /// there is nothing to clamp into: the entry is dated now, like any
    /// form opened with no ledger behind it.
    @Test("All Time dates the transaction now")
    func allTimeDatesNow() {
        let now = date(2026, 9, 18, 14, 32)
        let seed = TransactionSeed(
            filter: TransactionFilter(accountId: UUID()), visible: nil, now: now, calendar: calendar
        )

        #expect(seed.occurredAt == now)
        #expect(seed.accountId != nil)
    }

    @Test("Looking at the current period, the date is now")
    func currentPeriodKeepsNow() {
        let now = date(2026, 9, 18, 14, 32)
        #expect(TransactionSeed.date(in: month(2026, 9), now: now, calendar: calendar) == now)
    }

    /// The reason the date is clamped at all: the list filters on
    /// `occurred_at`, so a transaction dated today and added while looking
    /// at March would save and then disappear from the screen it was added
    /// from.
    @Test("A past period takes its last day, at the current time of day")
    func pastPeriodTakesItsLastDay() {
        let now = date(2026, 9, 18, 14, 32)
        let seeded = TransactionSeed.date(in: month(2026, 3), now: now, calendar: calendar)

        #expect(seeded == date(2026, 3, 31, 14, 32))
        #expect(month(2026, 3).contains(seeded))
    }

    @Test("A future period takes its first day, at the current time of day")
    func futurePeriodTakesItsFirstDay() {
        let now = date(2026, 9, 18, 14, 32)
        let seeded = TransactionSeed.date(in: month(2026, 12), now: now, calendar: calendar)

        #expect(seeded == date(2026, 12, 1, 14, 32))
        #expect(month(2026, 12).contains(seeded))
    }

    /// A single-day period is the case the feature was asked for by name:
    /// filter to one day, add a transaction, it is dated that day.
    @Test("A one-day period dates the transaction that day")
    func singleDayPeriod() {
        let day = date(2026, 5, 4)
        let interval = calendar.dateInterval(of: .day, for: day) ?? DateInterval(start: day, duration: 0)
        let seeded = TransactionSeed.date(in: interval, now: date(2026, 9, 18, 14, 32), calendar: calendar)

        #expect(calendar.isDate(seeded, inSameDayAs: day))
        #expect(interval.contains(seeded))
    }

    /// A custom range ends at the instant the user picked rather than at a
    /// day boundary, so the time of day carried over from now can overshoot
    /// it — and a transaction past `through` is one the list will not show.
    @Test("A custom range never seeds past its own end")
    func customRangeClampsToItsEnd() {
        let range = DateInterval(start: date(2026, 4, 1), end: date(2026, 4, 10, 9, 0))
        let seeded = TransactionSeed.date(in: range, now: date(2026, 9, 18, 14, 32), calendar: calendar)

        #expect(seeded == range.end)
        #expect(range.contains(seeded))
    }

    /// The Transactions screen's own fallback when a calendar cannot build
    /// an interval — `DateInterval(start: anchor, duration: 0)`.
    @Test("A zero-length period still resolves to an instant inside it")
    func zeroLengthPeriod() {
        let instant = date(2026, 2, 2, 8, 15)
        let seeded = TransactionSeed.date(
            in: DateInterval(start: instant, duration: 0), now: date(2026, 9, 18, 14, 32), calendar: calendar
        )

        #expect(seeded == instant)
    }
}
