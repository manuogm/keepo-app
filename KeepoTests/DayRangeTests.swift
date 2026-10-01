import Foundation
import Testing
@testable import Keepo

/// The range calendar's selection rules — shared by the Transactions list's
/// Custom Range sheet and Export's period page. The second rule is the one
/// that keeps a reversed interval (which `DateInterval` traps on) from ever
/// being built.
@Suite("Day range")
struct DayRangeTests {
    private let calendar = Calendar(identifier: .gregorian)

    private func day(_ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day)) ?? Date()
    }

    @Test("the first tap starts a range and the second, on or after it, ends it")
    func twoTaps() {
        var range = DayRange()
        range.select(day(9, 1))
        #expect(range.days == nil)
        #expect(range.state(of: day(9, 1)) == .single)
        range.select(day(9, 30))
        #expect(range.days == day(9, 1)...day(9, 30))
        #expect(range.state(of: day(9, 15)) == .between)
    }

    @Test("a tap before the start begins again instead of ending before it")
    func tapBeforeStart() {
        var range = DayRange(start: day(9, 10))
        range.select(day(9, 2))
        #expect(range.start == day(9, 2))
        #expect(range.end == nil)
    }

    @Test("a tap on a finished range begins a new one")
    func tapAfterFinished() {
        var range = DayRange(start: day(9, 1), end: day(9, 30))
        range.select(day(8, 15))
        #expect(range.start == day(8, 15))
        #expect(range.end == nil)
    }

    @Test("the same day twice is a one-day range")
    func singleDay() {
        var range = DayRange()
        range.select(day(9, 23))
        range.select(day(9, 23))
        #expect(range.days == day(9, 23)...day(9, 23))
        #expect(range.state(of: day(9, 23)) == .single)
    }

    @Test("All Time marks no days, whatever range sits under it")
    func allTimeMarksNothing() {
        let range = DayRange(start: day(9, 1), end: day(9, 30), isAllTime: true)
        #expect(range.state(of: day(9, 1)) == .none)
        #expect(range.state(of: day(9, 15)) == .none)
    }

    @Test("the month window reaches back to a selection older than six years")
    func windowWidensToSelection() {
        let old = calendar.date(from: DateComponents(year: 2012, month: 3, day: 5)) ?? Date()
        let window = DayRange(start: old, end: old).monthWindow(calendar: calendar)
        #expect(window.first == DayRange.monthStart(of: old, calendar: calendar))
    }
}
