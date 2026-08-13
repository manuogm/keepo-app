import Foundation
import Testing
@testable import KeepoCore

@Suite("CaptureIdentity")
struct CaptureIdentityTests {
    @Test("is deterministic — same inputs, same hash")
    func isDeterministic() {
        let date = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let a = CaptureIdentity.externalId(card: "card-1", amount: 45000, merchant: "BLUE BOTTLE", at: date)
        let b = CaptureIdentity.externalId(card: "card-1", amount: 45000, merchant: "BLUE BOTTLE", at: date)
        #expect(a == b)
    }

    @Test("a re-fired automation within the same minute hashes identically")
    func sameMinuteCollides() {
        let first = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let secondsLater = first.addingTimeInterval(5)
        let a = CaptureIdentity.externalId(card: "card-1", amount: 45000, merchant: "BLUE BOTTLE", at: first)
        let b = CaptureIdentity.externalId(card: "card-1", amount: 45000, merchant: "BLUE BOTTLE", at: secondsLater)
        #expect(a == b)
    }

    @Test("two purchases a minute-bucket apart never collide")
    func differentBucketsDiffer() {
        let first = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let later = first.addingTimeInterval(120)
        let a = CaptureIdentity.externalId(card: "card-1", amount: 45000, merchant: "BLUE BOTTLE", at: first)
        let b = CaptureIdentity.externalId(card: "card-1", amount: 45000, merchant: "BLUE BOTTLE", at: later)
        #expect(a != b)
    }

    @Test("a different card never collides, same everything else")
    func differentCardDiffers() {
        let date = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let a = CaptureIdentity.externalId(card: "card-1", amount: 45000, merchant: "BLUE BOTTLE", at: date)
        let b = CaptureIdentity.externalId(card: "card-2", amount: 45000, merchant: "BLUE BOTTLE", at: date)
        #expect(a != b)
    }

    @Test("a different amount never collides, same everything else")
    func differentAmountDiffers() {
        let date = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let a = CaptureIdentity.externalId(card: "card-1", amount: 45000, merchant: "BLUE BOTTLE", at: date)
        let b = CaptureIdentity.externalId(card: "card-1", amount: 55000, merchant: "BLUE BOTTLE", at: date)
        #expect(a != b)
    }

    @Test("a different merchant never collides, same everything else")
    func differentMerchantDiffers() {
        let date = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let a = CaptureIdentity.externalId(card: "card-1", amount: 45000, merchant: "BLUE BOTTLE", at: date)
        let b = CaptureIdentity.externalId(card: "card-1", amount: 45000, merchant: "TARGET", at: date)
        #expect(a != b)
    }

    @Test("produces a 64-character lowercase hex string (SHA-256)")
    func isHexSHA256() {
        let date = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let id = CaptureIdentity.externalId(card: "card-1", amount: 45000, merchant: "BLUE BOTTLE", at: date)
        #expect(id.count == 64)
        #expect(id == id.lowercased())
        #expect(id.allSatisfy { $0.isHexDigit })
    }
}
