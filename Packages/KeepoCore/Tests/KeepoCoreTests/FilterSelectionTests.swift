import Foundation
import Testing
@testable import KeepoCore

/// The three rules `FilterSelection` exists for. Each one is a bug the
/// obvious implementation has: "all" drifting out of date as categories are
/// added, tapping one option meaning "all but that one", and clearing the
/// last tick landing on a filter that matches nothing.
@Suite("Filter selection")
struct FilterSelectionTests {
    @Test("From all, one tap means only that option")
    func firstTapNarrowsToOne() {
        let groceries = UUID()

        #expect(FilterSelection.toggling(groceries, in: nil) == [groceries])
    }

    @Test("A second tap adds rather than replaces")
    func secondTapAdds() {
        let groceries = UUID()
        let transport = UUID()

        #expect(FilterSelection.toggling(transport, in: [groceries]) == [groceries, transport])
    }

    @Test("Unticking one of several leaves the rest")
    func untickingLeavesTheRest() {
        let groceries = UUID()
        let transport = UUID()

        #expect(FilterSelection.toggling(transport, in: [groceries, transport]) == [groceries])
    }

    /// The rule that matters most: an empty set matches **no** rows
    /// (`LocalTransactionRow.appendIn` spells it as a false clause), so a user
    /// clearing their last tick has to land back on "all", not on a blank
    /// ledger.
    @Test("Unticking the last one goes back to all, never the empty set")
    func lastUntickReturnsToAll() {
        let groceries = UUID()

        #expect(FilterSelection.toggling(groceries, in: [groceries]) == nil)
    }

    /// Works on any hashable axis, not just ids — the type filter's values are
    /// the same three strings `TransactionFilter.kinds` holds.
    @Test("The same rules hold for a string axis")
    func stringAxis() {
        #expect(FilterSelection.toggling("expense", in: nil) == ["expense"])
        #expect(FilterSelection.toggling("income", in: ["expense"]) == ["expense", "income"])
        #expect(FilterSelection.toggling("expense", in: ["expense"]) == nil)
    }
}

/// Which typed strings the ledger's search reads as an **amount** — the rule
/// that decides whether "15" also looks for money, and the reason "2 coffees"
/// does not.
@Suite("Search term as an amount")
struct SearchAmountTests {
    private func amount(_ term: String) -> Int64? {
        TransactionFilter(search: term).searchAmountE4
    }

    @Test("A plain number is an amount, at e4 scale")
    func plainNumber() {
        #expect(amount("15") == 150_000)
        #expect(amount("15.50") == 155_000)
        #expect(amount("0.05") == 500)
    }

    /// e4 is currency-independent — `123400` is 12.34 whatever the currency —
    /// so a zero-decimal currency's figure scales the same way.
    @Test("A zero-decimal currency's figure scales like any other")
    func zeroDecimalCurrency() {
        #expect(amount("1000") == 10_000_000)
    }

    @Test("Currency symbols and spaces are ignored")
    func symbolsIgnored() {
        #expect(amount("$15") == 150_000)
        #expect(amount(" 15 ") == 150_000)
        #expect(amount("€1.424,05") == amount("1.424,05"))
    }

    /// Amounts are signed in the database and drawn as magnitudes on screen,
    /// so somebody looking for what they spent types the magnitude.
    @Test("The sign is dropped")
    func signDropped() {
        #expect(amount("-15") == 150_000)
        #expect(amount("+15") == 150_000)
    }

    /// The rule that matters: `Decimal(string:)` reads "2 coffees" as 2, which
    /// would drop every 2.00 in the ledger into the results for a text search.
    @Test("A term with letters in it is not an amount")
    func lettersAreNotAmounts() {
        #expect(amount("2 coffees") == nil)
        #expect(amount("coffee") == nil)
        #expect(amount("15abc") == nil)
        #expect(amount("") == nil)
        #expect(TransactionFilter().searchAmountE4 == nil)
    }

    /// **The one that caught a real bug.** `AmountParser` finishes at
    /// `NSDecimalNumber.int64Value`, which wraps on overflow rather than
    /// trapping — forty nines came back as 80237960548581376, a number that
    /// looks like an amount, is not the one typed, and would have matched
    /// whatever transaction happened to hold it.
    @Test("A number too large to scale reads as no amount, never as a wrapped one")
    func absurdNumber() {
        #expect(amount(String(repeating: "9", count: 40)) == nil)
        // The boundary itself: `Int64.max / 10_000` still scales, one past it
        // does not.
        #expect(amount("922337203685477") == 9_223_372_036_854_770_000)
        #expect(amount("922337203685478") == nil)
    }
}
