import Foundation
import Testing
@testable import KeepoCore

@Suite("MerchantNormalizer")
struct MerchantNormalizerTests {
    @Test("strips Square's aggregator prefix", arguments: [
        "SQ *BLUE BOTTLE COFFEE",
        "SQ*BLUE BOTTLE COFFEE"
    ])
    func stripsSquarePrefix(raw: String) {
        #expect(MerchantNormalizer.normalize(raw) == "BLUE BOTTLE COFFEE")
    }

    @Test("strips Toast's aggregator prefix")
    func stripsToastPrefix() {
        #expect(MerchantNormalizer.normalize("TST* Rosa's Pizzeria") == "ROSA'S PIZZERIA")
    }

    @Test("strips a trailing numeric store number")
    func stripsTrailingStoreNumber() {
        #expect(MerchantNormalizer.normalize("TARGET 00123") == "TARGET")
        #expect(MerchantNormalizer.normalize("TARGET #4821") == "TARGET")
    }

    @Test("does not strip a short trailing number that isn't a store id")
    func keepsShortTrailingNumber() {
        #expect(MerchantNormalizer.normalize("SHELL OIL 66") == "SHELL OIL 66")
    }

    @Test("strips a corporate suffix", arguments: [
        ("ACME LLC", "ACME"),
        ("WIDGETS INC", "WIDGETS"),
        ("WIDGETS INC.", "WIDGETS"),
        ("GLOBAL CORP", "GLOBAL"),
        ("MAIN ST LTD", "MAIN ST")
    ])
    func stripsCorporateSuffix(raw: String, expected: String) {
        #expect(MerchantNormalizer.normalize(raw) == expected)
    }

    @Test("combines a prefix, a store number, and a suffix in one pass")
    func combinesAllThree() {
        #expect(MerchantNormalizer.normalize("SQ *WIDGETS LLC 00042") == "WIDGETS")
    }

    @Test("collapses internal whitespace and uppercases")
    func collapsesWhitespaceAndUppercases() {
        #expect(MerchantNormalizer.normalize("  blue   bottle  coffee  ") == "BLUE BOTTLE COFFEE")
    }

    @Test("a merchant with no noise normalizes to its own uppercased self")
    func plainMerchantUnchanged() {
        #expect(MerchantNormalizer.normalize("Whole Foods Market") == "WHOLE FOODS MARKET")
    }

    @Test("is stable — normalizing an already-normalized string is a no-op")
    func isIdempotent() {
        let once = MerchantNormalizer.normalize("SQ *Blue Bottle Coffee 00042 LLC")
        let twice = MerchantNormalizer.normalize(once)
        #expect(once == twice)
    }
}
