import Foundation
import Testing
@testable import KeepoCore

@Suite("DateBucketing")
struct DateBucketingTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    @Test("a 90-day span buckets weekly")
    func ninetyDaysIsWeekly() {
        let granularity = DateBucketing.granularity(from: date(2026, 1, 1), through: date(2026, 3, 31), calendar: calendar)
        #expect(granularity == .weekly)
    }

    @Test("a span longer than 90 days buckets monthly")
    func overNinetyDaysIsMonthly() {
        let granularity = DateBucketing.granularity(from: date(2026, 1, 1), through: date(2026, 6, 1), calendar: calendar)
        #expect(granularity == .monthly)
    }

    @Test("weekly bucketing keeps the last point in each calendar week")
    func weeklyKeepsLastPoint() {
        let points = [
            (date: date(2026, 1, 5), value: 100), // Monday
            (date: date(2026, 1, 6), value: 110),
            (date: date(2026, 1, 7), value: 120), // last point of that week
            (date: date(2026, 1, 12), value: 200) // next week
        ]
        let bucketed = DateBucketing.bucket(points, granularity: .weekly, calendar: calendar)
        #expect(bucketed.map(\.value) == [120, 200])
    }

    @Test("monthly bucketing keeps the last point in each calendar month")
    func monthlyKeepsLastPoint() {
        let points = [
            (date: date(2026, 1, 10), value: 100),
            (date: date(2026, 1, 25), value: 150), // last point of January
            (date: date(2026, 2, 3), value: 200)
        ]
        let bucketed = DateBucketing.bucket(points, granularity: .monthly, calendar: calendar)
        #expect(bucketed.map(\.value) == [150, 200])
    }

    @Test("bucketing an ascending series returns buckets in ascending date order")
    func preservesOrder() {
        let points = (1...10).map { (date: date(2026, 1, $0), value: $0) }
        let bucketed = DateBucketing.bucket(points, granularity: .weekly, calendar: calendar)
        #expect(bucketed.map(\.date) == bucketed.map(\.date).sorted())
        #expect(bucketed.count < points.count)
    }
}
