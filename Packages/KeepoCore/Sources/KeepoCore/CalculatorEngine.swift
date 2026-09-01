import Foundation

/// One arithmetic step in the amount field's pop-up calculator.
///
/// The raw values are the glyphs the keypad draws — a real minus sign and a
/// real multiplication sign, not the hyphen and the letter x — because they
/// are also what the expression line shows the user.
public enum CalculatorOperator: String, Sendable, CaseIterable {
    case add = "+"
    case subtract = "−"
    case multiply = "×"
    case divide = "÷"

    /// Multiplication and division bind tighter, so `2 + 3 × 4` is 14 rather
    /// than 20. A chain calculator that ignored this would quietly disagree
    /// with every other calculator the user has ever used.
    var precedence: Int {
        switch self {
        case .multiply, .divide: return 2
        case .add, .subtract: return 1
        }
    }
}

public enum CalculatorToken: Equatable, Sendable {
    case number(Decimal)
    case operation(CalculatorOperator)
}

/// Evaluates the flat token list a calculator keypad produces.
///
/// `Decimal` throughout, never `Double`: this feeds a money field, and a
/// binary float has already lost the value by the time it exists. It is not
/// a breach of the "all money arithmetic in SQL" rule either — nothing here
/// derives a balance, a total or a conversion from stored data. It is the
/// user's own scratch arithmetic on the way to deciding what to type, and
/// the result is a *typed amount* like any other, parsed back through
/// `AmountParser` when the form saves.
public enum CalculatorEngine {
    /// - Returns: `nil` for anything that is not a complete expression — no
    ///   input at all, a trailing operator, a division by zero. Never `0`:
    ///   the caller has to be able to tell "nothing to use yet" from "the
    ///   answer is zero" (money rule 5).
    public static func evaluate(_ tokens: [CalculatorToken]) -> Decimal? {
        var values: [Decimal] = []
        var operators: [CalculatorOperator] = []
        // Alternation is the only grammar this has to enforce: a keypad
        // cannot produce parentheses, so number-operator-number forever is
        // the whole language.
        var expectsNumber = true

        for token in tokens {
            switch token {
            case .number(let value):
                guard expectsNumber else { return nil }
                values.append(value)
                expectsNumber = false
            case .operation(let next):
                guard !expectsNumber else { return nil }
                while let pending = operators.last, pending.precedence >= next.precedence {
                    guard reduce(&values, &operators) else { return nil }
                }
                operators.append(next)
                expectsNumber = true
            }
        }

        guard !expectsNumber else { return nil }
        while !operators.isEmpty {
            guard reduce(&values, &operators) else { return nil }
        }
        return values.count == 1 ? values.first : nil
    }

    private static func reduce(_ values: inout [Decimal], _ operators: inout [CalculatorOperator]) -> Bool {
        guard let operation = operators.popLast(), values.count >= 2 else { return false }
        let right = values.removeLast()
        let left = values.removeLast()
        guard let result = apply(operation, left, right) else { return false }
        values.append(result)
        return true
    }

    private static func apply(_ operation: CalculatorOperator, _ left: Decimal, _ right: Decimal) -> Decimal? {
        switch operation {
        case .add: return left + right
        case .subtract: return left - right
        case .multiply: return left * right
        case .divide: return right == 0 ? nil : left / right
        }
    }
}
