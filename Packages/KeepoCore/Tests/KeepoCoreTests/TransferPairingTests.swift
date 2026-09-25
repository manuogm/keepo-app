import Foundation
import Testing
@testable import KeepoCore

/// The four shapes a pair of visible accounts can take, each pinned against
/// what `check_transfer_integrity` does with it at commit.
@Suite("Transfer pairing")
struct TransferPairingTests {
    private let me = UUID()
    private let partner = UUID()

    @Test("Two of your own accounts pair, shared or not")
    func sameOwnerAlwaysPairs() {
        #expect(TransferPairing.allows(.init(ownerId: me, isShared: false), .init(ownerId: me, isShared: false)))
        #expect(TransferPairing.allows(.init(ownerId: me, isShared: true), .init(ownerId: me, isShared: false)))
    }

    @Test("Your shared account pairs with your partner's shared account")
    func bothSharedPairs() {
        #expect(TransferPairing.allows(.init(ownerId: me, isShared: true), .init(ownerId: partner, isShared: true)))
    }

    /// The case the form used to offer and the trigger always refused —
    /// "legs must share one owner or one household".
    @Test("A private account does not pair with the partner's shared one, in either direction")
    func privateToPartnerDoesNotPair() {
        let mine = TransferPairing.Side(ownerId: me, isShared: false)
        let theirs = TransferPairing.Side(ownerId: partner, isShared: true)
        #expect(!TransferPairing.allows(mine, theirs))
        #expect(!TransferPairing.allows(theirs, mine))
    }
}
