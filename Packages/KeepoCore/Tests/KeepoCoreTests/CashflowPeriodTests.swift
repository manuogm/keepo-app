import Foundation
import Testing
@testable import KeepoCore

@Suite("Cashflow period")
struct CashflowPeriodTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? Date()
    }

    /// The whole point of the type: mid-August, the month in view is July —
    /// never August-so-far, which is not comparable to a full month.
    @Test("A month mid-period resolves to the last complete month")
    func monthResolvesToLastCompleteMonth() {
        let bounds = CashflowPeriod.month.bounds(now: date(2026, 8, 20), calendar: calendar)
        #expect(bounds.lowerBound == date(2026, 7, 1))
        #expect(bounds.upperBound == date(2026, 7, 31))
    }

    @Test("A year mid-period resolves to the last complete year")
    func yearResolvesToLastCompleteYear() {
        let bounds = CashflowPeriod.year.bounds(now: date(2026, 8, 20), calendar: calendar)
        #expect(bounds.lowerBound == date(2025, 1, 1))
        #expect(bounds.upperBound == date(2025, 12, 31))
    }

    @Test("The comparison period is the one immediately before")
    func previousIsTheStepBefore() {
        let previous = CashflowPeriod.month.previousBounds(now: date(2026, 8, 20), calendar: calendar)
        #expect(previous.lowerBound == date(2026, 6, 1))
        #expect(previous.upperBound == date(2026, 6, 30))

        let previousYear = CashflowPeriod.year.previousBounds(now: date(2026, 8, 20), calendar: calendar)
        #expect(previousYear.lowerBound == date(2024, 1, 1))
        #expect(previousYear.upperBound == date(2024, 12, 31))
    }

    /// Bounds are inclusive and land on the period's own last day, never the
    /// next period's first — otherwise a `BETWEEN` comparison would count a
    /// transaction on the seam in both periods.
    @Test("Periods do not overlap on the seam")
    func periodsDoNotOverlap() {
        let now = date(2026, 8, 20)
        let current = CashflowPeriod.month.bounds(now: now, calendar: calendar)
        let previous = CashflowPeriod.month.previousBounds(now: now, calendar: calendar)
        #expect(previous.upperBound < current.lowerBound)
        #expect(calendar.date(byAdding: .day, value: 1, to: previous.upperBound) == current.lowerBound)
    }

    @Test("January rolls the month back into the previous year")
    func januaryRollsBackAYear() {
        let bounds = CashflowPeriod.month.bounds(now: date(2027, 1, 15), calendar: calendar)
        #expect(bounds.lowerBound == date(2026, 12, 1))
        #expect(bounds.upperBound == date(2026, 12, 31))
    }

    @Test("A February window covers the leap day in a leap year")
    func februaryCoversTheLeapDay() {
        let bounds = CashflowPeriod.month.bounds(now: date(2028, 3, 10), calendar: calendar)
        #expect(bounds.lowerBound == date(2028, 2, 1))
        #expect(bounds.upperBound == date(2028, 2, 29))
    }

    @Test("The first day of a period still looks at the period before it")
    func firstDayOfPeriodLooksBack() {
        let bounds = CashflowPeriod.month.bounds(now: date(2026, 8, 1), calendar: calendar)
        #expect(bounds.lowerBound == date(2026, 7, 1))
        #expect(bounds.upperBound == date(2026, 7, 31))
    }

    @Test("Labels name the window rather than describing it")
    func labelsNameTheWindow() {
        let posix = Locale(identifier: "en_US_POSIX")
        let now = date(2026, 8, 20)
        #expect(CashflowPeriod.month.label(now: now, calendar: calendar, locale: posix) == "July")
        #expect(CashflowPeriod.year.label(now: now, calendar: calendar, locale: posix) == "2025")
    }
}
