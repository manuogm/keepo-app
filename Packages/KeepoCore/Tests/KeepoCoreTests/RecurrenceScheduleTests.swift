import Foundation
import Testing
@testable import KeepoCore

@Suite("Recurrence schedule")
struct RecurrenceScheduleTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? Date()
    }

    private func occurrences(
        anchor: Date, _ frequency: PublicSchema.RecurringFrequency, from: Date, to: Date
    ) -> [Date] {
        RecurrenceSchedule.occurrences(
            anchoredAt: anchor, frequency: frequency, in: from ... to, calendar: calendar
        )
    }

    @Test("A weekly rule repeats every seven days inside the window")
    func weeklyRepeatsEverySevenDays() {
        let result = occurrences(
            anchor: date(2026, 8, 20), .weekly, from: date(2026, 8, 20), to: date(2026, 9, 3)
        )
        #expect(result == [date(2026, 8, 20), date(2026, 8, 27), date(2026, 9, 3)])
    }

    @Test("A monthly rule yields at most one occurrence in a two-week window")
    func monthlyYieldsOneInTwoWeeks() {
        let result = occurrences(
            anchor: date(2026, 8, 25), .monthly, from: date(2026, 8, 20), to: date(2026, 9, 3)
        )
        #expect(result == [date(2026, 8, 25)])
    }

    @Test("A yearly rule outside the window yields nothing")
    func yearlyOutsideWindowYieldsNothing() {
        let result = occurrences(
            anchor: date(2026, 12, 1), .yearly, from: date(2026, 8, 20), to: date(2026, 9, 3)
        )
        #expect(result.isEmpty)
    }

    /// A rule whose `next_due_at` is in the past is normal — materialization
    /// runs on its own schedule and can be behind. The occurrences that fall
    /// in the window must still surface, or a bill that is genuinely owed
    /// would silently vanish from the widget.
    @Test("An anchor before the window still surfaces the occurrences inside it")
    func pastAnchorStillSurfacesInWindowOccurrences() {
        let result = occurrences(
            anchor: date(2026, 7, 2), .weekly, from: date(2026, 8, 20), to: date(2026, 8, 27)
        )
        #expect(result == [date(2026, 8, 20), date(2026, 8, 27)])
    }

    /// The reason occurrence *k* is `anchor + k periods` rather than
    /// `previous + 1 period`. Stepping one month at a time from 31 Jan lands
    /// on 28 Feb, and stepping again from *there* gives 28 March — the rule
    /// would walk its own due date permanently earlier. Multiplying from the
    /// anchor returns to the 31st as soon as the month has one.
    @Test("A month-end anchor does not drift earlier after February")
    func monthEndAnchorDoesNotDrift() {
        let result = occurrences(
            anchor: date(2027, 1, 31), .monthly, from: date(2027, 1, 1), to: date(2027, 4, 30)
        )
        #expect(result == [date(2027, 1, 31), date(2027, 2, 28), date(2027, 3, 31), date(2027, 4, 30)])
    }

    @Test("A leap-day anchor lands on the 29th only in leap years")
    func leapDayAnchorClampsInNonLeapYears() {
        let result = occurrences(
            anchor: date(2028, 2, 29), .yearly, from: date(2028, 1, 1), to: date(2030, 12, 31)
        )
        #expect(result == [date(2028, 2, 29), date(2029, 2, 28), date(2030, 2, 28)])
    }

    @Test("An anchor after the window yields nothing")
    func anchorAfterWindowYieldsNothing() {
        let result = occurrences(
            anchor: date(2026, 10, 1), .monthly, from: date(2026, 8, 20), to: date(2026, 9, 3)
        )
        #expect(result.isEmpty)
    }

    @Test("A single-day window containing the anchor yields exactly that day")
    func singleDayWindowYieldsTheAnchor() {
        let day = date(2026, 8, 20)
        #expect(occurrences(anchor: day, .monthly, from: day, to: day) == [day])
    }
}
