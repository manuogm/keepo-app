import Foundation
import KeepoCore
import Testing

/// The phone's copy of the server's start-date rules
/// (20261009100000, 20261011100000, 20261013100000).
@Suite("SharedHistory")
struct SharedHistoryTests {
    private let owner = UUID()
    private let partner = UUID()
    private let start = Date(timeIntervalSince1970: 1_790_000_000)
    private var before: Date { start.addingTimeInterval(-86_400) }
    private var after: Date { start.addingTimeInterval(86_400) }

    private var dated: AccountSharing { AccountSharing(ownerId: owner, isShared: true, sharedFrom: start) }
    private var full: AccountSharing { AccountSharing(ownerId: owner, isShared: true) }
    private var ownPrivate: AccountSharing { AccountSharing(ownerId: owner, isShared: false) }
    private var partnersFull: AccountSharing { AccountSharing(ownerId: partner, isShared: true) }
    private var partnersDated: AccountSharing {
        AccountSharing(ownerId: partner, isShared: true, sharedFrom: after)
    }

    private func placed(_ account: AccountSharing, _ date: Date, id: UUID = UUID()) -> SharedHistory.Placement {
        SharedHistory.Placement(accountId: id, account: account, date: date)
    }

    @Test("the owner is never limited; a partner is, on a dated share only")
    func earliestDate() {
        #expect(SharedHistory.earliestDate(on: dated, for: owner) == nil)
        #expect(SharedHistory.earliestDate(on: dated, for: partner) == start)
        #expect(SharedHistory.earliestDate(on: full, for: partner) == nil)
    }

    @Test("a transfer between two members is bound by the later start, for either of them")
    func earliestTransferDate() {
        #expect(SharedHistory.earliestTransferDate(dated, partnersDated, for: owner) == after)
        #expect(SharedHistory.earliestTransferDate(dated, partnersFull, for: owner) == start)
        #expect(SharedHistory.earliestTransferDate(dated, ownPrivate, for: owner) == nil)
        #expect(SharedHistory.earliestTransferDate(dated, full, for: partner) == start)
    }

    @Test("a partner's rule starts no earlier than the day the account opens for them")
    func earliestRuleDay() {
        #expect(SharedHistory.earliestRuleDay(on: dated, openingDay: "2026-09-24", for: partner) == "2026-09-24")
        #expect(SharedHistory.earliestRuleDay(on: dated, openingDay: "2026-09-24", for: owner) == nil)
        #expect(SharedHistory.earliestRuleDay(on: full, openingDay: "2020-01-01", for: partner) == nil)
    }

    @Test("a partner cannot date a row before the start")
    func partnerBeforeStart() {
        let legs = [SharedHistory.Leg(was: nil, now: placed(dated, before))]
        #expect(SharedHistory.refusal(saving: legs, viewer: partner, isTransfer: false) == SharedHistory.beforeYourStart)
        #expect(SharedHistory.refusal(saving: legs, viewer: owner, isTransfer: false) == nil)
    }

    @Test("the owner cannot date a transfer to the partner before her own account's start")
    func crossMemberTransfer() {
        let legs = [
            SharedHistory.Leg(was: nil, now: placed(dated, before)),
            SharedHistory.Leg(was: nil, now: placed(partnersFull, before))
        ]
        #expect(SharedHistory.refusal(saving: legs, viewer: owner, isTransfer: true)
            == SharedHistory.transferBeforeBothStarts)

        let own = [
            SharedHistory.Leg(was: nil, now: placed(dated, before)),
            SharedHistory.Leg(was: nil, now: placed(ownPrivate, before))
        ]
        #expect(SharedHistory.refusal(saving: own, viewer: owner, isTransfer: true) == nil)
    }

    @Test("a row the household sees cannot move to a private account or before the start")
    func movesOutOfView() {
        let account = UUID()
        let seen = placed(dated, after, id: account)

        let toPrivate = [SharedHistory.Leg(was: seen, now: placed(ownPrivate, after))]
        #expect(SharedHistory.refusal(saving: toPrivate, viewer: owner, isTransfer: false)
            == SharedHistory.movedToPrivateAccount(isTransfer: false))

        let backdated = [SharedHistory.Leg(was: seen, now: placed(dated, before, id: account))]
        #expect(SharedHistory.refusal(saving: backdated, viewer: owner, isTransfer: true)
            == SharedHistory.movedBeforeStart(isTransfer: true))
    }

    @Test("every other move is the owner's to make")
    func allowedMoves() {
        let neverSeen = placed(dated, before)
        let intoView = [SharedHistory.Leg(was: neverSeen, now: placed(dated, after))]
        #expect(SharedHistory.refusal(saving: intoView, viewer: owner, isTransfer: false) == nil)

        let stillSeen = [SharedHistory.Leg(was: placed(dated, after), now: placed(full, before))]
        #expect(SharedHistory.refusal(saving: stillSeen, viewer: owner, isTransfer: false) == nil)

        let privateToPrivate = [SharedHistory.Leg(was: placed(ownPrivate, after), now: placed(ownPrivate, before))]
        #expect(SharedHistory.refusal(saving: privateToPrivate, viewer: owner, isTransfer: false) == nil)
    }
}
