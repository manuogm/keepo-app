import Foundation
import Testing
@testable import KeepoCore

@Suite("LocalFxConvert")
struct LocalFxConvertTests {
    @Test("same-currency conversion short-circuits, no rate lookup needed")
    func sameCurrencyShortCircuit() {
        #expect(LocalFxConvert.convert(100, from: "USD", to: "USD", rates: [:]) == 100)
    }

    @Test("EUR resolves to a rate of 1 even though it never has a rates entry")
    func eurIsImplicitlyOne() {
        let result = LocalFxConvert.convert(100, from: "EUR", to: "USD", rates: ["USD": 1.1])
        #expect(result == 110)
    }

    @Test("converting between two non-EUR currencies pivots through EUR")
    func pivotsThroughEur() {
        // 100 USD -> EUR at 1.1 USD/EUR -> ~90.909 EUR -> GBP at 0.85 GBP/EUR
        let result = LocalFxConvert.convert(110, from: "USD", to: "GBP", rates: ["USD": 1.1, "GBP": 0.85])
        #expect(result == 85)
    }

    @Test("a missing rate for either currency returns nil, never a wrong number")
    func missingRateReturnsNil() {
        #expect(LocalFxConvert.convert(100, from: "USD", to: "JPY", rates: ["USD": 1.1]) == nil)
        #expect(LocalFxConvert.convert(100, from: "JPY", to: "USD", rates: ["USD": 1.1]) == nil)
    }
}
