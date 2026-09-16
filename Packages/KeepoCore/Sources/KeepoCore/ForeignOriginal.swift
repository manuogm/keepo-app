import Foundation

/// What a purchase was actually paid in, when that differs from the
/// account's own currency — `transactions.original_amount_e4` and
/// `original_currency` travelling as one value.
///
/// **One optional, not two.** The database says the pair is set or null
/// together (`original_amount_currency_together`), and two parallel
/// optionals in Swift would let a caller satisfy the type checker while
/// violating that — an amount with no currency is not a smaller mistake
/// than a wrong amount, it is an unreadable row. One optional makes "is
/// this foreign?" the same null check on both sides of the wire.
///
/// Provenance only: **never summed, never re-converted, never a balance**
/// (CLAUDE.md money rule 6). The figure that participates in a balance is
/// always `amount_e4`, always in the account's currency, and always one a
/// human has had the chance to correct.
public struct ForeignOriginal: Codable, Sendable, Equatable {
    /// Signed like the amount it accompanies — the database refuses a pair
    /// whose signs disagree, because €50 paid cannot have charged +$54.
    public let amountE4: Int64
    public let currency: String

    public init(amountE4: Int64, currency: String) {
        self.amountE4 = amountE4
        self.currency = currency
    }

    /// `nil` when the currency matches the account's, which is what the
    /// column pair means by "null": not foreign. Saves every call site the
    /// same three-line guard, and keeps the one rule in one place.
    public init?(amountE4: Int64?, currency: String?, accountCurrency: String?) {
        guard let amountE4, let currency, currency != accountCurrency else { return nil }
        self.amountE4 = amountE4
        self.currency = currency
    }

    /// `nil` when this original is already in `currency`. Every RPC
    /// normalizes the same way server-side rather than rejecting the row;
    /// the local mirror has to agree with it, or the two disagree about
    /// whether a transaction is foreign until the next pull corrects it.
    public func against(_ currency: String) -> ForeignOriginal? {
        self.currency == currency ? nil : self
    }
}
