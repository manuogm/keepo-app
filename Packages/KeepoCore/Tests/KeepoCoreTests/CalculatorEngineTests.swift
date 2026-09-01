import Foundation
import Testing
@testable import KeepoCore

@Suite("Calculator engine")
struct CalculatorEngineTests {
    private func number(_ value: String) -> CalculatorToken {
        .number(Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")) ?? 0)
    }

    @Test("a single number evaluates to itself")
    func singleNumber() {
        #expect(CalculatorEngine.evaluate([number("12.50")]) == Decimal(string: "12.50"))
    }

    @Test("multiplication binds tighter than addition")
    func precedenceIsRespected() {
        // 2 + 3 × 4 is 14, not the 20 a plain left-to-right chain gives.
        let tokens: [CalculatorToken] = [
            number("2"), .operation(.add), number("3"), .operation(.multiply), number("4")
        ]
        #expect(CalculatorEngine.evaluate(tokens) == 14)
    }

    @Test("same-precedence operators evaluate left to right")
    func leftAssociative() {
        // 10 − 3 − 4 is 3; a right-associative fold would give 11.
        let tokens: [CalculatorToken] = [
            number("10"), .operation(.subtract), number("3"), .operation(.subtract), number("4")
        ]
        #expect(CalculatorEngine.evaluate(tokens) == 3)
        // 100 ÷ 5 ÷ 2 is 10, not 40.
        let divisions: [CalculatorToken] = [
            number("100"), .operation(.divide), number("5"), .operation(.divide), number("2")
        ]
        #expect(CalculatorEngine.evaluate(divisions) == 10)
    }

    @Test("money keeps its exact value — the split of a bill that a Double would round")
    func decimalIsExact() {
        // 0.1 + 0.2 is 0.3 exactly in Decimal; in binary floating point it
        // is not, which is the whole reason this runs on Decimal.
        let tokens: [CalculatorToken] = [number("0.1"), .operation(.add), number("0.2")]
        #expect(CalculatorEngine.evaluate(tokens) == Decimal(string: "0.3"))
    }

    @Test("an incomplete expression is nil, never zero")
    func incompleteIsNil() {
        #expect(CalculatorEngine.evaluate([]) == nil)
        #expect(CalculatorEngine.evaluate([number("5"), .operation(.add)]) == nil)
        #expect(CalculatorEngine.evaluate([.operation(.add), number("5")]) == nil)
        #expect(CalculatorEngine.evaluate([number("5"), number("6")]) == nil)
    }

    @Test("dividing by zero is nil rather than a crash or an infinity")
    func divideByZero() {
        #expect(CalculatorEngine.evaluate([number("5"), .operation(.divide), number("0")]) == nil)
        // The zero is only reached after the multiplication collapses to it.
        let tokens: [CalculatorToken] = [
            number("5"), .operation(.divide), number("0"), .operation(.multiply), number("3")
        ]
        #expect(CalculatorEngine.evaluate(tokens) == nil)
    }

    @Test("a negative operand is an operand, not a subtraction")
    func negativeOperand() {
        let tokens: [CalculatorToken] = [number("-40"), .operation(.add), number("100")]
        #expect(CalculatorEngine.evaluate(tokens) == 60)
    }
}

/// The `decimal:` overload of `AmountFormatter.editableString` shares a base
/// name with the `Int64` e4 one. Unlabelled it silently captured every
/// integer-literal call site and reinterpreted an e4 amount as a plain
/// number; these pin that the two stay distinguishable.
@Suite("Editable string overloads")
struct EditableStringOverloadTests {
    private let usLocale = Locale(identifier: "en_US")

    @Test("an e4 amount still scales — the Int64 overload is what a bare number picks")
    func integerLiteralKeepsE4Scaling() {
        #expect(AmountFormatter.editableString(-425_000, minorUnit: 2, locale: usLocale) == "42.50")
    }

    @Test("a Decimal is taken at face value, not rescaled")
    func decimalIsNotRescaled() {
        let value = Decimal(string: "42.50", locale: Locale(identifier: "en_US_POSIX")) ?? 0
        #expect(AmountFormatter.editableString(decimal: value, minorUnit: 2, locale: usLocale) == "42.50")
    }

    @Test("a calculator result round-trips back through AmountParser")
    func roundTripsThroughParser() {
        let result = CalculatorEngine.evaluate([
            .number(Decimal(string: "25", locale: Locale(identifier: "en_US_POSIX")) ?? 0),
            .operation(.divide),
            .number(Decimal(string: "4", locale: Locale(identifier: "en_US_POSIX")) ?? 0)
        ])
        let text = AmountFormatter.editableString(decimal: result ?? 0, minorUnit: 2, locale: usLocale)
        #expect(text == "6.25")
        #expect(AmountParser.parse(text, locale: usLocale) == 62_500)
    }
}
