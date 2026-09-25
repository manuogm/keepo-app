import Foundation

/// The facts about one account that decide who sees which of its rows.
///
/// `TransferPairing` reads the first two; `SharedHistory` all three.
public struct AccountSharing: Equatable, Sendable {
    public let ownerId: UUID
    /// Shared into the viewer's household. "The same household" needs no
    /// field of its own: a user belongs to one household at most.
    public let isShared: Bool
    /// When a share that began on a date started — the start of that day in
    /// the owner's time zone (`share_start`). Nil for a share with full
    /// history, and for an account that is not shared.
    public let sharedFrom: Date?

    public init(ownerId: UUID, isShared: Bool, sharedFrom: Date? = nil) {
        self.ownerId = ownerId
        self.isShared = isShared
        self.sharedFrom = sharedFrom
    }

    /// Whether the household sees a row on this account dated `date` —
    /// the server's `transaction_shared_into` is not null.
    func householdSees(_ date: Date) -> Bool {
        guard isShared else { return false }
        return sharedFrom.map { date >= $0 } ?? true
    }
}

/// Where a share that began on a date lets a row go, asked before a save
/// rather than learned from the server's refusal after it.
///
/// Every rule here is the server's, which stays the authority:
///
///   * a partner cannot place a row before the start date
///     (`assert_transaction_date_visible`, 20261009100000);
///   * a transfer between the two members' accounts has both halves where the
///     household sees them (`assert_transfer_seen_by_both`, 20261013100000);
///   * a row the household sees cannot be moved out of their view
///     (`keep_shared_transaction_in_view`, 20261011100000).
///
/// The sentences are the server's too, word for word, so the pop-up reads the
/// same whether the phone or the server said no.
public enum SharedHistory {
    public static let beforeYourStart =
        "That date is before this account was shared with you. Pick a later date."

    public static let transferBeforeBothStarts =
        "This transfer is between your account and your partner's, so it can't be dated before both "
        + "accounts were shared. Pick a later date."

    public static func movedToPrivateAccount(isTransfer: Bool) -> String {
        "This \(noun(isTransfer)) is shared with your household, so it can't be moved to an account they "
            + "can't see. Delete it and add it again on that account."
    }

    public static func movedBeforeStart(isTransfer: Bool) -> String {
        "Your household sees this account's transactions from the day you shared it, so this "
            + "\(noun(isTransfer)) can't be moved before that date. Delete it and add it again with the earlier date."
    }

    /// Where one half of an entry is, or was.
    public struct Placement: Equatable, Sendable {
        public let accountId: UUID
        public let account: AccountSharing
        public let date: Date

        public init(accountId: UUID, account: AccountSharing, date: Date) {
            self.accountId = accountId
            self.account = account
            self.date = date
        }
    }

    /// One half of the entry being saved: where it goes, and where it was
    /// when this is an edit.
    public struct Leg: Equatable, Sendable {
        public let was: Placement?
        public let now: Placement

        public init(was: Placement?, now: Placement) {
            self.was = was
            self.now = now
        }
    }

    /// The earliest moment `viewer` may date a row on this account, or nil
    /// when nothing limits them: they own it, or it is shared with its full
    /// history.
    public static func earliestDate(on account: AccountSharing, for viewer: UUID) -> Date? {
        account.ownerId == viewer ? nil : account.sharedFrom
    }

    /// The same for a transfer. Between two members' accounts both halves
    /// must be where the household sees them, so the later of the two start
    /// dates binds whoever is entering it; between one person's own accounts
    /// only the viewer's own limits apply.
    public static func earliestTransferDate(
        _ from: AccountSharing, _ destination: AccountSharing, for viewer: UUID
    ) -> Date? {
        if from.ownerId != destination.ownerId {
            return later(from.sharedFrom, destination.sharedFrom)
        }
        return later(earliestDate(on: from, for: viewer), earliestDate(on: destination, for: viewer))
    }

    /// The first day a partner's recurring rule may start, as a `date`
    /// column spells it, or nil when nothing limits them.
    ///
    /// `openingDay` is the account's `opening_balance_at` as the viewer holds
    /// it. For a partner on a share that began on a date that is the owner's
    /// calendar day the share started (`account_opening_as_seen`), which is
    /// what the server compares a rule's first occurrence against — and the
    /// only place the partner's phone learns it, since the owner's time zone
    /// is not theirs to read.
    public static func earliestRuleDay(on account: AccountSharing, openingDay: String, for viewer: UUID) -> String? {
        earliestDate(on: account, for: viewer) == nil ? nil : String(openingDay.prefix(10))
    }

    /// The sentence the server would refuse this save with, or nil when it
    /// would accept it. Checked in the server's own order.
    public static func refusal(saving legs: [Leg], viewer: UUID, isTransfer: Bool) -> String? {
        for leg in legs {
            if let earliest = earliestDate(on: leg.now.account, for: viewer), leg.now.date < earliest {
                return beforeYourStart
            }
        }

        if isTransfer, legs.count == 2,
           legs[0].now.account.ownerId != legs[1].now.account.ownerId,
           !(legs[0].now.account.householdSees(legs[0].now.date)
               && legs[1].now.account.householdSees(legs[1].now.date)) {
            return transferBeforeBothStarts
        }

        for leg in legs {
            guard let was = leg.was, was.account.householdSees(was.date),
                  !leg.now.account.householdSees(leg.now.date) else { continue }
            return leg.now.accountId != was.accountId && !leg.now.account.isShared
                ? movedToPrivateAccount(isTransfer: isTransfer)
                : movedBeforeStart(isTransfer: isTransfer)
        }
        return nil
    }

    private static func noun(_ isTransfer: Bool) -> String { isTransfer ? "transfer" : "transaction" }

    private static func later(_ first: Date?, _ second: Date?) -> Date? {
        switch (first, second) {
        case let (first?, second?): return max(first, second)
        case let (first?, nil): return first
        case let (nil, second): return second
        }
    }
}
