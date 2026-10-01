import Foundation

/// Every field optional and AND'd together — an empty filter behaves
/// exactly like `TransactionRepository.fetchAll`.
///
/// **One field per axis, and the multi-valued axes are sets.** The ledger's
/// drop-down lets the user tick several categories, several types and either
/// household member, so "which category" is a set rather than a value; a
/// parallel `categoryId` beside `categoryIds` would be two answers to one
/// question, with nothing to say which wins. `accountId` stays singular
/// because the always-visible account chip picks exactly one (or none, which
/// is "all"), and `accountIds` is the export's own multi-account selection —
/// both may be set and are AND'd like everything else.
///
/// **An empty set matches nothing**, everywhere. "No categories chosen" is
/// not "any category": the UI resets an axis to `nil` rather than to `[]`
/// when the user unticks the last option, so the empty set is reachable only
/// from code that means it.
///
/// It is read by one query builder, `LocalTransactionRow.filteredSource` —
/// the ledger's rows and the export's counts and totals both go through it,
/// so a file can never hold a different set of transactions from the list it
/// was launched from. A PostgREST twin of that builder lived here until it
/// was deleted for having no callers since the ledger went local-first
/// (Phase L6); it had been quietly drifting — notes, tags and amount search
/// all had to be added to it by hand, and tags could not be expressed at all
/// without embedding `transaction_tags`.
public struct TransactionFilter: Equatable, Sendable {
    public var accountId: UUID?
    public var categoryIds: Set<UUID>?
    /// `TransactionFilter`'s own kind vocabulary — `"expense"`, `"income"`,
    /// `"transfer"` — the same three strings the `CASE` in
    /// `LocalTransactionRow.fetchFiltered` derives, so nothing translates
    /// between the drop-down and the query.
    public var kinds: Set<String>?
    /// Who **entered** the transaction (`transactions.created_by`), not whose
    /// account it landed on. The two are different facts and only this one is
    /// worth filtering by: a composite FK forces `transactions.owner_id` to
    /// equal its account's owner, so on one shared joint account every row
    /// has the same owner while the two members' entries are exactly what a
    /// household wants told apart. Same fact the transaction form's "Added
    /// by" pill names.
    public var createdByIds: Set<UUID>?
    /// How the transaction got here — `transactions.source`, the real enum,
    /// not a boolean "is it a capture".
    ///
    /// The ask was for the captures specifically, and a `Bool` would have
    /// answered it; the column has five values, so a boolean would be a lossy
    /// view of it that has to be widened the first time anybody wants to see
    /// only the recurring instances. `.capture` is the same test
    /// `TransactionRow` draws its chip glyph from, so the filter and the row's
    /// own provenance marker cannot come to disagree about what "captured"
    /// means.
    public var sources: Set<PublicSchema.TransactionSource>?
    public var from: Date?
    public var through: Date?
    public var search: String?
    /// Several accounts at once — the export's multi-account selection. The
    /// ledger's own chip picks one (`accountId`); both may be set and are
    /// AND'd like everything else.
    public var accountIds: Set<UUID>?

    public init(
        accountId: UUID? = nil,
        categoryIds: Set<UUID>? = nil,
        kinds: Set<String>? = nil,
        createdByIds: Set<UUID>? = nil,
        sources: Set<PublicSchema.TransactionSource>? = nil,
        from: Date? = nil,
        through: Date? = nil,
        search: String? = nil,
        accountIds: Set<UUID>? = nil
    ) {
        self.accountId = accountId
        self.categoryIds = categoryIds
        self.kinds = kinds
        self.createdByIds = createdByIds
        self.sources = sources
        self.from = from
        self.through = through
        self.search = search
        self.accountIds = accountIds
    }

    public var isEmpty: Bool {
        accountId == nil && categoryIds == nil && kinds == nil && createdByIds == nil && sources == nil
            && from == nil && through == nil && (search?.isEmpty ?? true) && accountIds == nil
    }

    /// The one category this filter is narrowed to, or `nil` when it is unset
    /// or holds several — what a prefill may honestly copy. A ledger showing
    /// two categories has not answered "which category", so a new transaction
    /// opened from it must not pretend otherwise.
    public var soleCategoryId: UUID? { categoryIds.flatMap { $0.count == 1 ? $0.first : nil } }

    /// `soleCategoryId`'s counterpart for the type axis, same reasoning.
    public var soleKind: String? { kinds.flatMap { $0.count == 1 ? $0.first : nil } }

    /// `search` read as an amount — the e4 magnitude a query like "15",
    /// "1.424,05" or "$15.00" is asking for — or `nil` when the term is not a
    /// number and the search is text only.
    ///
    /// **Here rather than at the query**, because two query builders read it
    /// (the local ledger and the PostgREST twin) and "which typed strings are
    /// amounts" is one decision, not two.
    ///
    /// Three rules, each of which the obvious version gets wrong:
    ///
    ///   1. **A term with letters in it is never an amount.** `Decimal(string:)`
    ///      happily reads "2 coffees" as 2, which would put every 2.00 in the
    ///      ledger among the results for a text search. Currency symbols and
    ///      spaces are stripped first, so "$15" and "15 " still count.
    ///   2. **Parsing goes through `AmountParser`**, the one place a typed
    ///      string becomes fixed-point money — so a comma-decimal locale reads
    ///      "15,50" the way its owner meant it, and nothing here ever touches
    ///      a `Double`.
    ///   3. **The sign is dropped.** Amounts are signed (money rule 1) and the
    ///      ledger draws magnitudes; somebody searching for what they spent
    ///      types "15", not "-15", and both should find it.
    public var searchAmountE4: Int64? {
        guard let search, !search.isEmpty else { return nil }
        let stripped = search.filter { !$0.isWhitespace && !$0.isCurrencySymbol }
        guard stripped.contains(where: \.isNumber),
              stripped.allSatisfy({ $0.isNumber || $0 == "." || $0 == "," || $0 == "-" || $0 == "+" })
        else { return nil }
        // A term too large to hold as e4 money comes back `nil` from the
        // parser itself, which is where that bound belongs — this used to
        // re-check it here, and two bounds for one rule is one of them
        // drifting later. `.min` cannot reach `abs` for the same reason: the
        // parser will not produce it.
        guard let parsed = AmountParser.parse(stripped) else { return nil }
        return abs(parsed)
    }
}
