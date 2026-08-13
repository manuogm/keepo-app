import Foundation
import Testing
@testable import KeepoCore

@Suite("PostgresDate")
struct PostgresDateTests {
    @Test("round-trips a timestamp through string and back")
    func timestampRoundTrip() {
        let original = Date(timeIntervalSince1970: 1_700_000_000)
        let string = PostgresDate.timestampString(original)
        let decoded = PostgresDate.date(fromTimestamp: string)
        #expect(decoded == original)
    }

    @Test("rejects malformed timestamp input")
    func timestampRejectsGarbage() {
        #expect(PostgresDate.date(fromTimestamp: "not-a-date") == nil)
    }

    @Test("date-only encoding uses the local calendar day, not a truncated UTC timestamp")
    func dateOnlyUsesLocalDay() {
        // 11:30 PM Pacific Standard Time (UTC-8, January — outside any DST
        // transition) is 07:30 UTC the *next* calendar day — the exact bug
        // in the code this replaced (ISO8601DateFormatter().string(...)
        // renders UTC by default, so slicing its first 10 characters would
        // have produced tomorrow's date here).
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!
        let components = DateComponents(year: 2026, month: 1, day: 10, hour: 7, minute: 30)
        let instant = utcCalendar.date(from: components)!

        var pacific = Calendar(identifier: .gregorian)
        pacific.timeZone = TimeZone(identifier: "America/Los_Angeles")!

        #expect(PostgresDate.dateOnlyString(instant, calendar: pacific) == "2026-01-09")
        #expect(PostgresDate.dateOnlyString(instant, calendar: utcCalendar) == "2026-01-10")
    }

    @Test("sqlite boundary format matches PostgREST's own rendering exactly")
    func sqliteBoundaryMatchesPostgRESTFormat() {
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!
        let instant = utcCalendar.date(from: DateComponents(
            year: 2026, month: 8, day: 11, hour: 13, minute: 38, second: 16
        ))!
        #expect(PostgresDate.sqliteTimestampBoundaryString(instant) == "2026-08-11T13:38:16.000000+00:00")
    }

    @Test("a same-second PostgREST row with a fractional part sorts after a whole-second boundary")
    func sqliteBoundarySortsCorrectlyAgainstFractionalRow() {
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!
        let instant = utcCalendar.date(from: DateComponents(
            year: 2026, month: 8, day: 11, hour: 13, minute: 38, second: 16
        ))!
        let boundary = PostgresDate.sqliteTimestampBoundaryString(instant)
        let row = "2026-08-11T13:38:16.320521+00:00"
        // The row occurred a third of a second AFTER the boundary instant,
        // so it must sort strictly greater — this is the exact comparison
        // `ISO8601DateFormatter`'s default `Z`-suffixed output gets backwards
        // (see this function's doc comment).
        #expect(row > boundary)
    }
}
