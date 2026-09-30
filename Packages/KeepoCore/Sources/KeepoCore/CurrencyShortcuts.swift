import Foundation

/// Which three currencies the currency wheel offers as one-tap pills.
///
/// They used to be a fixed EUR, USD, GBP — right for most users and wrong
/// for anyone whose money is in something else: a Swede spun the wheel past
/// twenty currencies every time, to reach the one they hold. Now the pills
/// are the user's own currencies, most important first, topped up from the
/// defaults when they hold fewer than three.
///
/// Two halves, because they run at different times. `rank` is the expensive
/// question — what does this user hold and use — and runs when their data
/// changes (`PreferredCurrencyCache`). `pills` is cheap and runs every time
/// the wheel draws, against the currencies the server currently supports.
public enum CurrencyShortcuts {
    /// The most common answers overall, in order. They fill the pills a user
    /// has no currency of their own for, and break ties between the ones
    /// they do.
    public static let defaults = ["EUR", "USD", "GBP"]

    /// How much a user relies on one currency.
    public struct Usage: Equatable, Sendable {
        public let code: String
        public let transactions: Int
        public let accounts: Int

        public init(code: String, transactions: Int, accounts: Int) {
            self.code = code
            self.transactions = transactions
            self.accounts = accounts
        }
    }

    /// Most important first: more transactions, then more accounts, then the
    /// defaults' own order, then alphabetical — so the result never depends
    /// on the order rows came out of the database.
    public static func rank(_ usage: [Usage]) -> [String] {
        usage
            .sorted { lhs, rhs in
                if lhs.transactions != rhs.transactions { return lhs.transactions > rhs.transactions }
                if lhs.accounts != rhs.accounts { return lhs.accounts > rhs.accounts }
                let lhsDefault = defaults.firstIndex(of: lhs.code) ?? defaults.count
                let rhsDefault = defaults.firstIndex(of: rhs.code) ?? defaults.count
                if lhsDefault != rhsDefault { return lhsDefault < rhsDefault }
                return lhs.code < rhs.code
            }
            .map(\.code)
    }

    /// The pills: the user's top three supported currencies in rank order,
    /// then the defaults they do not already hold, in the defaults' order.
    ///
    /// Only codes in `supported` are offered — a pill for a currency the
    /// wheel has no row for would select something the user cannot see.
    public static func pills(preferred: [String], supported: Set<String>, count: Int = 3) -> [String] {
        var result: [String] = []
        for code in preferred + defaults where supported.contains(code) && !result.contains(code) {
            result.append(code)
            if result.count == count { break }
        }
        return result
    }
}
