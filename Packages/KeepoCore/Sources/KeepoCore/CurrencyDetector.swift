import Foundation

/// Reads the currency out of Wallet's machine-formatted `Amount` string —
/// "€50.00", "1,06 US$", "CHF 10.00" — so a purchase charged in a currency
/// other than the account's can be recognised instead of silently recorded
/// as if it were in the account's (money rule 6).
///
/// **It does not carry a symbol table, and that is the design.** A
/// hand-written `$ → USD` map is a guess about what some formatter meant;
/// this inverts *the same table Foundation used to produce the string*,
/// restricted to the currencies Keepo actually supports. A symbol resolves
/// only when exactly one supported currency could have produced it, so the
/// ambiguity rule is **derived rather than asserted** — which matters,
/// because the honest answer changes by device:
///
/// - On a British, German or Spanish phone, `$` is unambiguously USD:
///   those locales write `CA$`, `A$` and `MX$` for the other dollars.
/// - On an Australian, Canadian, Singaporean, New Zealand or Mexican
///   phone, `$` means the **local** dollar, and there is no way to tell it
///   from a US one. Detection returns `nil` and the capture falls back to
///   the account's currency, exactly as before this existed.
/// - `¥` is JPY almost everywhere and CNY on a Chinese phone, so it
///   resolves there too — to nothing.
///
/// The device's own table is unioned with `en_US`'s, because the string was
/// not necessarily formatted by this device: **a disagreement between the
/// two is itself a reason not to act.** That union is what turns `$` on an
/// Australian phone into "don't know" rather than a coin flip between two
/// real answers.
///
/// Wrong here is expensive — it would convert an amount that never needed
/// converting — and silence is cheap, because silence is the behaviour
/// that shipped for a year. So every uncertain case returns `nil`.
public enum CurrencyDetector {
    /// - Parameter supported: the codes in the `currencies` reference
    ///   table. Restricting to them is what makes detection possible at
    ///   all — inverted over every ISO currency, `$` names dozens.
    /// - Returns: the detected code, or `nil` when the string names no
    ///   supported currency **or** names more than one. The caller must
    ///   treat `nil` as "use the account's currency", never as an error.
    public static func detect(in text: String, supported: [String], locale: Locale = .current) -> String? {
        let codes = supported.map { $0.uppercased() }
        guard !codes.isEmpty else { return nil }

        // An explicit ISO code wins outright, and it is not a rare case:
        // Spanish and Swedish phones render most foreign currencies as the
        // bare code ("1,06 CAD", "SEK 1,06"), and a code cannot be
        // ambiguous with anything.
        let spelled = codes.filter { contains(code: $0, in: text) }
        if spelled.count == 1 { return spelled[0] }
        if spelled.count > 1 { return nil }

        // Longest match first, so `US$` beats the `$` inside it and `R$`
        // (Brazil) beats the `R` (South Africa) inside it.
        let table = symbolTable(for: codes, locale: locale)
        let matches = table.keys
            .filter { text.localizedCaseInsensitiveContains($0) }
            .sorted { $0.count > $1.count }
        guard let symbol = matches.first, let owners = table[symbol], owners.count == 1 else { return nil }
        return owners.first
    }

    /// Standalone-letters only, so a code can never be found inside a
    /// longer run of letters.
    private static func contains(code: String, in text: String) -> Bool {
        text.range(of: "(?<![A-Za-z])\(code)(?![A-Za-z])", options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Symbol → the supported currencies that render as it, across the
    /// device's locale and `en_US`.
    ///
    /// Built fresh rather than cached: this runs once per captured
    /// purchase, where three dozen `NumberFormatter`s cost a few
    /// milliseconds in a background App Intent. `FormatterCache` exists for
    /// the opposite shape — a formatter rebuilt hundreds of times a second
    /// inside a scrolling list — and putting these in it would retain two
    /// formatters per supported currency forever to save nothing.
    private static func symbolTable(for codes: [String], locale: Locale) -> [String: Set<String>] {
        var table: [String: Set<String>] = [:]
        for tableLocale in [locale, Locale(identifier: "en_US")] {
            for code in codes {
                let formatter = NumberFormatter()
                formatter.numberStyle = .currency
                formatter.locale = tableLocale
                formatter.currencyCode = code
                guard let symbol = formatter.currencySymbol, !symbol.isEmpty else { continue }
                table[symbol, default: []].insert(code)
            }
        }
        return table
    }
}
