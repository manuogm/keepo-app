import Foundation
import KeepoCore
import Testing
@testable import Keepo

/// Handing a dashboard bucket to the Transactions screen crosses a calendar
/// boundary: every bucket bound in the dashboard is a UTC day, and that screen
/// works in `Calendar.current`.
@Suite("Transactions request")
struct TransactionsRequestTests {
    /// July has to arrive as July. Passing the UTC instants straight through
    /// landed on the previous local day anywhere west of UTC — the screen
    /// showed "Jun 30 – Jul 30" for a July bucket, off by one at both ends.
    @Test("A UTC day arrives as the same calendar day locally")
    func utcDayBecomesTheSameLocalDay() throws {
        let july = try #require(utcCalendar.date(from: DateComponents(year: 2026, month: 7, day: 1)))
        let end = try #require(utcCalendar.date(from: DateComponents(year: 2026, month: 7, day: 31)))
        let request = TransactionsRequest(categoryId: nil, kind: nil, utcDays: july ... end)

        let local = Calendar.current
        #expect(local.component(.month, from: request.from) == 7)
        #expect(local.component(.day, from: request.from) == 1)
        #expect(local.component(.month, from: request.through) == 7)
        #expect(local.component(.day, from: request.through) == 31)
    }

    /// The screen filters `occurred_at <= through`, so a midnight bound would
    /// silently drop everything that happened on the last day of the period —
    /// the day most likely to hold the transaction the user is looking for.
    @Test("The last day of the period is included in full")
    func lastDayIsIncludedInFull() throws {
        let day = try #require(utcCalendar.date(from: DateComponents(year: 2026, month: 7, day: 31)))
        let request = TransactionsRequest(categoryId: nil, kind: nil, utcDays: day ... day)

        let local = Calendar.current
        #expect(local.component(.hour, from: request.through) == 23)
        #expect(local.component(.minute, from: request.through) == 59)
        #expect(request.through > request.from)
    }

    /// The transfers roll-up has no category to filter by, so it asks for the
    /// kind instead — `TransactionFilter.kind`'s own vocabulary.
    @Test("A request carries either a category or a kind")
    func requestCarriesCategoryOrKind() throws {
        let day = try #require(utcCalendar.date(from: DateComponents(year: 2026, month: 7, day: 1)))
        let category = UUID()
        let byCategory = TransactionsRequest(categoryId: category, kind: nil, utcDays: day ... day)
        let byKind = TransactionsRequest(categoryId: nil, kind: "transfer", utcDays: day ... day)
        #expect(byCategory.categoryId == category)
        #expect(byCategory.kind == nil)
        #expect(byKind.categoryId == nil)
        #expect(byKind.kind == "transfer")
    }
}
