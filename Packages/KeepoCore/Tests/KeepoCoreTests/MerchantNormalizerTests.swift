import Foundation
import Testing
@testable import KeepoCore

@Suite("MerchantNormalizer")
struct MerchantNormalizerTests {
    @Test("strips an aggregator prefix whatever the spacing around the star", arguments: [
        "SQ *BLUE BOTTLE COFFEE",
        "SQ*BLUE BOTTLE COFFEE",
        "SQ * BLUE BOTTLE COFFEE",
        "sq *Blue Bottle Coffee"
    ])
    func stripsAggregatorPrefix(raw: String) {
        #expect(MerchantNormalizer.normalize(raw) == "BLUE BOTTLE COFFEE")
    }

    @Test("strips Toast's aggregator prefix")
    func stripsToastPrefix() {
        #expect(MerchantNormalizer.normalize("TST* Rosa's Pizzeria") == "ROSA'S PIZZERIA")
    }

    /// The defect this rewrite exists for: real Square output is
    /// `SQ * Equity Park,Llc`, and the three spellings one shop produces
    /// used to become three `merchant_category_map` keys — so a category
    /// learned under one never matched the next.
    @Test("the three real spellings of one shop collapse to one key", arguments: [
        "SQ * Equity Park,Llc",
        "SQ *EQUITY PARK LLC",
        "SQ * Equity Park, LLC",
        "SQ *EQUITY PARK 00042 LLC"
    ])
    func oneShopOneKey(raw: String) {
        #expect(MerchantNormalizer.normalize(raw) == "EQUITY PARK")
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

    @Test("strips a corporate suffix across the supported currencies' countries", arguments: [
        ("ACME LLC", "ACME"),
        ("WIDGETS INC", "WIDGETS"),
        ("WIDGETS INC.", "WIDGETS"),
        ("GLOBAL CORP", "GLOBAL"),
        ("MAIN ST LTD", "MAIN ST"),
        ("SUMUP *CAFE BERLIN GmbH", "CAFE BERLIN"),
        ("TIENDA MADRID S.L.", "TIENDA MADRID"),
        ("BAR ROMA S.R.L.", "BAR ROMA"),
        ("PADARIA LISBOA LDA", "PADARIA LISBOA"),
        ("MERCADO CDMX S.A. DE C.V.", "MERCADO CDMX"),
        ("PADARIA SP LTDA", "PADARIA SP"),
        ("BOULANGERIE PARIS SARL", "BOULANGERIE PARIS"),
        ("WINKEL AMSTERDAM B.V.", "WINKEL AMSTERDAM"),
        ("KAVARNA PRAHA S.R.O.", "KAVARNA PRAHA"),
        ("SKLEP WARSZAWA SP. Z O.O.", "SKLEP WARSZAWA"),
        ("ETTEREM BUDAPEST KFT", "ETTEREM BUDAPEST"),
        ("KAFE ISTANBUL LTD. ŞTI.", "KAFE ISTANBUL"),
        ("BUTIK OSLO A/S", "BUTIK OSLO"),
        ("KAFFE KOBENHAVN APS", "KAFFE KOBENHAVN"),
        ("KAUPPA HELSINKI OYJ", "KAUPPA HELSINKI"),
        ("KEDAI KL SDN BHD", "KEDAI KL"),
        ("HAWKER SG PTE LTD", "HAWKER SG"),
        ("CHAI MUMBAI PVT LTD", "CHAI MUMBAI"),
        ("SHANGHAI TEA CO., LTD.", "SHANGHAI TEA")
    ])
    func stripsCorporateSuffix(raw: String, expected: String) {
        #expect(MerchantNormalizer.normalize(raw) == expected)
    }

    /// Alternation is first-match-wins, so a shorter suffix contained in a
    /// longer one has to lose. With `LTD` ahead of `PTY LTD` this café
    /// normalizes to `BONDI CAFE PTY` — which is why the lists are sorted
    /// longest-first where the pattern is assembled, not by hand.
    @Test("a longer suffix beats the shorter one inside it", arguments: [
        ("BONDI CAFE PTY LTD", "BONDI CAFE"),
        ("JOZI STORE (PTY) LTD", "JOZI STORE"),
        ("TOKYO RAMEN CO., LTD.", "TOKYO RAMEN")
    ])
    func longestSuffixWins(raw: String, expected: String) {
        #expect(MerchantNormalizer.normalize(raw) == expected)
    }

    @Test("strips a company form that leads the name instead of trailing it", arguments: [
        ("PT SUMBER REJEKI", "SUMBER REJEKI"),
        ("PT. SUMBER REJEKI", "SUMBER REJEKI"),
        ("CV MAJU JAYA", "MAJU JAYA"),
        ("株式会社ローソン", "ローソン"),
        ("ローソン株式会社", "ローソン"),
        ("(주)카카오", "카카오")
    ])
    func stripsCompanyPrefix(raw: String, expected: String) {
        #expect(MerchantNormalizer.normalize(raw) == expected)
    }

    /// Punctuation inside a name is identity, not a separator — which is
    /// the whole reason blanket punctuation stripping was rejected: it
    /// collides `M&S` with `MS` and `H&M` with `HM`, and still fails to
    /// match `AT&T` against `AT AND T`.
    @Test("punctuation inside a name is left alone", arguments: [
        "AT&T", "JOE'S PIZZA", "H&M", "M&S", "BEN & JERRY'S"
    ])
    func keepsInternalPunctuation(raw: String) {
        #expect(MerchantNormalizer.normalize(raw) == raw.uppercased())
    }

    @Test("collapses internal whitespace and uppercases")
    func collapsesWhitespaceAndUppercases() {
        #expect(MerchantNormalizer.normalize("  blue   bottle  coffee  ") == "BLUE BOTTLE COFFEE")
    }

    @Test("a merchant with no noise normalizes to its own uppercased self")
    func plainMerchantUnchanged() {
        #expect(MerchantNormalizer.normalize("Whole Foods Market") == "WHOLE FOODS MARKET")
    }

    /// A two-letter state code is what a US card descriptor routinely ends
    /// in, so bare two-letter company forms stay out of the list on purpose.
    @Test("a bare two-letter company form is not stripped", arguments: [
        "PORTLAND ROASTERS OR", "STOCKHOLM KAFE AB", "ZURICH BAR AG", "AUSTIN TACOS TX"
    ])
    func keepsTwoLetterTrailingTokens(raw: String) {
        #expect(MerchantNormalizer.normalize(raw) == raw)
    }

    /// `CO` is the one deliberate exception to that rule, kept at the
    /// user's instruction. The cost is admitted rather than hidden: a shop
    /// genuinely called `LUCKY CO` collapses onto one called `LUCKY`.
    @Test("CO is stripped, and its known collision is accepted")
    func stripsCoSuffix() {
        #expect(MerchantNormalizer.normalize("BROOKLYN BREWING CO") == "BROOKLYN BREWING")
        #expect(MerchantNormalizer.normalize("LUCKY CO") == MerchantNormalizer.normalize("LUCKY"))
    }

    /// Bare `SPA` is excluded for the mirror-image reason.
    @Test("a nail salon is not an Italian S.p.A.")
    func keepsSpa() {
        #expect(MerchantNormalizer.normalize("SERENITY NAIL SPA") == "SERENITY NAIL SPA")
    }

    @Test("is stable — normalizing an already-normalized string is a no-op", arguments: [
        "SQ *Blue Bottle Coffee 00042 LLC",
        "SQ * Equity Park,Llc",
        "BONDI CAFE PTY LTD",
        "PT SUMBER REJEKI",
        "株式会社ローソン",
        "AT&T",
        "SHANGHAI TEA CO., LTD."
    ])
    func isIdempotent(raw: String) {
        let once = MerchantNormalizer.normalize(raw)
        #expect(MerchantNormalizer.normalize(once) == once)
    }

    /// The documented contract, which the previous implementation quietly
    /// broke: `SQ *` is entirely noise and used to normalize to an empty
    /// string, which would have been stored as a merchant key.
    @Test("never returns empty for non-empty input", arguments: ["SQ *", "LLC", "***"])
    func neverEmpty(raw: String) {
        #expect(!MerchantNormalizer.normalize(raw).isEmpty)
    }
}
