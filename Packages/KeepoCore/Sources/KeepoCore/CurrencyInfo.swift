import Foundation

/// Mirrors a row in the `currencies` reference table.
public struct CurrencyInfo: Sendable, Equatable {
    public let code: String
    public let minorUnit: Int

    public init(code: String, minorUnit: Int) {
        self.code = code
        self.minorUnit = minorUnit
    }
}
