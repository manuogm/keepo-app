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

    // MARK: - transactionId(forExternalId:) — C-07

    @Test("is deterministic — the same externalId always mints the same transaction id")
    func transactionIdIsDeterministic() {
        let a = CaptureIdentity.transactionId(forExternalId: "abc123")
        let b = CaptureIdentity.transactionId(forExternalId: "abc123")
        #expect(a == b)
    }

    @Test("a re-fired automation (same externalId) mints the same transaction id, not a random one")
    func transactionIdMatchesARefiredAutomation() {
        let date = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let firstExternalId = CaptureIdentity.externalId(card: "card-1", amount: 45000, merchant: "BLUE BOTTLE", at: date)
        let secondExternalId = CaptureIdentity.externalId(
            card: "card-1", amount: 45000, merchant: "BLUE BOTTLE", at: date.addingTimeInterval(5)
        )
        #expect(firstExternalId == secondExternalId)
        #expect(
            CaptureIdentity.transactionId(forExternalId: firstExternalId)
                == CaptureIdentity.transactionId(forExternalId: secondExternalId)
        )
    }

    @Test("a different externalId never collides")
    func transactionIdDiffersForDifferentExternalId() {
        let a = CaptureIdentity.transactionId(forExternalId: "abc123")
        let b = CaptureIdentity.transactionId(forExternalId: "abc124")
        #expect(a != b)
    }

    @Test("sets the RFC 4122 version 5 and variant bits")
    func transactionIdHasV5VersionAndVariantBits() {
        let id = CaptureIdentity.transactionId(forExternalId: "abc123")
        let bytes = id.uuid
        #expect((bytes.6 & 0xF0) == 0x50)
        #expect((bytes.8 & 0xC0) == 0x80)
    }
}
