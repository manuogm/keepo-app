import Foundation
import Testing
@testable import KeepoCore

@Suite("Stable seed")
struct StableSeedTests {
    @Test("The same string always yields the same index")
    func isDeterministic() {
        #expect(StableSeed.index("USD", upperBound: 12) == StableSeed.index("USD", upperBound: 12))
        #expect(StableSeed.hash("visa-4242") == StableSeed.hash("visa-4242"))
    }

    @Test("Different strings generally land on different indices")
    func spreadsAcrossTheRange() {
        let codes = ["USD", "EUR", "GBP", "JPY", "CHF", "SEK", "NOK", "AUD"]
        let indices = Set(codes.map { StableSeed.index($0, upperBound: 12) })
        // Not a guarantee of zero collisions across an arbitrary set — just
        // that this is a hash and not a constant.
        #expect(indices.count >= codes.count - 2)
    }

    @Test("An index is always inside the collection")
    func indexIsInRange() {
        for code in ["USD", "EUR", "A", "", "a very long identifier indeed"] {
            let index = StableSeed.index(code, upperBound: 5)
            #expect(index >= 0 && index < 5)
        }
    }

    /// Callers are picking a decoration, so an empty palette has to be
    /// survivable rather than a modulo-by-zero trap.
    @Test("An empty collection yields 0 rather than trapping")
    func emptyCollectionIsSafe() {
        #expect(StableSeed.index("USD", upperBound: 0) == 0)
        #expect(StableSeed.index("USD", upperBound: -3) == 0)
    }

    /// `CreditCardFace` shipped with this exact computation inlined and its
    /// output is visible (which card is which shade). Pinning it here means
    /// the extraction can't quietly re-colour anyone's existing cards.
    @Test("Reproduces the inlined computation CreditCardFace shipped with")
    func matchesPreviouslyInlinedComputation() {
        for identifier in ["4242", "visa-1881", "amex", "mastercard-0007"] {
            var expected = 2_166_136_261
            for byte in identifier.utf8 {
                expected = (expected ^ Int(byte)) &* 16_777_619
            }
            #expect(StableSeed.index(identifier, upperBound: 997) == Int(expected.magnitude % 997))
        }
    }

    @Test("The same string always derives the same UUID")
    func uuidIsStable() {
        let key = "a1b2c3:d4e5f6"
        #expect(StableSeed.uuid(from: key) == StableSeed.uuid(from: key))
    }

    @Test("Different strings derive different UUIDs, including a swapped pair")
    func uuidDistinguishesInputs() {
        // The outbox keys a transaction_tags item by "<transaction>:<tag>".
        // Swapping the two halves must not collide, or un-tagging one row
        // would silently replace a queued write on a different one.
        let forward = StableSeed.uuid(from: "aaaa:bbbb")
        let reversed = StableSeed.uuid(from: "bbbb:aaaa")
        #expect(forward != reversed)
        #expect(StableSeed.uuid(from: "aaaa:bbbb") != StableSeed.uuid(from: "aaaa:bbbc"))
    }
}
